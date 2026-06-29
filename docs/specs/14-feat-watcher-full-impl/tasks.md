# Implementation Plan

- [ ] 1. Core utilities + Stage Checkpoint + Slot Management
  - `core_utils.sh` module から log/warn/error/date 関数をポート（_log, _warn, _error）
  - `_env_get()` / `_env_set()` 等の env helper をポート
  - `sc_log()`, `sc_warn()`, `sc_error()` を追加（stage-checkpoint: prefix）
  - `stage_checkpoint_has_impl_notes()` / `stage_checkpoint_has_review_notes()` を追加
  - `sc_issue_state()` / `sc_tasks_unchecked_count()` を追加
  - `STAGE_CHECKPOINT_ENABLED` flag guard を追加
  - `slot_acquire()`, `slot_release()`, `slot_exists()` を追加
  - `flock` によるファイルロック実装をポート
  - `SLOT_MAX` / `SLOT_TIMEOUT` / CPU 数検出ロジックを追加
  - _Requirements: 1.3, 2.1, 2.2, 2.3, 2.4, 2.5, 12.1, 12.2, 12.3, 12.4, 12.5
  - _Boundary: core_utils, sc_*, slot_*

- [ ] 2. Tasks Count Gate + Spec Artifacts Guard
  - `tc_count_tasks()` を追加（regex: `^- \[ \]\*? [0-9]+\.[[:space:]]`）
  - `tc_validate()` を追加（≤10 pass, 11-13 consolidation, ≥14 escalate）
  - `TC_ENABLED=false` guard を追加
  - `dr_labels_contain()` を追加（needs-decisions label 判定用）
  - `_spec_check_requirements()` / `_spec_check_design()` / `_spec_check_tasks()` を追加
  - `_spec_artifacts_exist()` を追加（3 artifact 存在確認）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 8.1, 8.2, 8.3
  - _Boundary: tc_*, _spec_*
  - _Depends: 1

- [ ] 3. Label Operations + Mark/Handle/Detect Utilities
  - 全 17 ラベル定数を追加（既存 14 関数の label 定義を source に準拠）
  - `update_issue_labels()` を追加（add/remove 両対応）
  - `add_issue_label()` / `remove_issue_label()` を追加
  - `mark_issue_failed()` / `mark_issue_needs_decisions()` を追加
  - `handle_partial_status()` を追加（partial_blocked / partial_overrun 検出）
  - `detect_blocked_marker()` / `detect_needs_decision_marker()` を追加
  - `detect_partial_status()` / `detect_debugger_already_invoked()` を追加
  - _Requirements: 5.5, 9.1, 9.2, 9.3, 9.4, 9.5, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7
  - _Boundary: label defs, update_issue_labels, mark_*, handle_*, detect_*
  - _Depends: 1

- [ ] 4. Dispatcher Full Implementation
  - `_dispatcher_run()` を stub から full 実装へ書き換え
  - `claim_issue()` / `release_issue()` / `list_auto_dev_issues()` を追加
  - `FULL_AUTO_ENABLED` / `STALE_PICKUP_REAPER_ENABLED` flag guard を追加
  - exponential backoff retry 実装をポート
  - `dispatcher:` prefix ログを全 action に追加
  - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5
  - _Boundary: dispatcher_*, _dispatcher_*
  - _Depends: 2, 3

- [ ] 5. Codex CLI Integration + Implementation Pipeline
  - `codex_run()` / `codex_run_with_effort()` を追加
  - `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` config を追加
  - stage 別 reasoning effort（low/medium/high）実装
  - `CODEX_DEBUGGER_WEB_SEARCH` flag guard を追加
  - `.qwen/agents/*.md` から agent role 定義を注入するロジックをポート
  - `CODEX_DEFAULT_TIMEOUT_SEC` 尊重実装
  - `run_impl_pipeline()` を追加（Triage → Architect/Developer → PjM → Reviewer → Debugger）
  - 各 stage transition を `stage:` prefix でログ出力
  - `partial_blocked` / `partial_overrun` 検出で `codex-needs-decisions` エスカレーション
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 11.1, 11.2, 11.3, 11.4, 11.5
  - _Boundary: codex_*, run_impl_pipeline
  - _Depends: 3

- [ ] 6. Per-Task TDD Loop + Reviewer/Debugger Stages
  - `run_per_task_loop()` を追加（tasks.md 逐次処理）
  - 各タスクごとの fresh Codex session 起動ロジック
  - checkbox 更新 + `docs(tasks): mark <id> as done` commit 実装
  - `error_max_turns` 検出でタスク失敗（他タスク継続）
  - `PER_TASK_LOOP_ENABLED=false` 時の single-session fallback
  - `run_reviewer_stage()` / `run_debugger_stage()` を追加
  - Reviewer Round 1 / Round 2 ロジック（max 2 rounds）
  - Debugger guidance → Developer 再実行 → Reviewer 再提出
  - `CODEX_DEBUGGER_ENABLED` flag guard
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 6.1, 6.2, 6.3, 6.4, 6.5
  - _Boundary: pt_*, run_per_task_*, rv_*, dbg_*
  - _Depends: 5

- [ ] 7. Design Review Release + Failed Recovery + Resume
  - `drr_process()` / `drr_check_pr()` を追加
  - `codex-awaiting-design-review` 付き issue のポーリング
  - 設計 PR merge 検知 → ラベル除去 + `codex-picked-up` 追加
  - `DRR_GH_TIMEOUT` 尊重実装
  - `_failed_recovery_check()` / `_resume_from_checkpoint()` を追加
  - 既存 branch 検知 → 中断前 run の検出
  - Stage A artifacts 存在 → checkpoint からの resume
  - non-fast-forward branch 検出 → `codex-failed`
  - worktree busy 検出 → slot release + retry
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 9.1, 9.2, 9.3, 9.4, 9.5
  - _Boundary: drr_*, _failed_recovery_*, _resume_*
  - _Depends: 3

- [ ] 8. Dependency Resolver + Verify Utilities
  - `dr_resolve()` / `dr_check_depends()` / `dr_detect_cycle()` を追加
  - `Depends on: #N` 参照の parse ロジック
  - 依存 issue が `codex-failed` / `codex-needs-decisions` → ブロック + コメント
  - cycle 検出 → `codex-needs-decisions` エスカレーション
  - `DR_AUTO_UNBLOCK_ENABLED=true` 時の自動 unblock
  - `verify_pushed_or_retry()` / `verify_stagec_pr_or_retry()` を追加
  - push 成功確認 + retry ロジック
  - Stage C PR 作成確認 + retry ロジック
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 5.3, 6.2
  - _Boundary: dr_*, verify_*
  - _Depends: 3

- [ ] 9. Stub Function Full Implementation + Feature Flag Parity
  - 既存 14 関数（config / env loading / basic label ops / stub dispatcher）を source に準じて full 実装へ書き換え
  - `_watcher_config()` / `_load_env()` / `_load_modules()` の full 実装
  - `label_codex_claimed()` 等の既存 stub 関数を full 実装へ
  - 全 `*_ENABLED` feature flag を source に準じて追加
  - 各 flag の guard pattern（`if [ "$*_ENABLED" = "true" ]`）を実装
  - default 値を source と同一に設定
  - _Requirements: 1.2, 1.3
  - _Boundary: config, env_loader, label defs
  - _Depends: 1, 3

- [ ] 10. Module Porting + Shellcheck + Test Script
  - `core_utils.sh`, `env-loader.sh`, `needs-decisions-auto.sh` 等の module ファイルを source から port
  - `modules/` ディレクトリを作成し、source の modules 構造を再現
  - target ファイルの module loading ロジックを更新
  - `shellcheck` zero warnings を達成（SC1090/SC1091 source-follow 除外）
  - `qwen-watcher/test/test-watcher.sh` を作成（core utilities の動作確認）
  - _Requirements: 1.5, NFR 1.1, NFR 4.2, NFR 5.2
  - _Boundary: modules/, test/
  - _Depends: 4, 5, 6, 7, 8

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。


```sh
shellcheck qwen-watcher/bin/idd-qwen-issue-watcher.sh
```

## Split Proposal

> **budget overflow による split proposal 起票** — `tasks.md` 件数 10 件が閾値 10 件に到達（≤10 のため pass）

### 判定根拠

- tasks.md タスク件数: 10 件（最上位 numeric ID タスクのみカウント）
- 適用閾値: ≤10 件（pass）
- consolidate 試行結果: 不要（pass のため）

### 分割候補

- サブ Issue 1: Phase 1 — Core + Checkpoint + Slot + Tasks + Spec (Tasks 1-3)
  - 含むタスク: 1, 2, 3
  - 対応 requirement: 1.3, 2.1-2.5, 3.1-3.5, 8.1-8.3, NFR 2, NFR 4.2
  - 説明: 基盤系サブシステム。他タスクの依存起点。独立して実装・テスト可能
- サブ Issue 2: Phase 2 — Dispatcher + Pipeline (Tasks 4-5)
  - 含むタスク: 4, 5
  - 対応 requirement: 5.1-5.5, 14.1-14.5
  - 説明: メインディスパッチャーと実装パイプライン。Phase 1 完了後に実装可能
- サブ Issue 3: Phase 3 — Per-Task Loop + Reviewer/Debugger (Tasks 6)
  - 含むタスク: 6
  - 対応 requirement: 4.1-4.6, 6.1-6.5
  - 説明: per-task TDD loop と品質ゲート。Phase 2 完了後に実装可能
- サブ Issue 4: Phase 4 — Recovery + Dependency + Verify (Tasks 7-9)
  - 含むタスク: 7, 8, 9
  - 対応 requirement: 7.1-7.4, 9.1-9.5, 10.1-10.5, 1.2, 1.3
  - 説明: 回復メカニズムと依存解決。Phase 2-3 完了後に実装可能
- サブ Issue 5: Phase 5 — Module Porting + Shellcheck + Test (Task 10)
  - 含むタスク: 10
  - 対応 requirement: 1.5, NFR 1.1, NFR 4.2, NFR 5.2
  - 説明: 最終検証。全 Phase 完了後に実装可能

### 人間判断を要する論点

- 分割後の Issue 起票順序と並列実装の可否（Phase 1 は他 Phase に依存するため逐次、Phase 2-4 は並列可か）
- `CODEX_SANBOX=danger-full-access` のデフォルト値を idd-qwen でそのまま採用してよいか（セキュリティレビューが必要）
- module ファイル（core_utils.sh, env-loader.sh 等）を同一ディレクトリに port するか、別 repo にするか