#!/usr/bin/env bash
# codex-guard.sh - Codex Guard Hook
#
# 用途: 危険な操作（force push, hook 自己改変等）を防止
#
# 著者: idd-qwen contributors
# ライセンス: MIT

_is_codex_guard_loaded() { return 0; }

# ─── Codex Guard 実行 ───────────────────────────────────────────────────────

# 危険な操作を検出
codex_guard_check() {
    local action="$1"
    local args="$2"

    log_info "Codex Guard を実行: ${action}"

    case "${action}" in
        "force-push")
            # force push は deny
            log_error "Codex Guard: force push は禁止されています"
            return 1
            ;;
        "hook-modify")
            # hook 自己改変は deny
            log_error "Codex Guard: hook 自己改変は禁止されています"
            return 1
            ;;
        "base-push")
            # base branch への直接 push は deny
            log_error "Codex Guard: base branch への直接 push は禁止されています"
            return 1
            ;;
        *)
            log_info "Codex Guard: ${action} は許可されています"
            return 0
            ;;
    esac
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

codex_guard_init() {
    log_debug "codex-guard.sh をロードしました"
}