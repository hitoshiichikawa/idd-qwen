#!/usr/bin/env bash
# core_utils_test.sh - core_utils.sh のテスト
#
# 用途: core_utils.sh の関数をテスト
#
# 著者: idd-qwen contributors
# ライセンス: MIT

set -euo pipefail

# テスト対象のモジュールを source
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../qwen-watcher/bin/idd-qwen-modules" && pwd)"
source "${MODULE_DIR}/core_utils.sh"

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
        return 1
    fi
}

assert_true() {
    local condition="$1"
    local test_name="$2"

    if [[ "${condition}" == "true" ]]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
        return 1
    fi
}

assert_false() {
    local condition="$1"
    local test_name="$2"

    if [[ "${condition}" == "false" ]]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
        return 1
    fi
}

# テストケース
echo "=== core_utils.sh テスト ==="

# ロガーテスト
echo ""
echo "--- ロガーテスト ---"
_qw_log_info "テストメッセージ"
echo "PASS: ロガー出力"

# 環境変数ヘルパーテスト
echo ""
echo "--- 環境変数ヘルパーテスト ---"
export TEST_TRUE=true
export TEST_FALSE=false
export TEST_EMPTY=
export TEST_NUM=42

assert_eq "true" "$(_qw_get_bool TEST_TRUE)" "bool: true"
assert_eq "false" "$(_qw_get_bool TEST_FALSE)" "bool: false"
assert_eq "false" "$(_qw_get_bool TEST_EMPTY)" "bool: empty"
assert_eq "true" "$(_qw_get_bool TEST_NUM)" "bool: number"

assert_eq "42" "$(_qw_get_int TEST_NUM)" "int: 42"
assert_eq "0" "$(_qw_get_int TEST_EMPTY)" "int: empty"
assert_eq "10" "$(_qw_get_int NONEXISTENT 10)" "int: default"

# ファイル操作ヘルパーテスト
echo ""
echo "--- ファイル操作ヘルパーテスト ---"
assert_true "$(_qw_file_exists "${MODULE_DIR}/core_utils.sh")" "file_exists: existing file"
assert_false "$(_qw_file_exists "/nonexistent/file.txt")" "file_exists: nonexistent file"

assert_true "$(_qw_dir_exists "${MODULE_DIR}")" "dir_exists: existing dir"
assert_false "$(_qw_dir_exists "/nonexistent/dir")" "dir_exists: nonexistent dir"

# Slug 生成テスト
echo ""
echo "--- Slug 生成テスト ---"
assert_eq "test-issue" "$(_qw_generate_slug "Test Issue")" "slug: simple"
assert_eq "test-issue-with-long-title" "$(_qw_generate_slug "Test Issue With Long Title That Exceeds Forty Characters")" "slug: long title (40 char limit)"

# Spec Dir 生成テスト
echo ""
echo "--- Spec Dir 生成テスト ---"
assert_eq "docs/specs/123-test-issue" "$(_qw_spec_dir 123 "test-issue")" "spec_dir: simple"

echo ""
echo "=== テスト完了 ==="