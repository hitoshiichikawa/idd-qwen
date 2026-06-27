# 実装完了確認と PR 準備

実装コミットが既に存在する Issue について、実装内容を確認し、PR を Review 待ち状態に整える。
実装は sub-agent（Developer）が完了済みで、人間がレビューして merge するまでのブリッジ手順。

## 前提

- Issue が `codex-auto-dev` ラベル付きで存在し、実装ブランチが push 済み
- PR が既に作成されている（PjM が作成）
- 人間が PR をレビューして merge する

## 手順

### 1. Issue 状態の把握

```bash
gh issue view <issue-number> --json title,body,state,labels,comments,assignees
```

確認ポイント:
- Issue が OPEN であること
- `codex-needs-decisions` ラベルの有無（あれば削除対象）
- 関連 PR の存在確認

### 2. 実装ブランチとコミット確認

```bash
git log --oneline -5
git branch -a | grep -E '<slug>'
```

確認ポイント:
- 実装ブランチが最新コミットを含む
- ブランチ名が `feat/<slug>` パターンに一致

### 3. 実装ファイルの確認

```bash
# 行数確認（stub → full の差分が期待通りか）
wc -l < path/to/module.sh

# 先頭確認（ヘッダ・プレフィックスが正しいか）
head -50 path/to/module.sh

# 直近差分確認
git diff HEAD~1..HEAD --stat
git diff HEAD~1..HEAD -- path/to/module.sh | head -200
```

確認ポイント:
- 行数が移植元と同等以上
- 既存 stub 関数が維持されている
- プレフィックスが移植先規則に一致

### 4. PR 状態の確認

```bash
gh pr list --head <branch-name> --json number,title,state,labels,mergeable,reviewRequests
```

確認ポイント:
- PR が OPEN であること
- `mergeable: MERGEABLE` であること
- レビューリクエストが未設定（人間に回す状態）

### 5. 構文チェック

```bash
bash -n path/to/module.sh && echo "Syntax OK" || echo "Syntax ERROR"
```

bash スクリプトの場合、`bash -n` で構文チェックを必ず行う。

### 6. ラベル操作

- Issue から `codex-needs-decisions` を削除
- PR に appropriate なラベルを付与（`enhancement` 等）

```bash
# Issue から codex-needs-decisions を削除
gh issue edit <issue-number> --remove-label codex-needs-decisions

# PR に appropriate ラベルを付与
gh pr edit <pr-number> --add-label enhancement
```

利用可能なラベル一覧:
```bash
gh label list
```

### 7. 完了報告

ユーザーに対して以下の情報をまとめて報告:

- Issue 番号とタイトル
- 実装ブランチとコミットハッシュ
- PR 番号と状態
- 行数・差分サマリー
- 構文チェック結果
- ラベル操作内容
- 次のステップ（人間による PR review + merge）

## 判断ポイント

| 項目 | 正常時 | 異常時 |
|---|---|---|
| Issue state | `OPEN` | `CLOSED` なら何らかの対応が必要 |
| PR state | `OPEN` + `MERGEABLE` | `CLOSED` / `MERGE_CONFLICT` なら調査 |
| 行数 | 移植元 ≥ 移植先 | 移植先 > 移植元 は要確認（過剰実装） |
| 構文 | `Syntax OK` | `Syntax ERROR` なら実装不備 |
| codex-needs-decisions | 削除済み | 未削除なら削除する |

## よくある落とし穴

- **ラベル名の不一致**: `needs-review` は標準ラベルではない。レポジトリ固有のラベル（`codex-ready-for-review` 等）を確認する
- **mergeable の誤認**: `MERGEABLE` は local clone での判定。remote で conflict が発生している場合あり
- **行数の過大**: 移植先が移植元より多い場合、移植元固有機能が混入していないか確認
- **プレフィックス混在**: `_qw_` と `cu_` 等、異なるプレフィックスが混在していないか

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-stub-to-full](./auto-skill-stub-to-full/SKILL.md) — stub から full implementation への移植