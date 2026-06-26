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

# ─── ANSI カラー定数 ────────────────────────────────────────────────────────
# NO_COLOR (https://no-color.org/) が設定されていれば色コードを出力しない。
# shellcheck disable=SC2034
_QW_COLOR_RESET='\033[0m'
_QW_COLOR_BLACK='\033[0;30m'
_QW_COLOR_RED='\033[0;31m'
_QW_COLOR_GREEN='\033[0;32m'
_QW_COLOR_YELLOW='\033[0;33m'
_QW_COLOR_BLUE='\033[0;34m'
_QW_COLOR_MAGENTA='\033[0;35m'
_QW_COLOR_CYAN='\033[0;36m'
_QW_COLOR_WHITE='\033[0;37m'
_QW_COLOR_BOLD='\033[1m'

# NO_COLOR 環境変数が設定されていれば色コードを空文字に置換
_qw_init_colors() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        _QW_COLOR_RESET=''
        _QW_COLOR_BLACK=''
        _QW_COLOR_RED=''
        _QW_COLOR_GREEN=''
        _QW_COLOR_YELLOW=''
        _QW_COLOR_BLUE=''
        _QW_COLOR_MAGENTA=''
        _QW_COLOR_CYAN=''
        _QW_COLOR_WHITE=''
        _QW_COLOR_BOLD=''
    fi
}

# 初回呼び出し時に色を初期化
_qw_colors_initialized=0
_qw_ensure_colors() {
    if [[ "${_qw_colors_initialized}" -ne 1 ]]; then
        _qw_init_colors
        _qw_colors_initialized=1
    fi
}

# ─── ロガー関数 ─────────────────────────────────────────────────────────────

_qw_log() {
    _qw_ensure_colors
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local color=""
    case "${level}" in
        INFO)  color="${_QW_COLOR_BLUE}" ;;
        DEBUG) color="${_QW_COLOR_BLACK}" ;;
        WARN)  color="${_QW_COLOR_YELLOW}" ;;
        ERROR) color="${_QW_COLOR_RED}" ;;
        *)     color="${_QW_COLOR_WHITE}" ;;
    esac
    echo "${color}[${timestamp}] [${level}] ${msg}${_QW_COLOR_RESET}"
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

# ═══════════════════════════════════════════════════════════════════════════════
# 以下は idd-codex 版 full implementation の移植（Processor 専用ロガー等）
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Quota-aware 専用ロガー ─────────────────────────────────────────────────

# Issue #119 Req 1.5 / 1.6 / NFR 2.2: 時刻 prefix と processor prefix の間に
# `[$REPO]` を 1 つだけ挿入し、複数リポ運用時に `grep "\[owner/name\]"` で
# 該当 repo のサイクル全行を抽出できるようにする。
qa_log() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: $*"
}
qa_warn() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: WARN: $*" >&2
}
qa_error() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: ERROR: $*" >&2
}

# ─── ISO 8601 フォーマッタ ──────────────────────────────────────────────────

# epoch 秒 → ISO 8601 (タイムゾーン付き) 文字列。GNU date / BSD date 両対応。
# 失敗時は epoch をそのまま返す。
# Args: $1 = epoch seconds (integer)
# Stdout: ISO 8601 string with TZ offset (e.g. "2026-04-29T15:00:00+09:00")
qa_format_iso8601() {
  local epoch="$1"
  local out=""
  # GNU date (Linux): -d @epoch -Iseconds
  if out=$(date -d "@${epoch}" -Iseconds 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # BSD date (macOS): -r epoch +format
  if out=$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # フォールバック: epoch をそのまま返す
  printf '%s' "$epoch"
}

# ─── Merge-queue 専用ロガー ─────────────────────────────────────────────────

mq_log() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: $*"
}
mq_warn() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: WARN: $*" >&2
}
mq_error() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: ERROR: $*" >&2
}

# ─── Auto-rebase 専用ロガー ─────────────────────────────────────────────────

ar_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: $*"
}
ar_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: WARN: $*" >&2
}
ar_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: ERROR: $*" >&2
}

# ─── Auto-merge 専用ロガー ──────────────────────────────────────────────────

am_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: $*"
}
am_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: WARN: $*" >&2
}
am_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: ERROR: $*" >&2
}

# ─── Design auto-merge 専用ロガー ───────────────────────────────────────────

amd_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: $*"
}
amd_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: WARN: $*" >&2
}
amd_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: ERROR: $*" >&2
}

# ─── Promote-pipeline 専用ロガー ────────────────────────────────────────────

pp_log() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: $*"
}
pp_warn() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: WARN: $*" >&2
}
pp_error() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: ERROR: $*" >&2
}

# ─── PR Iteration 専用ロガー ────────────────────────────────────────────────

pi_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: $*"
}
pi_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: WARN: $*" >&2
}
pi_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: ERROR: $*" >&2
}

# ─── Design Review Release 専用ロガー ───────────────────────────────────────

drr_log() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: $*"
}
drr_warn() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: WARN: $*" >&2
}
drr_error() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: ERROR: $*" >&2
}

# ─── PR Reviewer 専用ロガー ─────────────────────────────────────────────────

pr_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: $*"
}
pr_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: WARN: $*" >&2
}
pr_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: ERROR: $*" >&2
}

# ─── Failed Recovery 専用ロガー ─────────────────────────────────────────────

fr_log() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: $*"
}
fr_warn() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: WARN: $*" >&2
}
fr_error() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: ERROR: $*" >&2
}

# ─── Needs Decisions Auto 専用ロガー ────────────────────────────────────────

nda_log() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: $*"
}
nda_warn() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: WARN: $*" >&2
}
nda_error() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: ERROR: $*" >&2
}

# ─── Slack Notify 専用ロガー ────────────────────────────────────────────────

sn_log() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: $*"
}
sn_warn() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: WARN: $*" >&2
}
sn_error() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: ERROR: $*" >&2
}

# ─── Stale Pickup Reaper 専用ロガー ─────────────────────────────────────────

sr_log() {
  echo "[$(date '+%F %T')] [$REPO] stale-pickup-reaper: $*"
}
sr_warn() {
  echo "[$(date '+%F %T')] [$REPO] stale-pickup-reaper: WARN: $*" >&2
}
sr_error() {
  echo "[$(date '+%F %T')] [$REPO] stale-pickup-reaper: ERROR: $*" >&2
}

# ─── Secure Tempfile Helper ─────────────────────────────────────────────────

# 一時ファイルを private tmp root 配下へ non-predictable name で作成する。
# mktemp 失敗時は fail closed し、呼び出し元が current operation を失敗扱いにできるよう非 0 を返す。
#
# Args:
#   $1 = human-readable label（basename に使う前に safe charset へ正規化）
# Stdout:
#   作成済み tempfile の絶対 path
# Returns:
#   0 = created / 1 = failed（stderr に operator-visible reason）
_qw_secure_mktemp() {
  local label="${1:-tmp}"
  local tmp_root="${IDD_CODEX_TMP_DIR:-}"
  if [ -z "$tmp_root" ]; then
    if [ -n "${LOG_DIR:-}" ]; then
      tmp_root="$LOG_DIR/tmp"
    else
      local uid_part="${UID:-}"
      if [ -z "$uid_part" ]; then
        uid_part="$(id -u 2>/dev/null || printf 'unknown')"
      fi
      tmp_root="${TMPDIR:-/tmp}/idd-qwen-${uid_part}/tmp"
    fi
  fi

  if [ -L "$tmp_root" ]; then
    echo "secure-tempfile: ERROR: tmp root is a symlink: $tmp_root" >&2
    return 1
  fi
  if [ -e "$tmp_root" ] && [ ! -d "$tmp_root" ]; then
    echo "secure-tempfile: ERROR: tmp root is not a directory: $tmp_root" >&2
    return 1
  fi
  if ! mkdir -p "$tmp_root" 2>/dev/null; then
    echo "secure-tempfile: ERROR: failed to create tmp root: $tmp_root" >&2
    return 1
  fi
  if ! chmod 700 "$tmp_root" 2>/dev/null; then
    echo "secure-tempfile: ERROR: failed to set owner-only mode on tmp root: $tmp_root" >&2
    return 1
  fi

  local mode=""
  if mode=$(stat -c '%a' "$tmp_root" 2>/dev/null); then
    :
  elif mode=$(stat -f '%Lp' "$tmp_root" 2>/dev/null); then
    :
  else
    echo "secure-tempfile: ERROR: failed to inspect tmp root mode: $tmp_root" >&2
    return 1
  fi
  if [ "$mode" != "700" ]; then
    echo "secure-tempfile: ERROR: tmp root is not owner-only mode=0${mode}: $tmp_root" >&2
    return 1
  fi

  local safe_label
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9_.-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
  if [ -z "$safe_label" ]; then
    safe_label="tmp"
  fi

  local tmp_file
  if ! tmp_file=$(umask 077; mktemp "$tmp_root/idd-qwen-${safe_label}-XXXXXX" 2>/dev/null); then
    echo "secure-tempfile: ERROR: mktemp failed in private tmp root: $tmp_root" >&2
    return 1
  fi
  chmod 600 "$tmp_file" 2>/dev/null || true
  printf '%s\n' "$tmp_file"
}

# ─── Codex API 529 Overloaded Detector (Issue #259) ─────────────────────────

# Codex API の一時的な過負荷 (HTTP 529 Overloaded) は codex CLI の stream-json
# 出力に Codex API のエラー JSON 断片として現れる。代表的なシグネチャ:
#   - `"api_error_status":529`
#   - `"error_status":529`
#   - `"status":529`（HTTP 5xx の直書き）
#   - `"type":"overloaded_error"`
#   - `"Overloaded"`（人間可読 message）
#
# 設計判断:
#   - false-positive を避けるため、`529` 単独の数値検出はせず、必ず `status[:.]?\s*529`
#     形式（JSON key の隣接）に限定する。
#   - `Overloaded` は API の一般的な過負荷文言と被るため、case-insensitive ではなく
#     大文字 O 始まりの単語境界一致で検出する。
#   - ファイル不在 / 読み取り不能 / 空ファイルは検出なし扱い（後段の警告コメント
#     投稿を抑止して既存挙動を妨げない / Req 1.5 / 2.4 / 4.4）。
#   - 副作用なし（純粋な検査関数）。失敗系含めて呼び出し元の既存処理を継続させる
#     ため、grep が失敗してもエラー伝播させない。
#
# 引数: $1 = 検査対象のログファイルパス
# 戻り値:
#   0 = 529 痕跡を検知（呼び出し元で警告メッセージを付加する）
#   1 = 検知なし（既存メッセージのみ）
#   2 = ファイル不在 / 読み取り不能（検知なし相当として扱うが grep スキップ）
# 出力: stdout には何も書かない。
#
# Requirements: 1.1, 1.5, 2.1, 2.4, 3.1, 3.2, 4.4, NFR 1.1
codex_log_detect_529() {
  local log_path="${1:-}"
  if [ -z "$log_path" ]; then
    return 2
  fi
  if [ ! -f "$log_path" ] || [ ! -r "$log_path" ]; then
    return 2
  fi
  # 検出パターン群:
  #   - `"api_error_status":529` / `"error_status":529` / `"status":529`
  #   - `"type":"overloaded_error"`
  #   - 単独の "Overloaded" 単語境界
  if grep -qE '"(api_error_status|error_status|status)"\s*:\s*529' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bstatus\s*:\s*529\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '"type"\s*:\s*"overloaded_error"' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bOverloaded\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C: Worktree Manager
# ═══════════════════════════════════════════════════════════════════════════════

# Per-slot 永続 worktree を $WORKTREE_BASE_DIR/<repo-slug>/slot-N/ に配置し、
# slot 同士の作業ツリー干渉を物理隔離する（Req 3.5）。

# slot 番号から worktree ディレクトリの絶対パスを返す。
# 引数: $1 = slot 番号
# Req 3.1, 3.7
_worktree_path() {
  local n="$1"
  echo "$WORKTREE_BASE_DIR/$REPO_SLUG/slot-$n"
}

# 指定 path が現在の repo の git worktree として登録済みかを判定。
# 0 = 登録済み / 非ゼロ = 未登録
_worktree_is_registered() {
  local wt_path="$1"
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
    | grep -Fx "worktree $wt_path" >/dev/null 2>&1
}

# Per-slot worktree を冪等に確保する。
# 引数: $1 = slot 番号
# 戻り値: 0 = ok（worktree が存在し利用可能） / 1 = 失敗
# 副作用: $WORKTREE_BASE_DIR/<slug>/slot-N/ を作成または再利用
_worktree_ensure() {
  local n="$1"
  local wt_path
  wt_path="$(_worktree_path "$n")"
  local parent_dir
  parent_dir="$(dirname "$wt_path")"

  if ! mkdir -p "$parent_dir" 2>/dev/null; then
    dispatcher_warn "slot-${n}: worktree 親ディレクトリ作成に失敗: $parent_dir"
    return 1
  fi

  # ケース A: 既に worktree として登録済み → 再利用
  if _worktree_is_registered "$wt_path"; then
    if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
      return 0
    fi
    # 登録は残っているが実体が壊れている → prune してから再作成
    dispatcher_warn "slot-${n}: worktree 登録あり実体欠損、prune して再作成: $wt_path"
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース B: dir は存在するが worktree として登録されていない
  if [ -e "$wt_path" ]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local broken="${wt_path}.broken-${ts}"
    dispatcher_warn "slot-${n}: 既存ディレクトリを退避して worktree を再作成: $wt_path -> $broken"
    if ! mv "$wt_path" "$broken" 2>/dev/null; then
      dispatcher_warn "slot-${n}: 既存ディレクトリの退避に失敗: $wt_path"
      return 1
    fi
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース C: 新規作成（origin/$BASE_BRANCH から detached HEAD として）
  if ! git -C "$REPO_DIR" worktree add --detach "$wt_path" "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    dispatcher_warn "slot-${n}: git worktree add に失敗: $wt_path"
    return 1
  fi
  dispatcher_log "slot-${n}: worktree 作成: $wt_path (detached @ origin/${BASE_BRANCH})"
  return 0
}

# Per-slot worktree を origin/$BASE_BRANCH の最新状態に強制リセットする。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = ok / 1 = 失敗
#
# Issue #295: root 所有 docker bind-mount 生成物（`frontend/node_modules/` /
# `frontend/.next/` 等）が残った場合、`git clean -fdx` が EACCES で非 0 終了する。
# 旧実装は stderr を `/dev/null` に握り潰しており、失敗理由が SLOT_LOG に残らず
# 無関係な次 Issue に `codex-failed` が付く偽陽性が発生していた。本改修は:
#   - 失敗時 stderr を SLOT_LOG に残す（Req 1.1, 1.2, 1.3）
#   - `WORKTREE_DOCKER_CLEANUP_ENABLED=true` opt-in 時のみ docker 経路で root 所有
#     artifact を削除する escalation を追加（Req 2 / Req 3）
#   - docker 経路が使えない／失敗した場合は `git worktree remove --force` →
#     `git worktree add --detach` の fallback で worktree を作り直す（Req 4）
#   - 通常ケース（root 所有 artifact なし）は追加処理を起動しない（Req 5.1）
#
# Req 1.1, 1.2, 1.3, 1.4, 3.4, 5.1, 5.2, 5.3, 5.4
_worktree_reset() {
  local wt="$1"
  if [ ! -d "$wt" ]; then
    return 1
  fi
  # NOTE (Issue #167): per-slot の `git -C "$wt" fetch origin --prune` は削除。
  # 複数 slot worktree は同一 $REPO_DIR の .git オブジェクト DB / refs を共有するため、
  # PARALLEL_SLOTS>1 で複数 slot がほぼ同時に fetch すると lock 競合が起きる。
  # origin 参照の最新化は親プロセスがサイクル冒頭で 1 回だけ実行済み。
  #
  # 1. detached HEAD を origin/$BASE_BRANCH に強制移動。
  #    reset 前に必ず detached に戻し、古い Issue branch を汚染しない（Issue #58）。
  if ! git -C "$wt" checkout --detach --force "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: git checkout --detach failed (wt=$wt, base=origin/${BASE_BRANCH})" >&2
    return 1
  fi

  # 2. origin/$BASE_BRANCH に強制移動。
  #    Issue #295: stderr は SLOT_LOG に残すため `2>/dev/null` を外す（Req 1.1, 1.3）。
  if ! git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: git reset --hard failed (wt=$wt)" >&2
    return 1
  fi

  # 3. untracked + ignored を消去。
  #    EACCES 起因の失敗を検出して escalated cleanup に分岐するため、stderr を tmp file に
  #    キャプチャしてから内容を SLOT_LOG（>&2 経由）にも転写する。
  local clean_stderr=""
  if ! clean_stderr="$(_qw_secure_mktemp "worktree-reset-clean-stderr")"; then
    echo "[$(date '+%F %T')] worktree-reset: ERROR: secure stderr tempfile creation failed (wt=$wt)" >&2
    return 1
  fi
  local clean_rc=0
  git -C "$wt" clean -fdx >/dev/null 2>"$clean_stderr" || clean_rc=$?

  if [ "$clean_rc" -eq 0 ]; then
    if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
      cat "$clean_stderr" >&2 || true
    fi
    if [ -n "$clean_stderr" ]; then
      rm -f "$clean_stderr" 2>/dev/null || true
    fi
    return 0
  fi

  # 失敗パス: stderr を SLOT_LOG（>&2）に転写（Req 1.2, 1.3）。
  if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
    echo "[$(date '+%F %T')] worktree-reset: git clean -fdx failed (wt=$wt, rc=$clean_rc):" >&2
    cat "$clean_stderr" >&2 || true
  else
    echo "[$(date '+%F %T')] worktree-reset: git clean -fdx failed (wt=$wt, rc=$clean_rc, no stderr captured)" >&2
  fi

  # EACCES / permission 起因か判定（Req 3.1, 3.5）。
  local is_perm_fail=0
  if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
    if grep -qE 'EACCES|[Pp]ermission denied|Operation not permitted' "$clean_stderr" 2>/dev/null; then
      is_perm_fail=1
    fi
  fi
  if [ -n "$clean_stderr" ]; then
    rm -f "$clean_stderr" 2>/dev/null || true
  fi

  if [ "$is_perm_fail" -ne 1 ]; then
    return 1
  fi

  echo "[$(date '+%F %T')] worktree-reset: permission-denied detected, starting escalated cleanup (wt=$wt)" >&2

  # Docker 経路（opt-in / Req 2 / Req 3.2）。
  if [ "${WORKTREE_DOCKER_CLEANUP_ENABLED:-false}" = "true" ]; then
    if command -v docker >/dev/null 2>&1; then
      if _worktree_reset_docker_cleanup "$wt"; then
        if git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null \
          && git -C "$wt" clean -fdx >/dev/null; then
          echo "[$(date '+%F %T')] worktree-reset: docker cleanup + retry reset 成功 (wt=$wt)" >&2
          return 0
        fi
        echo "[$(date '+%F %T')] worktree-reset: docker cleanup 後の reset/clean が再度失敗 (wt=$wt)" >&2
      else
        echo "[$(date '+%F %T')] worktree-reset: docker cleanup 試行が失敗 (wt=$wt)" >&2
      fi
    else
      echo "[$(date '+%F %T')] worktree-reset: WORKTREE_DOCKER_CLEANUP_ENABLED=true だが docker コマンド未検出、fallback へ (wt=$wt)" >&2
    fi
  else
    echo "[$(date '+%F %T')] worktree-reset: WORKTREE_DOCKER_CLEANUP_ENABLED=true 未宣言、docker 経路 skip して fallback へ (wt=$wt)" >&2
  fi

  # worktree 再作成 fallback（Req 4）。
  if _worktree_reset_recreate "$wt"; then
    echo "[$(date '+%F %T')] worktree-reset: worktree 再作成 fallback で復旧 (wt=$wt)" >&2
    return 0
  fi
  echo "[$(date '+%F %T')] worktree-reset: ERROR: escalated cleanup 全経路が失敗 (wt=$wt) — _worktree_reset を非 0 終了" >&2
  return 1
}

# Docker cleanup 経路。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = cleanup 成功 / 1 = 失敗
_worktree_reset_docker_cleanup() {
  local wt="$1"
  local image="${WORKTREE_DOCKER_CLEANUP_IMAGE:-busybox}"
  if ! docker run --rm --network=none \
    -v "$wt":/wt \
    "$image" \
    sh -c 'set -e; cd /wt && find . -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +'; then
    return 1
  fi
  return 0
}

# Docker cleanup が利用不可／失敗したときの最終 fallback として、worktree を作り直す。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = 再作成成功 / 1 = 失敗
_worktree_reset_recreate() {
  local wt="$1"
  echo "[$(date '+%F %T')] worktree-reset: 再作成 fallback 開始 (wt=$wt)" >&2

  if ! git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] worktree-reset: git worktree remove --force が失敗（既存未登録の可能性、prune で継続） (wt=$wt)" >&2
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  if [ -e "$wt" ]; then
    if ! rm -rf "$wt"; then
      echo "[$(date '+%F %T')] worktree-reset: ERROR: 既存 worktree dir の rm に失敗（root 所有残存の可能性） (wt=$wt)" >&2
      return 1
    fi
  fi

  if ! git -C "$REPO_DIR" worktree add --detach "$wt" "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: ERROR: git worktree add 再作成に失敗 (wt=$wt)" >&2
    return 1
  fi
  echo "[$(date '+%F %T')] worktree-reset: 再作成 fallback 完了 (wt=$wt, base=origin/${BASE_BRANCH})" >&2
  return 0
}

# worktree の最終 scaffolding 状態を run サマリへ記録する薄いヘルパ。
# 引数: $1 = 判定対象 worktree 絶対パス
# 戻り値: 常に 0（fail-open）
_worktree_record_scaffolding() {
  local wt="$1"
  command -v rs_set_scaffolding >/dev/null 2>&1 || return 0
  if [ -d "$wt/.codex/agents" ] && [ -d "$wt/.codex/rules" ]; then
    rs_set_scaffolding ok || true
  else
    rs_set_scaffolding missing || true
  fi
  return 0
}

# gitignore 運用 repo 向けに、worktree reset 直後の slot worktree へ
# REPO_DIR のローカル `.codex/` を注入する（Issue #237）。
# 引数:
#   $1 = 注入元 REPO_DIR
#   $2 = 注入先 worktree 絶対パス
# 戻り値: 常に 0（fail-open）
_worktree_inject_codex() {
  local src_repo_dir="$1"
  local wt="$2"

  # NO-OP 条件 1: worktree に既に `.codex/` がある = tracked 運用 repo。
  if [ -e "$wt/.codex" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi
  # NO-OP 条件 2: 注入元 REPO_DIR に `.codex/` が無い。
  if [ ! -d "$src_repo_dir/.codex" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # `.codex/` のみをコピーする（`cp -a` で mode / timestamps / symlink を保持）。
  if cp -a "$src_repo_dir/.codex" "$wt/" 2>/dev/null; then
    slot_log ".codex を REPO_DIR から worktree へ注入 (src=$src_repo_dir/.codex)"
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # fail-open（Req 3.1, 3.2, 3.3）: コピー失敗時は warn のみ出して継続する。
  rm -rf "$wt/.codex" 2>/dev/null || true
  slot_warn ".codex の注入に失敗しました（継続します / src=$src_repo_dir/.codex）"
  _worktree_record_scaffolding "$wt"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C: Slot Lock Manager
# ═══════════════════════════════════════════════════════════════════════════════

# slot 番号から lock file path を返す。
# 引数: $1 = slot 番号
# Req 4.1
_slot_lock_path() {
  local n="$1"
  echo "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-${n}.lock"
}

# 指定 slot の per-slot 非ブロッキング flock を取得する（成功時 fd 210+N が open のまま残る）。
# 引数: $1 = slot 番号
# 戻り値: 0 = acquired / 1 = 既に他プロセスがロック中、または fd open 失敗
_slot_acquire() {
  local n="$1"
  local lock_file
  lock_file="$(_slot_lock_path "$n")"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
  local fd=$((210 + n))
  if ! eval "exec ${fd}>\"\$lock_file\"" 2>/dev/null; then
    return 1
  fi
  if ! flock -n "$fd" 2>/dev/null; then
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  return 0
}

# 指定 slot の per-slot lock を解放する。
# 引数: $1 = slot 番号
# 戻り値: 常に 0
_slot_release() {
  local n="$1"
  local fd=$((210 + n))
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

# ─── SLOT_INIT_HOOK 起動 wrapper ────────────────────────────────────────────

# SLOT_INIT_HOOK が設定されていれば実行する。
# 引数: $1 = slot 番号
# 戻り値: hook の exit status（hook が未設定なら 0）
_hook_invoke() {
  local n="$1"
  if [ -z "${SLOT_INIT_HOOK:-}" ]; then
    return 0
  fi
  local hook_log="${SLOT_LOG_DIR:-/tmp}/slot-${n}-hook.log"
  eval "$SLOT_INIT_HOOK" >> "$hook_log" 2>&1
  return $?
}

# ─── full_auto_enabled: 完全自動化 kill switch の述語 (#97 移植) ──────────
#
# 用途: 完全自動化（full-auto）系の外部副作用を安全に制御する。
#   `FULL_AUTO_ENABLED` が `true` の場合のみ true を返す。
#   二重 opt-in gate（例: `SLACK_NOTIFY_ENABLED` AND `full_auto_enabled`）で使用する。
#   既定は false（安全側）。unset / 空 / typo（`True` / `on` / `1`）は全て false。
#
# 戻り値: 0 = FULL_AUTO_ENABLED=true / 1 = それ以外
# ─────────────────────────────────────────────────────────────────────────────
full_auto_enabled() {
  case "${FULL_AUTO_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

core_utils_init() {
    _qw_log_debug "core_utils.sh をロードしました"
}