# スタブモジュール → full implementation 移植

既存レポジトリの stub（未完成）bash モジュールを、移植元レポジトリの full implementation を参考にして完成させる。特に `core_utils.sh` 系ユーティリティの移植で得たパターンを記録する。

## 前提

- 移植先モジュールが既に stub として存在し、一部関数が `_qw_` プレフィックスで定義されている
- 移植元モジュール（例: `idd-codex`）に full implementation が存在する
- 移植先と移植元で命名規則が異なる（`_qw_` vs 他プレフィックス）

## 手順

### 1. 移植元と移植先の両方を `read_file` で読む

```bash
# 移植元（full implementation）
read_file /path/to/idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh

# 移植先（stub）
read_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

両方を一度に読み、構造を把握してから移植方針を決定する。

### 2. 移植方針の決定

移植元モジュールの機能を分類する:

| 分類 | 方針 | 例 |
|---|---|---|
| 移植先に既に存在する | 既存関数を維持、新機能は追加 | `_qw_log`, `_qw_gh_issue_comment` |
| 移植先固有の用途に合う | 移植元パターンを適応して追加 | `_qw_run_qwen_headless` |
| 移植元固有の用途（不要） | 移植しない | worktree 管理、slot ロック、processor 専用ロガー |
| 移植先で必要な汎用ユーティリティ | 移植元パターンに基づいて新規追加 | 一時ファイル管理、配列操作、数値計算 |

### 3. 既存 stub のバグを検出

stub 内に移植元パターンと一致しない箇所を特定する:

- **プレフィックス不一致**: `log_info` → `_qw_log_info` 等、命名規則が統一されていない
- **未定義関数の参照**: `_qw_` プレフィックスでない関数呼び出し
- **引数/戻り値の不一致**: 移植元と stub でシグネチャが異なる

### 4. 移植先固有の制約を考慮

移植元 full implementation をそのまま写すのではなく、移植先の文脈で適応する:

- **プレフィックス**: 移植先の命名規則（`_qw_`）に統一
- **依存関係**: 移植先で既に移植済みのモジュールのみ `source`
- **グローバル変数**: 移植先で定義済みの変数（`$LOG_DIR` 等）を参照
- **不要な機能**: 移植元の processor 固有機能（worktree, slot locking）は除外

### 5. 実装

`write_file` で移植先ファイルを完全に上書き:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

実装時のチェックリスト:
- [ ] 既存 stub 関数（`_qw_` プレフィックス）を維持
- [ ] 移植元固有機能（worktree, slot locking）を除外
- [ ] 移植先固有機能（Qwen Code ヘッドレス実行）を保持
- [ ] 既存 stub のバグを修正（プレフィックス不一致等）
- [ ] 新機能は移植元パターンに基づいて追加
- [ ] 各関数にセクション区切りを付与

### 6. 検証

```bash
# 行数比較
echo "移植元: $(wc -l < /path/to/idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh) 行"
echo "移植先: $(wc -l < /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh) 行"

# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

## core_utils.sh 移植で得た知見

### 移植すべき新機能一覧

移植元 `core_utils.sh` (862行) から移植先 `core_utils.sh` (620行) に移植した機能:

| カテゴリ | 関数 | 移植元由来 |
|---|---|---|
| 一時ファイル | `_qw_tmpfile`, `_qw_tmpdir`, `_qw_cleanup`, `_qw_on_exit_cleanup` | 移植元パターン |
| ファイル操作 | `_qw_read_file`, `_qw_write_file`, `_qw_append_file`, `_qw_file_is_empty` | 移植元パターン |
| 文字列操作 | `_qw_trim`, `_qw_starts_with`, `_qw_ends_with`, `_qw_contains`, `_qw_slugify` | 移植元パターン |
| 配列操作 | `_qw_array_contains`, `_qw_array_unique`, `_qw_array_join`, `_qw_array_slice` | 移植元パターン |
| 数値計算 | `_qw_random_int`, `_qw_max`, `_qw_min`, `_qw_clamp` | 移植元パターン |
| 日付・時刻 | `_qw_epoch`, `_qw_iso8601`, `_qw_human_duration` | 移植元パターン |
| 進捗表示 | `_qw_progress_bar`, `_qw_spinner`, `_qw_status_message` | 移植元パターン |
| 環境変数 | `_qw_get_required`, `_qw_get_path` | 移植元パターン |

### 移植元固有で除外した機能

移植元 `idd-codex` 固有の機能で、`idd-qwen` では不要なもの:

- `*_processor_logger()` — processor 固有のロガー（worker, triage 等）
- `worktree` 管理関数 — idd-qwen は worktree を使わない
- `slot_lock` 関連関数 — idd-qwen はスロットロック機構を持たない
- `secure_tmpfile` — idd-qwen は `_qw_tmpfile` で十分

### バグ修正例

既存 stub 内にあった以下のバグを修正:

```bash
# Before (バグ: log_info が未定義)
_qw_run_qwen_headless() {
    log_info "Qwen Code を実行: issue #${issue_number}"  # ← 未定義
}

# After (修正: _qw_log_info に統一)
_qw_run_qwen_headless() {
    _qw_log_info "Qwen Code を実行: issue #${issue_number}"
}
```

### _qw_iso8601 のクロスプラットフォーム対応

移植元パターンでは GNU date (Linux) と BSD date (macOS) の両方に対応:

```bash
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
    echo "${epoch}"
}
```

## よくある落とし穴

- **移植元固有機能の混入**: worktree 管理や slot locking 等は移植先では不要。移植元の用途を考慮して除外する
- **既存 stub のバグ**: stub 内にプレフィックス不一致等のバグがある場合、移植時に同時に修正する
- **グローバル変数の衝突**: 移植先で既に定義済みの変数（`$LOG_DIR` 等）を上書きしない
- **依存モジュールの順序**: 移植先で未移植のモジュールを `source` しない

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-repo-rename](./auto-skill-repo-rename/SKILL.md) — レポジトリ名の一括書き換え