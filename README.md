# idd-qwen

**I**ssue-**D**riven **D**evelopment with **Qwen Code** — GitHub Issue を起点に、
PM / Architect / 開発者 / PjM の 4 サブエージェント体制で自動開発を行うためのテンプレート一式。

Qwen Code のネイティブ機能（ヘッドレスモード、agent ツール、loop スキル等）を使用して、
Issue 駆動の開発ワークフローを自動化します。

---

## 概要

`idd-qwen` は、Qwen Code を使用して GitHub Issue 駆動の開発を自動化するためのワークフローテンプレートです。

Codex CLI 向けに設計された `idd-codex` のワークフローを、Qwen Code のネイティブ機能で再実装しています。

### 主な特徴

- **Qwen Code ネイティブ**: Qwen Code のヘッドレスモード、agent ツール、loop スキルを最大限に活用
- **Issue 駆動**: `codex-auto-dev` ラベルの Issue を自動検出 → ブランチ作成 → 実装 → PR作成まで自動化
- **人間レビュー内蔵**: 重要な判断は Issue コメントで人間に確認（Human-in-the-Loop）
- **ラベルベースの状態管理**: Issue の状態遷移を GitHub ラベルで表現
- **設計 PR ゲート**: 複雑な Issue は Architect が設計書（requirements.md, design.md, tasks.md）を生成 → 人間レビュー → 実装

---

## ディレクトリ構成

```
idd-qwen/
├── README.md                        # 本ファイル
├── MIGRATION-GUIDE.md               # idd-codex からの移行ガイド
├── .gitignore
│
├── .qwen/                           # Qwen Code 用設定
│   ├── agents/                      # エージェント定義
│   │   ├── product-manager.md       # PM: 要件定義（requirements.md）
│   │   ├── architect.md             # Architect: 設計書（design.md + tasks.md）
│   │   ├── developer.md             # Developer: 実装・テスト・コミット
│   │   ├── reviewer.md              # Reviewer: 実装差分の独立レビュー
│   │   ├── project-manager.md       # PjM: PR 作成・ラベル管理
│   │   ├── qa.md                    # QA: 高リスク独立レビュー（手動）
│   │   └── debugger.md              # Debugger: 原因究明 + Fix Plan
│   └── rules/                       # エージェントが参照する共通ルール
│       ├── ears-format.md           # 受入基準の EARS 記法
│       ├── requirements-review-gate.md  # PM 自己レビューゲート
│       ├── design-principles.md     # design.md 記述原則
│       ├── design-review-gate.md    # Architect 自己レビューゲート
│       ├── tasks-generation.md      # tasks.md アノテーション規約
│       ├── feature-flag.md          # Feature Flag Protocol 規約
│       └── issue-dependency.md      # Issue 間依存関係の記法
│
├── qwen-watcher/                    # Qwen Code 用 Issue 監視 watcher
│   ├── bin/
│   │   ├── qwen-codex-issue-watcher.sh      # メイン watcher スクリプト
│   │   └── qwen-codex-modules/              # モジュール群
│   │       ├── core_utils.sh                # 共通ユーティリティ
│   │       ├── triage.sh                    # Triage プロセッサ
│   │       ├── dispatch.sh                  # Dispatch プロセッサ
│   │       ├── stage-a-verify.sh            # Stage A Verify
│   │       ├── merge-queue.sh               # マージキュー
│   │       ├── pr-iteration.sh              # PR Iteration
│   │       ├── promote-pipeline.sh          # Promote Pipeline
│   │       ├── quota-aware.sh               # クォータ制御
│   │       ├── auto-rebase.sh               # 自動 Rebase
│   │       └── codex-guard.sh               # Codex Guard Hook
│   └── LaunchAgents/
│       └── com.local.qwen-codex-issue-watcher.plist  # macOS launchd 設定
│
├── repo-template/                 # 他 repo に配置するテンプレート
│   ├── AGENTS.md
│   ├── .codex/
│   │   ├── agents/
│   │   └── rules/
│   └── .github/
│       ├── ISSUE_TEMPLATE/
│       └── scripts/
│
└── tests/                         # テストスクリプト
```

---

## セットアップ

### クイックインストール

```bash
# 対象ディレクトリに cd してから実行
cd /path/to/your-project

# idd-qwen を clone
git clone https://github.com/hitoshiichikawa/idd-qwen.git
cd idd-qwen

# 対象リポジトリに配置
./install.sh --repo /path/to/your-project
```

### 手動セットアップ

```bash
# 1. idd-qwen を clone
git clone https://github.com/hitoshiichikawa/idd-qwen.git
cd idd-qwen

# 2. 対象リポジトリにテンプレートを配置
cp -r .qwen /path/to/your-project/
cp -r qwen-watcher /path/to/your-project/

# 3. GitHub ラベルを作成
gh label create codex-auto-dev --repo owner/repo --color 1f77b4 --description "自動開発対象"
gh label create codex-claimed --repo owner/repo --color c39bd3 --description "Codex CLI が claim 済"
gh label create codex-picked-up --repo owner/repo --color 9b59b6 --description "Codex CLI 実行中"
gh label create codex-ready-for-review --repo owner/repo --color 2ecc71 --description "PR 作成完了"
gh label create codex-failed --repo owner/repo --color e74c3c --description "自動実行が失敗"
# ... 以下必要なラベルを継続

# 4. cron または launchd で watcher を定期実行
# 例: 5分ごとに実行
*/5 * * * * cd /path/to/repo && ~/bin/qwen-codex-issue-watcher.sh 2>&1 | tee -a /tmp/qwen-codex.log
```

### macOS 向け LaunchAgents 設定

```bash
# LaunchAgents plist を配置
cp qwen-watcher/launch/com.idd-qwen.issue-watcher.plist ~/Library/LaunchAgents/

# launchctl に登録
launchctl load ~/Library/LaunchAgents/com.idd-qwen.issue-watcher.plist

# 状態確認
launchctl list | grep qwen-codex
```

---

## 使い方

### 対話型（推奨）

Qwen Code セッションを開始し、以下のようにプロンプトを入力するだけでワークフローが実行されます。

```
Check repo for codex-auto-dev issues and process them
```

### ヘッドレス型（自動化向け）

```bash
# 単回実行
qwen "Check repo for codex-auto-dev issues and process them" -y --channel CI --max-tool-calls 100 --max-wall-time 900s

# 定期実行（cron 等）
qwen-watcher/bin/qwen-codex-issue-watcher.sh
```

### qwen serve による HTTP API 利用

```bash
# Qwen Code サーバーを起動
qwen serve --token your-secret-token --max-sessions 20

# Issue 処理を HTTP API で実行
curl -X POST http://localhost:4170/session \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Check repo for codex-auto-dev issues and process them"}'
```

---

## ワークフロー

```
Issue 起票（codex-auto-dev ラベル付与）
    |
    v
Triage（Qwen Code ヘッドレス実行）
    |
    +-- needs_architect: false --> Developer 直起動
    |                                   |
    |                              実装 + テスト + コミット
    |                                   |
    |                              Reviewer 起動
    |                                   |
    |                              approve --> PjM: impl PR 作成
    |                              reject  --> Developer 修正
    |
    +-- needs_architect: true --> Architect 起動
                                       |
                                       v
                                  PM 起動（requirements.md）
                                       |
                                       v
                                  Architect 起動（design.md + tasks.md）
                                       |
                                       v
                                  PjM: design-review PR 作成
                                       |
                                    [人間レビュー / merge]
                                       |
                                       v
                                  Developer 起動（実装）
                                       |
                                       v
                                  Reviewer 起動（レビュー）
                                       |
                                       v
                                  PjM: impl PR 作成
```

---

## 移行ガイド

`idd-codex` から `idd-qwen` への移行については、[MIGRATION-GUIDE.md](./MIGRATION-GUIDE.md) を参照してください。

---

## 依存関係

- **Qwen Code**: 最新バージョン（`qwen` コマンドが実行できる状態）
- **GitHub CLI**: `gh` コマンドのインストールと `gh auth login` 済み
- **jq**: JSON 処理用
- **git**: バージョン管理
- **bash**: 4+（Linux / macOS / WSL）

---

## ライセンス

MIT License

---

## 参考

- 元となった `idd-codex`: https://github.com/hitoshiichikawa/idd-codex
- Qwen Code: https://code.qwen.ai/