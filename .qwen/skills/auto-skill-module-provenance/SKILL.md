# モジュール移植時の関数出自追跡（git history による分類）

移植先モジュールの関数が「移植元由来」か「移植先固有」かを、git log で追跡して分類する。
移植元との行数比較だけでは出自が判別できず、`_qw_` 接頭辞の関数が移植先固有のものか移植元由来のものか混在する可能性がある。

## 前提

- 移植元モジュール（例: `idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh`）と
  移植先モジュール（例: `idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh`）の両方が存在する
- 移植先モジュールの行数が移植元より多い場合、移植先固有の関数が混入している可能性が高い
- 移植先モジュールが git 管理下にあること（history 追跡のため）

## 手順

### 1. 移植先モジュールの git history を確認

```bash
cd /path/to/idd-qwen
git log --oneline --all -- qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

典型的なコミット履歴:

```
5673814 fix(watcher): add ANSI color support with NO_COLOR and rename idd_secure_mktemp
d12d33e feat(watcher): full implementation of core_utils.sh module
2b9933a chore: rename qwen-codex symbols to idd-qwen across the repo
8022920 feat: add watcher modules, install script, and repo-template
```

各コミットの意味:

| コミット | 意味 | 関数出自 |
|---|---|---|
| 8022920 | 初期 stub 作成 | **移植先固有**（stub として新規設計） |
| 2b9933a | シンボル名 rename | 既存関数のリネームのみ |
| d12d33e | full implementation | **移植元由来**（idd-codex からの移植）+ **移植先固有**（stub 実装） |
| 5673814 | カラー対応 | **移植先固有**（ANSI カラー追加） |

### 2. 各コミットの diff を確認

移植先固有関数と移植元由来関数を区別するため、各コミットの diff を確認する:

```bash
# 全実装コミットの内容確認
git show d12d33e --stat
git show d12d33e -- qwen-watcher/bin/idd-qwen-modules/core_utils.sh

# 初期 stub 確認（移植先固有関数の一覧取得）
git show 8022920:qwen-watcher/bin/qwen-codex-modules/core_utils.sh | head -80

# カラー対応コミット確認
git show 5673814 --stat
git show 5673814 -- qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

### 3. 移植先関数の全列挙と分類

移植先モジュールの全関数を列挙し、各関数の出自を分類する:

```bash
grep -oE '^[a-z_]+\(\)' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh | sort
```

各関数を以下のカテゴリに分類:

| 分類 | 判定 | 処理 |
|---|---|---|
| **移植先固有** | 初期 stub（8022920）で定義済み、またはカラー対応（5673814）で追加 | スコープ分類ルールで判定 |
| **移植元由来** | 移植コミット（d12d33e）で移植元から追加 | 移植元での用途を確認して分類 |
| **リネーム** | rename コミット（2b9933a）で名前変更のみ | 移植元由来として扱う |

### 4. 移植元との関数名比較

移植元と移植先の関数名を比較し、移植元由来関数の対応関係を特定する:

```bash
# 移植元の関数名
grep -oE '^[a-z_]+\(\)' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/core_utils.sh | sort

# 移植先の関数名
grep -oE '^[a-z_]+\(\)' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh | sort
```

対応関係の特定:

| 移植元 | 移植先 | 対応関係 |
|---|---|---|
| `idd_secure_mktemp()` | `_qw_secure_mktemp()` | リネーム（移植元由来） |
| `codex_log_detect_529()` | （未実装） | 削除指示（移植元由来だが不要） |
| `qa_log()`, `am_log()` 等 | 同名 | 移植元由来（processor ロガー） |
| `_worktree_path()` 等 | 同名 | 移植元由来（worktree 管理） |
| `_qw_log()` 等 | 同名 | 移植先固有（初期 stub 実装） |

## 判断のポイント

| 項目 | 移植先固有 | 移植元由来 |
|---|---|---|
| 初期 stub に存在するか | ✅ 存在 | ❌ 存在しない |
| 移植コミットで追加されたか | ❌ 追加なし | ✅ 移植元から追加 |
| 移植元の用途と一致するか | 移植先の用途 | 移植元の用途 |
| 移植先の文脈で意味を持つか | ✅ 意味がある | 移植元の用途を確認 |

## よくある落とし穴

- **行数の過大**: 移植先が移植元より多い場合、移植先固有の関数が混入している。git history で確認せずに「移植元由来」と誤判定しない
- **関数名の一致**: 移植先で `_qw_` 接頭辞の関数がある場合、それが移植元由来か移植先固有か、git history で確認せずに分類しない
- **リネーム関数の追跡**: `idd_secure_mktemp` → `_qw_secure_mktemp` のように名前が変わった関数は、rename コミットで確認する
- **削除関数の追跡**: `codex_log_detect_529` のように削除された関数は、移植元と移植先の diff で確認する

## 関連

- [auto-skill-core-utils-scope-separation](./auto-skill-core-utils-scope-separation/SKILL.md) — スコープ分離手順
- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順