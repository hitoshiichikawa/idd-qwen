# モジュール移植（idd-codex → idd-qwen 他レポジトリ間移植）

既存のレポジトリ（idd-codex）から別のレポジトリ（idd-qwen）へ、bash モジュールを移植する。
stub（未完成）または新規作成が必要なモジュールを特定し、full implementation に書き換える。

## 前提

- 移植元レポジトリ（例: `idd-codex`）と移植先レポジトリ（例: `idd-qwen`）が同一マシンに存在する
- 両レポジトリの `gh` CLI 操作が可能

## 手順

### 1. 移植ギャップの特定

移植先モジュールと移植元モジュールの行数・存在を比較:

```bash
SRC_REPO="/path/to/idd-codex/local-watcher/bin/idd-codex-modules/"
DST_REPO="/path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/"

# 移植元モジュールの列挙
ls "$SRC_REPO"

# 移植先モジュールの列挙
ls "$DST_REPO"

# 行数比較
for f in "$SRC_REPO"*.sh; do
  src=$(wc -l < "$f")
  base=$(basename "$f")
  dst="$DST_REPO/$base"
  if [ -f "$dst" ]; then
    dst_lines=$(wc -l < "$dst")
    if [ "$src" -gt "$dst_lines" ]; then
      echo "$base: $src → $dst_lines ($((src - dst_lines))行の差分)"
    else
      echo "$base: 移植済み (${src}行)"
    fi
  else
    echo "$base: 未移植 (${src}行)"
  fi
done
```

### 2. Issue 作成（sub-agent 実行用）

移植すべきモジュールごとに GitHub Issue を作成する。sub-agent が個別セッションで完結する粒度にする:

```bash
cd /path/to/idd-qwen

gh issue create \
  --title "feat: implement <module-name>.sh module" \
  --label "codex-auto-dev" \
  --body "## 概要

\`qwen-watcher/bin/idd-qwen-modules/<module-name>.sh\` を新規作成する。

**移植元**: \`idd-codex/local-watcher/bin/idd-codex-modules/<module-name>.sh\` (<行数>行)
**移植先**: \`qwen-watcher/bin/idd-qwen-modules/<module-name>.sh\` (新規作成)

## 移植すべき機能

- <機能 1>
- <機能 2>
- <機能 3>

## Acceptance Criteria

1. <AC 1>
2. <AC 2>
3. shellcheck が clean である

## 参考

- 移植元: /path/to/idd-codex/local-watcher/bin/idd-codex-modules/<module-name>.sh
"
```

### 3. Issue 一覧の管理

```bash
cd /path/to/idd-qwen
gh issue list --label "codex-auto-dev" --json number,title,url
```

### 4. 移植先モジュールの構造理解

移植元モジュールを `read_file` で読み、移植先の既存 stub と比較:

```bash
# 移植元（full implementation）
read_file /path/to/idd-codex/local-watcher/bin/idd-codex-modules/<module-name>.sh

# 移植先（stub）
read_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh
```

比較ポイント:
- stub に実装されている関数のシグネチャ
- 移植元で使われている依存モジュール
- 移植先で既に定義されている変数・定数

### 5. 移植

移植元モジュールを `read_file` で読み、移植先のファイルパスに合わせて書き換え:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh
```

移植時の注意点:
- **パスの置換**: `idd-codex` → `idd-qwen`、`local-watcher` → `qwen-watcher`
- **変数名の整合**: `MODULE_DIR` 等の変数が移植先で既に定義されている場合は上書きしない
- **依存モジュール**: 移植先で既に移植済みのモジュールを `source` しているか確認
- **shellcheck 互換**: 移植元と移植先の shellcheck 設定が一致するか確認

### 6. 検証

```bash
# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh

# 移植元との行数比較
echo "移植元: $(wc -l < /path/to/idd-codex/local-watcher/bin/idd-codex-modules/<module-name>.sh) 行"
echo "移植先: $(wc -l < /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh) 行"
```

## 移植すべきモジュール一覧（idd-codex → idd-qwen）

| モジュール | 行数 | 状態 |
|---|---|---|
| core_utils.sh | 861 | stub (211行) → 移植必要 |
| env-loader.sh | 169 | 未移植 |
| slack-notify.sh | 109 | 未移植 |
| failed-recovery.sh | 759 | 未移植 |
| needs-decisions-auto.sh | 236 | 未移植 |
| pr-reviewer.sh | 1599 | 未移植 |
| run-summary.sh | 329 | 未移植 |
| auto-merge.sh | 201 | 未移植 |
| auto-merge-design.sh | 195 | 未移植 |
| context-map.sh | 978 | 未移植 |
| scaffolding-health.sh | 368 | 未移植 |
| stale-pickup-reaper.sh | 566 | 未移植 |

## よくある落とし穴

- **パスの混同**: `idd-codex` と `idd-qwen` のパスを混同しない。移植元は参照用、移植先は書き換え用
- **変数の衝突**: 両レポジトリで同名の変数が定義されている場合、移植先の変数値を保持する
- **依存モジュールの順序**: 移植先で未移植のモジュールを `source` しない
- **shellcheck の設定**: 移植元と移植先で shellcheck の設定が異なる場合、移植先の設定に合わせる

## 関連

- [auto-skill-repo-rename](./auto-skill-repo-rename/SKILL.md) — レポジトリ名の一括書き換え
- [design-review-gate.md](../../rules/design-review-gate.md) — 設計レビューゲート