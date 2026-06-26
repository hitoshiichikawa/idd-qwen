#!/usr/bin/env bash
# stage-a-verify.sh - Stage A Verify プロセッサ
#
# 用途: 実装完了後の検証フェーズ（Stage A）
#
# 著者: idd-qwen contributors
# ライセンス: MIT

_is_stage_a_verify_loaded() { return 0; }

# ─── Stage A Verify 実行 ────────────────────────────────────────────────────

# 実装を検証し、結果を返す
stage_a_verify_run() {
    local _repo="$1"  # Used externally via core_utils
    local issue_number="$2"

    log_info "Stage A Verify を実行: Issue #${issue_number}"

    # 検証プロンプトの生成
    local prompt
    prompt=$(stage_a_verify_build_prompt "${issue_number}")

    # Qwen Code で検証実行
    local output_file="${LOG_DIR}/stage-a-verify-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}" "${output_file}"; then
        log_error "Stage A Verify に失敗: Issue #${issue_number}"
        echo '{"passed": false, "findings": []}'
        return 1
    fi

    # 結果解析
    if [[ -f "${output_file}" ]]; then
        local result
        result=$(jq -c '.' "${output_file}" 2>/dev/null || echo '')
        if [[ -n "${result}" ]]; then
            log_info "Stage A Verify 完了: Issue #${issue_number}"
            echo "${result}"
            return 0
        fi
    fi

    log_warn "Stage A Verify の出力ファイルが不存在: ${output_file}"
    echo '{"passed": false, "findings": []}'
    return 0
}

# 検証プロンプトの生成
stage_a_verify_build_prompt() {
    local issue_number="$1"

    cat <<EOF
GitHub Issue #${issue_number} の実装を検証してください。

仕様書: docs/specs/${issue_number}-*/requirements.md
設計書: docs/specs/${issue_number}-*/design.md（存在する場合）
実装ノート: docs/specs/${issue_number}-*/impl-notes.md（存在する場合）

以下の点を検証してください:
1. Acceptance Criteria が全て満たされているか
2. テストが適切に実行されているか
3. コード品質（読みやすさ、保守性、パフォーマンス）
4. Security 観点での問題点

結果を JSON 形式で出力してください:
{
  "passed": boolean,
  "findings": [
    {
      "category": "quality" | "security" | "test" | "ac",
      "severity": "critical" | "major" | "minor",
      "description": "string"
    }
  ]
}
EOF
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

stage_a_verify_init() {
    log_debug "stage-a-verify.sh をロードしました"
}