# idd-qwen プロジェクト憲章（Qwen Code 版）

このファイルは、Qwen Code を使用して Issue 駆動開発を行う際のプロジェクト憲章です。
すべての貢献者は、作業開始前にこのファイルを読み直してください。

---

## 技術スタック

- **スクリプト**: bash 4+ (Linux / macOS / WSL)
- **依存 CLI**: `qwen`, `gh`, `jq`, `git`
- **ランタイム追加なし**: Node.js / Python 等は依存しない

---

## コード規約

### bash スクリプト

- 冒頭で `set -euo pipefail` を必ず宣言
- 変数展開は常にクォート (`"$var"`, 配列は `"${arr[@]}"`)
- `which` ではなく `command -v` でコマンドの存在確認
- `~` ではなく `$HOME` を使う
- ファイル冒頭のコメントで「用途 / 配置先 / 依存 / セットアップ参照先」を明記
- 環境変数は `"${VAR:-default}"` で override 可能にし、後方互換性を壊さない
- 破壊的操作（`git checkout`, `rm -rf`, `git push --force*`）の前に前提条件を check
- エラーメッセージは `>&2` に出す

### markdown（テンプレート類）

- h1 はファイル先頭 1 つのみ、以降は階層を一貫させる
- コードフェンスには言語タグを付ける（` ```bash ` / ` ```yaml ` 等）
- 内部リンクは相対パス、コード箇所は `file_path:line_number` 形式

### 全体共通

- 単一責務の関数・セクションに分割する
- 設定値（URL、path prefix、default 値）はファイル冒頭の config ブロックにまとめる
- silent fail を作らない（失敗は exit code / log で明示）

---

## テスト・検証

### 静的解析

- `shellcheck` — 警告ゼロを目指す（accepted な info 級 false-positive は root の `.shellcheckrc` で抑止）

### 手動スモークテスト（変更した成果物ごとに実施）

- **`install.sh` 変更時**: 使い捨て scratch repo を `/tmp` に作り、`./install.sh --repo /tmp/scratch` を実行して冪等性とファイル配置を確認
- **`qwen-codex-issue-watcher.sh` 変更時**:
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo ~/bin/qwen-codex-issue-watcher.sh` を対象なし状態で流し、`処理対象の Issue なし` で正常終了すること
  - E2E: 本リポジトリに test issue を立てて watcher が Triage → PR 作成までできるか

### 冪等性

- `install.sh` は再実行で壊さない
- 既存ファイルがある場合は `.bak` バックアップまたは `--force` で opt-in 上書き

---

## ブランチ・コミット規約

- ブランチ名: `codex/issue-<番号>-<slug>` を原則とする
- コミット: [Conventional Commits](https://www.conventionalcommits.org/) に準拠
  - `feat(scope): ...` / `fix(scope): ...` / `docs(scope): ...` / `refactor(scope): ...` / `chore(scope): ...` / `test(scope): ...`
- 1 PR = 1 Issue を原則とする

---

## 禁止事項

- base ブランチ（既定 `main`、`BASE_BRANCH` 設定によっては `develop` 等）への直接 push
- `.env` / Secrets 実値のコミット、スクリプト内 API Key ハードコード
- 後方互換性を壊す変更を無告知で入れる
- `sudo` を必要とする手順の追加（idd-qwen はユーザースコープ前提）
- モデル ID のハードコード（env default で override 可能にする）
- opt-in gate なしで新しい外部サービス呼び出しを有効化

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念
- **Architect** は要件を変更しない。モジュール構成 / シェルスクリプト分割 / env var 設計 / 後方互換性方針 / ラベル体系 / template 互換性等の設計に専念
- **Developer** は仕様を追加・解釈しない。不明点は PM / Architect に差し戻す
- **Reviewer** は Developer 完了後の独立レビューのみを担当
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念

### idd-qwen 特有の設計上の注意

- **`qwen-watcher/bin/qwen-codex-issue-watcher.sh` の変更**: 既稼働の cron / launchd を壊さない
- **モデル ID デフォルト更新**: 既存ユーザが明示 override している前提で、env default のみ更新
- **README との二重管理**: 挙動を変えたら README の該当箇所も同じ PR で更新する

---

## エージェントが参照する共通ルール（`.qwen/rules/`）

各エージェントは作業前に以下のルールを `Read` で読み込む:

| ルールファイル | 参照エージェント | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC の EARS 記法（When / If / While / Where / shall） |
| `requirements-review-gate.md` | PM | requirements.md の自己レビュー |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー |
| `tasks-generation.md` | Architect / Developer | tasks.md のアノテーション規約 |
| `feature-flag.md` | Developer / Reviewer | Feature Flag Protocol 規約 |
| `issue-dependency.md` | PM / Triage / Architect | Issue 間依存・親子関係の記法 |

---

## 機密情報の扱い

本リポジトリは OSS として公開されるツール / テンプレートです。扱わないもの:

- API keys / OAuth tokens の実値
- 作者個人名義の非公開 path / URL を例示用以外の形でハードコード
- 本番環境の認証情報

Issue 本文に実値が含まれた場合、PM エージェントは実装を進めず `codex-needs-decisions` で人間にエスカレーションする。

---

## 参考資料

- サブエージェント定義: `.qwen/agents/*.md`
- Watcher 実装: `qwen-watcher/bin/qwen-codex-issue-watcher.sh`
- ワークフロー全体像・セットアップ手順: `README.md`