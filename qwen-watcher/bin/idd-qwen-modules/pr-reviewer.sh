#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# idd-qwen PR Reviewer Module (#8)
#   PR 自動レビュー: レビュー結果コメント投稿 / VERDICT 検出 / ラベル付与
#   出典: idd-codex/local-watcher/bin/idd-codex-modules/pr-reviewer.sh
#   差分: codex CLI → Qwen Code CLI、agent 名 "codex" → "qwen"
#         quota management / claude second gate は未実装（stub）
# ─────────────────────────────────────────────────────────────────────────────

# ロガー（core_utils.sh から import 済み前提）
pr_log()    { log_info "[pr-reviewer] $*"; }
pr_warn()   { log_warn "[pr-reviewer] $*"; }
pr_error()  { log_error "[pr-reviewer] $*"; }

# ─── Config（外部 env で上書き可能、既定値は安全側）────────────────────────────

PR_REVIEWER_ENABLED="${PR_REVIEWER_ENABLED:-false}"
PR_REVIEWER_TOOL="${PR_REVIEWER_TOOL:-}"
PR_REVIEWER_CODEX_ENABLED="${PR_REVIEWER_CODEX_ENABLED:-false}"
PR_REVIEWER_ANTIGRAVITY_ENABLED="${PR_REVIEWER_ANTIGRAVITY_ENABLED:-false}"

# codex CLI 実行コマンド（sandbox read-only 固定）
PR_REVIEWER_CODEX_CMD="${PR_REVIEWER_CODEX_CMD:-qwen exec --sandbox read-only \"\$(cat '{PROMPT_FILE}')\"}"

# antigravity (agy) CLI 実行コマンド（JSON 出力形式）
PR_REVIEWER_ANTIGRAVITY_CMD="${PR_REVIEWER_ANTIGRAVITY_CMD:-agy -p \"\$(cat '{PROMPT_FILE}')\" --output-format json}"

# レビュー指示プロンプト本体（空なら内蔵 default 使用）
PR_REVIEWER_PROMPT="${PR_REVIEWER_PROMPT:-}"

# 認証チェックコマンド
PR_REVIEWER_CODEX_AUTH_CMD="${PR_REVIEWER_CODEX_AUTH_CMD:-qwen status}"
PR_REVIEWER_ANTIGRAVITY_AUTH_CMD="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD:-}"

# VERDICT 検出パターン（iteration keyword）
PR_REVIEWER_ITERATION_PATTERN="${PR_REVIEWER_ITERATION_PATTERN:-^[[:space:]]*VERDICT:[[:space:]]*codex-needs-iteration[[:space:]]*$}"

# head branch pattern（候補 PR 選択用）
PR_REVIEWER_HEAD_PATTERN="${PR_REVIEWER_HEAD_PATTERN:-^codex/}"

# 最大処理 PR 数
PR_REVIEWER_MAX_PRS="${PR_REVIEWER_MAX_PRS:-5}"

# git 操作タイムアウト（秒）
PR_REVIEWER_GIT_TIMEOUT="${PR_REVIEWER_GIT_TIMEOUT:-120}"

# 実行タイムアウト（秒）
PR_REVIEWER_EXEC_TIMEOUT="${PR_REVIEWER_EXEC_TIMEOUT:-600}"

# commit status publish gate（AND 二重 opt-in）
PR_REVIEWER_STATUS_CHECK_ENABLED="${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}"
case "$PR_REVIEWER_STATUS_CHECK_ENABLED" in
  true|false) : ;;
  *)    PR_REVIEWER_STATUS_CHECK_ENABLED="false" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_tool: tool 解決（codex / antigravity / none / conflict）
#   戻り値: 0 = codex|antigravity / 1 = conflict / 2 = none
#   出力: stdout に tool 名
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_tool() {
  local codex_enabled=0 antigravity_enabled=0

  if [ -n "$PR_REVIEWER_TOOL" ]; then
    case "$PR_REVIEWER_TOOL" in
      codex)       codex_enabled=1 ;;
      antigravity) antigravity_enabled=1 ;;
      *)           pr_warn "未知の tool 指定: '${PR_REVIEWER_TOOL}'" ;;
    esac
  fi

  if [ "$PR_REVIEWER_CODEX_ENABLED" = "true" ]; then
    codex_enabled=1
  fi
  if [ "$PR_REVIEWER_ANTIGRAVITY_ENABLED" = "true" ]; then
    antigravity_enabled=1
  fi

  if [ "$codex_enabled" -eq 1 ] && [ "$antigravity_enabled" -eq 1 ]; then
    pr_warn "codex と antigravity の両方が有効（排他エラー）"
    return 1
  fi
  if [ "$codex_enabled" -eq 1 ]; then
    printf 'codex'
    return 0
  fi
  if [ "$antigravity_enabled" -eq 1 ]; then
    printf 'antigravity'
    return 0
  fi

  # 明示指定なし → 利用可能ツールを自動検出
  if command -v qwen >/dev/null 2>&1; then
    printf 'codex'
    return 0
  fi
  if command -v agy >/dev/null 2>&1; then
    printf 'antigravity'
    return 0
  fi

  pr_log "利用可能なレビューツールがありません（qwen / agy 両方不在）"
  return 2
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_installed: ツールが PATH 上にあるか
#   入力: $1 = tool 名 (codex|antigravity)
#   戻り値: 0 = あり / 1 = 不在
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_installed() {
  local tool="$1"
  case "$tool" in
    codex)
      if command -v qwen >/dev/null 2>&1; then
        return 0
      fi
      ;;
    antigravity)
      if command -v agy >/dev/null 2>&1; then
        return 0
      fi
      ;;
  esac
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_authenticated: ツールが認証済みか
#   入力: $1 = tool 名
#   戻り値: 0 = ok / 1 = not-authenticated / 2 = check 無効（env 空 = skip）
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_authenticated() {
  local tool="$1"
  local auth_cmd=""

  case "$tool" in
    codex)       auth_cmd="${PR_REVIEWER_CODEX_AUTH_CMD}" ;;
    antigravity) auth_cmd="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD}" ;;
  esac

  if [ -z "$auth_cmd" ]; then
    pr_log "PR Reviewer: ${tool} 認証チェックスキップ（auth cmd 未設定）"
    return 2
  fi

  if bash -c "$auth_cmd" >/dev/null 2>&1; then
    pr_log "PR Reviewer: ${tool} 認証チェック result=ok"
    return 0
  fi

  pr_log "PR Reviewer: ${tool} 認証チェック result=not-authenticated"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_marker: hidden marker 生成
#   入力: $1=sha $2=kind $3=tool
#   出力: marker 文字列
# ─────────────────────────────────────────────────────────────────────────────
pr_build_marker() {
  local sha="$1" kind="$2" tool="${3:-none}"
  printf '<!-- idd-qwen:pr-reviewer kind=%s sha=%s tool=%s -->' "$kind" "$sha" "$tool"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_already_processed: 同一 (sha, kind) の comment が既存か
#   入力: $1=pr_number $2=sha $3=kind
#   戻り値: 0 = 既存 / 1 = 新規
# ─────────────────────────────────────────────────────────────────────────────
pr_already_processed() {
  local pr_number="$1" sha="$2" kind="$3"
  local comments_json marker

  marker=$(pr_build_marker "$sha" "$kind" "none")

  if ! comments_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    return 1
  fi

  if printf '%s' "$comments_json" | jq -e --arg m "$marker" \
      '[.[]?.body // "" | select(test($m))] | length > 0' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_fetch_candidate_prs: レビュー対象 PR を列挙（jq 配列）
#   条件: open / non-draft / head=${PR_REVIEWER_HEAD_PATTERN} / non-fork
#   戻り値: 0 固定（jq 配列を stdout）
# ─────────────────────────────────────────────────────────────────────────────
pr_fetch_candidate_prs() {
  local prs_json

  prs_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr list \
      --repo "$REPO" \
      --state open \
      --json number,title,url,state,headRefName,baseRefName,headRefOid,isDraft,isCrossRepository \
      2>/dev/null || echo "[]")

  # draft 除外 / fork 除外 / head pattern 一致 / base branch 一致
  printf '%s' "$prs_json" | jq -c --arg pattern "$PR_REVIEWER_HEAD_PATTERN" \
      --arg base "$BASE_BRANCH" '
    [ .[] | select(
      .isDraft == false and
      .isCrossRepository == false and
      (.headRefName | test($pattern)) and
      (.baseRefName == $base or .baseRefName == "")
    ) ]
  ' 2>/dev/null || echo "[]"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_default_prompt: 内蔵 default レビュー指示プロンプト
# ─────────────────────────────────────────────────────────────────────────────
pr_default_prompt() {
  cat <<'PROMPT'
You are a senior PR reviewer. Review the following PR and provide your assessment.

Base branch: {BASE}
Head branch: {HEAD}
PR: #{PR}

Read the diff carefully and evaluate:
1. Does the implementation meet the requirements?
2. Are there any boundary violations?
3. Is the code quality acceptable?

Output your verdict at the end of your review:
- For approval: VERDICT: approve
- For iteration needed: VERDICT: codex-needs-iteration

PROMPT
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_prompt_file: prompt tempfile 生成 + プレースホルダ置換
#   入力: $1=pr_number $2=base_ref $3=head_ref
#   出力: tempfile path（caller が rm する）
#   戻り値: 0 = ok / 1 = 失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_build_prompt_file() {
  local pr_number="$1" base_ref="$2" head_ref="$3"
  local prompt_file prompt_text

  if ! prompt_file=$(idd_secure_mktemp "pr-reviewer-prompt-${pr_number}"); then
    return 1
  fi

  # custom prompt がある場合はそれを使用、なければ default
  if [ -n "$PR_REVIEWER_PROMPT" ]; then
    prompt_text="$PR_REVIEWER_PROMPT"
  else
    prompt_text=$(pr_default_prompt)
  fi

  # プレースホルダ置換（{BASE}/{HEAD}/{PR}/{PROMPT_FILE}）
  prompt_text="${prompt_text//\{BASE\}/$base_ref}"
  prompt_text="${prompt_text//\{HEAD\}/$head_ref}"
  prompt_text="${prompt_text//\{PR\}/$pr_number}"
  prompt_text="${prompt_text//\{PROMPT_FILE\}/$prompt_file}"

  printf '%s\n' "$prompt_text" > "$prompt_file"
  printf '%s' "$prompt_file"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_substitute_placeholders: コマンドテンプレートのプレースホルダ置換 + unsafe 検査
#   入力: $1=template $2=base_ref $3=head_ref $4=pr_number $5=prompt_file
#   出力: 置換済みコマンド（stdout）
#   戻り値: 0 = ok / 1 = unsafe value 検出
# ─────────────────────────────────────────────────────────────────────────────
pr_substitute_placeholders() {
  local template="$1" base_ref="$2" head_ref="$3" pr_number="$4" prompt_file="$5"

  # unsafe value 検査（コマンドインジェクション防止）
  for value in "$base_ref" "$head_ref" "$pr_number" "$prompt_file"; do
    if [[ "$value" =~ [\;\|\&\`\$\(\)] ]]; then
      pr_warn "unsafe value 検出: '${value}'"
      return 1
    fi
  done

  local resolved="$template"
  resolved="${resolved//\{BASE\}/$base_ref}"
  resolved="${resolved//\{HEAD\}/$head_ref}"
  resolved="${resolved//\{PR\}/$pr_number}"
  resolved="${resolved//\{PROMPT_FILE\}/$prompt_file}"

  printf '%s' "$resolved"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_execute_review_command: head checkout + レビュー実行 + read-only 検査
#   入力: $1=head_ref $2=resolved_cmd $3=tool $4=out_file $5=err_file $6=result_file
#   戻り値: 0 固定（結果判定は result_file 経由）
# ─────────────────────────────────────────────────────────────────────────────
pr_execute_review_command() {
  local head_ref="$1"
  local resolved_cmd="$2"
  local tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  : > "$out_file"
  : > "$err_file"
  : > "$result_file"

  (
    set +e
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の git fetch に失敗"
      printf 'fetch-fail\n' > "$result_file"
      exit 0
    fi
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の checkout に失敗"
      printf 'checkout-fail\n' > "$result_file"
      exit 0
    fi

    # レビュー実行（eval 不使用、subshell に閉じ込める）
    local exec_rc=0
    timeout "$PR_REVIEWER_EXEC_TIMEOUT" bash -c "$resolved_cmd" >"$out_file" 2>"$err_file" || exec_rc=$?

    # read-only invariant 検査
    local wsmod="clean"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git checkout -- . >/dev/null 2>&1 || true
      wsmod="modified"
    fi
    printf 'ran:%s:%s\n' "$exec_rc" "$wsmod" > "$result_file"
    exit 0
  )

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_review_comment: レビュー結果コメントを投稿
#   入力: $1=pr_number $2=sha $3=review_text $4=tool
#   戻り値: 0 = ok / 1 = 投稿失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_post_review_comment() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local marker body
  marker=$(pr_build_marker "$sha" "review" "$tool")
  body=$(printf '%s\n\n%s' "$review_text" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: レビュー結果コメントの投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: レビュー結果コメント投稿 kind=review tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_error_comment: エラーコメントを投稿
#   入力: $1=pr_number $2=sha $3=kind $4=detail $5=tool
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_post_error_comment() {
  local pr_number="$1"
  local sha="$2"
  local kind="$3"
  local detail="$4"
  local tool="${5:-none}"

  # 同一 (sha, kind) が既存なら再投稿しない（冪等）
  if pr_already_processed "$pr_number" "$sha" "$kind"; then
    pr_log "PR #${pr_number}: kind=${kind} sha=${sha} のエラーコメントは既存のため再投稿しません"
    return 0
  fi

  local marker body
  marker=$(pr_build_marker "$sha" "$kind" "$tool")
  body=$(printf '## 自動レビューエラー\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: エラーコメント (kind=${kind}) の投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: エラーコメント投稿 kind=${kind} tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_iteration_keyword: レビュー結果から VERDICT token を検出
#   入力: $1=pr_number $2=review_text
#   出力: stdout にマッチ件数（整数）
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_iteration_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern="${PR_REVIEWER_ITERATION_PATTERN}"

  local count
  count=$(printf '%s' "$review_text" | grep -E -i -c "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: iteration keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_approval_keyword: レビュー結果から approve VERDICT token を検出
#   入力: $1=pr_number $2=review_text
#   出力: stdout にマッチ件数（整数）
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_approval_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern='^[[:space:]]*VERDICT:[[:space:]]*approve[[:space:]]*$'

  local count
  count=$(printf '%s' "$review_text" | grep -E -i -c "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: approve keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_review_verdict: review_text から approve / iteration / none / conflict
#   入力: $1=pr_number $2=review_text
#   出力: stdout に approve | iteration | none | conflict
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_review_verdict() {
  local pr_number="$1"
  local review_text="$2"

  local approve_count iteration_count
  approve_count=$(pr_detect_approval_keyword "$pr_number" "$review_text")
  iteration_count=$(pr_detect_iteration_keyword "$pr_number" "$review_text")
  approve_count="${approve_count:-0}"
  iteration_count="${iteration_count:-0}"

  if [ "$approve_count" -gt 0 ] 2>/dev/null && [ "$iteration_count" -gt 0 ] 2>/dev/null; then
    pr_warn "PR #${pr_number}: approve と iteration の VERDICT が混在しています"
    printf 'conflict'
    return 0
  fi
  if [ "$iteration_count" -gt 0 ] 2>/dev/null; then
    printf 'iteration'
    return 0
  fi
  if [ "$approve_count" -gt 0 ] 2>/dev/null; then
    printf 'approve'
    return 0
  fi
  printf 'none'
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_try_post_formal_approval: approve verdict を GitHub formal review として投稿
#   入力: $1=pr_number $2=sha $3=review_text $4=tool
#   戻り値: 0 = 成功 / 1 = 失敗（非致命、fallback 継続）
# ─────────────────────────────────────────────────────────────────────────────
pr_try_post_formal_approval() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local body_file err_file
  if ! body_file=$(idd_secure_mktemp "pr-reviewer-approval-body-${pr_number}"); then
    pr_warn "PR #${pr_number}: formal approval body 一時ファイルの作成に失敗"
    return 1
  fi
  if ! err_file=$(idd_secure_mktemp "pr-reviewer-approval-stderr-${pr_number}"); then
    rm -f "$body_file"
    pr_warn "PR #${pr_number}: formal approval stderr 一時ファイルの作成に失敗"
    return 1
  fi

  printf '%s\n' "$review_text" > "$body_file"

  if timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr review "$pr_number" --repo "$REPO" --approve --body-file "$body_file" >/dev/null 2>"$err_file"; then
    rm -f "$body_file" "$err_file"
    pr_log "PR #${pr_number}: GitHub formal approval を投稿 tool=${tool} sha=${sha}"
    return 0
  fi

  rm -f "$body_file" "$err_file"
  pr_warn "PR #${pr_number}: GitHub formal approval 投稿に失敗（権限/self-review/API 制約または timeout）。marker approval fallback を継続 tool=${tool} sha=${sha}"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_add_iteration_label: codex-needs-iteration ラベルを付与
#   入力: $1=pr_number
#   戻り値: 0 = ok / 1 = 付与失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_add_iteration_label() {
  local pr_number="$1"
  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_ITERATION" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルの付与に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルを付与"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_status_check_enabled: commit status publish gate
#   戻り値: 0 = 両 gate ON / 1 = いずれか OFF
# ─────────────────────────────────────────────────────────────────────────────
pr_status_check_enabled() {
  if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  if [ "${FULL_AUTO_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_commit_status: commit status を publish（#98 移植）
#   入力: $1=pr_number $2=sha $3=context $4=state $5=description $6=target_url
#   戻り値: 0=成功 / 1=gate OFF / 2=入力検証失敗 / 3=API 失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_commit_status() {
  local pr_number="$1" sha="$2" context="$3" state="$4" description="$5" target_url="${6:-}"

  if ! pr_status_check_enabled; then
    return 1
  fi

  # 入力検証
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pr_warn "commit status publish: 不正な pr_number='${pr_number}'"; return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    pr_warn "commit status publish: 不正な sha='${sha}'"; return 2
  fi
  case "$state" in
    success|failure|pending|error) : ;;
    *) pr_warn "commit status publish: 不正な state='${state}'"; return 2 ;;
  esac

  # description 整形（72 字超切り詰め）
  if [ -z "$description" ]; then
    description="${context}: ${state}"
  fi
  if [ "${#description}" -gt 72 ]; then
    description="${description:0:72}"
  fi

  local err_file api_rc=0
  err_file=$(idd_secure_mktemp "pr-status-${pr_number}" 2>/dev/null || true)
  if [ -n "$err_file" ]; then
    timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api -X POST \
        "repos/${REPO}/statuses/${sha}" \
        -f "state=$state" -f "context=$context" -f "description=$description" \
        >/dev/null 2>"$err_file" || api_rc=$?
  else
    timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api -X POST \
        "repos/${REPO}/statuses/${sha}" \
        -f "state=$state" -f "context=$context" -f "description=$description" \
        >/dev/null 2>&1 || api_rc=$?
  fi

  if [ "$api_rc" -ne 0 ]; then
    pr_warn "commit status publish FAILED: pr=#${pr_number} context=${context} state=${state} rc=${api_rc}"
    return 3
  fi
  [ -n "$err_file" ] && rm -f "$err_file"
  pr_log "commit status published: pr=#${pr_number} context=${context} state=${state}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_codex_status: codex Reviewer の verdict を codex-review status へ写す
#   入力: $1=pr_number $2=sha $3=verdict $4=pr_url
#   戻り値: pr_publish_commit_status の戻り値をそのまま返す
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_codex_status() {
  local pr_number="$1" sha="$2" verdict="$3" pr_url="${4:-}"
  local state description
  case "$verdict" in
    approve) state="success"; description="qwen: approve" ;;
    *)       state="failure"; description="qwen: ${verdict}" ;;
  esac
  pr_publish_commit_status "$pr_number" "$sha" "qwen-review" "$state" "$description" "$pr_url"
}

# ═════════════════════════════════════════════════════════════════════════════
# Stub: Quota management / 2nd gate（未実装）
#   idd-codex 由来の機能だが、Qwen Code CLI の使用制限モデルが異なるため
#   現時点では stub のみ。必要に応じて将来的に実装する。
# ═════════════════════════════════════════════════════════════════════════════

# pr_detect_usage_limit_reset_epoch: usage-limit reset epoch を抽出（stub）
pr_detect_usage_limit_reset_epoch() {
  # TODO: Qwen Code CLI のレートリミット検出を実装
  printf ''
  return 0
}

# pr_handle_quota_wait: quota wait 退避（stub）
pr_handle_quota_wait() {
  # TODO: Qwen Code CLI の使用制限待機を実装
  pr_log "PR #${1}: quota wait は未実装（stub）"
  return 0
}

# pr_process_quota_resume: quota wait 解除再レビュー（stub）
pr_process_quota_resume() {
  # TODO: Qwen Code CLI の使用制限解除後処理を実装
  return 0
}

# pr_second_gate_enabled / pr_check_claude_installed / pr_run_claude_second_gate: 2nd gate（stub）
# Qwen Code には claude second gate に相当する機能がないため未実装
pr_second_gate_enabled() { return 1; }
pr_check_claude_installed() { return 1; }
pr_check_claude_authenticated() { return 2; }
pr_publish_claude_status() { return 0; }
pr_run_claude_second_gate() { return 0; }

# ─────────────────────────────────────────────────────────────────────────────
# pr_run_review_for_pr: 1 PR 分のレビューを統括（orchestration）
#   入力: $1=pr_json（jq 配列要素） $2=tool
#   戻り値: 0=success / 1=failure / 2=skip（重複）/ 3=exec-error
# ─────────────────────────────────────────────────────────────────────────────
pr_run_review_for_pr() {
  local pr_json="$1"
  local tool="$2"

  local pr_number head_ref base_ref sha pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json" | jq -r '.headRefName')
  base_ref=$(echo "$pr_json" | jq -r '.baseRefName')
  sha=$(echo "$pr_json" | jq -r '.headRefOid')
  pr_url=$(echo "$pr_json" | jq -r '.url')

  if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
    base_ref="$BASE_BRANCH"
  fi

  # 同一 (sha, kind=review) が既存なら重複レビューを skip
  if pr_already_processed "$pr_number" "$sha" "review"; then
    pr_log "PR #${pr_number}: sha=${sha} は既にレビュー済み。skip"
    return 2
  fi

  pr_log "PR #${pr_number}: レビュー着手 tool=${tool} head=${head_ref} base=${base_ref} sha=${sha} (${pr_url})"

  # cmd template を tool 別に解決
  local cmd_template
  case "$tool" in
    codex)       cmd_template="${PR_REVIEWER_CODEX_CMD}" ;;
    antigravity) cmd_template="${PR_REVIEWER_ANTIGRAVITY_CMD}" ;;
    *)
      pr_warn "PR #${pr_number}: 未知の tool '${tool}'、skip"
      return 1
      ;;
  esac

  # prompt tempfile + 実行結果受け渡し tempfile を生成
  local prompt_file out_file err_file result_file
  if ! prompt_file=$(pr_build_prompt_file "$pr_number" "$base_ref" "$head_ref"); then
    pr_warn "PR #${pr_number}: prompt 生成に失敗、skip"
    return 1
  fi
  if ! out_file=$(idd_secure_mktemp "pr-reviewer-out-${pr_number}"); then
    rm -f "$prompt_file"
    pr_warn "PR #${pr_number}: stdout tempfile 作成に失敗、skip"
    return 1
  fi
  if ! err_file=$(idd_secure_mktemp "pr-reviewer-stderr-${pr_number}"); then
    rm -f "$prompt_file" "$out_file"
    pr_warn "PR #${pr_number}: stderr tempfile 作成に失敗、skip"
    return 1
  fi
  if ! result_file=$(idd_secure_mktemp "pr-reviewer-result-${pr_number}"); then
    rm -f "$prompt_file" "$out_file" "$err_file"
    pr_warn "PR #${pr_number}: result tempfile 作成に失敗、skip"
    return 1
  fi
  local cleanup_cmd
  printf -v cleanup_cmd 'rm -f %q %q %q %q' "$prompt_file" "$out_file" "$err_file" "$result_file"
  trap "$cleanup_cmd" RETURN

  # プレースホルダ置換 + unsafe value 検査
  local resolved_cmd
  if ! resolved_cmd=$(pr_substitute_placeholders "$cmd_template" "$base_ref" "$head_ref" "$pr_number" "$prompt_file"); then
    return 1
  fi

  # レビュー実行
  pr_execute_review_command "$head_ref" "$resolved_cmd" "$tool" "$out_file" "$err_file" "$result_file"

  local result
  result=$(cat "$result_file" 2>/dev/null || echo "")

  case "$result" in
    fetch-fail|checkout-fail)
      pr_warn "PR #${pr_number}: head '${head_ref}' の取得に失敗 (${result})、当該 PR を skip"
      return 1
      ;;
  esac

  local exec_rc wsmod
  exec_rc=$(printf '%s' "$result" | awk -F: '{print $2}')
  wsmod=$(printf '%s' "$result" | awk -F: '{print $3}')
  exec_rc="${exec_rc:-1}"

  # read-only invariant 違反
  if [ "$wsmod" = "modified" ]; then
    pr_error "PR #${pr_number}: レビュー実行がワークツリーを変更（read-only invariant 違反）"
    pr_post_error_comment "$pr_number" "$sha" "workspace-modified" \
      "レビューツール \`${tool}\` の実行がワークツリーを変更しました。read-only 制約に違反するため tracked 変更を破棄しました。" \
      "$tool"
    return 3
  fi

  # 実行失敗
  if [ "$exec_rc" -ne 0 ]; then
    local quota_reset_epoch
    quota_reset_epoch=$(pr_detect_usage_limit_reset_epoch "$out_file" "$err_file")
    if [[ "$quota_reset_epoch" =~ ^[0-9]+$ ]]; then
      pr_handle_quota_wait "$pr_number" "$sha" "$tool" "$quota_reset_epoch" || true
      return 2
    fi

    pr_error "PR #${pr_number}: レビュー実行コマンドが非ゼロ終了 (exit=${exec_rc}, tool=${tool})"
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" \
      "レビュー実行コマンドが非ゼロ終了しました（tool=${tool}）。" \
      "$tool"
    return 3
  fi

  # 成功: stdout をレビュー結果として収集
  local review_text
  review_text=$(cat "$out_file" 2>/dev/null || echo "")

  # antigravity は JSON 出力のため message 部を抽出
  if [ "$tool" = "antigravity" ]; then
    local extracted
    extracted=$(printf '%s' "$review_text" | jq -r '.message // .text // .response // empty' 2>/dev/null || echo "")
    if [ -n "$extracted" ]; then
      review_text="$extracted"
    fi
  fi

  if [ -z "$review_text" ]; then
    pr_warn "PR #${pr_number}: レビュー結果が空。exec-failed として扱う"
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" \
      "レビュー実行は成功しましたが出力が空でした（tool=${tool}）。" \
      "$tool"
    return 3
  fi

  local verdict
  verdict=$(pr_resolve_review_verdict "$pr_number" "$review_text")
  pr_log "PR #${pr_number}: review verdict=${verdict} tool=${tool} sha=${sha}"

  if [ "$verdict" = "approve" ]; then
    pr_try_post_formal_approval "$pr_number" "$sha" "$review_text" "$tool" || true
  fi

  # レビュー結果コメント投稿
  if ! pr_post_review_comment "$pr_number" "$sha" "$review_text" "$tool"; then
    return 1
  fi

  # iteration / conflict は codex-needs-iteration ラベル付与
  if [ "$verdict" = "iteration" ] || [ "$verdict" = "conflict" ]; then
    pr_add_iteration_label "$pr_number"
  fi

  # codex-review commit status を publish（AND 二重 opt-in gate ON 時のみ）
  pr_publish_codex_status "$pr_number" "$sha" "$verdict" "$pr_url" || true

  # 2nd gate（claude-review）。toggle OFF（既定）では no-op
  if pr_second_gate_enabled; then
    pr_run_claude_second_gate "$pr_number" "$sha" "$head_ref" "$base_ref" "$pr_url" || true
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_broadcast_error_to_prs: 候補 PR 全件に同種エラーコメントを投稿（内部 helper）
#   入力: $1=prs_json $2=kind $3=tool $4=detail
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_broadcast_error_to_prs() {
  local prs_json="$1"
  local kind="$2"
  local tool="$3"
  local detail="$4"

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")
  [ -z "$pr_iter" ] && return 0

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number sha
    pr_number=$(echo "$pr_json" | jq -r '.number')
    sha=$(echo "$pr_json" | jq -r '.headRefOid')
    pr_post_error_comment "$pr_number" "$sha" "$kind" "$detail" "$tool" || true
  done <<< "$pr_iter"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_reviewer: dispatcher から呼ばれるエントリ関数
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しない）
# ─────────────────────────────────────────────────────────────────────────────
process_pr_reviewer() {
  # opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${PR_REVIEWER_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # tool 解決
  local resolved_tool resolve_rc=0
  resolved_tool=$(pr_resolve_tool) || resolve_rc=$?

  pr_log "cycle start: tool=${resolved_tool} max_prs=${PR_REVIEWER_MAX_PRS:-unset} git_timeout=${PR_REVIEWER_GIT_TIMEOUT:-unset}s exec_timeout=${PR_REVIEWER_EXEC_TIMEOUT:-unset}s head_pattern=${PR_REVIEWER_HEAD_PATTERN:-unset}"

  # none（rc=2）は静かに skip
  if [ "$resolve_rc" -eq 2 ]; then
    return 0
  fi

  # quota wait 解除処理（stub 呼び出し）
  pr_process_quota_resume

  # 候補 PR 列挙
  local prs_json total
  prs_json=$(pr_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  # conflict（rc=1）は候補 PR へ排他エラーを broadcast
  if [ "$resolve_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "conflict-tool" "none" \
      "\`codex\` と \`antigravity\` の両方が有効化されています（排他エラー）。"
    pr_log "サマリ: tool=conflict reviewed=0 skip=0 fail=0 errored=${total}"
    return 0
  fi

  # 候補 0 件 → サマリのみ
  if [ "$total" -eq 0 ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0（候補 PR なし）"
    return 0
  fi

  # 未インストール → broadcast して中止
  if ! pr_check_tool_installed "$resolved_tool"; then
    pr_broadcast_error_to_prs "$prs_json" "not-installed" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` の実行ファイルが PATH 上に見つかりません。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}"
    return 0
  fi

  # 未認証 → broadcast して中止
  local auth_rc=0
  pr_check_tool_authenticated "$resolved_tool" || auth_rc=$?
  if [ "$auth_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "not-authenticated" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` が未認証です。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}"
    return 0
  fi

  # MAX_PRS で truncate
  local target_count="$total" skipped_overflow=0
  if [ "$total" -gt "$PR_REVIEWER_MAX_PRS" ]; then
    target_count="$PR_REVIEWER_MAX_PRS"
    skipped_overflow=$((total - PR_REVIEWER_MAX_PRS))
    pr_log "対象候補 ${total} 件中、上限 ${PR_REVIEWER_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    pr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  # レビュー loop
  local reviewed=0 skip=0 fail=0 errored=0
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0"
    return 0
  fi

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local rc=0
    pr_run_review_for_pr "$pr_json" "$resolved_tool" || rc=$?
    case $rc in
      0) reviewed=$((reviewed + 1)) ;;
      2) skip=$((skip + 1)) ;;
      3) errored=$((errored + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  pr_log "サマリ: tool=${resolved_tool} reviewed=${reviewed} skip=${skip} fail=${fail} errored=${errored} overflow=${skipped_overflow}"

  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  return 0
}