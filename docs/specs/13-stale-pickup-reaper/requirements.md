# Requirements Document

## Introduction

watcher セッションがクラッシュ / OOM / マシン再起動などで異常終了したとき、`codex-picked-up` / `codex-claimed` ラベルが Issue に残り続け、dispatcher が「処理中」とみなして候補から永久除外する停止状態を、3 観点（marker 経過時間 / slot ロック保持 / セッション存在）の AND 判定で「非アクティブ」と確定した Issue についてのみ `codex-auto-dev` 状態へ自動復帰させる Stale Pickup Reaper モジュールを実装する。

## Requirements

### Requirement 1: Stale Pickup Reaper 単独 opt-in gate

**Objective:** As a watcher operator, I want the stale pickup reaper to be independently enabled or disabled, so that I can control its behavior regardless of full-auto settings.

#### Acceptance Criteria

1. The stale pickup reaper shall be enabled only when `STALE_PICKUP_REAPER_ENABLED=true` (exact match)
2. The stale pickup reaper shall be disabled when `STALE_PICKUP_REAPER_ENABLED` is unset, `false`, or any other value
3. The stale pickup reaper shall not call any `gh` API when disabled

### Requirement 2: Marker persistence

**Objective:** As the watcher, I want to persist per-issue marker JSON to track pickup observation state, so that I can determine staleness across watcher restarts.

#### Acceptance Criteria

1. The stale pickup reaper shall store marker JSON at `$STALE_PICKUP_REAPER_STATE_DIR/<issue>.json`
2. The marker schema shall include: `issue`, `first_seen_at`, `last_seen_at`, `last_known_labels[]`, `status` (observing/reverted), `revert_at`
3. The stale pickup reaper shall use atomic write (mktemp → mv -f) for marker persistence
4. Missing or corrupted marker files shall be treated as `{}` (fail-open)

### Requirement 3: Candidate selection

**Objective:** As the stale pickup reaper, I want to enumerate open Issues with `codex-picked-up` or `codex-claimed` labels, so that I can identify stale pickups.

#### Acceptance Criteria

1. The stale pickup reaper shall fetch Issues with `codex-picked-up` label via `gh issue list`
2. The stale pickup reaper shall fetch Issues with `codex-claimed` label via `gh issue list`
3. The stale pickup reaper shall exclude Issues with labels: `codex-failed`, `codex-needs-decisions`, `codex-awaiting-design`, `codex-needs-quota-wait`, `codex-blocked`, `codex-staged-for-release`, `codex-awaiting-slot`
4. The stale pickup reaper shall deduplicate merged results by Issue number
5. The stale pickup reaper shall truncate to `$STALE_PICKUP_REAPER_MAX_ISSUES` (default: 5)
6. If `gh issue list` fails, the stale pickup reaper shall log a warning and return an empty array

### Requirement 4: Active decision — 3-observation AND判定

**Objective:** As the stale pickup reaper, I want to determine whether a picked-up Issue is still active using 3 observations, so that I only revert truly stale pickups.

#### Acceptance Criteria

1. The stale pickup reaper shall check marker age: if `first_seen_at` is older than `$STALE_PICKUP_REAPER_THRESHOLD_MINUTES` (default: 120), mark as aged
2. The stale pickup reaper shall check slot lock: if any slot lock file exists and is held by another process, mark as potentially active
3. The stale pickup reaper shall check session: if the lock file's PID is alive, mark as potentially active
4. The stale pickup reaper shall determine "inactive" only when all 3 observations indicate inactivity (AND logic)
5. If any observation is uncertain, the stale pickup reaper shall keep the Issue (safe-side)
6. The stale pickup reaper shall log the decision reason with observation results

### Requirement 5: Recovery action — revert to auto-dev

**Objective:** As the stale pickup reaper, I want to revert inactive Issues to `codex-auto-dev` state, so that the dispatcher can pick them up again.

#### Acceptance Criteria

1. The stale pickup reaper shall remove `codex-picked-up` and `codex-claimed` labels from the Issue
2. The stale pickup reaper shall add `codex-auto-dev` label if not already present
3. The stale pickup reaper shall not touch any git branches or working trees
4. The stale pickup reaper shall be idempotent: processing the same Issue twice in one cycle shall not re-apply labels
5. The stale pickup reaper shall log the revert action with age, previous labels, and timestamp

### Requirement 6: Orchestrator — single cycle entry point

**Objective:** As the watcher, I want the stale pickup reaper to run as part of each watcher cycle, so that stale pickups are continuously recovered.

#### Acceptance Criteria

1. The stale pickup reaper shall be listed in `REQUIRED_MODULES` of the main watcher script
2. The stale pickup reaper shall be called by the dispatcher after Issue processing
3. The stale pickup reaper shall fail-continue: errors shall not stop subsequent Issue processing
4. The stale pickup reaper shall always return 0 (even on failure)

## Non-Functional Requirements

### NFR 1: Safety

1. The stale pickup reaper shall never revert an Issue that might still be actively processed by a running watcher session
2. The stale pickup reaper shall never modify git branches, working trees, or commit history

### NFR 2: Observability

1. The stale pickup reaper shall log each candidate evaluation with observation results
2. The stale pickup reaper shall log each revert action with age, previous labels, and timestamp
3. The stale pickup reaper shall log warnings for any API failures or unexpected states

### NFR 3: Portability

1. The stale pickup reaper shall support both Linux (GNU date, fuser) and macOS (BSD date, lsof)
2. The stale pickup reaper shall use `command -v` to detect available tools

## Out of Scope

- `codex-failed` Issues (handled by failed-recovery module)
- `codex-needs-decisions` Issues (handled by needs-decisions-auto module)
- Branch cleanup (stale-pickup-reaper does not touch git)
- Manual intervention UI (label changes are done via `gh issue edit`)

## Open Questions

なし