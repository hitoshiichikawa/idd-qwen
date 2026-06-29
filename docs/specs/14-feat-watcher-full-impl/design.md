# Design Document

## Overview

この設計書は Issue #14「feat: rewrite main watcher script from stub to full implementation」
の実装設計を定義します。`idd-codex` の 11,726 行・161 関数のフル実装を
`idd-qwen` の 721 行・14 関数の stub からポートし、production-ready な Issue Watcher
に書き換えます。

**Purpose**: idd-qwen リポジトリの Issue Watcher を idd-codex と同等の機能レベルに引き上げ、
ローカル開発・CI 自動化で drop-in replacement として使用可能にする。
**Users**: idd-qwen の maintainers が `idd-qwen-issue-watcher.sh` を cron/launchd で
定期実行し、GitHub Issue を自動処理する。
**Impact**: 現状の stub（Triage → Architect/Developer → Reviewer の最小フロー）から、
per-task TDD loop、stage checkpoint resume、dependency resolver、parallel execution 等
13+ のサブシステムを統合し、完全な状態機械駆動の watcher に置き換える。

### Goals
- 161 関数の porting を 100% 完了し、shellcheck zero warnings を達成
- 既存 14 関数（config / env loading / basic label ops / stub dispatcher）を保持・強化
- 全 feature flag（`*_ENABLED`）を同等のデフォルト値で再現
- 13+ サブシステムを依存順序で実装（slot management → stage checkpoint → dispatcher → pipeline → per-task → reviewer → debugger → dependency resolver → resume → design review release → spec artifacts → verify → mark/handle/detect）
- 各サブシステムを独立コミット可能な粒度でタスク分割

### Non-Goals
- GitHub Actions 統合（別 Issue）
- リモート実行（local-only 維持）
- 複数リポジトリ同時処理（1 invocation = 1 REPO）
- Web UI / ダッシュボード

## Architecture

### Existing Architecture Analysis

- 現状の target ファイルは基本的な config / env loading / module loading / label 定義 /
  14 個の stub 関数 / simple dispatcher loop を持つ
- source ファイルは 161 関数、13+ サブシステム、複雑な状態機械を実装
- 両者の差は ~130 関数、~10,000+ 行。stub 関数は既存保持し、追加関数をポート
- 尊重すべき既存パターン:
  - `set -euo pipefail` + `export PATH`
  - env var 経由の config（`${VAR:-default}`）
  - module loading（`source` によるモジュール読み込み）
  - label 定義（定数としてのラベル名）
  - `_dispatcher_run` メインループ

### Architecture Pattern & Boundary Map

**Architecture Integration**:
- 採用パターン: **monolithic bash script with modular includes**（現状のアーキテクチャを維持）
- ドメイン／機能境界: 各サブシステムを関数プレフィックスで分離（`sc_*`, `tc_*`, `pt_*`, `dr_*`, `drr_*`, `codex_*`, `slot_*`, `mark_*`, `handle_*`, `detect_*`, `verify_*`, `rv_*`, `dbg_*`）
- 既存パターンの維持: config block → env loader → module loading → label defs → function defs → dispatcher loop
- 新規コンポーネントの根拠: 既存 stub 関数を保持しつつ、追加関数を同一ファイルにポート。別ファイル分割は行わない（source と同一ファイル構成を維持）

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Shell | bash 5.x (macOS) | Watcher script language | `set -euo pipefail` 必須 |
| GitHub API | gh CLI | Issue/PR/Label operations | 既存 module で port |
| jq | jq 1.7+ | JSON parsing for gh output | 既存 module で port |
| Codex CLI | codex (latest) | AI agent execution | `CODEX_*` env vars で制御 |
| File locking | flock | Worktree slot management | 既存 module で port |
| Git | git 2.x | Branch management, worktrees | 既存 module で port |

## File Structure Plan

### Directory Structure

```
qwen-watcher/
├── bin/
│   └── idd-qwen-issue-watcher.sh    # 単一ファイル。全関数をここにポート
├── modules/                          # source の modules 相当
│   ├── core_utils.sh                 # core utilities (log, env, etc.)
│   ├── env-loader.sh                 # per-repo env file loader
│   ├── needs-decisions-auto.sh       # auto-continue for needs-decisions
│   ├── pr-reviewer.sh                # PR reviewer integration
│   ├── auto-merge.sh                 # auto-merge logic
│   └── ...                           # other modules from source
└── test/
    └── test-watcher.sh               # shellcheck + unit tests
```

### Modified Files

- `qwen-watcher/bin/idd-qwen-issue-watcher.sh` — 既存 14 関数を保持し、~130 関数を追加ポート。
  既存関数の実装も source に準じて強化（例: `_dispatcher_run` の stub から full 実装へ）

## Requirements Traceability

| Requirement | Summary | Components |
|-------------|---------|------------|
| 1 | Porting scope and completeness | All subsystems |
| 2 | Stage checkpoint system | sc_*, stage_checkpoint_* |
| 3 | Tasks count gate | tc_* |
| 4 | Per-task TDD loop | pt_*, run_per_task_* |
| 5 | Implementation pipeline | run_impl_pipeline |
| 6 | Reviewer and Debugger stages | rv_*, dbg_*, run_reviewer_stage, run_debugger_stage |
| 7 | Design review release processor | drr_* |
| 8 | Spec artifacts completeness guard | _spec_*, spec_artifacts_* |
| 9 | Failed recovery and resume | _failed_recovery_*, _resume_* |
| 10 | Dependency resolver | dr_* |
| 11 | Codex CLI integration | codex_* |
| 12 | Slot management and parallel execution | slot_* |
| 13 | Label operations and state transitions | mark_*, update_issue_labels |
| 14 | Dispatcher with full-auto and stale pickup reaper | dispatcher_*, _dispatcher_* |
| NFR 1-5 | Non-functional requirements | All |

## Components and Interfaces

### Stage Checkpoint

| Field | Detail |
|-------|--------|
| Intent | Stage 完了状態を checkpoint マーカーとして記録・復元 |
| Requirements | 2 |

**Responsibilities & Constraints**
- Stage A/B/C 完了時に checkpoint マーカーを log に記録
- 再起動時に既存 checkpoint を検出し、完了済み stage をスキップ
- `stage-checkpoint:` prefix で grep 抽出可能

**Dependencies**
- Inbound: run_impl_pipeline — checkpoint 状態参照
- Outbound: (none) — pure utility

**Contracts**: [ ] Service / [x] Utility / [ ] API

##### Utility Interface

```bash
sc_log() { echo "[$(date '+%F %T')] stage-checkpoint: $*" }
sc_warn() { echo "[$(date '+%F %T')] stage-checkpoint: WARN: $*" >&2 }
sc_error() { echo "[$(date '+%F %T')] stage-checkpoint: ERROR: $*" >&2 }
stage_checkpoint_has_impl_notes() { ... }
stage_checkpoint_has_review_notes() { ... }
sc_issue_state() { ... }
sc_tasks_unchecked_count() { ... }
```

### Tasks Count Gate

| Field | Detail |
|-------|--------|
| Intent | tasks.md のタスク数を検証し、過大タスクリストを早期検出 |
| Requirements | 3 |

**Responsibilities & Constraints**
- 最上位未チェックタスク数をカウント（regex: `^- \[ \]\*? [0-9]+\.[[:space:]]`）
- ≤10: pass, 11-13: consolidation attempt, ≥14: escalate to human
- `TC_ENABLED=false` でスキップ可能

**Dependencies**
- Inbound: Architect stage completion — tasks.md 存在確認
- Outbound: dr_labels_contain — needs-decisions label 付与

**Contracts**: [ ] Service / [x] Utility / [ ] API

### Per-Task TDD Loop

| Field | Detail |
|-------|--------|
| Intent | タスク単位で fresh Codex session を起動し、turn budget 管理 |
| Requirements | 4 |

**Responsibilities & Constraints**
- 各タスクを独立 session で実行（prompt injection で scope 限定）
- `error_max_turns` 発生時はタスク失敗だが他タスクは継続
- checkbox 更新 + `docs(tasks): mark <id> as done` commit
- `PER_TASK_LOOP_ENABLED=false` で single-session Fallback

**Dependencies**
- Inbound: run_impl_pipeline — タスクリスト取得
- Outbound: pt_run_repeated_reject_warning_redo — Reviewer reject 対応
- External: Codex CLI — session 起動

**Contracts**: [x] Service / [ ] API / [ ] Event

### Implementation Pipeline

| Field | Detail |
|-------|--------|
| Intent | 完全な実装パイプライン（Triage → Architect/Developer → PjM → Reviewer → Debugger）をオーケストレート |
| Requirements | 5 |

**Responsibilities & Constraints**
- `codex-auto-dev` ラベルの issue を claim → Triage → Architect/Developer → PjM → Reviewer → Debugger
- 各 stage transition を `stage:` prefix でログ出力
- `partial_blocked` / `partial_overrun` 検出で `codex-needs-decisions` エスカレーション
- 全 stage 失敗で `codex-failed`

**Dependencies**
- Inbound: _dispatcher_run — issue 取得
- Outbound: run_per_task_loop, run_reviewer_stage, run_debugger_stage
- External: gh CLI, Codex CLI

**Contracts**: [x] Service / [ ] API

### Reviewer and Debugger

| Field | Detail |
|-------|--------|
| Intent | 実装後の独立品質ゲート（Reviewer + optional Debugger） |
| Requirements | 6 |

**Responsibilities & Constraints**
- Developer 完了後、Reviewer が最新 diff + requirements.md + tasks.md + impl-notes.md でレビュー
- Reviewer approve → PjM、reject → Developer 再実行（max 2 rounds）
- Round 2 reject で Debugger 起動（`CODEX_DEBUGGER_ENABLED=true`）
- Debugger guidance → Developer 再実行 → Reviewer 再提出

**Dependencies**
- Inbound: run_impl_pipeline — 実装完了通知
- Outbound: rv_*, dbg_* — 個別 stage 実行

**Contracts**: [x] Service / [ ] API

### Design Review Release

| Field | Detail |
|-------|--------|
| Intent | 設計 PR merge 検知で自動ラベル解放 |
| Requirements | 7 |

**Responsibilities & Constraints**
- `codex-awaiting-design-review` 付き issue をポーリング
- 設計 PR merge 検知 → ラベル除去 + `codex-picked-up` 追加
- `DRR_GH_TIMEOUT` 尊重

**Dependencies**
- Inbound: _dispatcher_run — issue 取得
- Outbound: gh CLI — PR 状態確認

**Contracts**: [ ] Service / [x] Utility / [ ] API

### Spec Artifacts Guard

| Field | Detail |
|-------|--------|
| Intent | 全 spec artifact の存在検証 |
| Requirements | 8 |

**Responsibilities & Constraints**
- Architect 完了後、`requirements.md` / `design.md` / `tasks.md` の存在確認
- 不足あり → `codex-failed` + 欠落 artifact 名をログ

**Dependencies**
- Inbound: Architect stage completion
- Outbound: (none) — pure check

**Contracts**: [ ] Service / [x] Utility / [ ] API

### Failed Recovery and Resume

| Field | Detail |
|-------|--------|
| Intent | 部分失敗からの復旧（checkpoint 基準） |
| Requirements | 9 |

**Responsibilities & Constraints**
- 既存 branch 検知 → 中断前 run の検出
- Stage A artifacts 存在 → checkpoint からの resume
- non-fast-forward branch → `codex-failed`
- worktree busy → slot release + retry

**Dependencies**
- Inbound: _dispatcher_run — issue 取得
- Outbound: git — branch 操作

**Contracts**: [ ] Service / [x] Utility / [ ] API

### Dependency Resolver

| Field | Detail |
|-------|--------|
| Intent | cross-issue dependency の解決とブロック |
| Requirements | 10 |

**Responsibilities & Constraints**
- `Depends on: #N` 参照をチェック
- 依存 issue が `codex-failed` / `codex-needs-decisions` → ブロック + コメント
- cycle 検出 → `codex-needs-decisions` エスカレーション
- `DR_AUTO_UNBLOCK_ENABLED=true` → 依存 merge 後の自動 unblock

**Dependencies**
- Inbound: _dispatcher_run — issue 取得
- Outbound: gh CLI — issue 状態確認
- External: GitHub API — GraphQL / REST

**Contracts**: [x] Service / [ ] API

### Codex CLI Integration

| Field | Detail |
|-------|--------|
| Intent | Codex CLI への適切な統合（reasoning effort, timeout, web search, agent roles） |
| Requirements | 11 |

**Responsibilities & Constraints**
- `CODEX_SANBOX=danger-full-access`, `CODEX_APPROVAL_POLICY=never`
- stage 別の reasoning effort（Triage: low, Architect: medium, Developer: high）
- `CODEX_DEBUGGER_WEB_SEARCH=true` → Debugger で web search 有効化
- `.qwen/agents/*.md` から agent role 定義を注入
- `CODEX_DEFAULT_TIMEOUT_SEC` 尊重

**Dependencies**
- Inbound: 各 stage — stage 種別取得
- Outbound: Codex CLI — 実行

**Contracts**: [x] Service / [ ] API

### Slot Management

| Field | Detail |
|-------|--------|
| Intent | worktree slot の並列管理（flock によるファイルロック） |
| Requirements | 12 |

**Responsibilities & Constraints**
- issue 取得時に slot 取得（flock）
- slot 利用不可 → スキップ + 次 poll cycle で再試行
- 処理完了 → slot 解放
- SLOT_TIMEOUT 超過 → 強制解放
- `SLOT_MAX` 設定対応（デフォルト: CPU 数）

**Dependencies**
- Inbound: _dispatcher_run — issue 取得/完了通知
- Outbound: flock — ファイルロック

**Contracts**: [x] Service / [ ] API

### Label Operations

| Field | Detail |
|-------|--------|
| Intent | GitHub issue label の状態遷移管理 |
| Requirements | 13 |

**Responsibilities & Constraints**
- 全 17 ラベル定義を保持
- claim: `codex-claimed` 追加 / `codex-auto-dev` 除去
- Triage → Architect: `codex-awaiting-design-review` 追加
- Developer 完了: `codex-ready-for-review` 追加
- Reviewer approve: `codex-picked-up` 追加
- 全 stage 失敗: `codex-failed` 追加
- 人間判断待ち: `codex-needs-decisions` 追加

**Dependencies**
- Inbound: 各 stage — ラベル操作要求
- Outbound: gh CLI — label 操作

**Contracts**: [ ] Service / [x] Utility / [x] API

### Dispatcher

| Field | Detail |
|-------|--------|
| Intent | メインディスパッチャーループ（poll → claim → dispatch） |
| Requirements | 14 |

**Responsibilities & Constraints**
- 設定済み poll interval で issue ポーリング
- `FULL_AUTO_ENABLED=true` → `codex-needs-decisions` 自動継続
- `STALE_PICKUP_REAPER_ENABLED=true` → 古い claim を解放
- 各 dispatch action を `dispatcher:` prefix でログ
- エラー時（rate limit / network）→ exponential backoff retry

**Dependencies**
- Inbound: (none) — entry point
- Outbound: claim_issue, release_issue, list_auto_dev_issues
- External: GitHub API — issue 一覧取得

**Contracts**: [x] Service / [ ] API

### Mark/Handle/Detect Utilities

| Field | Detail |
|-------|--------|
| Intent | issue 状態マーカーの付与・検出 |
| Requirements | 5, 9 |

**Responsibilities & Constraints**
- `mark_issue_failed()` — `codex-failed` 付与 + コメント
- `mark_issue_needs_decisions()` — `codex-needs-decisions` 付与
- `handle_partial_status()` — `partial_blocked` / `partial_overrun` 検出
- `detect_blocked_marker()` — `BLOCKED:` マーカー検出
- `detect_needs_decision_marker()` — `NEEDS_DECISION:` マーカー検出
- `detect_partial_status()` — `STATUS: partial_*` 検出
- `detect_debugger_already_invoked()` — Debugger 既呼出検出

**Dependencies**
- Inbound: 各 stage — マーカー操作要求
- Outbound: add_issue_comment, update_issue_labels

**Contracts**: [ ] Service / [x] Utility / [ ] API

### Verify Utilities

| Field | Detail |
|-------|--------|
| Intent | push / PR 検証 |
| Requirements | 5, 6 |

**Responsibilities & Constraints**
- `verify_pushed_or_retry()` — push 成功確認 + retry
- `verify_stagec_pr_or_retry()` — Stage C PR 作成確認 + retry

**Dependencies**
- Inbound: PjM stage — PR 作成完了通知
- Outbound: gh CLI — PR 状態確認

**Contracts**: [ ] Service / [x] Utility / [ ] API

## Data Models

### Issue State Machine

```
[codex-auto-dev] --claim--> [codex-claimed]
                              |
                              v
                          [Triage]
                              |
              +---------------+---------------+
              |                               |
              v (needs-decisions)             v (safe)
        [codex-needs-decisions]         [Architect / Developer]
              |                               |
              v (human decision)              v
        [human resolves]                [design.md + tasks.md]
                                            |
                                            v
                                      [codex-awaiting-design-review]
                                            |
                                            v (design PR merged)
                                      [codex-picked-up]
                                            |
                                            v
                                      [Developer → per-task loop]
                                            |
                                            v
                                      [codex-ready-for-review]
                                            |
                                            v
                                      [Reviewer Round 1]
                                            |
                              +-------------+-------------+
                              |                           |
                              v (approve)                v (reject)
                        [codex-picked-up]          [Developer re-run]
                              |                           |
                              v                           v
                        [PjM: PR]               [Reviewer Round 2]
                              |                   |           |
                              |                   v (approve) v (reject)
                              |              [PjM: PR]    [Debugger]
                              |                           |
                              |                           v
                              |                    [Developer re-run]
                              |                           |
                              |                           v
                              |                    [Reviewer Round 1]
                              |                           |
                              v (cycle)                   v
                        [PjM: PR]               (loop or fail)
                              |
                              v
                         [complete]
```

### Error State Transitions

| Condition | Action | Label |
|-----------|--------|-------|
| Any stage fails | Mark failed | `codex-failed` |
| partial_blocked / partial_overrun | Escalate | `codex-needs-decisions` |
| Dependency not met | Block | `codex-needs-decisions` + comment |
| Cycle detected | Escalate | `codex-needs-decisions` |
| Stale pickup detected | Release | Remove `codex-claimed` |

## Error Handling

### Error Strategy

- 全 stage は `try/catch` 的な `trap` で囲み、エラー時は `mark_issue_failed()` を呼ぶ
- GitHub API 失敗（rate limit / network）→ exponential backoff retry（max 3 回）
- Codex CLI 失敗 → stage 失敗として記録（per-task loop 時はタスク失敗のみ）
- Worktree slot 取得失敗 → skip + 次 poll cycle で再試行

### Error Categories and Responses

- **GitHub API Errors (4xx/5xx)**: retry with backoff、rate limit 検知で待機
- **Codex CLI Errors**: stage 失敗として記録、partial status 検出でエスカレーション
- **Git Errors (branch conflict, worktree busy)**: slot release + retry、non-ff branch で failed
- **File I/O Errors**: log error + fallback、checkpoint 不備で stage skip

## Testing Strategy

- **Unit Tests**: shellcheck zero warnings、各 utility function の独立テスト
- **Integration Tests**: `qwen-watcher/test/test-watcher.sh` で core utilities の動作確認
- **E2E Tests**: 手動テスト（GitHub Issue での end-to-end 実行）— CI 自動化は別 Issue

## Optional Sections

### Performance & Scalability

- `SLOT_MAX` で並列処理数を制限（デフォルト: CPU 数）
- poll interval で負荷調整（`DISPATCH_INTERVAL`）
- GitHub API rate limit 対応で exponential backoff

### Migration Strategy

```
Current State (stub, 14 funcs)
    |
    v
Phase 1: Core utilities + Stage Checkpoint + Slot Management
    |
    v
Phase 2: Tasks Count Gate + Spec Artifacts Guard
    |
    v
Phase 3: Dispatcher + Label Operations + Mark/Handle/Detect
    |
    v
Phase 4: Codex CLI Integration + Implementation Pipeline
    |
    v
Phase 5: Per-Task TDD Loop + Reviewer/Debugger
    |
    v
Phase 6: Design Review Release + Failed Recovery + Resume
    |
    v
Phase 7: Dependency Resolver + Verify Utilities
    |
    v
Complete (161 funcs, shellcheck clean)
```

## Supporting References

- Source: `/Users/hitoshi/github/idd-codex/local-watcher/bin/idd-codex-issue-watcher.sh`
- Target: `/Users/hitoshi/github/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh`
- Requirements: `docs/specs/14-feat-watcher-full-impl/requirements.md`