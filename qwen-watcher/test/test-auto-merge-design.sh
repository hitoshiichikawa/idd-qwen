#!/usr/bin/env bash
# test-auto-merge-design.sh - auto-merge-design.sh のテスト
#
# 用途: auto-merge-design.sh の関数をテスト
#
# 著者: idd-qwen contributors
# ライセンス: MIT

set -uo pipefail

# テスト対象のモジュールを source
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin/idd-qwen-modules" && pwd)"
source "${MODULE_DIR}/core_utils.sh"
source "${MODULE_DIR}/auto-merge-design.sh"

# テストヘルパー
assert_eq() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    if [[ "${expected}" == "${actual}" ]]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
        echo "  expected: ${expected}"
        echo "  actual:   ${actual}"
    fi
}

assert_true() {
    local condition="$1"
    local test_name="$2"

    if [[ "${condition}" == "true" ]]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
    fi
}

# テストケース
echo "=== auto-merge-design.sh テスト ==="

# 設定テスト
echo ""
echo "--- 設定テスト ---"
export AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"
export AUTO_MERGE_DESIGN_MAX_PRS="${AUTO_MERGE_DESIGN_MAX_PRS:-10}"
export AUTO_MERGE_DESIGN_HEAD_PATTERN="${AUTO_MERGE_DESIGN_HEAD_PATTERN:-^codex/issue-.*-design}"
echo "PASS: 設定変数が初期化された"

# gate 判定テスト
echo ""
echo "--- gate 判定テスト ---"
# OFF（既定）
export AUTO_MERGE_DESIGN_ENABLED=false
if amd_resolve_gate_enabled; then
    assert_true "false" "gate: false なら return 1 (OFF)"
else
    assert_true "true" "gate: false なら return 1 (OFF)"
fi

# ON
export AUTO_MERGE_DESIGN_ENABLED=true
if amd_resolve_gate_enabled; then
    assert_true "true" "gate: true なら return 0 (ON)"
else
    assert_true "false" "gate: true なら return 0 (ON)"
fi

# 未設定
unset AUTO_MERGE_DESIGN_ENABLED 2>/dev/null || true
if amd_resolve_gate_enabled; then
    assert_true "false" "gate: 未設定なら return 1 (OFF)"
else
    assert_true "true" "gate: 未設定なら return 1 (OFF)"
fi

# typo（opt-out）
export AUTO_MERGE_DESIGN_ENABLED="True"
if amd_resolve_gate_enabled; then
    assert_true "false" "gate: 'True' (typo) なら return 1 (OFF)"
else
    assert_true "true" "gate: 'True' (typo) なら return 1 (OFF)"
fi

# HEAD_PATTERN テスト
echo ""
echo "--- head pattern テスト ---"
export AUTO_MERGE_DESIGN_HEAD_PATTERN="^codex/issue-.*-design"

# 設計 PR pattern マッチ
if printf 'codex/issue-42-design-foo' | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    assert_true "true" "head pattern: 設計 PR マッチ"
else
    assert_true "false" "head pattern: 設計 PR マッチ"
fi

# 設計 PR pattern 不一致（impl PR）
if printf 'codex/issue-42-impl-foo' | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    assert_true "false" "head pattern: impl PR は不一致"
else
    assert_true "true" "head pattern: impl PR は不一致"
fi

# should_enable_for_pr テスト
echo ""
echo "--- should_enable_for_pr テスト ---"

# 有効な設計 PR（全て MERGEABLE, ラベルなし, draft=false）
VALID_DESIGN_PR=$(jq -n '{
    number: 42,
    headRefName: "codex/issue-42-design-foo",
    headRefOid: "abc123",
    baseRefName: "main",
    mergeable: "MERGEABLE",
    labels: [],
    url: "https://github.com/test/repo/pull/42",
    isDraft: false,
    headRepositoryOwner: { login: "owner" },
    autoMergeRequest: null
}')

if amd_should_enable_for_pr "$VALID_DESIGN_PR"; then
    assert_eq "0" "0" "should_enable: 有効な設計 PR は 0"
else
    assert_eq "0" "1" "should_enable: 有効な設計 PR は 0"
fi

# draft PR（除外）
DRAFT_PR=$(echo "$VALID_DESIGN_PR" | jq '.isDraft = true')
if amd_should_enable_for_pr "$DRAFT_PR"; then
    assert_eq "1" "0" "should_enable: draft PR は 1 (skip)"
else
    assert_eq "1" "1" "should_enable: draft PR は 1 (skip)"
fi

# codex-failed ラベル付き（除外）
FAILED_PR=$(echo "$VALID_DESIGN_PR" | jq '.labels = [{"name": "codex-failed"}]')
if amd_should_enable_for_pr "$FAILED_PR"; then
    assert_eq "1" "0" "should_enable: codex-failed 付きは 1 (skip)"
else
    assert_eq "1" "1" "should_enable: codex-failed 付きは 1 (skip)"
fi

# codex-needs-decisions ラベル付き（除外）
ND_PR=$(echo "$VALID_DESIGN_PR" | jq '.labels = [{"name": "codex-needs-decisions"}]')
if amd_should_enable_for_pr "$ND_PR"; then
    assert_eq "1" "0" "should_enable: codex-needs-decisions 付きは 1 (skip)"
else
    assert_eq "1" "1" "should_enable: codex-needs-decisions 付きは 1 (skip)"
fi

# codex-needs-iteration ラベル付き（除外）
ITER_PR=$(echo "$VALID_DESIGN_PR" | jq '.labels = [{"name": "codex-needs-iteration"}]')
if amd_should_enable_for_pr "$ITER_PR"; then
    assert_eq "1" "0" "should_enable: codex-needs-iteration 付きは 1 (skip)"
else
    assert_eq "1" "1" "should_enable: codex-needs-iteration 付きは 1 (skip)"
fi

# 既に auto-merge 有効（冪等 skip）
ALREADY_PR=$(echo "$VALID_DESIGN_PR" | jq '.autoMergeRequest = {"state": "pending"}')
if amd_should_enable_for_pr "$ALREADY_PR"; then
    assert_eq "2" "0" "should_enable: 既に auto-merge 有効なら 2"
else
    rc=$?
    assert_eq "2" "$rc" "should_enable: 既に auto-merge 有効なら 2"
fi

# impl PR pattern（除外）
IMPL_PR=$(echo "$VALID_DESIGN_PR" | jq '.headRefName = "codex/issue-42-impl-foo"')
if amd_should_enable_for_pr "$IMPL_PR"; then
    assert_eq "1" "0" "should_enable: impl PR は 1 (skip)"
else
    assert_eq "1" "1" "should_enable: impl PR は 1 (skip)"
fi

# CONFLICTING（除外）
CONFLICT_PR=$(echo "$VALID_DESIGN_PR" | jq '.mergeable = "CONFLICTING"')
if amd_should_enable_for_pr "$CONFLICT_PR"; then
    assert_eq "1" "0" "should_enable: CONFLICTING は 1 (skip)"
else
    assert_eq "1" "1" "should_enable: CONFLICTING は 1 (skip)"
fi

# enable_auto_merge_for_pr テスト（pr_number 検証のみ）
echo ""
echo "--- enable_auto_merge_for_pr テスト ---"
# 不正な pr_number
if amd_enable_auto_merge_for_pr "not-a-number" "head" "sha" "url"; then
    assert_true "false" "enable: 不正 pr_number は 1 (skip)"
else
    assert_true "true" "enable: 不正 pr_number は 1 (skip)"
fi

echo ""
echo "=== テスト完了 ==="