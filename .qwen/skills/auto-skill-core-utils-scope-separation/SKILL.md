# core_utils.sh スコープ分離（汎用ユーティリティ vs ドメイン固有機能）

移植元 `core_utils.sh` を移植先に移植した後、移植元固有機能を適切なモジュールに分離する。
移植元 `core_utils.sh` は 1 ファイルに **汎用ユーティリティ** と **ドメイン固有機能** が混在しており、移植先では分離が必要。

## 前提

- `core_utils.sh` の full implementation 移植が完了している
- 移植元に `core_utils.sh` が 1 ファイルで存在し、汎用ユーティリティとドメイン固有機能が混在している
- 移植先ではモジュールを分離し、`core_utils.sh` は **汎用ユーティリティのみ** を含む

## 分類ルール

移植元 `core_utils.sh` の関数を以下の 2 カテゴリに分類する:

| カテゴリ | 基準 | 例 | 処理 |
|---|---|---|---|
| **汎用ユーティリティ** | 移植先でも再利用可能な低レベル関数 | `_qw_log`, `_qw_tmpfile`, `_qw_slugify` | `core_utils.sh` に保持 |
| **ドメイン固有機能** | 移植元の特定ドメインに依存する機能 | worktree 管理, slot locking, processor ロガー | 別モジュールへ分離 |

### 汎用ユーティリティ（core_utils.sh に保持）

以下のカテゴリに属する関数のみ `core_utils.sh` に含める:

| カテゴリ | 関数 |
|---|---|
| ロギング | `_qw_log`, `_qw_log_info`, `_qw_log_warn`, `_qw_log_error`, `_qw_log_debug`, `_qw_log_section` |
| 環境変数 | `_qw_get_env`, `_qw_get_bool`, `_qw_get_int`, `_qw_get_required`, `_qw_get_path` |
| 一時ファイル | `_qw_tmpfile`, `_qw_tmpdir`, `_qw_cleanup`, `_qw_on_exit_cleanup`, `_qw_secure_mktemp` |
| ファイル操作 | `_qw_file_exists`, `_qw_dir_exists`, `_qw_mkdir_p`, `_qw_read_file`, `_qw_write_file`, `_qw_append_file`, `_qw_file_is_empty` |
| 文字列操作 | `_qw_trim`, `_qw_starts_with`, `_qw_ends_with`, `_qw_contains`, `_qw_slugify` |
| 配列操作 | `_qw_array_contains`, `_qw_array_unique`, `_qw_array_join`, `_qw_array_slice` |
| 数値計算 | `_qw_random_int`, `_qw_max`, `_qw_min`, `_qw_clamp` |
| 日付・時刻 | `_qw_epoch`, `_qw_iso8601`, `_qw_human_duration` |
| 進捗表示 | `_qw_progress_bar`, `_qw_spinner`, `_qw_status_message` |
| Issue/Slug | `_qw_generate_slug`, `_qw_spec_dir` |

### ドメイン固有機能（別モジュールへ分離）

以下の関数は移植元固有であり、適切なモジュールに分離する:

| カテゴリ | 関数 | 分離先モジュール |
|---|---|---|
| GitHub API | `_qw_gh_issue_list`, `_qw_gh_issue_edit`, `_qw_gh_issue_comment` | `gh_api.sh` |
| ラベル操作 | `_qw_update_issue_labels` | `gh_api.sh` |
| Qwen Code | `_qw_run_qwen_headless` | `qwen_code.sh` |
| Processor ロガー | `qa_log`, `mq_log`, `ar_log`, `am_log`, `amd_log`, `pp_log`, `pi_log`, `drr_log`, `pr_log`, `fr_log`, `nda_log`, `sn_log`, `sr_log` | `processors.sh` |
| Codex 529 Detector | `codex_log_detect_529` | 固有机能なので削除（または `codex.sh`） |
| Worktree Manager | `_worktree_path`, `_worktree_is_registered`, `_worktree_ensure`, `_worktree_reset`, `_worktree_reset_docker_cleanup`, `_worktree_reset_recreate`, `_worktree_record_scaffolding`, `_worktree_inject_codex` | `worktree.sh` |
| Slot Lock | `_slot_lock_path`, `_slot_acquire`, `_slot_release` | `slot_lock.sh` |
| Hook | `_hook_invoke` | `hooks.sh` |

## 手順

### 1. 移植元と移植先の両方を `read_file` で読む

```bash
# 移植元（full implementation）
read_file /path/to/idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh

# 移植先（移植済み）
read_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

移植先ファイルの行数が移植元より多い場合、スコープ外の関数が混入している可能性が高い。

### 2. 移植先関数の分類

移植先 `core_utils.sh` の全関数を `grep` で列挙し、分類する:

```bash
grep -n '^_qw_\|^qa_\|^mq_\|^ar_\|^am_\|^amd_\|^pp_\|^pi_\|^drr_\|^pr_\|^fr_\|^nda_\|^sn_\|^sr_\|^idd_\|^_worktree_\|^_slot_\|^_hook_\|^core_utils_init' \
  /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

### 3. スコープ外関数の特定

移植先 `core_utils.sh` に以下の関数がある場合、**スコープ外** としてマークする:

| 関数プレフィックス | スコープ | 処理 |
|---|---|---|
| `_qw_gh_*` | ❌ スコープ外 | `gh_api.sh` へ移動 |
| `_qw_run_qwen_*` | ❌ スコープ外 | `qwen_code.sh` へ移動 |
| `_qw_update_issue_labels` | ❌ スコープ外 | `gh_api.sh` へ移動 |
| `qa_log`, `mq_log` 等 | ❌ スコープ外 | `processors.sh` へ移動 |
| `codex_log_detect_529` | ❌ スコープ外 | 削除（または `codex.sh`） |
| `_worktree_*` | ❌ スコープ外 | `worktree.sh` へ移動 |
| `_slot_*` | ❌ スコープ外 | `slot_lock.sh` へ移動 |
| `_hook_*` | ❌ スコープ外 | `hooks.sh` へ移動 |

### 4. core_utils.sh の修正

`write_file` で `core_utils.sh` を上書きし、スコープ外関数を削除:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

修正後の `core_utils.sh` は以下のセクションのみを含む:
- ANSI カラー定数 + `_qw_init_colors`, `_qw_ensure_colors`
- ロギング: `_qw_log` 系
- 環境変数: `_qw_get_*` 系
- 一時ファイル: `_qw_tmpfile`, `_qw_tmpdir`, `_qw_cleanup`, `_qw_on_exit_cleanup`, `_qw_secure_mktemp`
- ファイル操作: `_qw_file_*`, `_qw_mkdir_p`, `_qw_read_file`, `_qw_write_file`, `_qw_append_file`
- 文字列操作: `_qw_trim`, `_qw_starts_with`, `_qw_ends_with`, `_qw_contains`, `_qw_slugify`
- 配列操作: `_qw_array_*`
- 数値計算: `_qw_random_int`, `_qw_max`, `_qw_min`, `_qw_clamp`
- 日付・時刻: `_qw_epoch`, `_qw_iso8601`, `_qw_human_duration`
- 進捗表示: `_qw_progress_bar`, `_qw_spinner`, `_qw_status_message`
- Issue/Slug: `_qw_generate_slug`, `_qw_spec_dir`
- 初期化: `core_utils_init`

### 5. 分離先モジュールの作成

スコープ外関数を適切なモジュールファイルに分割して作成:

```bash
# gh_api.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/gh_api.sh

# qwen_code.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/qwen_code.sh

# processors.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/processors.sh

# worktree.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/worktree.sh

# slot_lock.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/slot_lock.sh

# hooks.sh
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/hooks.sh
```

各モジュールの冒頭に用途説明コメントを付ける:

```bash
#!/usr/bin/env bash
# gh_api.sh - GitHub API ヘルパー
#
# 用途: gh CLI を介した Issue / PR 操作を提供
# 依存: core_utils.sh (_qw_log_info, _qw_log_error)
```

### 6. 検証

```bash
# core_utils.sh の行数（移植元より減っているはず）
echo "移植元: $(wc -l < /path/to/idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh) 行"
echo "移植先: $(wc -l < /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh) 行"

# 各モジュールの行数確認
for f in /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/*.sh; do
  echo "$(basename "$f"): $(wc -l < "$f") 行"
done

# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/*.sh
```

## 判断のポイント

| 項目 | 汎用ユーティリティ | ドメイン固有機能 |
|---|---|---|
| 再利用性 | 複数のモジュールから参照される | 単一ドメインに閉じる |
| 移植元依存 | 移植元固有の概念に依存しない | 移植元の特定機構に依存する |
| 移植先適合 | 移植先の文脈で意味を持つ | 移植先では不要または別モジュール |
| 例 | `_qw_log`, `_qw_tmpfile` | worktree 管理, slot locking |

## よくある落とし穴

- **移植元固有機能の混入**: worktree 管理や slot locking 等は移植先では不要。移植元の用途を考慮して除外する
- **Processor ロガーの混入**: `qa_log`, `mq_log` 等は processor 固有であり、`core_utils.sh` に含めない
- **GitHub API の混入**: `gh issue list` 等は GitHub 固有であり、`core_utils.sh` に含めない
- **行数の過大**: 移植先が移植元より多い場合、スコープ外関数が混入していないか確認
- **依存関係の切断**: 分離先モジュールが `core_utils.sh` の関数を参照する場合、`source` 順序に注意

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-stub-to-full](./auto-skill-stub-to-full/SKILL.md) — stub から full implementation への移植