#!/usr/bin/env bash
# failed-recovery.sh — Agent 失敗時の自動回復モジュール（idd-qwen 版）
#
# 移植元: idd-codex/local-watcher/bin/idd-codex-modules/failed-recovery.sh
#
# 用途:
#   codex-failed / codex-blocked 状態の Issue および CI 失敗 PR を検出し、
#   自動回復（再試行）を試みる。二重 opt-in gate（FULL_AUTO_ENABLED AND
#   FAILED_RECOVERY_ENABLED）の下で動作。
#
# 機能:
#   - Issue 経路: codex-failed / codex-blocked Issue の検出と再試行
#   - PR 経路: auto-merge 待ち CI 失敗 PR の復旧
#   - 通算 attempt budget（FAILED_RECOVERY_MAX_ATTEMPTS、状態ファイルで永続化）
#   - no-progress ガード（失敗 signature 比較による無限ループ防止）
#   - quota 統合（rc=99 検出で budget 不消費の待機）
#   - exponential backoff（再試行間の待機時間）
#   - 失敗レポート生成
#
# 依存:
#   - core_utils.sh（fr_log / fr_warn / fr_error / full_auto_enabled）
#   - slack-notify.sh（sn_notify_intervention、終端処理のみ）
#   - jq, gh, git, qwen
#
# 環境変数:
#   FAILED_RECOVERY_ENABLED      : 機能 ON/OFF（既定: false）
#   FAILED_RECOVERY_MAX_ATTEMPTS : 最大試行回数（既定: 4）
#   FAILED_RECOVERY_MAX_PRS      : 同時に回復可能な PR 数（既定: 3）
#   FAILED_RECOVERY_GIT_TIMEOUT  : git コマンドのタイムアウト秒（既定: 60）
#   FAILED_RECOVERY_DEV_MODEL    : 回復用モデル名（既定: ${DEV_MODEL} または gpt-5.5）
#   FAILED_RECOVERY_STATE_DIR    : 状態ファイル格納ディレクトリ

# ─── ロガー（core_utils.sh から借用） ──────────────────────────────────────
# fr_log / fr_warn / fr_error は core_utils.sh で定義済み。
# なければフォールバック定義（module 単体テスト用）。

_fr_logger_defined="${fr_log+_set}"
if [[ "${_fr_logger_defined}" != "_set" ]]; then
  fr_log()    { echo "[$(date '+%F %T')] [FR] $*"; }
  fr_warn()   { echo "[$(date '+%F %T')] [FR-WARN] $*" >&2; }
  fr_error()  { echo "[$(date '+%F %T')] [FR-ERROR] $*" >&2; }
fi

# ─── 定数 ──────────────────────────────────────────────────────────────────

FAILED_RECOVERY_ENABLED="${FAILED_RECOVERY_ENABLED:-false}"
case "$FAILED_RECOVERY_ENABLED" in
  true|false) ;;
  *)    FAILED_RECOVERY_ENABLED="false" ;;
esac

FAILED_RECOVERY_MAX_ATTEMPTS="${FAILED_RECOVERY_MAX_ATTEMPTS:-4}"
case "$FAILED_RECOVERY_MAX_ATTEMPTS" in
  ''|*[!0-9]*) FAILED_RECOVERY_MAX_ATTEMPTS=4 ;;
  *) [ "$FAILED_RECOVERY_MAX_ATTEMPTS" -le 0 ] && FAILED_RECOVERY_MAX_ATTEMPTS=4 ;;
esac

FAILED_RECOVERY_MAX_PRS="${FAILED_RECOVERY_MAX_PRS:-3}"

FAILED_RECOVERY_GIT_TIMEOUT="${FAILED_RECOVERY_GIT_TIMEOUT:-60}"

FAILED_RECOVERY_DEV_MODEL="${FAILED_RECOVERY_DEV_MODEL:-${DEV_MODEL:-gpt-5.5}}"

FAILED_RECOVERY_STATE_DIR="${FAILED_RECOVERY_STATE_DIR:-$HOME/.idd-qwen/failed-recovery}"

# ─── 初期化 ─────────────────────────────────────────────────────────────────

failed_recovery_init() {
    mkdir -p "${FAILED_RECOVERY_STATE_DIR}" 2>/dev/null || true
}

# ─── 状態ファイル操作 ──────────────────────────────────────────────────────

# fr_state_path: 対象 ID 用の状態ファイルパスを返す（純粋関数）
fr_state_path() {
    local kind="$1"  # issue | pr
    local id="$2"    # issue number | PR number
    echo "${FAILED_RECOVERY_STATE_DIR}/${kind}-${id}.json"
}

# fr_load_state: 状態ファイルから JSON を読み込む。存在しなければ空 JSON を返す。
fr_load_state() {
    local state_file="$1"
    if [[ -f "${state_file}" ]]; then
        cat "${state_file}"
    else
        echo '{"attempts":0,"last_signature":"","last_recovered_at":""}'
    fi
}

# fr_save_state: JSON 状態をファイルに保存する
fr_save_state() {
    local state_file="$1"
    local state_json="$2"
    echo "${state_json}" > "${state_file}" 2>/dev/null || {
        fr_warn "状態ファイルの保存に失敗: ${state_file}"
        return 1
    }
    return 0
}

# ─── 失敗シグネチャ ────────────────────────────────────────────────────────

# fr_compute_failure_signature: Issue の最終コメント + ラベルから失敗 signature を生成
fr_compute_failure_signature() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        echo "no-repo"
        return 0
    fi

    # 最終コメントの本文とラベルを抽出
    local last_comment
    last_comment=$(gh issue view --repo "${repo}" "${issue_number}" \
        --comments 1 --json comments --jq '.comments[0].body // ""' 2>/dev/null || echo "")

    local labels
    labels=$(gh issue view --repo "${repo}" "${issue_number}" \
        --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

    # signature = ラベル + 最終コメントの最初の 200 文字
    local sig
    sig="$(printf '%s' "${labels}:"; echo "${last_comment}" | head -c 200 | tr '\n' ' ')" 2>/dev/null || sig=""
    # ハッシュ化（衝突防止）
    echo "${sig}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "sig-${issue_number}"
}

# fr_detect_no_progress: 前回と同じ signature なら no-progress 判定
fr_detect_no_progress() {
    local current_sig="$1"
    local saved_sig="$2"

    if [[ -z "${saved_sig}" || "${saved_sig}" == "none" ]]; then
        return 1  # 初回回復なので no-progress でない
    fi

    if [[ "${current_sig}" == "${saved_sig}" ]]; then
        return 0  # 同じ signature = progress なし
    fi

    return 1  # 異なる signature = progress あり
}

# ─── Issue 経路 ────────────────────────────────────────────────────────────

# fr_fetch_failed_issues: codex-failed / codex-blocked の open Issue を一覧取得
fr_fetch_failed_issues() {
    local repo="${1:-${REPO:-}}"
    if [[ -z "${repo}" ]]; then
        return 0
    fi

    # codex-failed Issue を取得
    local failed_json
    failed_json=$(gh issue list --repo "${repo}" \
        --label "codex-failed" \
        --state open \
        --json number,title,url,labels,comments \
        --jq '.[] | {number: .number, title: .title, url: .url, labels: [.labels[].name], comments: (.comments | length)}' \
        2>/dev/null || echo "")

    # codex-blocked Issue も取得
    local blocked_json
    blocked_json=$(gh issue list --repo "${repo}" \
        --label "codex-blocked" \
        --state open \
        --json number,title,url,labels,comments \
        --jq '.[] | {number: .number, title: .title, url: .url, labels: [.labels[].name], comments: (.comments | length)}' \
        2>/dev/null || echo "")

    # 結合（重複除去）
    if [[ -n "${failed_json}" ]]; then
        echo "${failed_json}"
    fi
    if [[ -n "${blocked_json}" ]]; then
        echo "${blocked_json}"
    fi
}

# fr_collect_issue_context: Issue のコンテキストを収集（body + 最終コメント + ラベル）
fr_collect_issue_context() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        echo "no-repo"
        return 1
    fi

    local body title labels url
    body=$(gh issue view --repo "${repo}" "${issue_number}" --body 2>/dev/null || echo "")
    title=$(gh issue view --repo "${repo}" "${issue_number}" --json title --jq '.title' 2>/dev/null || echo "unknown")
    labels=$(gh issue view --repo "${repo}" "${issue_number}" --json labels --jq '[.labels[].name] | join(", ")' 2>/dev/null || echo "")
    url=$(gh issue view --repo "${repo}" "${issue_number}" --json url --jq '.url' 2>/dev/null || echo "")

    {
        echo "=== Issue Context ==="
        echo "Title: ${title}"
        echo "URL: ${url}"
        echo "Labels: ${labels}"
        echo ""
        echo "=== Issue Body ==="
        echo "${body}"
        echo ""
        echo "=== Last Comment ==="
        gh issue view --repo "${repo}" "${issue_number}" --comments 1 --json comments \
            --jq '.comments[0].body // "no comments"' 2>/dev/null || echo "no comments"
    }
}

# fr_post_attempt_comment: 試行開始を Issue にコメント報告
fr_post_attempt_comment() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"
    local attempt="$3"
    local max_attempts="$4"

    if [[ -z "${repo}" ]]; then
        return 0
    fi

    local comment="🔄 **Failed Recovery (Attempt ${attempt}/${max_attempts})**

This issue has been automatically retried by the failed recovery module.

- Attempt: ${attempt}/${max_attempts}
- Trigger: codex-failed / codex-blocked recovery
- Model: ${FAILED_RECOVERY_DEV_MODEL}

The recovery attempt is in progress. Please monitor the issue for updates."

    gh issue comment --repo "${repo}" "${issue_number}" \
        --body "${comment}" 2>/dev/null || {
        fr_warn "試行開始コメントの投稿に失敗: Issue #${issue_number}"
    }
}

# ─── PR 経路 ───────────────────────────────────────────────────────────────

# fr_fetch_failed_prs: CI 失敗の open PR を一覧取得（auto-merge 対象）
fr_fetch_failed_prs() {
    local repo="${1:-${REPO:-}}"
    if [[ -z "${repo}" ]]; then
        return 0
    fi

    # CI 失敗の PR を取得（auto-merge 待ちで CI が失敗している）
    gh pr list --repo "${repo}" \
        --state open \
        --json number,title,url,labels,checks,files \
        --jq '[.[] | select(.checks != null and (.checks | length > 0)) |
               select(.checks[]?.status == "IN_PROGRESS" or .checks[]?.conclusion == null or
                      (.checks[]?.conclusion == "failure" and .labels[]?.name == "auto-merge"))] |
              .[] | {number: .number, title: .title, url: .url,
                     labels: [.labels[].name], checks: [.checks[]?.name // empty]}' \
        2>/dev/null || echo ""
}

# fr_collect_pr_ci_context: PR の CI コンテキストを収集
fr_collect_pr_ci_context() {
    local pr_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        echo "no-repo"
        return 1
    fi

    {
        echo "=== PR CI Context ==="
        echo "PR #${pr_number}"
        echo ""
        echo "=== CI Checks ==="
        gh pr checks --repo "${repo}" "${pr_number}" 2>/dev/null || echo "no checks available"
        echo ""
        echo "=== PR Files ==="
        gh pr diff --repo "${repo}" "${pr_number}" --stat 2>/dev/null | head -20 || echo "no diff available"
    }
}

# ─── 回復プロンプト構築 ────────────────────────────────────────────────────

# fr_build_recovery_prompt: Issue 回復用の Qwen Code プロンプトを生成
fr_build_recovery_prompt() {
    local issue_number="$1"
    local issue_title="$2"
    local issue_url="$3"
    local context="$4"
    local attempt="$5"
    local max_attempts="$6"

    cat <<EOF
GitHub Issue #${issue_number} の自動回復を試みます。

タイトル: ${issue_title}
URL: ${issue_url}
試行回数: ${attempt}/${max_attempts}

=== 失敗コンテキスト ===
${context}

=== 指示 ===
この Issue は以前失敗しました。以下の手順で再試行してください:

1. Issue の本文とコメントを再確認
2. 前回失敗した原因を推測（timeout / quota / 外部依存 / 実装ミス）
3. 原因に応じた対策を講じて実装を再開
4. 既存の spec（requirements.md / design.md / tasks.md）を尊重
5. 実装後、テストを再通过確認
6. impl-notes.md に回復理由と対策を記録

ブランチ: codex/issue-${issue_number}-impl

重要: 前回と同じ失敗を繰り返さないよう、原因を特定して対策してください。
EOF
}

# ─── Qwen Code 実行 ────────────────────────────────────────────────────────

# fr_invoke_codex: Issue 回復用に Qwen Code を実行
fr_invoke_codex() {
    local prompt="$1"
    local issue_number="$2"
    local output_file="${LOG_DIR}/qwen-recovery-${issue_number}.json"

    fr_log "Qwen Code を回復実行: Issue #${issue_number}"

    # Qwen Code のヘッドレス実行（既存の run_qwen_headless と同パターン）
    qwen "${prompt}" \
        -y \
        --channel CI \
        --output-format json \
        --json-file "${output_file}" \
        --max-session-turns "${QWEN_MAX_TURNS:-200}" \
        --max-wall-time "${QWEN_MAX_WALL_TIME:-1800}s" \
        2>&1 | tee -a "${LOG_DIR}/qwen-recovery-${issue_number}.log"

    local exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        # rc=99 は quota 不足（後続で特別処理）
        if [[ ${exit_code} -eq 99 ]]; then
            return 99
        fi
        fr_warn "Qwen Code の回復実行が失敗: Issue #${issue_number} (exit code: ${exit_code})"
        return ${exit_code}
    fi

    fr_log "Qwen Code の回復実行が完了: Issue #${issue_number}"
    return 0
}

# ─── 終端処理 ──────────────────────────────────────────────────────────────

# fr_finalize_success: 回復成功時の処理（ラベル更新 + コメント）
fr_finalize_success() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        return 0
    fi

    # codex-failed / codex-blocked ラベルを削除
    gh issue edit --repo "${repo}" "${issue_number}" \
        --remove-label "codex-failed" \
        --remove-label "codex-blocked" \
        2>/dev/null || {
        fr_warn "ラベルの削除に失敗: Issue #${issue_number}"
    }

    # 成功コメントを投稿
    local comment="✅ **Failed Recovery Successful**

The automatic recovery has completed successfully.

- The issue has been reprocessed
- Failed labels have been removed

You can proceed with the next steps (e.g., review, merge)."

    gh issue comment --repo "${repo}" "${issue_number}" \
        --body "${comment}" 2>/dev/null || {
        fr_warn "成功コメントの投稿に失敗: Issue #${issue_number}"
    }

    fr_log "Issue #${issue_number} の回復成功処理を完了"
}

# fr_handle_quota: rc=99（quota 不足）時の処理
fr_handle_quota() {
    fr_warn "API quota 不足。待機後に再試行します。"

    # slack-notify.sh の sn_notify_intervention を呼び出し（存在する場合）
    if declare -f sn_notify_intervention &>/dev/null; then
        sn_notify_intervention "failed-recovery" \
            "API quota 不足により failed-recovery を一時停止しました。" 2>/dev/null || true
    fi

    # 待機（exponential backoff の一部として）
    local wait_seconds=300  # 5 分
    fr_log "${wait_seconds} 秒待機後、再試行します..."
    sleep "${wait_seconds}"
    return 0
}

# ─── 回復試行実行 ──────────────────────────────────────────────────────────

# fr_run_recovery_attempt: Issue の単一回復試行を実行
fr_run_recovery_attempt() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"
    local attempt="$3"
    local max_attempts="$4"

    if [[ -z "${repo}" ]]; then
        fr_warn "repo が未指定。skip: Issue #${issue_number}"
        return 1
    fi

    # 状態ファイルのパスを解決
    local state_file
    state_file=$(fr_state_path "issue" "${issue_number}")

    # 現在の状態を読み込み
    local state_json
    state_json=$(fr_load_state "${state_file}")

    local saved_attempts saved_signature
    saved_attempts=$(echo "${state_json}" | jq -r '.attempts // 0' 2>/dev/null || echo "0")
    saved_signature=$(echo "${state_json}" | jq -r '.last_signature // ""' 2>/dev/null || echo "")

    # attempt 数をインクリメント
    local new_attempts=$((saved_attempts + 1))

    # 最大試行回数チェック
    if [[ ${new_attempts} -gt ${max_attempts} ]]; then
        fr_warn "最大試行回数を超過: Issue #${issue_number} (${new_attempts}/${max_attempts})"
        _fr_terminate_max_attempts "${issue_number}" "${repo}"
        return 1
    fi

    # 失敗 signature を計算
    local current_signature
    current_signature=$(fr_compute_failure_signature "${issue_number}" "${repo}")

    # no-progress ガード
    if fr_detect_no_progress "${current_signature}" "${saved_signature}"; then
        fr_warn "no-progress 検出: Issue #${issue_number}（前回と同じ失敗 signature）"
        _fr_terminate_no_progress "${issue_number}" "${repo}"
        return 1
    fi

    # 試行開始コメントを投稿
    fr_post_attempt_comment "${issue_number}" "${repo}" "${new_attempts}" "${max_attempts}"

    # Issue コンテキストを収集
    local context
    context=$(fr_collect_issue_context "${issue_number}" "${repo}" 2>/dev/null || echo "context unavailable")

    # 回復プロンプトを構築
    local prompt
    prompt=$(fr_build_recovery_prompt \
        "${issue_number}" \
        "$(gh issue view --repo "${repo}" "${issue_number}" --json title --jq '.title' 2>/dev/null || echo 'unknown')" \
        "$(gh issue view --repo "${repo}" "${issue_number}" --json url --jq '.url' 2>/dev/null || echo '')" \
        "${context}" \
        "${new_attempts}" \
        "${max_attempts}")

    # Qwen Code を実行
    local rc=0
    fr_invoke_codex "${prompt}" "${issue_number}" || rc=$?

    # rc=99 は quota 不足
    if [[ ${rc} -eq 99 ]]; then
        fr_handle_quota
        # quota 待機後も状態は保存（budget 不消費）
        local now
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
        local new_state
        new_state=$(jq -n \
            --argjson att "${new_attempts}" \
            --arg sig "${current_signature}" \
            --arg ts "${now}" \
            '{"attempts":$att,"last_signature":$sig,"last_recovered_at":$ts}' 2>/dev/null || echo '{}')
        fr_save_state "${state_file}" "${new_state}"
        return 0
    fi

    # 状態を更新
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
    local new_state
    new_state=$(jq -n \
        --argjson att "${new_attempts}" \
        --arg sig "${current_signature}" \
        --arg ts "${now}" \
        '{"attempts":$att,"last_signature":$sig,"last_recovered_at":$ts}' 2>/dev/null || echo '{}')
    fr_save_state "${state_file}" "${new_state}"

    # 成功判定（output_file の存在で簡易判定）
    local output_file="${LOG_DIR}/qwen-recovery-${issue_number}.json"
    if [[ -f "${output_file}" ]]; then
        fr_finalize_success "${issue_number}" "${repo}"
        fr_log "Issue #${issue_number} の回復成功: attempt ${new_attempts}/${max_attempts}"
    else
        fr_warn "Issue #${issue_number} の回復: output_file 不在（失敗または未完了）"
    fi

    return 0
}

# ─── 終端ハンドラ ──────────────────────────────────────────────────────────

# _fr_terminate_max_attempts: 最大試行回数到達時の処理
_fr_terminate_max_attempts() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        return 0
    fi

    local comment="⚠️ **Failed Recovery: Maximum Attempts Reached**

The automatic recovery has been terminated after ${FAILED_RECOVERY_MAX_ATTEMPTS} attempts.

- Maximum attempts exceeded
- Manual intervention required
- Labels will be reset for re-trial

Please review this issue and consider:
1. Splitting into smaller sub-issues
2. Providing additional context or clarification
3. Manual implementation"

    gh issue comment --repo "${repo}" "${issue_number}" \
        --body "${comment}" 2>/dev/null || {
        fr_warn "終端コメントの投稿に失敗: Issue #${issue_number}"
    }

    # codex-failed / codex-blocked を残したまま、codex-needs-decisions を追加
    gh issue edit --repo "${repo}" "${issue_number}" \
        --add-label "codex-needs-decisions" \
        2>/dev/null || true

    fr_log "Issue #${issue_number}: 最大試行回数到達。codex-needs-decisions 付与。"
}

# _fr_terminate_no_progress: no-progress 検出時の処理
_fr_terminate_no_progress() {
    local issue_number="$1"
    local repo="${2:-${REPO:-}}"

    if [[ -z "${repo}" ]]; then
        return 0
    fi

    local comment="⚠️ **Failed Recovery: No Progress Detected**

The automatic recovery has been paused because the same failure signature was detected.

- Same failure pattern as previous attempt
- Further automatic retries likely to fail
- Manual intervention recommended

Please review:
1. Whether the issue requires different approach
2. Whether spec (requirements/design/tasks) needs clarification
3. Whether the issue should be split or closed"

    gh issue comment --repo "${repo}" "${issue_number}" \
        --body "${comment}" 2>/dev/null || {
        fr_warn "終端コメントの投稿に失敗: Issue #${issue_number}"
    }

    gh issue edit --repo "${repo}" "${issue_number}" \
        --add-label "codex-needs-decisions" \
        2>/dev/null || true

    fr_log "Issue #${issue_number}: no-progress 検出。codex-needs-decisions 付与。"
}

# ─── 回復候補のディスパッチ ────────────────────────────────────────────────

# _fr_dispatch_candidate: 単一回復候補を処理する（内部関数）
_fr_dispatch_candidate() {
    local kind="$1"  # issue | pr
    local id="$2"    # issue number | PR number

    case "${kind}" in
        issue)
            fr_run_recovery_attempt "${id}" "${REPO}" \
                "$(( $(fr_load_state "$(fr_state_path issue "${id}")" | jq -r '.attempts // 0') + 1 ))" \
                "${FAILED_RECOVERY_MAX_ATTEMPTS}"
            ;;
        pr)
            fr_warn "PR 経路は idd-qwen で未実装: PR #${id}"
            ;;
        *)
            fr_warn "不明な kind: ${kind}"
            ;;
    esac
}

# ─── メイン処理 ────────────────────────────────────────────────────────────

# process_failed_recovery: 失敗回復のメインエントリーポイント
#
# 二重 opt-in gate（FULL_AUTO_ENABLED AND FAILED_RECOVERY_ENABLED）の下で動作。
# 外部呼び出し側で gate 判定してもよいが、本関数内でも再判定して安全側を確保。
process_failed_recovery() {
    # 二重 opt-in gate
    if [[ "${FULL_AUTO_ENABLED:-false}" != "true" ]]; then
        return 0
    fi
    if [[ "${FAILED_RECOVERY_ENABLED}" != "true" ]]; then
        return 0
    fi

    fr_log "failed-recovery: 起動（二重 gate 通過）"

    # Issue 経路: codex-failed / codex-blocked Issue の回復
    local issues
    issues=$(fr_fetch_failed_issues "${REPO}" 2>/dev/null || echo "")

    if [[ -n "${issues}" ]]; then
        local issue_count
        issue_count=$(echo "${issues}" | grep -c '"number"' 2>/dev/null || echo "0")
        fr_log "failed-recovery: ${issue_count} 件の失敗 Issue を検出"

        # Issue ごとに回復を試行
        echo "${issues}" | jq -c '. // empty' 2>/dev/null | while read -r issue; do
            local issue_number issue_title
            issue_number=$(echo "${issue}" | jq -r '.number' 2>/dev/null || echo "")
            issue_title=$(echo "${issue}" | jq -r '.title' 2>/dev/null || echo "unknown")

            if [[ -z "${issue_number}" || "${issue_number}" == "null" ]]; then
                continue
            fi

            fr_log "failed-recovery: Issue #${issue_number} (${issue_title}) を回復試行"
            _fr_dispatch_candidate "issue" "${issue_number}"
        done
    else
        fr_log "failed-recovery: 回復対象の Issue なし"
    fi

    fr_log "failed-recovery: 完了"
    return 0
}