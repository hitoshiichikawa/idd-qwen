#!/usr/bin/env bash
# install.sh - idd-qwen インストーラ
#
# 用途: idd-qwen をユーザースコープにインストール
#
# 著者: idd-qwen contributors
# ライセンス: MIT

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
LAUNCH_DIR="${LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${LOG_DIR:-$HOME/log/idd-qwen}"
LOCK_DIR="${LOCK_DIR:-$HOME/lock}"

# ─── 引数処理 ───────────────────────────────────────────────────────────────

DRY_RUN=false
FORCE=false
REPO=""
REPO_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
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
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: install.sh [--dry-run] [--force] [--repo owner/repo] [--repo-dir /path/to/repo]"
            echo ""
            echo "Options:"
            echo "  --dry-run          Show what would be installed"
            echo "  --force            Overwrite existing files"
            echo "  --repo OWNER/REPO  GitHub repository to monitor"
            echo "  --repo-dir PATH    Path to the repository clone"
            echo "  --install-dir PATH  Installation directory (default: ~/bin)"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ─── ロガー ──────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_section() { echo ""; echo "=== $* ==="; echo ""; }

# ─── インストール ────────────────────────────────────────────────────────────

install_files() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script_src="${script_dir}/qwen-watcher/bin/idd-qwen-issue-watcher.sh"
    local plist_src="${script_dir}/qwen-watcher/launch/com.idd-qwen.issue-watcher.plist"

    if [[ ! -f "${script_src}" ]]; then
        log_error "Watcher スクリプトが見つかりません: ${script_src}"
        exit 1
    fi

    if [[ ! -f "${plist_src}" ]]; then
        log_error "LaunchAgents plist が見つかりません: ${plist_src}"
        exit 1
    fi

    # ディレクトリ作成
    if [[ "${DRY_RUN}" == "false" ]]; then
        mkdir -p "${INSTALL_DIR}"
        mkdir -p "${LAUNCH_DIR}"
        mkdir -p "${LOG_DIR}"
        mkdir -p "${LOCK_DIR}"
    fi

    # スクリプトインストール
    local script_dst="${INSTALL_DIR}/idd-qwen-issue-watcher.sh"
    if [[ -f "${script_dst}" && "${FORCE}" == "false" ]]; then
        log_warn "既存ファイルを上書きしません: ${script_dst}"
        log_warn "--force を指定すると上書きされます"
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] インストール: ${script_src} → ${script_dst}"
        else
            cp "${script_src}" "${script_dst}"
            chmod +x "${script_dst}"
            log_info "インストール完了: ${script_dst}"
        fi
    fi

    # modules ディレクトリインストール
    local modules_src="${script_dir}/qwen-watcher/bin/idd-qwen-modules"
    local modules_dst="${INSTALL_DIR}/idd-qwen-modules"
    if [[ -d "${modules_src}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] インストール: ${modules_src} → ${modules_dst}/"
        else
            cp -R "${modules_src}" "${modules_dst}"
            log_info "インストール完了: ${modules_dst}/"
        fi
    else
        log_error "Modules ディレクトリが見つかりません: ${modules_src}"
        exit 1
    fi

    # LaunchAgents plist インストール
    local plist_dst="${LAUNCH_DIR}/com.idd-qwen.issue-watcher.plist"

    # plist 内のプレースホルダを置換
    local plist_content
    plist_content=$(cat "${plist_src}")

    if [[ -n "${REPO}" ]]; then
        plist_content=$(echo "${plist_content}" | sed "s|owner/your-repo|${REPO}|g")
    fi
    if [[ -n "${REPO_DIR}" ]]; then
        plist_content=$(echo "${plist_content}" | sed "s|/Users/hitoshi/work/your-repo|${REPO_DIR}|g")
    fi
    plist_content=$(echo "${plist_content}" | sed "s|/Users/hitoshi|${HOME}|g")

    if [[ -f "${plist_dst}" && "${FORCE}" == "false" ]]; then
        log_warn "既存ファイルを上書きしません: ${plist_dst}"
        log_warn "--force を指定すると上書きされます"
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] インストール: ${plist_src} → ${plist_dst}"
        else
            echo "${plist_content}" > "${plist_dst}"
            log_info "インストール完了: ${plist_dst}"
        fi
    fi
}

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

    log_info "依存 CLI を確認しました"
}

# ─── メイン ──────────────────────────────────────────────────────────────────

log_section "=== idd-qwen インストーラ ==="

check_dependencies

if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "ドライランモード: 何もインストールしません"
fi

install_files

log_section "=== インストール完了 ==="

if [[ "${DRY_RUN}" == "false" ]]; then
    log_info "LaunchAgents に plist を登録しました:"
    log_info "  launchctl load ${LAUNCH_DIR}/com.idd-qwen.issue-watcher.plist"
    log_info ""
    log_info "起動確認:"
    log_info "  launchctl list | grep idd-qwen"
    log_info ""
    log_info "ログ確認:"
    log_info "  tail -f ${LOG_DIR}/watcher.log"
fi

exit 0