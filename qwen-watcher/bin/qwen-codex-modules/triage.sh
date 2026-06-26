#!/usr/bin/env bash
# triage.sh - Triage プロセッサ
#
# 用途: codex-auto-dev ラベルの Issue を分析し、Architect が必要か判定
#
# 著者: idd-qwen contributors
# ライセンス: MIT

_is_triage_loaded() { return 0; }

# ─── Triage 実行 ────────────────────────────────────────────────────────────

# Issue を Triage し、結果を JSON で返す
# 戻り値: JSON 文字列（needs_architect, needs_decisions, decisions）
triage_run() {
    local _repo="$1"  # Used externally via core_utils
    local issue_number="$2"
    local issue_title="$3"
    local issue_body="$4"
    local issue_url="$5"

    log_info "Triage を実行: Issue #${issue_number}"

    # Triage プロンプトの生成
    local prompt
    prompt=$(triage_build_prompt "${issue_number}" "${issue_title}" "${issue_body}" "${issue_url}")

    # Qwen Code で Triage 実行
    local output_file="${LOG_DIR}/triage-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}"; then
        log_error "Triage に失敗: Issue #${issue_number}"
        echo '{"needs_architect": false, "needs_decisions": false, "decisions": []}'
        return 1
    fi

    # 結果解析
    if [[ -f "${output_file}" ]]; then
        local result
        result=$(jq -c '.' "${output_file}" 2>/dev/null || echo '')
        if [[ -n "${result}" ]]; then
            log_info "Triage 完了: Issue #${issue_number}"
            echo "${result}"
            return 0
        fi
    fi

    log_warn "Triage の出力ファイルが不存在: ${output_file}"
    echo '{"needs_architect": false, "needs_decisions": false, "decisions": []}'
    return 0
}

# Triage プロンプトの生成
triage_build_prompt() {
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

# ─── モジュール初期化 ───────────────────────────────────────────────────────

triage_init() {
    log_debug "triage.sh をロードしました"
}