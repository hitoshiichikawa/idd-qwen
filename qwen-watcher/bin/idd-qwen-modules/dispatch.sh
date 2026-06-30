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
# 引数: $1 = issue_number, $2 = issue_title, $3 = triage_output_file
# 戻り値: 0 (成功), 1 (失敗)
dispatch_run() {
    local issue_number="$1"
    local issue_title="$2"
    local triage_output_file="$3"

    dispatcher_log "Issue #${issue_number}: 振り分けを実行"

    # Triage 結果から判定
    local needs_architect
    needs_architect=$(jq -r '.needs_architect // false' "${triage_output_file}" 2>/dev/null || echo "false")
    local needs_decisions
    needs_decisions=$(jq -r '.needs_decisions // false' "${triage_output_file}" 2>/dev/null || echo "false")

    dispatcher_log "Issue #${issue_number}: 振り分け判定 needs_architect=${needs_architect}, needs_decisions=${needs_decisions}"

    # needs-decisions 自動続行（classification=safe かつ第一推奨ありの場合）
    if [[ "${needs_decisions}" == "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        if declare -f nda_evaluate_auto_continue &>/dev/null; then
            if nda_evaluate_auto_continue "${triage_output_file}"; then
                dispatcher_log "Issue #${issue_number}: needs-decisions 自動続行済み（次サイクルで再 pickup 待ち）"
                return 0
            else
                dispatcher_log "Issue #${issue_number}: needs-decisions 自動続行 skip（従来経路へ）"
            fi
        fi
    fi

    if [[ "${needs_architect}" == "true" ]]; then
        dispatcher_log "Issue #${issue_number}: Architect パスへ"
        dispatch_architect_path "${REPO}" "${issue_number}" "${issue_title}"
        return $?
    fi

    dispatcher_log "Issue #${issue_number}: Developer 直結パスへ"
    dispatch_developer_path "${REPO}" "${issue_number}" "${issue_title}"
    return $?
}

# Architect 経由パス（PM → Architect → PjM）
dispatch_architect_path() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    dispatcher_log "=== Architect 経由パスを開始: Issue #${issue_number} ==="

    # PM: requirements.md 作成
    dispatcher_log "PM を起動（requirements.md 作成）..."
    if ! dispatch_pm_run "${repo}" "${issue_number}" "${issue_title}"; then
        dispatcher_error "PM 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # Architect: design.md + tasks.md 作成
    dispatcher_log "Architect を起動（design.md + tasks.md 作成）..."
    if ! dispatch_architect_run "${repo}" "${issue_number}" "${issue_title}"; then
        dispatcher_error "Architect 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # PjM: design-review PR 作成
    dispatcher_log "PjM: design-review PR 作成..."
    if ! dispatch_pjmdesign_review_pr "${repo}" "${issue_number}"; then
        dispatcher_error "design-review PR 作成失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # 人間レビュー待ち（ラベル付与）
    dispatcher_log "設計 PR を作成し、人間レビュー待ちに設定"
    _qw_update_issue_labels "${repo}" "${issue_number}" "codex-awaiting-design-review"

    dispatcher_log "=== Architect 経由パス完了: Issue #${issue_number} ==="
    return 0
}

# Developer 直結パス（Developer → Reviewer → PjM）
dispatch_developer_path() {
    local repo="$1"
    local issue_number="$2"
    local issue_title="$3"

    dispatcher_log "=== Developer 直結パスを開始: Issue #${issue_number} ==="

    # Developer: 実装
    dispatcher_log "Developer を起動（実装）..."
    if ! dispatch_developer_run "${repo}" "${issue_number}" "${issue_title}"; then
        dispatcher_error "Developer 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # Reviewer: リビュー
    dispatcher_log "Reviewer を起動..."
    if ! dispatch_reviewer_run "${repo}" "${issue_number}" "${issue_title}"; then
        dispatcher_error "Reviewer 失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # PjM: impl PR 作成
    dispatcher_log "PjM: impl PR 作成..."
    if ! dispatch_pjm_impl_pr "${repo}" "${issue_number}"; then
        dispatcher_error "impl PR 作成失敗: Issue #${issue_number}"
        _qw_update_issue_labels "${repo}" "${issue_number}" "codex-failed"
        return 1
    fi

    # ラベル更新
    _qw_update_issue_labels "${repo}" "${issue_number}" "codex-ready-for-review"

    dispatcher_log "=== Developer 直結パス完了: Issue #${issue_number} ==="
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
        dispatcher_error "PM 実行失敗: Issue #${issue_number}"
        return 1
    fi

    dispatcher_log "PM 完了: Issue #${issue_number}"
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
        dispatcher_error "Architect 実行失敗: Issue #${issue_number}"
        return 1
    fi

    dispatcher_log "Architect 完了: Issue #${issue_number}"
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
        dispatcher_error "Developer 実行失敗: Issue #${issue_number}"
        return 1
    fi

    dispatcher_log "Developer 完了: Issue #${issue_number}"
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
        dispatcher_error "Reviewer 実行失敗: Issue #${issue_number}"
        return 1
    fi

    dispatcher_log "Reviewer 完了: Issue #${issue_number}"
    return 0
}

# PjM: design-review PR 作成
dispatch_pjmdesign_review_pr() {
    local repo="$1"
    local issue_number="$2"

    dispatcher_log "design-review PR 作成: Issue #${issue_number}"

    # branch 名を生成
    local branch
    branch="codex/issue-${issue_number}-design"

    # branch が存在するか確認
    if ! git rev-parse --verify "${branch}" &>/dev/null; then
        dispatcher_warn "design branch '${branch}' が存在しません"
        return 1
    fi

    # branch を push
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! git push -u origin "${branch}" 2>&1 | dispatcher_log; then
            dispatcher_error "design branch push 失敗: ${branch}"
            return 1
        fi
    else
        dispatcher_log "[DRY RUN] design branch push: ${branch}"
    fi

    # PR 作成
    local pr_title
    pr_title="spec(#${issue_number}): design review for Issue #${issue_number}"

    local pr_body
    pr_body="## 概要

この PR は **設計レビュー専用** です。実装コードは含まれません。
\`docs/specs/${issue_number}-*/\` 配下の requirements / design / tasks を merge するためのゲートです。

## 対応 Issue

Refs #${issue_number}

## 含まれる成果物

- \`docs/specs/${issue_number}-*/requirements.md\` — 要件定義（PM 成果物）
- \`docs/specs/${issue_number}-*/design.md\` — 設計書（Architect 成果物）
- \`docs/specs/${issue_number}-*/tasks.md\` — 実装タスク分割

## レビュー観点

- requirements.md の FR / NFR / AC に過不足はないか
- design.md のモジュール構成・公開 IF が FR をカバーしているか
- 既存コードの再利用が検討されているか、重複実装が混じっていないか
- tasks.md の分割粒度が独立コミット可能か

## 次のステップ

- この PR を **merge** したら、Issue から \`codex-awaiting-design-review\` ラベルを外してください。
  次回ポーリングで Developer が自動起動し、実装 PR が別途作られます
- 設計に問題があれば、直接この PR で commit / suggest-edit / line comment して修正してください
- やり直したい場合は PR を close して、Issue の \`codex-awaiting-design-review\` ラベルを外してください
"

    if [[ "${DRY_RUN}" != "true" ]]; then
        local pr_number
        if ! pr_number=$(gh pr create \
            --base "${BASE_BRANCH:-main}" \
            --head "${branch}" \
            --title "${pr_title}" \
            --body "${pr_body}" 2>&1 | grep -oE '#[0-9]+' | head -1); then
            dispatcher_error "design-review PR 作成失敗: ${pr_title}"
            dispatcher_log "gh 出力: $(gh pr create --base "${BASE_BRANCH:-main}" --head "${branch}" --title "${pr_title}" --body "${pr_body}" 2>&1)"
            return 1
        fi

        dispatcher_log "design-review PR 作成完了: #${pr_number}"
    else
        dispatcher_log "[DRY RUN] design-review PR 作成: ${pr_title} (--base ${BASE_BRANCH:-main} --head ${branch})"
    fi

    return 0
}

# PjM: impl PR 作成
dispatch_pjm_impl_pr() {
    local repo="$1"
    local issue_number="$2"

    dispatcher_log "impl PR 作成: Issue #${issue_number}"

    # branch 名を生成
    local branch
    branch="codex/issue-${issue_number}-impl"

    # branch が存在するか確認
    if ! git rev-parse --verify "${branch}" &>/dev/null; then
        dispatcher_warn "impl branch '${branch}' が存在しません"
        return 1
    fi

    # branch を push
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! git push -u origin "${branch}" 2>&1 | dispatcher_log; then
            dispatcher_error "impl branch push 失敗: ${branch}"
            return 1
        fi
    else
        dispatcher_log "[DRY RUN] impl branch push: ${branch}"
    fi

    # PR 本文を生成
    local pr_title
    pr_title="feat(#${issue_number}): implement Issue #${issue_number}"

    # impl-notes.md からサマリーを抽出
    local impl_notes
    impl_notes=$(find "docs/specs/${issue_number}-*" -name "impl-notes.md" -type f 2>/dev/null | head -1)

    local pr_body="## 概要

Issue #${issue_number} の実装

## 対応 Issue

Refs #${issue_number}

## 実装内容

- 実装完了
- テスト追加
- lint / build 確認

## テスト結果

- 全テスト pass

## 実装上の判断

- 既存コード規約に従った実装
"

    if [[ -n "${impl_notes}" ]]; then
        pr_body="${pr_body}

## 確認事項

$(grep -A 20 '## 確認事項\|## Confirmation Items' "${impl_notes}" 2>/dev/null | head -15 || echo "なし")
"
    fi

    pr_body="${pr_body}
---

🤖 この PR は idd-qwen ワークフローにより Codex CLI が自動生成しました。
"

    if [[ "${DRY_RUN}" != "true" ]]; then
        local pr_number
        if ! pr_number=$(gh pr create \
            --base "${BASE_BRANCH:-main}" \
            --head "${branch}" \
            --title "${pr_title}" \
            --body "${pr_body}" 2>&1 | grep -oE '#[0-9]+' | head -1); then
            dispatcher_error "impl PR 作成失敗: ${pr_title}"
            dispatcher_log "gh 出力: $(gh pr create --base "${BASE_BRANCH:-main}" --head "${branch}" --title "${pr_title}" --body "${pr_body}" 2>&1)"
            return 1
        fi

        dispatcher_log "impl PR 作成完了: #${pr_number}"
    else
        dispatcher_log "[DRY RUN] impl PR 作成: ${pr_title} (--base ${BASE_BRANCH:-main} --head ${branch})"
    fi

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