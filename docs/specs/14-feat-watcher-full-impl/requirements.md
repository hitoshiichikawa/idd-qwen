# Requirements Document

## Introduction

Issue #14 の目標は、`qwen-watcher/bin/idd-qwen-issue-watcher.sh` の stub 実装を
`idd-codex` のフル実装（11,726 行、161 関数）からポートし、**production-ready な Issue
Watcher** に書き換えることです。

現在、target ファイルには 14 個の stub 関数（config / env loading / basic label ops /
stub dispatcher）のみが実装されています。残り 130 以上の関数（~10,000+ 行）を
ポートする必要があります。

本要件は porting の **スコープと受入基準** を定義します。実装詳細（ファイル構成、関数名、
ロジック）は Architect が design.md で決定します。

## Requirements

### Requirement 1: Porting scope and completeness

**Objective:** As a maintainer, I want the idd-qwen watcher to have feature parity
with idd-codex's watcher, so that idd-qwen can be used as a drop-in replacement for
local development and CI automation.

#### Acceptance Criteria

1. When the target file is checked, every logical subsystem present in the source file
   (stage checkpoint, tasks count, per-task loop, implementation pipeline, reviewer,
   debugger, dependency resolver, slot management, etc.) must have a corresponding
   ported implementation in the target
2. If the source file has a `*_ENABLED` feature flag (e.g. `PER_TASK_LOOP_ENABLED`), the
   target file must have the same flag with the same default value and the same guard
   pattern (`if [ "$*_ENABLED" = "true" ]`)
3. While the target file is running, all log levels (log / warn / error) from source must
   have corresponding log functions in the target (same prefix pattern, same stderr/stdout
   semantics)
4. Where the source file has a stage checkpoint mechanism, the target file must have the
   same checkpoint mechanism with the same `stage-checkpoint:` prefix for grep extraction
5. The target file must pass `shellcheck` with zero warnings (SC1090/SC1091 source-follow
   excluded)

### Requirement 2: Stage checkpoint system

**Objective:** As a watcher, I must persist stage completion state so that on restart I
can resume from the last completed stage instead of re-running everything from scratch.

#### Acceptance Criteria

1. When Stage A (Developer) completes, the target file must create a stage checkpoint
   marker (`stage-checkpoint: stage-a-done`) in the log and record `impl-notes.md`
   existence on the branch HEAD
2. If Stage B (Reviewer) fails and the watcher restarts, the target file must detect the
   Stage A checkpoint and skip Stage A re-execution
3. If Stage C (PjM) fails and the watcher restarts, the target file must detect both
   Stage A and Stage B checkpoints and skip both
4. While resuming, the target file must log the resumed stage with `stage-checkpoint:`
   prefix for observability
5. If `STAGE_CHECKPOINT_ENABLED=false` is explicitly set, the target file must always
   start from Stage A (backward compatibility)

### Requirement 3: Tasks count gate

**Objective:** As a maintainer, I want the watcher to validate task counts in
`tasks.md` after Architect completes, so that oversized task lists are caught early.

#### Acceptance Criteria

1. When Architect completes and `tasks.md` exists, the target file must count the number
   of top-level unchecked tasks (regex: `^- \[ \]\*? [0-9]+\.[[:space:]]`)
2. If the count is ≤ 10, the target file must proceed normally (pass)
3. If the count is 11–13, the target file must attempt task consolidation and log the
   result
4. If the count is ≥ 14, the target file must add the `codex-needs-decisions` label and
   escalate to human
5. If `TC_ENABLED=false` is explicitly set, the target file must skip this check

### Requirement 4: Per-task TDD loop

**Objective:** As a developer, I want the watcher to execute implementation one task at
a time with fresh Codex sessions, so that turn budget limits don't cause cascading failures.

#### Acceptance Criteria

1. When the implementation stage starts and `PER_TASK_LOOP_ENABLED=true`, the target file
   must iterate over each task in `tasks.md` sequentially
2. For each task, the target file must launch a fresh Codex session with only that task's
   scope (via prompt injection of `_Requirements:` and `_Boundary:`)
3. If a task fails due to `error_max_turns` (turn budget exceeded), the target file must
   mark the task as failed and continue to the next task (not abort the whole issue)
4. While each task completes, the target file must update the task's checkbox from `- [ ]`
   to `- [x]` and commit with `docs(tasks): mark <id> as done`
5. After all tasks complete, the target file must proceed to the Reviewer stage
6. If `PER_TASK_LOOP_ENABLED=false` (default), the target file must fall back to the
   original single-session behavior (all tasks in one Codex run)

### Requirement 5: Implementation pipeline

**Objective:** As a watcher, I must orchestrate the full implementation pipeline
(Triage → Architect/Developer → PjM → Reviewer → Debugger) with proper error handling
and state transitions.

#### Acceptance Criteria

1. When the dispatcher picks up an issue with `codex-auto-dev` label, the target file must
   claim the issue (add `codex-claimed`, remove `codex-auto-dev`)
2. If the issue has `codex-needs-decisions` label, the target file must skip Triage and
   proceed directly to Architect/Developer with a needs-decisions prompt
3. While the implementation pipeline runs, the target file must log each stage transition
   with `stage:` prefix for observability
4. If any stage fails, the target file must mark the issue as `codex-failed` and log the
   failure reason
5. If the issue has a `partial_blocked` or `partial_overrun` status, the target file must
   add `codex-needs-decisions` label and escalate to human (not mark as failed)

### Requirement 6: Reviewer and Debugger stages

**Objective:** As a maintainer, I want independent quality gates (Reviewer + optional
Debugger) after implementation, so that AC coverage and boundary compliance are verified.

#### Acceptance Criteria

1. When Developer completes, the target file must launch the Reviewer stage with the
   latest commit diff and `requirements.md` / `tasks.md` / `impl-notes.md`
2. If the Reviewer approves, the target file must proceed to PjM (create PR)
3. If the Reviewer rejects, the target file must re-run the Developer stage with the
   rejection findings and re-submit to Reviewer (max 2 rounds)
4. If the Reviewer rejects a second time (Round 2), the target file must launch the
   Debugger stage if `CODEX_DEBUGGER_ENABLED=true`
5. If the Debugger provides guidance, the target file must re-run the Developer stage
   with the guidance and re-submit to Reviewer

### Requirement 7: Design review release processor

**Objective:** As a watcher, I must detect when a design PR is merged and automatically
release the `codex-awaiting-design-review` label so that the Developer stage can start.

#### Acceptance Criteria

1. When the watcher starts, the target file must check for issues with
   `codex-awaiting-design-review` label and a design PR
2. If the design PR is merged, the target file must remove the
   `codex-awaiting-design-review` label and add `codex-picked-up`
3. If the design PR is not merged, the target file must skip the issue
4. If `DRR_GH_TIMEOUT` is set, the target file must respect the timeout for GitHub API
   calls

### Requirement 8: Spec artifacts completeness guard

**Objective:** As a maintainer, I want the watcher to verify that all spec artifacts
(requirements.md, design.md, tasks.md) exist and are well-formed before proceeding.

#### Acceptance Criteria

1. When the Architect stage completes, the target file must verify that all three spec
   artifacts exist in `docs/specs/<N>-<slug>/`
2. If any artifact is missing, the target file must mark the issue as `codex-failed` and
   log which artifact is missing
3. If all artifacts exist, the target file must proceed to the implementation stage

### Requirement 9: Failed recovery and resume

**Objective:** As a watcher, I must recover from partial failures by resuming from the
last safe checkpoint, so that work is not lost on restart.

#### Acceptance Criteria

1. When the watcher starts, the target file must check for existing branches for the
   issue and detect if a previous run was interrupted
2. If a previous run exists and Stage A artifacts (impl-notes.md) are present, the target
   file must resume from the last completed stage
3. If the branch is non-fast-forward with HEAD, the target file must mark the issue as
   failed (to avoid merge conflicts)
4. If the branch checkout fails due to worktree busy, the target file must release the
   worktree slot and retry
5. If the issue has `codex-needs-decisions` label, the target file must not auto-continue
   (wait for human decision)

### Requirement 10: Dependency resolver

**Objective:** As a maintainer, I want the watcher to resolve cross-issue dependencies
before starting implementation, so that issues depending on other issues are blocked
until dependencies are met.

#### Acceptance Criteria

1. When the dispatcher picks up an issue, the target file must check for
   `Depends on: #N` references in the issue body
2. If a dependency issue has `codex-failed` or `codex-needs-decisions` label, the target
   file must block the issue and add a comment explaining the dependency
3. If all dependencies are met (merged or completed), the target file must proceed normally
4. If a cycle is detected (A depends on B, B depends on A), the target file must escalate
   to human with `codex-needs-decisions` label
5. If `DR_AUTO_UNBLOCK_ENABLED=true`, the target file must auto-unblock issues whose
   dependencies have been merged

### Requirement 11: Codex CLI integration

**Objective:** As a watcher, I must integrate with Codex CLI using proper configuration
for reasoning effort, timeouts, web search, and agent roles.

#### Acceptance Criteria

1. When launching Codex CLI, the target file must set `CODEX_SANDBOX=danger-full-access`
   and `CODEX_APPROVAL_POLICY=never` (as configured in source)
2. For each stage (Triage, Architect, Developer, Reviewer), the target file must set the
   appropriate reasoning effort level (low for Triage, medium for Architect, high for
   Developer)
3. If `CODEX_DEBUGGER_WEB_SEARCH=true`, the target file must enable web search for the
   Debugger stage
4. When injecting agent role definitions, the target file must read role definitions from
   `.qwen/agents/*.md` files
5. The target file must respect `CODEX_DEFAULT_TIMEOUT_SEC` (default 1800s) for each
   Codex invocation

### Requirement 12: Slot management and parallel execution

**Objective:** As a watcher, I must manage worktree slots for parallel issue processing,
so that multiple issues can be processed concurrently without conflicts.

#### Acceptance Criteria

1. When the dispatcher picks up an issue, the target file must acquire a worktree slot
   (using file locking via `flock`)
2. If no slot is available, the target file must skip the issue and try again on the next
   poll cycle
3. When the issue processing completes (success or failure), the target file must release
   the worktree slot
4. If a slot is held for too long (SLOT_TIMEOUT), the target file must force-release it
5. The target file must support `SLOT_MAX` configuration (default: number of CPUs)

### Requirement 13: Label operations and state transitions

**Objective:** As a watcher, I must manage GitHub issue labels as state machine transitions,
so that the issue lifecycle is observable and auditable.

#### Acceptance Criteria

1. When the dispatcher claims an issue, the target file must add `codex-claimed` and
   remove `codex-auto-dev`
2. When Triage determines the issue needs Architect, the target file must add
   `codex-awaiting-design-review`
3. When Developer completes, the target file must add `codex-ready-for-review`
4. When Reviewer approves, the target file must add `codex-picked-up` (for PjM to create PR)
5. When any stage fails, the target file must add `codex-failed`
6. If the issue needs human decision, the target file must add `codex-needs-decisions`
7. The target file must support all label definitions from the source file (17 labels)

### Requirement 14: Dispatcher with full-auto and stale pickup reaper

**Objective:** As a watcher, I must implement the main dispatcher loop that polls for
issues, claims them, and dispatches to the appropriate stage — with safeguards for
full-auto mode and stale pickup detection.

#### Acceptance Criteria

1. When the watcher starts, the target file must enter the main dispatcher loop with
   configurable poll interval (DISPATCH_INTERVAL)
2. If `FULL_AUTO_ENABLED=true`, the target file must auto-continue issues with
   `codex-needs-decisions` label using recommended defaults
3. If `STALE_PICKUP_REAPER_ENABLED=true`, the target file must periodically check for
   issues with `codex-claimed` label that have no recent activity and release them
4. The target file must log each dispatch action with `dispatcher:` prefix for
   observability
5. If the dispatcher encounters an error (GitHub API rate limit, network issue), the
   target file must retry with exponential backoff and log the error

## Non-Functional Requirements

### NFR 1: Shell quality

1. The target file must pass `shellcheck` with zero warnings (SC1090/SC1091 source-follow
   excluded, as modules are in a different directory)
2. The target file must use `set -euo pipefail` at the top
3. All functions must have doc comments describing input, return value, and side effects

### NFR 2: Observability

1. All log output must use the `[YYYY-MM-DD HH:MM:SS] prefix:` format
2. Stage transitions must use `stage:` prefix
3. Stage checkpoints must use `stage-checkpoint:` prefix
4. Dispatcher actions must use `dispatcher:` prefix
5. All warn/error logs must go to stderr

### NFR 3: Backward compatibility

1. If `STAGE_CHECKPOINT_ENABLED=false` is set, the target file must behave identically to
   the pre-checkpoint version (always start from Stage A)
2. If `PER_TASK_LOOP_ENABLED=false` is set, the target file must fall back to single-session
   behavior (pre-per-task-loop version)
3. All feature flags from the source file must be supported in the target file

### NFR 4: Environment variable configuration

1. All configurable values must be read from environment variables with sensible defaults
2. The target file must support per-repo env file loading (via `env-loader.sh` module)
3. The target file must document all environment variables in a Config block at the top

### NFR 5: Testability

1. Utility functions (logging, counting, detection) must be pure or side-effect-free,
   so they can be tested independently
2. The target file must include a test script at `qwen-watcher/test/test-watcher.sh`
   that validates core utilities

## Out of Scope

- GitHub Actions integration (separate issue)
- Remote execution (this watcher is local-only)
- Multi-repository concurrent processing (single REPO per invocation)
- Web UI or dashboard for monitoring

## Open Questions

- Should the target file use the same function naming convention as the source (e.g. `sc_*`,
  `tc_*`, `pt_*`) or adapt to idd-qwen naming? (Recommendation: keep source naming for
  traceability during porting, rename after port is complete)
- Should `CODEX_SANBOX` default to `danger-full-access` for idd-qwen, or should it be
  configurable per-repo? (Recommendation: configurable, default to `danger-full-access`
  for parity with idd-codex)
- Should the target file include the `env-loader.sh` module port, or is that handled
  separately? (Recommendation: include in this issue, as it's part of the Config block)