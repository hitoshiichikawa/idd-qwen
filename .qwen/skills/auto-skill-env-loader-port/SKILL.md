# env-loader.sh モジュールの移植（fresh port + namespace 変換 + config block 統合）

移植元（idd-codex）の full implementation を移植先（idd-qwen）へ **fresh port** する。
stub 移植と異なり、移植先モジュールが未存在のため新規作成し、namespace 変換 + config block 統合を行う。

## 前提

- 移植元モジュール（例: `idd-codex/local-watcher/bin/idd-codex-modules/env-loader.sh`）が full implementation として存在
- 移植先モジュール（例: `idd-qwen/qwen-watcher/bin/idd-qwen-modules/env-loader.sh`）は未存在
- 移植先で namespace 変換が必要（`idd-codex` → `idd-qwen`、`idd_secure` → `el_` 等）
- 移植先の watcher スクリプト（`idd-qwen-issue-watcher.sh`）に統合する

## 手順

### 1. 移植元モジュールの構造理解

移植元モジュールを `read_file` で読み、以下の要素を特定する:

- **public functions**: 外部から呼ばれるエントリポイント（`el_load` 等）
- **private functions**: 内部ヘルパー（`el_resolve_env_file` 等）
- **dependencies**: 他のモジュールを `source` しているか
- **namespace**: プレフィックス規則（`el_` 等）
- **logging**: 既存ログ形式に合わせる必要があるか

```bash
read_file /path/to/idd-codex/local-watcher/bin/idd-codex-modules/env-loader.sh

# 移植元の関数一覧
grep -E '^[a-z_]+\(\)' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/env-loader.sh
```

### 2. 移植先での namespace 変換

移植元の命名規則を移植先の規則に変換する:

| 移植元 (idd-codex) | 移植先 (idd-qwen) | 変換理由 |
|---|---|---|
| `idd_secure_` | `el_` | idd-qwen 固有プレフィックス |
| `idd_codex_log` | `el_log` | namespace 変換 |
| `idd_codex_modules` | `idd_qwen_modules` | ディレクトリ名変換 |
| `.idd-codex/` | `.idd-qwen/` | ディレクトリ名変換 |

### 3. 移植先でのファイル新規作成

移植元モジュールをベースに、移植先の命名規則に変換して新規作成:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/env-loader.sh
```

移植時の注意点:
- **プレフィックス変換**: 移植元の関数名プレフィックスを移植先の規則に変換
- **logging 形式**: 移植先の既存ログ形式（3 段 prefix: `INFO | timestamp | message`）に合わせる
- **namespace 変換**: `idd-codex` → `idd-qwen`、`.idd-codex/` → `.idd-qwen/`
- **依存モジュール**: 移植先で既に移植済みのモジュールのみ `source`
- **安全策**: モジュール不在時は何もしない（既存挙動と等価）

### 4. watcher スクリプトへの統合

移植先 watcher スクリプト（`idd-qwen-issue-watcher.sh`）に統合する:

```bash
# 既存の watcher スクリプトを読み、Config ブロック直前に env-loader を追加
read_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh
```

統合ポイント:
1. **REPO_SLUG 定義後**: `REPO_SLUG` が定義された直後に env-loader.sh を source
2. **Config ブロック前**: `*_ENABLED` 等のデフォルト評価より前に env-loader を実行
3. **REQUIRED_MODULES**: `REQUIRED_MODULES` 配列に `env-loader` を追加
4. **el_load() 呼び出し**: source 後に `el_load` を呼出

```bash
# 統合後の watcher スクリプト（Config ブロック直前）
# ─── per-repo env ファイル ローダ ───
IDD_ENV_LOADER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/idd-qwen-modules/env-loader.sh"
if [ -f "$IDD_ENV_LOADER_PATH" ]; then
  . "$IDD_ENV_LOADER_PATH"
  el_load
fi
unset IDD_ENV_LOADER_PATH
```

### 5. README.md の更新

移植先 README.md のモジュール一覧に新規モジュールを追加:

```bash
read_file /path/to/idd-qwen/README.md
```

追加箇所:
- `qwen-watcher/bin/idd-qwen-modules/` セクションに `env-loader.sh` を追加
- 用途説明をコメントとして付与

### 6. 検証

```bash
# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/env-loader.sh
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh

# 移植元との行数比較
echo "移植元: $(wc -l < /path/to/idd-codex/local-watcher/bin/idd-codex-modules/env-loader.sh) 行"
echo "移植先: $(wc -l < /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/env-loader.sh) 行"

# 移植先モジュールの関数一覧
grep -E '^[a-z_]+\(\)' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/env-loader.sh
```

## 動作原理

env-loader.sh は per-repo env ファイル経由で `*_ENABLED` 系フラグを供給する:

1. 起動時に `REPO_SLUG` を導出
2. env-loader.sh を source（module 不在時は skip、既存挙動と等価）
3. `el_load()` が env ファイルを解決・適用（precedence: inline cron env > env file）
4. Config ブロックの `KEY="${KEY:-default}"` が既存値（env file 由来）を尊重

これにより crontab 行の長さが限界（~1024 文字）に達する問題を解消する。

## 既存モジュールとの関係

| モジュール | 関係 |
|---|---|
| core_utils.sh | 依存なし（独立モジュール） |
| env-loader.sh | Config ブロックより前に source される |
| REQUIRED_MODULES | `env-loader` を含める |

## よくある落とし穴

- **namespace 混同**: 移植元の `idd_codex_` プレフィックスと移植先の `el_` プレフィックスを混同しない
- **Config ブロック順序**: env-loader は Config ブロックより前に source される必要がある
- **モジュール不在時の挙動**: 移植先モジュールが存在しない場合は何もしない（既存挙動と等価）
- **logging 形式の不一致**: 移植元の logging 形式が移植先の形式と異なる場合は変換する
- **依存モジュールの順序**: 移植先で未移植のモジュールを `source` しない

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-repo-rename](./auto-skill-repo-rename/SKILL.md) — レポジトリ名の一括書き換え