# レポジトリ横断シンボル・ファイル名リネーム

既存のレポジトリ内で、旧命名（例: `qwen-codex`）を新命名（例: `idd-qwen`）に一括書き換えする。
ファイル名変更は `git mv` でコミット履歴を保持し、参照パスも全ファイルで整合させる。

## 手順

### 1. 全スキャン（grep）

```bash
# 旧名の全出現箇所を列挙（.git は除く）
git grep -n 'old-symbol' -- ':!.git'

# 旧名を含むファイル名の列挙
git ls-files | grep 'old-symbol'
```

### 2. ファイル / ディレクトリ名の物理リネーム（git mv）

```bash
# ファイル名変更（履歴保持）
git mv qwen-codex-issue-watcher.sh idd-qwen-issue-watcher.sh

# ディレクトリ名変更（履歴保持）
git mv qwen-codex-modules/ idd-qwen-modules/
```

> **注意**: ディレクトリ名そのものは変更しないケースがある（例: `qwen-watcher/` ディレクトリは残す）。
> 対象を明確に区別すること。**ファイル名**のみ変更する場合、ディレクトリ名への誤変換を防ぐ。

### 3. 参照パスの一括置換

リネームしたファイル / ディレクトリを参照している全ファイルを grep で特定し、`edit` で書き換え:

```bash
# 旧パスを含むファイルを検索
git grep -l 'qwen-codex-modules' -- ':!.git'
git grep -l 'qwen-codex-issue-watcher' -- ':!.git'
```

対象ファイル:
- スクリプト内の `MODULE_DIR` / `LOG_DIR` / `LOCK_FILE` 等の変数値
- plist ファイルの `ProgramArguments` / `StandardOutPath` / `StandardErrorPath`
- README.md のコマンド例・ディレクトリ構成
- `install.sh` の配置パス
- テストファイルの `MODULE_DIR` パス
- `AGENTS.md` 内の watcher 参照
- cron 例・launchctl 例

### 4. 移行文書の扱い

`MIGRATION-GUIDE.md` 等、移行元を示すための文書は **旧名を保持** する（書き換えない）。
移行ガイド自体が「旧名 → 新名」の案内なので、旧名を残すのが意図。

### 5. 最終検証

```bash
# 旧名の残存チェック（.git / MIGRATION-GUIDE.md 以外）
git grep -n 'old-symbol' -- ':!.git' ':!MIGRATION-GUIDE.md'

# リネーム済みファイルの存在確認
git ls-files | grep 'new-symbol'
```

旧名が 0 件になれば完了。

### 6. コミット

```bash
git add -A
git commit -m "chore: rename old-symbol to new-symbol across the repo

- Rename old-file.sh → new-file.sh
- Rename old-dir/ → new-dir/
- Update all internal path references
- Update README.md, install.sh, AGENTS.md references"
```

## 判断ポイント

| 項目 | 方針 |
|---|---|
| ファイル名変更 | `git mv` で履歴保持 |
| ディレクトリ名変更 | 必要に応じて `git mv`。ディレクトリ名そのものは残す場合あり |
| MIGRATION-GUIDE.md | 旧名を保持（移行案内のため） |
| README.md | 新名に更新。cron/launchctl 例も新パスに |
| plist ファイル | `ProgramArguments` / log path を新パスに |
| テストファイル | `MODULE_DIR` 等のパスを新名に |
| AGENTS.md | watcher 参照を新名に |

## よくある落とし穴

- **ディレクトリ名との混同**: `qwen-watcher/` ディレクトリは残して `qwen-codex-issue-watcher.sh` ファイルのみ変更、等。区別を明確にする
- **README の過剰置換**: ディレクトリ名 `qwen-watcher/` を `idd-qwen-watcher/` に誤って書き換えない。コマンド例のパスもディレクトリ名は変えずファイル名のみ変更
- **MIGRATION-GUIDE.md の書き換え**: 移行元を示す文書は旧名を残す
- **plist の漏れ**: `ProgramArguments` のパスだけでなく `StandardOutPath` / `StandardErrorPath` の log ディレクトリも更新