#!/usr/bin/env bash
# idd-qwen Issue Watcher - Qwen Code 版
#
# GitHub Issue をポーリングし、codex-auto-dev ラベルが付いた未処理 Issue を検出して
# Qwen Code を起動して自動処理する。
#
# 配置先: ~/bin/idd-qwen-issue-watcher.sh
# 依存  : qwen / gh / jq / flock / git
#
# セットアップ: このファイル冒頭の Config ブロックを編集し、
#   launchd (macOS) または cron (Linux) に登録する。README.md を参照。
# =============================================================================

set -euo pipefail

# cron / launchd は対話シェルの profile を読まないため PATH が最小限になり、
# ~/.local/bin や /usr/local/bin にインストールした qwen / gh が見つからない。
# 一般的なインストール先を先頭に足しておく。
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config（環境に合わせて書き換える）
#
# 複数リポジトリ運用:
#   REPO / REPO_DIR は環境変数で上書き可能。各 repo の cron / launchd エントリから
#   env var を渡せば、このスクリプト 1 ファイルを使い回せる。
#   LOCK_FILE / LOG_DIR は REPO から自動派生するため衝突しない。
#
#   cron 例:
#     */2 * * * * REPO=owner/a REPO_DIR=$HOME/work/a $HOME/bin/idd-qwen-issue-watcher.sh
#     */3 * * * * REPO=owner/b REPO_DIR=$HOME/work/b $HOME/bin/idd-qwen-issue-watcher.sh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# env var で上書き可能（未設定なら下のデフォルトを使う）
REPO="${REPO:-owner/your-repo}"
REPO_DIR="${REPO_DIR:-$HOME/work/your-repo}"

# REPO から repo-unique な slug を導出（lock / log / 一時ファイルの隔離に使う）
REPO_SLUG="$(echo "$REPO" | tr '/' '-')"

# ─── per-repo env ファイル ローダ（idd-codex env-loader.sh 移植）───
# Config ブロックの `*_ENABLED` 等の `${VAR:-default}` 評価より **前** に env-loader.sh を
# 単独 source して per-repo env ファイル（`WATCHER_ENV_FILE` 明示パス または
# `$HOME/.idd-qwen/<REPO_SLUG>.env`）から `*_ENABLED` 等を供給する。crontab 行を
# REPO / REPO_DIR / BASE_BRANCH の最小限に保ち、行長限界（~1024 文字）での `command too
# long` を解消する。env ファイル経由の値は inline cron env より低優先（既設定 KEY は不上書）。
# REQUIRED_MODULES の通常ローダ（Config 後）より前に動かす必要があるため、ここで単独 source。
# モジュール不在時は何もしない（導入前と等価）。REPO_SLUG / REPO 定義後・HOME 利用可で動作。
IDD_ENV_LOADER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/idd-qwen-modules/env-loader.sh"
if [ -f "$IDD_ENV_LOADER_PATH" ]; then
  # shellcheck source=/dev/null
  . "$IDD_ENV_LOADER_PATH"
  el_load
fi
unset IDD_ENV_LOADER_PATH

# per-repo log / lock / 一時ファイル
LOG_DIR="${LOG_DIR:-${HOME}/log/idd-qwen}"
LOCK_FILE="${LOCK_FILE:-${HOME}/lock/idd-qwen-issue-watcher-${REPO_SLUG}.lock}"
WORKTREE_BASE="${WORKTREE_BASE:-main}"
WORKTREE_PREFIX="${WORKTREE_PREFIX:-qwen-worktree-}"

# Qwen Code 設定
QWEN_MODEL="${QWEN_MODEL:-gpt-5.5}"
QWEN_YOLO="${QWEN_YOLO:-true}"
QWEN_MAX_TURNS="${QWEN_MAX_TURNS:-100}"
QWEN_MAX_WALL_TIME="${QWEN_MAX_WALL_TIME:-900}"

# 並列処理スロット数
PARALLEL_SLOTS="${PARALLEL_SLOTS:-3}"

# 失敗回復（二重 opt-in: FULL_AUTO_ENABLED AND FAILED_RECOVERY_ENABLED）
FULL_AUTO_ENABLED="${FULL_AUTO_ENABLED:-false}"
case "$FULL_AUTO_ENABLED" in
  true|false) ;;
  *)    FULL_AUTO_ENABLED="false" ;;
esac
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
FAILED_RECOVERY_STATE_DIR="${FAILED_RECOVERY_STATE_DIR:-$HOME/.idd-qwen/failed-recovery}"

# run-summary（Per-Run Evidence Summary）
RUN_SUMMARY_ENABLED="${RUN_SUMMARY_ENABLED:-true}"
case "$RUN_SUMMARY_ENABLED" in
  true|false) ;;
  *)    RUN_SUMMARY_ENABLED="true" ;;
esac

# needs-decisions 自動続行（二重 opt-in: FULL_AUTO_ENABLED AND NEEDS_DECISIONS_MODE）
NEEDS_DECISIONS_MODE="${NEEDS_DECISIONS_MODE:-all-human}"
case "$NEEDS_DECISIONS_MODE" in
  all-human|classified|all-auto) ;;
  *) NEEDS_DECISIONS_MODE="all-human" ;;
esac
NEEDS_DECISIONS_AUTO_MAX="${NEEDS_DECISIONS_AUTO_MAX:-4}"
case "$NEEDS_DECISIONS_AUTO_MAX" in
  ''|*[!0-9]*) NEEDS_DECISIONS_AUTO_MAX=4 ;;
  *) [ "$NEEDS_DECISIONS_AUTO_MAX" -le 0 ] && NEEDS_DECISIONS_AUTO_MAX=4 ;;
esac
NEEDS_DECISIONS_GIT_TIMEOUT="${NEEDS_DECISIONS_GIT_TIMEOUT:-30}"
case "$NEEDS_DECISIONS_GIT_TIMEOUT" in
  ''|*[!0-9]*) NEEDS_DECISIONS_GIT_TIMEOUT=30 ;;
  *) [ "$NEEDS_DECISIONS_GIT_TIMEOUT" -le 0 ] && NEEDS_DECISIONS_GIT_TIMEOUT=30 ;;
esac

# ドライランモード（デフォルト false）
DRY_RUN="${DRY_RUN:-false}"

# Per-task context-map 試験機能（#34）
# `CONTEXT_MAP_ENABLED=true` で per-task context-map.md 生成 + prompt 注入が有効になる。
CONTEXT_MAP_ENABLED="${CONTEXT_MAP_ENABLED:-false}"
# Context Indexer（LLM-powered read-only indexer）
# `CONTEXT_INDEXER_ENABLED=true` で context-map 生成時に LLM Indexer を起動する。
CONTEXT_INDEXER_ENABLED="${CONTEXT_INDEXER_ENABLED:-false}"
# Indexer 最大 turn 数（既定 10）。Indexer の runaway を抑止する上限。
CONTEXT_INDEXER_MAX_TURNS="${CONTEXT_INDEXER_MAX_TURNS:-10}"

# ─── Full-auto Kill Switch (#97) ──────────────────────────────────────────────
# full-auto 系 processor（auto-merge 等）の共通 gate。
# `FULL_AUTO_ENABLED=true` 厳密一致でのみ全 full-auto が有効になる。
full_auto_enabled() {
  case "${FULL_AUTO_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# モジュール読み込み
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/idd-qwen-modules" && pwd)"
REQUIRED_MODULES=("core_utils" "env-loader" "needs-decisions-auto" "pr-reviewer" "auto-merge" "auto-merge-design" "run-summary" "context-map")
for mod in "${REQUIRED_MODULES[@]}"; do
    mod_file="${MODULE_DIR}/${mod}.sh"
    if [[ -f "${mod_file}" ]]; then
        # shellcheck source=/dev/null
        source "${mod_file}"
        if declare -f "${mod}_init" &> /dev/null; then
            "${mod}_init"
        fi
    else
        echo "ERROR: Required module not found: ${mod_file}" >&2
        exit 1
    fi
done

# ─── ラベル定義 ─────────────────────────────────────────────────────────────

LABEL_AUTO_DEV="codex-auto-dev"
LABEL_CLAIMED="codex-claimed"
LABEL_PICKED_UP="codex-picked-up"
LABEL_READY_FOR_REVIEW="codex-ready-for-review"
LABEL_FAILED="codex-failed"
LABEL_BLOCKED="codex-blocked"
LABEL_AWAITING_SLOT="codex-awaiting-slot"
LABEL_AWAITING_DESIGN="codex-awaiting-design-review"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
LABEL_NEEDS_REBASE="codex-needs-rebase"
LABEL_NEEDS_ITERATION="codex-needs-iteration"
LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"
LABEL_ST_FAILED="codex-st-failed"
LABEL_SKIP_TRIAGE="codex-skip-triage"
LABEL_HOTFIX="codex-hotfix"

# ─── 初期化 ──────────────────────────────────────────────────────────────────

mkdir -p "${LOG_DIR}"
mkdir -p "$(dirname "${LOCK_FILE}")"
mkdir -p "${FAILED_RECOVERY_STATE_DIR}" 2>/dev/null || true

# run-summary 初期化（サイクル冒頭で 1 回）
rs_init

# ─── シグナルハンドラ ────────────────────────────────────────────────────────

cleanup() {
    log_info "クリーンアップを開始します"
    # 実行中のサブプロセスがあれば停止
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    log_info "クリーンアップが完了しました"
}

trap cleanup EXIT INT TERM
trap 'rs_emit || true' EXIT

# ─── 引数処理 ────────────────────────────────────────────────────────────────

DRY_RUN_ARG=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN_ARG=true
            shift
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--dry-run] [--repo owner/repo] [--repo-dir /path/to/repo]"
            exit 0
            ;;
        *)
            log_error "不明な引数: $1"
            exit 1
            ;;
    esac
done

# --dry-run 引数があった場合は DRY_RUN を上書き
if [[ "${DRY_RUN_ARG}" == "true" ]]; then
    DRY_RUN=true
fi

# ─── 依存確認 ────────────────────────────────────────────────────────────────

check_dependencies() {
    local deps=("qwen" "gh" "jq" "git")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "依存 CLI が不足しています: ${missing[*]}"
        log_error "$(brew install) 等でインストールしてください"
        exit 1
    fi
}

check_repo() {
    if [[ -z "${REPO}" ]]; then
        log_error "REPO 環境変数が設定されていません"
        log_error "例: REPO=owner/repo idd-qwen-issue-watcher.sh"
        exit 1
    fi

    if [[ -z "${REPO_DIR}" ]]; then
        log_error "REPO_DIR 環境変数が設定されていません"
        log_error "例: REPO_DIR=/path/to/repo idd-qwen-issue-watcher.sh"
        exit 1
    fi

    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        log_error "${REPO_DIR} は git リポジトリではありません"
        exit 1
    fi
}

# ─── Issue 監視機能 ──────────────────────────────────────────────────────────

# codex-auto-dev ラベルの Issue を一覧取得
list_auto_dev_issues() {
    gh issue list --repo "${REPO}" \
        --label "${LABEL_AUTO_DEV}" \
        --state open \
        --json number,title,url,labels,author \
        --jq '.[] | {number: .number, title: .title, url: .url, labels: [.labels[].name], author: .author.login}' 2>/dev/null || echo ""
}

# Issue を claim したことを報告（ラベル付与）
claim_issue() {
    local issue_number="$1"
    gh issue edit --repo "${REPO}" "${issue_number}" \
        --add-label "${LABEL_CLAIMED}" 2>/dev/null || {
        log_error "Issue #${issue_number} の claim に失敗しました"
        return 1
    }
    log_info "Issue #${issue_number} を claim しました"
}

# Issue の claim を解除（ラベル削除）
release_issue() {
    local issue_number="$1"
    gh issue edit --repo "${REPO}" "${issue_number}" \
        --remove-label "${LABEL_CLAIMED}" 2>/dev/null || {
        log_warn "Issue #${issue_number} の release に失敗しました"
    }
}

# Issue にコメントを追加
add_issue_comment() {
    local issue_number="$1"
    local message="$2"
    gh issue comment --repo "${REPO}" "${issue_number}" \
        --body "$message" 2>/dev/null || {
        log_warn "Issue #${issue_number} へのコメントに失敗しました"
    }
}

# Issue のラベルを更新
update_issue_labels() {
    local issue_number="$1"
    shift
    local labels=("$@")

    # 既存の codex-* ラベルを削除
    gh issue edit --repo "${REPO}" "${issue_number}" \
        --remove-label "${LABEL_CLAIMED}" \
        --remove-label "${LABEL_PICKED_UP}" \
        --remove-label "${LABEL_READY_FOR_REVIEW}" \
        --remove-label "${LABEL_FAILED}" \
        --remove-label "${LABEL_BLOCKED}" \
        --remove-label "${LABEL_AWAITING_SLOT}" \
        --remove-label "${LABEL_AWAITING_DESIGN}" \
        --remove-label "${LABEL_NEEDS_DECISIONS}" \
        --remove-label "${LABEL_NEEDS_REBASE}" \
        --remove-label "${LABEL_NEEDS_ITERATION}" \
        --remove-label "${LABEL_NEEDS_QUOTA_WAIT}" \
        --remove-label "${LABEL_STAGED_FOR_RELEASE}" \
        --remove-label "${LABEL_ST_FAILED}" \
        --remove-label "${LABEL_SKIP_TRIAGE}" \
        --remove-label "${LABEL_HOTFIX}" \
        2>/dev/null || true

    # 新規ラベルを付与
    local gh_labels=""
    for label in "${labels[@]}"; do
        gh_labels="${gh_labels} --add-label ${label}"
    done

    if [[ -n "${gh_labels}" ]]; then
        eval "gh issue edit --repo ${REPO} ${issue_number} ${gh_labels}" 2>/dev/null || {
            log_warn "ラベルの付与に失敗: ${labels[*]}"
        }
    fi
}

# ─── Qwen Code 実行機能 ────────────────────────────────────────────────────

# Qwen Code をヘッドレスで実行
run_qwen_headless() {
    local prompt="$1"
    local issue_number="$2"
    local output_file="${LOG_DIR}/qwen-output-${issue_number}.json"

    log_info "Qwen Code を実行: Issue #${issue_number}"
    log_debug "プロンプト: ${prompt}"

    # Qwen Code のヘッドレス実行
    qwen "${prompt}" \
        -y \
        --channel CI \
        --output-format json \
        --json-file "${output_file}" \
        --max-session-turns "${QWEN_MAX_TURNS}" \
        --max-wall-time "${QWEN_MAX_WALL_TIME}s" \
        --include-directories "${REPO_DIR}" \
        2>&1 | tee -a "${LOG_DIR}/qwen-${issue_number}.log"

    local exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Qwen Code の実行が失敗しました (exit code: ${exit_code})"
        return ${exit_code}
    fi

    log_info "Qwen Code の実行が完了しました: Issue #${issue_number}"
    return 0
}

# Triage プロンプトの生成
build_triage_prompt() {
    local issue_number="$1"
    local issue_title="$2"
    local issue_body="$3"
    local issue_url="$4"

    cat <<EOF
GitHub Issue #${issue_number} を分析してください。

タイトル: ${issue_title}
URL: ${issue_url}
本文:
${issue_body}

以下の点を判定してください:
1. この Issue は自動実装可能か（needs_architect: true/false）
2. 人間判断が必要な決定事項があるか（needs_decisions: true/false）
3. 必要な場合、Architect を挟むべきか

結果を JSON 形式で出力してください:
{
  "needs_architect": boolean,
  "needs_decisions": boolean,
  "decisions": [
    {
      "id": "string",
      "question": "string",
      "classification": "safe" | "human-only"
    }
  ]
}
EOF
}

# Developer プロンプトの生成
build_developer_prompt() {
    local issue_number="$1"
    local issue_title="$2"
    local issue_url="$3"
    local spec_dir="${REPO_DIR}/docs/specs/${issue_number}-*"

    # context-map: per-task 実行前に deterministic metadata を生成
    local context_map_block=""
    if declare -f qw_write_context_map &>/dev/null; then
        qw_write_context_map "0" "developer" "" "" 2>/dev/null || true
    fi
    if declare -f qw_build_prompt_block &>/dev/null; then
        context_map_block="$(qw_build_prompt_block 2>/dev/null || true)"
    fi

    cat <<EOF
GitHub Issue #${issue_number} を実装してください。

タイトル: ${issue_title}
URL: ${issue_url}

仕様書: ${spec_dir}/requirements.md
設計書: ${spec_dir}/design.md（存在する場合）
タスクリスト: ${spec_dir}/tasks.md（存在する場合）

以下の手順で実進してください:
1. 仕様書（requirements.md）を読み、Acceptance Criteria を理解
2. 設計書（design.md）が存在すれば読み、File Structure Plan を確認
3. タスクリスト（tasks.md）が存在すれば、番号順にタスクを消化
4. 各タスクでテストを先に書き、Red -> Green で実装
5. Conventional Commits でコミット
6. impl-notes.md に AC Coverage Matrix を作成

ブランチ: codex/issue-${issue_number}-impl
${context_map_block}
EOF
}

# Architect プロンプトの生成
build_architect_prompt() {
    local issue_number="$1"
    local issue_title="$2"
    local issue_url="$3"
    local requirements_file="${REPO_DIR}/docs/specs/${issue_number}-*/requirements.md"

    cat <<EOF
GitHub Issue #${issue_number} の設計書（design.md）とタスクリスト（tasks.md）を作成してください。

タイトル: ${issue_title}
URL: ${issue_url}

要件定義: ${requirements_file}

以下の内容を作成してください:
1. design.md - 設計書（File Structure Plan, Components and Interfaces, Traceability）
2. tasks.md - 実装タスクリスト（numeric ID, アノテーション付き）

ルール:
- [`.qwen/rules/design-principles.md`](../rules/design-principles.md) を参照
- [`.qwen/rules/tasks-generation.md`](../rules/tasks-generation.md) を参照
- EARS 形式の AC が全て design.md に反映されていることを確認
EOF
}

# ─── Dispatcher（メインループ） ──────────────────────────────────────────────

_dispatcher_run() {
    log_section "=== Dispatcher を開始 ==="

    # Issue 一覧の取得
    log_info "codex-auto-dev ラベルの Issue を一覧取得中..."
    issues_json=$(list_auto_dev_issues)

    if [[ -z "${issues_json}" ]]; then
        log_info "処理対象の Issue なし"
        return 0
    fi

    # Issue 数カウント
    issue_count=$(echo "${issues_json}" | jq 'length')
    log_info "処理対象の Issue 数: ${issue_count}"

    # run-summary: mode 設定（impl 系）
    rs_set_mode "impl"

    # PR Reviewer（PR 自動レビュー。Issue 処理の前に実行）
    if declare -f process_pr_reviewer &>/dev/null; then
        process_pr_reviewer || pr_log "process_pr_reviewer が想定外のエラーで終了（後続 Issue 処理は継続）"
    fi

    # 実装 PR auto-merge（#99）。gate OFF 時は no-op。
    if declare -f process_auto_merge &>/dev/null; then
        process_auto_merge || am_warn "process_auto_merge が想定外のエラーで終了（後続 Issue 処理は継続）"
    fi

    # 設計 PR auto-merge（#10）。gate OFF 時は no-op。
    if declare -f process_auto_merge_design &>/dev/null; then
        process_auto_merge_design || am_warn "process_auto_merge_design が想定外のエラーで終了（後続 Issue 処理は継続）"
    fi

    # 失敗回復処理（二重 gate: FULL_AUTO_ENABLED AND FAILED_RECOVERY_ENABLED）
    if declare -f process_failed_recovery &>/dev/null; then
        process_failed_recovery || fr_warn "process_failed_recovery が想定外のエラーで終了（後続 Issue 処理は継続）"
    fi

    # Issue ごとに処理
    echo "${issues_json}" | jq -c '.[]' | while read -r issue; do
        issue_number=$(echo "${issue}" | jq -r '.number')
        issue_title=$(echo "${issue}" | jq -r '.title')
        issue_url=$(echo "${issue}" | jq -r '.url')
        issue_labels=$(echo "${issue}" | jq -r '.labels[]' 2>/dev/null || echo "")

        log_section "Issue #${issue_number} を処理中: ${issue_title}"

        # run-summary: issue 番号・stage 記録
        rs_set_issue "${issue_number}"
        rs_record_stage "A"

        # 既に claim されているか確認
        if echo "${issue_labels}" | grep -q "${LABEL_CLAIMED}"; then
            log_warn "Issue #${issue_number} は既に claim されています。スキップ"
            rs_set_result "hold"
            continue
        fi

        # Issue を claim
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Issue #${issue_number} を claim"
        else
            if ! claim_issue "${issue_number}"; then
                log_error "Issue #${issue_number} の claim に失敗。次へ"
                rs_set_result "failed"
                continue
            fi
        fi

        # Issue 本文を取得
        issue_body=$(gh issue view --repo "${REPO}" "${issue_number}" --body 2>/dev/null || echo "")

        # Triage
        log_info "Triage を実行中..."
        triage_prompt=$(build_triage_prompt "${issue_number}" "${issue_title}" "${issue_body}" "${issue_url}")

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Qwen Code を実行: Triage"
            # 仮の判定
            needs_architect=false
            needs_decisions=false
        else
            # Qwen Code で Triage 実行
            if ! run_qwen_headless "${triage_prompt}" "${issue_number}"; then
                log_error "Triage に失敗。Issue #${issue_number} を ${LABEL_FAILED} に設定"
                update_issue_labels "${issue_number}" "${LABEL_FAILED}"
                release_issue "${issue_number}"
                rs_set_result "failed"
                continue
            fi

            # 結果解析（JSON から抽出）
            output_file="${LOG_DIR}/qwen-output-${issue_number}.json"
            if [[ -f "${output_file}" ]]; then
                needs_architect=$(jq -r '.needs_architect // false' "${output_file}" 2>/dev/null || echo "false")
                needs_decisions=$(jq -r '.needs_decisions // false' "${output_file}" 2>/dev/null || echo "false")
            else
                log_warn "Qwen Code の出力ファイルが不存在。デフォルトで続行"
                needs_architect=false
                needs_decisions=false
            fi
        fi

        log_info "Triage 結果: needs_architect=${needs_architect}, needs_decisions=${needs_decisions}"

        # needs-decisions 自動続行（classification=safe かつ第一推奨ありの場合、
        # PM の第一推奨で自動続行。成功時は本ループを skip し、
        # 失敗時 / human-only / 未設定は従来経路へ流れる）
        if [[ "${needs_decisions}" == "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
            output_file="${LOG_DIR}/qwen-output-${issue_number}.json"
            if declare -f nda_evaluate_auto_continue &>/dev/null; then
                if nda_evaluate_auto_continue "${output_file}"; then
                    log_info "needs-decisions 自動続行: Issue #${issue_number} は自動続行済み（次サイクルで再 pickup 待ち）"
                    rs_set_result "hold"
                    continue
                else
                    log_info "needs-decisions 自動続行: skip（従来経路へ）"
                fi
            fi
        fi

        # Architect が必要か判定
        if [[ "${needs_architect}" == "true" ]]; then
            log_info "Architect を起動..."

            # PM 起動（requirements.md 作成）
            log_info "PM を起動（requirements.md 作成）..."

            # Architect 起動（design.md + tasks.md 作成）
            log_info "Architect を起動（design.md + tasks.md 作成）..."

            # PjM: design-review PR 作成
            log_info "PjM: design-review PR 作成..."

            # 人間レビュー待ち（ラベル付与）
            log_info "設計 PR を作成し、人間レビュー待ちに設定"
            update_issue_labels "${issue_number}" "${LABEL_AWAITING_DESIGN}"
            release_issue "${issue_number}"
            rs_set_result "hold"
            continue
        fi

        # Developer 直起動（design-less）
        log_info "Developer を起動（design-less）..."
        rs_record_stage "A'"

        developer_prompt=$(build_developer_prompt "${issue_number}" "${issue_title}" "${issue_url}")

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Qwen Code を実行: Developer"
        else
            if ! run_qwen_headless "${developer_prompt}" "${issue_number}"; then
                log_error "Developer に失敗。Issue #${issue_number} を ${LABEL_FAILED} に設定"
                update_issue_labels "${issue_number}" "${LABEL_FAILED}"
                release_issue "${issue_number}"
                rs_set_result "failed"
                continue
            fi
        fi

        # Reviewer 起動
        log_info "Reviewer を起動..."
        rs_record_stage "B"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Reviewer を実行"
        else
            # Reviewer 実行後、approve なら PjM が impl PR 作成
            log_info "Reviewer: approve → PjM が impl PR 作成"
        fi

        # PjM: impl PR 作成
        log_info "PjM: impl PR 作成..."
        rs_record_stage "C"

        # ラベル更新
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Issue #${issue_number} のラベルを更新: codex-ready-for-review"
        else
            update_issue_labels "${issue_number}" "${LABEL_READY_FOR_REVIEW}"
            release_issue "${issue_number}"
        fi

        rs_set_result "ready"

        log_section "Issue #${issue_number} の処理が完了しました"
    done

    # run-summary: degraded log スキャン
    rs_scan_degraded_log "${LOG_DIR}/idd-qwen-issue-watcher.log"

    log_section "=== Dispatcher を終了 ==="
    log_info "全 Issue の処理が完了しました"
}

# ─── メイン ──────────────────────────────────────────────────────────────────

log_section "=== idd-qwen Issue Watcher を開始 ==="
log_info "REPO=${REPO}"
log_info "REPO_DIR=${REPO_DIR}"
log_info "QWEN_MODEL=${QWEN_MODEL}"
log_info "DRY_RUN=${DRY_RUN}"

# 依存確認
check_dependencies
check_repo

# ロックファイルの取得（単一インスタンス保証）
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    log_warn "他のインスタンスが実行中です。終了待機"
    flock 200
    log_info "前のインスタンスが完了しました"
fi

# Dispatcher 実行
_dispatcher_run

exit 0