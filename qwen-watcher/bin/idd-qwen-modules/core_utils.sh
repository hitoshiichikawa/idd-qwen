#!/usr/bin/env bash
# core_utils.sh - Qwen Code 版共通ユーティリティ
#
# 用途: idd-qwen watcher で使用する低レベルユーティリティ関数を提供
#
# 著者: idd-qwen contributors
# ライセンス: MIT
#
# 依存:
#   - 本モジュールは idd-qwen-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$LOG_DIR 等）は本体側で定義済み。

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

_qw_get_required() {
    local var_name="${1:?var_name required}"
    local value="${!var_name:-}"
    if [[ -z "${value}" ]]; then
        _qw_log_error "Required environment variable '${var_name}' is not set"
        return 1
    fi
    echo "${value}"
}

_qw_get_path() {
    local var_name="${1:?var_name required}"
    local default="${2:-}"
    local value="${!var_name:-$default}"
    local dir
    dir="$(dirname "$value")"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" 2>/dev/null || {
            _qw_log_error "Failed to create directory: ${dir}"
            return 1
        }
    fi
    echo "${value}"
}

# ─── 一時ファイル・ディレクトリ管理 ──────────────────────────────────────────

_qw_tmpfile() {
    local prefix="${1:-tmp}"
    local tmp_dir="${IDD_CODEX_TMP_DIR:-}"
    if [[ -z "${tmp_dir}" ]]; then
        if [[ -n "${LOG_DIR:-}" ]]; then
            tmp_dir="${LOG_DIR}/tmp"
        else
            tmp_dir="${TMPDIR:-/tmp}/idd-qwen-$(id -u 2>/dev/null || echo "unknown")/tmp"
        fi
    fi

    if [[ -L "${tmp_dir}" ]]; then
        _qw_log_error "tmp root is a symlink: ${tmp_dir}"
        return 1
    fi

    if [[ ! -d "${tmp_dir}" ]]; then
        if ! mkdir -p "${tmp_dir}" 2>/dev/null; then
            _qw_log_error "Failed to create tmp root: ${tmp_dir}"
            return 1
        fi
        chmod 700 "${tmp_dir}" 2>/dev/null || true
    fi

    local safe_prefix
    safe_prefix="$(printf '%s' "$prefix" | tr -cs 'A-Za-z0-9_.-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
    if [[ -z "${safe_prefix}" ]]; then
        safe_prefix="tmp"
    fi

    local tmp_file
    tmp_file="$(umask 077; mktemp "${tmp_dir}/qw-${safe_prefix}-XXXXXX" 2>/dev/null)" || {
        _qw_log_error "mktemp failed in tmp root: ${tmp_dir}"
        return 1
    }
    chmod 600 "${tmp_file}" 2>/dev/null || true
    echo "${tmp_file}"
}

_qw_tmpdir() {
    local prefix="${1:-tmp}"
    local tmp_dir="${IDD_CODEX_TMP_DIR:-}"
    if [[ -z "${tmp_dir}" ]]; then
        if [[ -n "${LOG_DIR:-}" ]]; then
            tmp_dir="${LOG_DIR}/tmp"
        else
            tmp_dir="${TMPDIR:-/tmp}/idd-qwen-$(id -u 2>/dev/null || echo "unknown")/tmp"
        fi
    fi

    if [[ ! -d "${tmp_dir}" ]]; then
        mkdir -p "${tmp_dir}" 2>/dev/null || {
            _qw_log_error "Failed to create tmp root: ${tmp_dir}"
            return 1
        }
        chmod 700 "${tmp_dir}" 2>/dev/null || true
    fi

    local safe_prefix
    safe_prefix="$(printf '%s' "$prefix" | tr -cs 'A-Za-z0-9_.-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
    if [[ -z "${safe_prefix}" ]]; then
        safe_prefix="tmp"
    fi

    local tmp_dir_result
    tmp_dir_result="$(umask 077; mktemp -d "${tmp_dir}/qw-${safe_prefix}-XXXXXX" 2>/dev/null)" || {
        _qw_log_error "mktemp -d failed in tmp root: ${tmp_dir}"
        return 1
    }
    echo "${tmp_dir_result}"
}

_qw_cleanup() {
    local path="$1"
    if [[ -f "${path}" ]]; then
        rm -f "${path}" 2>/dev/null || true
    elif [[ -d "${path}" ]]; then
        rm -rf "${path}" 2>/dev/null || true
    fi
}

_qw_on_exit_cleanup() {
    local tmp_paths=("$@")
    local tmp_path
    for tmp_path in "${tmp_paths[@]}"; do
        _qw_cleanup "${tmp_path}"
    done
}

# ─── ファイル操作ヘルパー ───────────────────────────────────────────────────

_qw_file_exists() {
    local path="$1"
    [[ -f "${path}" ]]
}

_qw_dir_exists() {
    local path="$1"
    [[ -d "${path}" ]]
}

_qw_mkdir_p() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        _qw_log_info "Directory created: ${dir}"
    fi
}

_qw_read_file() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        _qw_log_error "File not found: ${path}"
        return 1
    fi
    cat "${path}" 2>/dev/null
}

_qw_write_file() {
    local path="$1"
    local content="$2"
    local dir
    dir="$(dirname "$path")"
    _qw_mkdir_p "${dir}"
    printf '%s' "${content}" > "${path}" 2>/dev/null || {
        _qw_log_error "Failed to write file: ${path}"
        return 1
    }
}

_qw_append_file() {
    local path="$1"
    local content="$2"
    local dir
    dir="$(dirname "$path")"
    _qw_mkdir_p "${dir}"
    printf '%s\n' "${content}" >> "${path}" 2>/dev/null || {
        _qw_log_error "Failed to append to file: ${path}"
        return 1
    }
}

_qw_file_is_empty() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        return 1
    fi
    [[ ! -s "${path}" ]]
}

# ─── 文字列操作ヘルパー ─────────────────────────────────────────────────────

_qw_trim() {
    local str="$1"
    # 両端の空白を削除
    str="${str#"${str%%[![:space:]]*}"}"
    str="${str%"${str##*[![:space:]]}"}"
    echo "${str}"
}

_qw_starts_with() {
    local str="$1"
    local prefix="$2"
    [[ "${str}" == "${prefix}"* ]]
}

_qw_ends_with() {
    local str="$1"
    local suffix="$2"
    [[ "${str}" == *"${suffix}" ]]
}

_qw_contains() {
    local str="$1"
    local substr="$2"
    [[ "${str}" == *"${substr}"* ]]
}

_qw_slugify() {
    local title="$1"
    # lowercase / ハイフン区切り / 40 文字以内に正規化
    local slug
    slug="$(echo "${title}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
    echo "${slug:0:40}"
}

# ─── 配列操作ヘルパー ───────────────────────────────────────────────────────

_qw_array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

_qw_array_unique() {
    local -A seen
    local item
    for item in "$@"; do
        if [[ -z "${seen[${item}]:-}" ]]; then
            seen["${item}"]=1
            echo "${item}"
        fi
    done
}

_qw_array_join() {
    local separator="$1"
    shift
    local first=1
    local item
    for item in "$@"; do
        if [[ "${first}" -eq 1 ]]; then
            printf '%s' "${item}"
            first=0
        else
            printf '%s%s' "${separator}" "${item}"
        fi
    done
    echo ""
}

_qw_array_slice() {
    local start="$1"
    local length="$2"
    shift 2
    local items=("$@")
    local count="${#items[@]}"
    local end=$((start + length))
    if [[ "${end}" -gt "${count}" ]]; then
        end="${count}"
    fi
    local i
    for ((i = start; i < end; i++)); do
        echo "${items[i]}"
    done
}

# ─── 数値計算ヘルパー ───────────────────────────────────────────────────────

_qw_random_int() {
    local min="${1:-0}"
    local max="${2:-100}"
    local range=$((max - min + 1))
    if [[ "${range}" -le 0 ]]; then
        _qw_log_error "Invalid range: min=${min} max=${max}"
        return 1
    fi
    echo $((RANDOM % range + min))
}

_qw_max() {
    local a="$1"
    local b="$2"
    if [[ "${a}" -ge "${b}" ]]; then
        echo "${a}"
    else
        echo "${b}"
    fi
}

_qw_min() {
    local a="$1"
    local b="$2"
    if [[ "${a}" -le "${b}" ]]; then
        echo "${a}"
    else
        echo "${b}"
    fi
}

_qw_clamp() {
    local value="$1"
    local min_val="$2"
    local max_val="$3"
    if [[ "${value}" -lt "${min_val}" ]]; then
        echo "${min_val}"
    elif [[ "${value}" -gt "${max_val}" ]]; then
        echo "${max_val}"
    else
        echo "${value}"
    fi
}

# ─── 日付・時刻ヘルパー ─────────────────────────────────────────────────────

_qw_epoch() {
    date '+%s'
}

_qw_iso8601() {
    local epoch="${1:-}"
    if [[ -z "${epoch}" ]]; then
        date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
        return
    fi
    # GNU date (Linux): -d @epoch -Iseconds
    local out
    if out="$(date -d "@${epoch}" -Iseconds 2>/dev/null)" && [[ -n "${out}" ]]; then
        echo "${out}"
        return
    fi
    # BSD date (macOS): -r epoch +format
    if out="$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null)" && [[ -n "${out}" ]]; then
        echo "${out}"
        return
    fi
    # Fallback: return epoch as-is
    echo "${epoch}"
}

_qw_human_duration() {
    local seconds="$1"
    if [[ -z "${seconds}" ]] || [[ "${seconds}" -le 0 ]] 2>/dev/null; then
        echo "0s"
        return
    fi

    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))

    local result=""
    if [[ "${days}" -gt 0 ]]; then
        result="${days}d"
    fi
    if [[ "${hours}" -gt 0 ]]; then
        result="${result}${hours}h"
    fi
    if [[ "${minutes}" -gt 0 ]]; then
        result="${result}${minutes}m"
    fi
    if [[ "${secs}" -gt 0 ]] || [[ -z "${result}" ]]; then
        result="${result}${secs}s"
    fi
    echo "${result}"
}

# ─── 進捗表示ヘルパー ───────────────────────────────────────────────────────

_qw_progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"

    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do
        bar="${bar}#"
    done
    for ((i = 0; i < empty; i++)); do
        bar="${bar}-"
    done

    printf "\r[%s] %3d%% (%d/%d)" "${bar}" "${percent}" "${current}" "${total}"
    if [[ "${current}" -eq "${total}" ]]; then
        echo ""
    fi
}

_qw_spinner() {
    local pid="$1"
    local message="$2"
    local spinchars=("|" "/" "-" "\\")
    local idx=0

    # バックグラウンドでスピナーを回す
    (
        while kill -0 "${pid}" 2>/dev/null; do
            printf "\r[%s] %s" "${spinchars[idx]}" "${message}"
            idx=$(( (idx + 1) % ${#spinchars[@]} ))
            sleep 0.1
        done
        # 完了時にクリア
        printf "\r[✓] %s\n" "${message}"
    ) &
    echo $!
}

_qw_status_message() {
    local status="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${status}] ${message}"
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

    _qw_log_info "Qwen Code を実行: issue #${issue_number}"
    _qw_log_debug "コマンド: ${cmd}"

    eval "${cmd}" 2>&1 || {
        _qw_log_error "Qwen Code の実行に失敗しました"
        return 1
    }

    _qw_log_info "Qwen Code の実行が完了: ${output_file}"
    return 0
}

# ─── Issue 番号と Slug の生成 ───────────────────────────────────────────────

_qw_generate_slug() {
    local title="$1"
    # lowercase / ハイフン区切り / 40 文字以内に正規化
    local slug
    slug="$(echo "${title}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
    echo "${slug:0:40}"
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
    local label
    for label in "${labels[@]}"; do
        gh_labels="${gh_labels} --add-label \"${label}\""
    done

    if [[ -n "${gh_labels}" ]]; then
        eval "gh issue edit --repo \"${repo}\" \"${issue_number}\" ${gh_labels}" 2>/dev/null || {
            _qw_log_error "ラベルの付与に失敗: ${labels[*]}"
            return 1
        }
    fi

    return 0
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

core_utils_init() {
    _qw_log_debug "core_utils.sh をロードしました"
}