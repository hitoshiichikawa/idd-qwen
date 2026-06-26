#!/usr/bin/env bash
# dispatch.sh - Issue 振り分けモジュール
#
# 用途: Triage 結果に基づき、Issue を Developer 直または Architect 経由にする
#
# 著者: idd-qwen contributors
# ライセンス: MIT

_is_dispatch_loaded() { return 0; }

# ─── Issue 振り分け ─────────────────────────────────────────────────────────

# Triage 結果に基づき Issue を振り分け
# 戻り値: 0 (成功), 1 (失敗)
dispatch_run() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"
    local triage_result="$4"

    log_info "Issue #${issue_number} の振り分けを開始"

    # Triage 結果から判定
    local needs_architect
    needs_architect=$(echo "${triage_result}" | jq -r '.needs_architect // false')

    local needs_decisions
    needs_decisions=$(echo "${triage_result}" | jq -r '.needs_decisions // false')

    log_info "振り分け判定: needs_architect=${needs_architect}, needs_decisions=${needs_decisions}"

    if [[ "${needs_architect}" == "true" ]]; then
        log_info "Architect 経由で処理: Issue #${issue_number}"
        dispatch_architect_path "${repo}" "${issue_number}" "${issue_title}"
        return $?
    fi

    log_info "Developer 直結で処理: Issue #${issue_number}"
    dispatch_developer_path "${repo}" "${issue_number}" "${issue_title}"
    return $?
}

# Architect 経由パス（PM → Architect → PjM）
dispatch_architect_path() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    log_section "Architect 経由パスを開始: Issue #${issue_number}"

    # PM: requirements.md 作成
    log_info "PM を起動（requirements.md 作成）..."
    if ! dispatch_pm_run "${repo}" "${issue_number}" "${issue_title}"; then
        log_error "PM 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # Architect: design.md + tasks.md 作成
    log_info "Architect を起動（design.md + tasks.md 作成）..."
    if ! dispatch_architect_run "${repo}" "${issue_number}" "${issue_title}"; then
        log_error "Architect 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # PjM: design-review PR 作成
    log_info "PjM: design-review PR 作成..."
    if ! dispatch_pjmdesign_review_pr "${repo}" "${issue_number}"; then
        log_error "design-review PR 作成失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # 人間レビュー待ち（ラベル付与）
    log_info "設計 PR を作成し、人間レビュー待ちに設定"
    _qw_update_issue_labels "${repo}" "${issue_number}" "codex-awaiting-design-review"

    log_section "Architect 経由パス完了: Issue #${issue_number}"
    return 0
}

# Developer 直結パス（Developer → Reviewer → PjM）
dispatch_developer_path() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    log_section "Developer 直結パスを開始: Issue #${issue_number}"

    # Developer: 実装
    log_info "Developer を起動（実装）..."
    if ! dispatch_developer_run "${repo}" "${issue_number}" "${issue_title}"; then
        log_error "Developer 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # Reviewer: リビュー
    log_info "Reviewer を起動..."
    if ! dispatch_reviewer_run "${repo}" "${issue_number}" "${issue_title}"; then
        log_error "Reviewer 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # PjM: impl PR 作成
    log_info "PjM: impl PR 作成..."
    if ! dispatch_pjm_impl_pr "${repo}" "${issue_number}"; then
        log_error "impl PR 作成失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # ラベル更新
    _qw_update_issue_labels "${repo}" "${issue_number}" "codex-ready-for-review"

    log_section "Developer 直結パス完了: Issue #${issue_number}"
    return 0
}

# PM 起動（requirements.md 作成）
dispatch_pm_run() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    local prompt
    prompt=$(dispatch_build_pm_prompt "${issue_number}" "${issue_title}")

    local output_file="${LOG_DIR}/pm-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}" "${output_file}"; then
        log_error "PM 実行失敗: Issue #${issue_number}"
        return 1
    fi

    log_info "PM 完了: Issue #${issue_number}"
    return 0
}

# Architect 起動（design.md + tasks.md 作成）
dispatch_architect_run() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    local prompt
    prompt=$(dispatch_build_architect_prompt "${issue_number}" "${issue_title}")

    local output_file="${LOG_DIR}/architect-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}" "${output_file}"; then
        log_error "Architect 実行失敗: Issue #${issue_number}"
        return 1
    fi

    log_info "Architect 完了: Issue #${issue_number}"
    return 0
}

# Developer 起動（実装）
dispatch_developer_run() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    local prompt
    prompt=$(dispatch_build_developer_prompt "${issue_number}" "${issue_title}")

    local output_file="${LOG_DIR}/developer-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}" "${output_file}"; then
        log_error "Developer 実行失敗: Issue #${issue_number}"
        return 1
    fi

    log_info "Developer 完了: Issue #${issue_number}"
    return 0
}

# Reviewer 起動（レビュー）
dispatch_reviewer_run() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    local prompt
    prompt=$(dispatch_build_reviewer_prompt "${issue_number}" "${issue_title}")

    local output_file="${LOG_DIR}/reviewer-${issue_number}.json"
    if ! _qw_run_qwen_headless "${prompt}" "${issue_number}" "${output_file}"; then
        log_error "Reviewer 実行失敗: Issue #${issue_number}"
        return 1
    fi

    log_info "Reviewer 完了: Issue #${issue_number}"
    return 0
}

# PjM: design-review PR 作成
dispatch_pjmdesign_review_pr() {
    local repo="$1"
    local issue_number="$2"

    log_info "design-review PR 作成: Issue #${issue_number}"
    # TODO: 実際の PR 作成ロジック
    return 0
}

# PjM: impl PR 作成
dispatch_pjm_impl_pr() {
    local repo="$1"
    local issue_number="$2"

    log_info "impl PR 作成: Issue #${issue_number}"
    # TODO: 実際の PR 作成ロジック
    return 0
}

# PM プロンプトの生成
dispatch_build_pm_prompt() {
    local issue_number="$1"
    local issue_title="$2"

    cat <<EOF
GitHub Issue #${issue_number} の要件定義書（requirements.md）を作成してください。

タイトル: ${issue_title}

以下の内容を作成してください:
1. requirements.md - 要件定義書（EARS 形式の AC、numeric ID 階層）

ルール:
- [`.qwen/rules/ears-format.md`](../rules/ears-format.md) を参照
- [`.qwen/rules/requirements-review-gate.md`](../rules/requirements-review-gate.md) を参照
- 要件見出しは numeric ID のみ使用
- AC は EARS 5 パターンで書く
- Out of Scope を明示
EOF
}

# Architect プロンプトの生成
dispatch_build_architect_prompt() {
    local issue_number="$1"
    local issue_title="$2"

    cat <<EOF
GitHub Issue #${issue_number} の設計書（design.md）とタスクリスト（tasks.md）を作成してください。

タイトル: ${issue_title}

要件定義: docs/specs/${issue_number}-*/requirements.md

以下の内容を作成してください:
1. design.md - 設計書（File Structure Plan, Components and Interfaces, Traceability）
2. tasks.md - 実装タスクリスト（numeric ID, アノテーション付き）

ルール:
- [`.qwen/rules/design-principles.md`](../rules/design-principles.md) を参照
- [`.qwen/rules/tasks-generation.md`](../rules/tasks-generation.md) を参照
- EARS 形式の AC が全て design.md に反映されていることを確認
EOF
}

# Developer プロンプトの生成
dispatch_build_developer_prompt() {
    local issue_number="$1"
    local issue_title="$2"

    cat <<EOF
GitHub Issue #${issue_number} を実装してください。

タイトル: ${issue_title}

仕様書: docs/specs/${issue_number}-*/requirements.md
設計書: docs/specs/${issue_number}-*/design.md（存在する場合）
タスクリスト: docs/specs/${issue_number}-*/tasks.md（存在する場合）

以下の手順で実進してください:
1. 仕様書（requirements.md）を読み、Acceptance Criteria を理解
2. 設計書（design.md）が存在すれば読み、File Structure Plan を確認
3. タスクリスト（tasks.md）が存在すれば、番号順にタスクを消化
4. 各タスクでテストを先に書き、Red -> Green で実装
5. Conventional Commits でコミット
6. impl-notes.md に AC Coverage Matrix を作成

ブランチ: codex/issue-${issue_number}-impl
EOF
}

# Reviewer プロンプトの生成
dispatch_build_reviewer_prompt() {
    local issue_number="$1"
    local issue_title="$2"

    cat <<EOF
GitHub Issue #${issue_number} の実装をレビューしてください。

タイトル: ${issue_title}

仕様書: docs/specs/${issue_number}-*/requirements.md
設計書: docs/specs/${issue_number}-*/design.md（存在する場合）
実装ノート: docs/specs/${issue_number}-*/impl-notes.md（存在する場合）

以下の点をレビューしてください:
1. Acceptance Criteria が全て満たされているか
2. テストが適切に書かれているか
3. コード品質（読みやすさ、保守性、パフォーマンス）
4. Security 観点での問題点

結果を JSON 形式で出力してください:
{
  "result": "approve" | "reject",
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

dispatch_init() {
    log_debug "dispatch.sh をロードしました"
}