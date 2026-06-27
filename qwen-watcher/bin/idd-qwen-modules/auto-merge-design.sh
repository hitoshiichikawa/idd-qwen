#!/usr/bin/env bash
# ─── Auto-merge Design Processor (#10) ────────────────────────────────────────
# 設計 PR（head `^codex/issue-.*-design`）を対象に、GitHub ネイティブ auto-merge を
# 有効化する（`gh pr merge --auto --squash --delete-branch`）。watcher は **直接
# merge せず**、実 merge は GitHub が必須 check 全 green 到達時に squash 実行する。
#
# 設計 PR は `codex-ready-for-review` ラベルを持たないため、実装 PR 版（auto-merge.sh /
# #99）と異なり **positive な ready ラベル必須条件は付けない**（head pattern + 否定ラベル
# + mergeable で判定）。`codex-needs-iteration` ラベルも除外対象に追加。
#
# 完全自動化 kill switch `FULL_AUTO_ENABLED` と `AUTO_MERGE_DESIGN_ENABLED` の **AND 二重
# opt-in** で動き、いずれか OFF（既定）では外部副作用ゼロで no-op。
#
# 依存: core_utils.sh（logger / idd_secure_mktemp）
# 設定: AUTO_MERGE_DESIGN_ENABLED（true のみ有効）
#       AUTO_MERGE_DESIGN_MAX_PRS（上限数）
#       AUTO_MERGE_DESIGN_GIT_TIMEOUT（gh/git タイムアウト秒）
#       AUTO_MERGE_DESIGN_HEAD_PATTERN（head branch pattern）
#       full_auto_enabled（main スクリプトから供給される関数）

# ─── 設定 ─────────────────────────────────────────────────────────────────────
AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"
AUTO_MERGE_DESIGN_MAX_PRS="${AUTO_MERGE_DESIGN_MAX_PRS:-10}"
AUTO_MERGE_DESIGN_GIT_TIMEOUT="${AUTO_MERGE_DESIGN_GIT_TIMEOUT:-60}"
AUTO_MERGE_DESIGN_HEAD_PATTERN="${AUTO_MERGE_DESIGN_HEAD_PATTERN:-^codex/issue-.*-design}"

# ─── Logger（core_utils.sh 依存） ─────────────────────────────────────────────
amd_log()  { _qw_log_info "auto-merge-design" "$*"; }
amd_warn() { _qw_log_warn "auto-merge-design" "$*"; }
amd_error(){ _qw_log_error "auto-merge-design" "$*"; }

# ─── GitHub Labels ────────────────────────────────────────────────────────────
LABEL_FAILED="codex-failed"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
LABEL_NEEDS_ITERATION="codex-needs-iteration"

# ─── amd_resolve_gate_enabled: AUTO_MERGE_DESIGN_ENABLED 個別 gate の判定 ─────
#   戻り値: 0 = ON（=true 厳密一致）/ 1 = OFF（未設定 / 空 / False / 1 / on / typo）
amd_resolve_gate_enabled() {
  case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── amd_should_enable_for_pr: 1 設計 PR が auto-merge 有効化の対象かを判定 ───
#   入力: $1 = pr_json（jq 配列の単一要素）
#   戻り値: 0 = enable 対象 / 1 = skip（対象外）/ 2 = 既に auto-merge 有効
#   設計 PR は positive ready ラベルを持たないため、head pattern + 否定ラベル + mergeable で判定。
amd_should_enable_for_pr() {
  local pr_json="$1"
  local head_ref is_draft mergeable auto_merge has_failed has_nd has_iter

  head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // "null"')
  has_failed=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_FAILED" \
    '.labels // [] | map(.name) | index($l) // "no"')
  has_nd=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_NEEDS_DECISIONS" \
    '.labels // [] | map(.name) | index($l) // "no"')
  has_iter=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_NEEDS_ITERATION" \
    '.labels // [] | map(.name) | index($l) // "no"')

  # head pattern（設計 PR のみ。impl PR は不一致で自動排他）
  if ! printf '%s' "$head_ref" | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    return 1
  fi
  # draft は対象外
  if [ "$is_draft" = "true" ]; then
    return 1
  fi
  # failed / needs-decisions / needs-iteration が付いていたら対象外（人間ゲート）
  if [ "$has_failed" != "no" ]; then
    return 1
  fi
  if [ "$has_nd" != "no" ]; then
    return 1
  fi
  if [ "$has_iter" != "no" ]; then
    return 1
  fi
  # MERGEABLE 以外（CONFLICTING / UNKNOWN）は触らない（merge-queue/auto-rebase へ委譲）
  if [ "$mergeable" != "MERGEABLE" ]; then
    return 1
  fi
  # 既に auto-merge 有効なら冪等 skip
  if [ "$auto_merge" != "null" ]; then
    return 2
  fi
  return 0
}

# ─── amd_enable_auto_merge_for_pr: 1 設計 PR に GitHub native auto-merge を有効化 ─
#   入力: $1=pr_number $2=head_ref $3=head_sha $4=pr_url
#   戻り値: 0 = 有効化成功 / 1 = 失敗（WARN 済み・パイプライン継続）
#   副作用: gh pr merge --auto --squash --delete-branch（実 merge は GitHub 任せ）
amd_enable_auto_merge_for_pr() {
  local pr_number="$1" head_ref="$2" head_sha="$3" pr_url="$4"

  if ! printf '%s' "$pr_number" | grep -qE '^[0-9]+$'; then
    amd_warn "auto-merge 有効化を skip: 不正な pr_number='${pr_number}'"
    return 1
  fi

  local stderr_file rc=0
  stderr_file=$(idd_secure_mktemp "auto-merge-design-${pr_number}" 2>/dev/null || true)
  if [ -n "$stderr_file" ]; then
    timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?
  else
    timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    [ -n "$stderr_file" ] && rm -f "$stderr_file"
    amd_log "PR #${pr_number}: design auto-merge enabled (squash, delete-branch) head=${head_ref} sha=${head_sha} url=${pr_url}"
    return 0
  fi

  # 失敗を stderr 内容で分類（silent fail せず WARN）
  local err_tail="" category="api-error"
  if [ -n "$stderr_file" ]; then
    err_tail=$(tail -c 512 "$stderr_file" 2>/dev/null | tr '\n' ' ')
    rm -f "$stderr_file"
  fi
  case "$err_tail" in
    *"could not resolve host"*|*[Nn]etwork*|*timeout*|*"connection"*) category="transport-error" ;;
    *"branch protection"*|*"not allowed"*|*"auto merge"*|*"Auto-merge"*|*"not enabled"*) category="repo-config-rejected" ;;
  esac
  amd_warn "PR #${pr_number}: design auto-merge 有効化に失敗 (${category}, rc=${rc}) stderr='${err_tail}'"
  return 1
}

# ─── 主要処理 ─────────────────────────────────────────────────────────────────

# process_auto_merge_design: dispatcher エントリ（毎サイクル呼ばれる）
#   戻り値: 0 固定（後続 processor を阻害しない / dispatcher fail-continue 契約）
#   gate: full_auto_enabled() AND amd_resolve_gate_enabled の AND 二重 opt-in
process_auto_merge_design() {
  # AND 二重 opt-in。kill switch OFF は無言で return。
  if ! full_auto_enabled; then
    return 0
  fi
  if ! amd_resolve_gate_enabled; then
    amd_log "suppressed by AUTO_MERGE_DESIGN_ENABLED gate (no-op)"
    return 0
  fi

  local repo_owner="${REPO%%/*}"
  local prs_json
  # 設計 PR には positive ready ラベルが無いため、否定ラベル + draft 除外で取得し
  # head pattern で絞る。
  if ! prs_json=$(timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" --state open \
      --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\" -draft:true" \
      --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest \
      --limit 50 2>/dev/null); then
    amd_warn "対象設計 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # client-side: draft 除外 + head pattern + fork 除外
  local filtered
  filtered=$(printf '%s' "$prs_json" | jq -c --arg pat "$AUTO_MERGE_DESIGN_HEAD_PATTERN" --arg owner "$repo_owner" \
    '[ .[] | select((.isDraft // false) == false) | select((.headRefName // "") | test($pat)) | select((.headRepositoryOwner.login // "") == $owner) ]' 2>/dev/null || echo "[]")

  local total target_count
  total=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    return 0
  fi
  target_count="$total"
  local overflow=0
  if [ "$total" -gt "$AUTO_MERGE_DESIGN_MAX_PRS" ]; then
    target_count="$AUTO_MERGE_DESIGN_MAX_PRS"
    overflow=$((total - AUTO_MERGE_DESIGN_MAX_PRS))
  fi

  local enabled=0 skipped=0 already=0 failed=0
  local pr_iter
  pr_iter=$(printf '%s' "$filtered" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number head_ref head_sha pr_url
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
    head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName')
    head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url')

    amd_should_enable_for_pr "$pr_json"
    case $? in
      0)
        if amd_enable_auto_merge_for_pr "$pr_number" "$head_ref" "$head_sha" "$pr_url"; then
          enabled=$((enabled + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      2)
        already=$((already + 1))
        amd_log "PR #${pr_number}: design auto-merge は既に有効（skip）"
        ;;
      *)
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  amd_log "design auto-merge summary: enabled=${enabled} already-enabled=${already} skipped=${skipped} failed=${failed} overflow=${overflow}"
  return 0
}

# ─── 出力 ─────────────────────────────────────────────────────────────────────
# このモジュールを直接実行した場合のテスト用出力
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # core_utils.sh を source
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/core_utils.sh"

  amd_log "=== auto-merge-design.sh テスト ==="
  amd_log "AUTO_MERGE_DESIGN_ENABLED=$AUTO_MERGE_DESIGN_ENABLED"
  amd_log "AUTO_MERGE_DESIGN_MAX_PRS=$AUTO_MERGE_DESIGN_MAX_PRS"
  amd_log "AUTO_MERGE_DESIGN_HEAD_PATTERN=$AUTO_MERGE_DESIGN_HEAD_PATTERN"

  # 関数定義の確認
  declare -f process_auto_merge_design >/dev/null 2>&1 && amd_log "process_auto_merge_design: OK" || amd_log "process_auto_merge_design: MISSING"
  declare -f amd_resolve_gate_enabled >/dev/null 2>&1 && amd_log "amd_resolve_gate_enabled: OK" || amd_log "amd_resolve_gate_enabled: MISSING"
  declare -f amd_should_enable_for_pr >/dev/null 2>&1 && amd_log "amd_should_enable_for_pr: OK" || amd_log "amd_should_enable_for_pr: MISSING"
  declare -f amd_enable_auto_merge_for_pr >/dev/null 2>&1 && amd_log "amd_enable_auto_merge_for_pr: OK" || amd_log "amd_enable_auto_merge_for_pr: MISSING"
fi