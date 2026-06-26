#!/usr/bin/env bash
# core_utils.sh - Qwen Code 版共通ユーティリティ
#
# 用途: idd-qwen watcher で使用する低レベルユーティリティ関数を提供
#
# 著者: idd-qwen contributors
# ライセンス: MIT

# 既に source されていれば何もしない
_is_core_utils_loaded() { return 0; }

# ─── ロガー関数 ─────────────────────────────────────────────────────────────

_qw_log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}"
}

_qw_log_info()  { _qw_log "INFO"  "$@"; }
_qw_log_warn()  { _qw_log "WARN"  "$@"; }
_qw_log_error() { _qw_log "ERROR" "$@" >&2; }
_qw_log_debug() { _qw_log "DEBUG" "$@"; }
_qw_log_section() { echo ""; _qw_log "INFO" "=== $* ==="; echo ""; }

# ─── 環境変数ヘルパー ───────────────────────────────────────────────────────

_qw_get_env() {
    local var_name="${1:?var_name required}"
    local default="${2:-}"
    echo "${!var_name:-$default}"
}

_qw_get_bool() {
    local var_name="${1:?var_name required}"
    local default="${2:-false}"
    local value="${!var_name:-$default}"
    if [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

_qw_get_int() {
    local var_name="${1:?var_name required}"
    local default="${2:-0}"
    local value="${!var_name:-$default}"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        echo "${value}"
    else
        echo "${default}"
    fi
}

# ─── GitHub API ヘルパー ────────────────────────────────────────────────────

_qw_gh_issue_list() {
    local repo="${1:?repo required}"
    local labels="${2:-}"
    local state="${3:-open}"
    local json_query="${4:-'.[] | {number: .number, title: .title, url: .url, labels: [.labels[].name]}'}"

    local cmd="gh issue list --repo \"${repo}\" --state \"${state}\" --json number,title,url,labels"
    if [[ -n "${labels}" ]]; then
        cmd="${cmd} --label \"${labels}\""
    fi

    eval "${cmd} --jq '${json_query}'" 2>/dev/null || echo ""
}

_qw_gh_issue_edit() {
    local repo="${1:?repo required}"
    local number="$2"
    shift 2
    gh issue edit --repo "${repo}" "${number}" "$@" 2>/dev/null
}

_qw_gh_issue_comment() {
    local repo="${1:?repo required}"
    local number="$2"
    local body="$3"
    gh issue comment --repo "${repo}" "${number}" --body "${body}" 2>/dev/null
}

# ─── Qwen Code ヘッドレス実行ヘルパー ───────────────────────────────────────

_qw_run_qwen_headless() {
    local prompt="$1"
    local issue_number="$2"
    local output_file="${3:-}"
    # shellcheck disable=SC2034
    local model="${QWEN_MODEL:-gpt-5.5}"
    local yolo="${QWEN_YOLO:-true}"
    local max_turns="${QWEN_MAX_TURNS:-100}"
    local max_wall_time="${QWEN_MAX_WALL_TIME:-900}"
    local output_dir="${LOG_DIR:-${HOME}/log/idd-qwen}"

    if [[ -z "${output_file}" ]]; then
        output_file="${output_dir}/qwen-output-${issue_number}.json"
    fi

    local cmd="qwen \"${prompt}\" \
        --channel CI \
        --output-format json \
        --json-file \"${output_file}\""

    if [[ "${yolo}" == "true" ]]; then
        cmd="${cmd} -y"
    fi

    cmd="${cmd} --max-session-turns \"${max_turns}\" --max-wall-time \"${max_wall_time}s\""

    log_info "Qwen Code を実行: issue #${issue_number}"
    log_debug "コマンド: ${cmd}"

    eval "${cmd}" 2>&1 || {
        log_error "Qwen Code の実行に失敗しました"
        return 1
    }

    log_info "Qwen Code の実行が完了: ${output_file}"
    return 0
}

# ─── ファイル操作ヘルパー ───────────────────────────────────────────────────

_qw_mkdir_p() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        log_info "ディレクトリを作成: ${dir}"
    fi
}

_qw_file_exists() {
    local path="$1"
    [[ -f "${path}" ]]
}

_qw_dir_exists() {
    local path="$1"
    [[ -d "${path}" ]]
}

# ─── Issue 番号と Slug の生成 ───────────────────────────────────────────────

_qw_generate_slug() {
    local title="$1"
    # lowercase / ハイフン区切り / 40 文字以内に正規化
    local slug
    slug=$(echo "${title}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
    slug="${slug:0:40}"
    echo "${slug}"
}

_qw_spec_dir() {
    local issue_number="$1"
    local slug="$2"
    echo "docs/specs/${issue_number}-${slug}"
}

# ─── ラベル操作ヘルパー ─────────────────────────────────────────────────────

_qw_update_issue_labels() {
    local repo="$1"
    local issue_number="$2"
    shift 2
    local labels=("$@")

    # 既存ラベルを一旦全て削除（codex-* ラベルのみ）
    gh issue edit --repo "${repo}" "${issue_number}" \
        --remove-label "codex-auto-dev" \
        --remove-label "codex-claimed" \
        --remove-label "codex-picked-up" \
        --remove-label "codex-ready-for-review" \
        --remove-label "codex-failed" \
        --remove-label "codex-awaiting-design-review" \
        --remove-label "codex-awaiting-slot" \
        --remove-label "codex-blocked" \
        --remove-label "codex-needs-rebase" \
        --remove-label "codex-needs-iteration" \
        --remove-label "codex-needs-quota-wait" \
        --remove-label "codex-staged-for-release" \
        --remove-label "codex-st-failed" \
        --remove-label "codex-skip-triage" \
        --remove-label "codex-needs-decisions" \
        2>/dev/null || true

    # 新ラベルを付与
    local gh_labels=""
    for label in "${labels[@]}"; do
        gh_labels="${gh_labels} --add-label \"${label}\""
    done

    if [[ -n "${gh_labels}" ]]; then
        eval "gh issue edit --repo \"${repo}\" \"${issue_number}\" ${gh_labels}" 2>/dev/null || {
            log_error "ラベルの付与に失敗: ${labels[*]}"
            return 1
        }
    fi

    return 0
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

core_utils_init() {
    log_debug "core_utils.sh をロードしました"
}