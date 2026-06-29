# Design Document

## Overview

この機能は、watcher セッションがクラッシュ / OOM / マシン再起動などで異常終了したとき、`codex-picked-up` / `codex-claimed` ラベルが Issue に残り続け、dispatcher が「処理中」とみなして候補から永久除外する停止状態を、3 観点（marker 経過時間 / slot ロック保持 / セッション存在）の AND 判定で「非アクティブ」と確定した Issue についてのみ `codex-auto-dev` 状態へ自動復帰させる Stale Pickup Reaper モジュールを実装する。

**Purpose**: crashed watcher による stale pickup（ラベルのみ残留した Issue）を自動検知・自動復帰させる。
**Users**: watcher 運用者が、異常終了後の手動復旧作業を省略できる。
**Impact**: 既存の failed-recovery モジュールが `codex-failed` のみを扱うのに対し、`codex-picked-up` / `codex-claimed` の stale 状態もカバーする。

### Goals
- 3 観点 AND 判定で stale pickup を正確に検出
- marker JSON の atomic write による crash-safe 永続化
- single opt-in gate（`STALE_PICKUP_REAPER_ENABLED`）で独立制御
- failed-recovery との機能 gap を埋める

### Non-Goals
- `codex-failed` Issue の復帰（failed-recovery モジュールの領分）
- git branch / working tree の操作（本機能はラベルのみ変更）
- 手動介入 UI（`gh issue edit` 経由のラベル操作のみ）

## Architecture

### Existing Architecture Analysis

- 既存の `failed-recovery.sh` モジュールが `codex-failed` Issue の復帰を処理
- 既存の `core_utils.sh` モジュールが共通ユーティリティ（ロギング / ラベル操作）を提供
- 既存の `env-loader.sh` が Config 変数の初期値を定義
- main watcher スクリプトが REQUIRED_MODULES でモジュール列挙し、dispatcher で逐次呼び出し

### Architecture Pattern & Boundary Map

既存モジュールパターン（単独関数群 + gate layer + orchestrator layer）を踏襲する。

**Architecture Integration**:
- 採用パターン: 既存モジュールパターン準拠（関数 prefix `sr_` / gate layer / persistence layer / candidate selection / active decision / recovery action / orchestrator）
- ドメイン／機能境界: `failed-recovery.sh`（`codex-failed` 復帰）と `stale-pickup-reaper.sh`（`codex-picked-up` / `codex-claimed` 復帰）で分離
- 既存パターンの維持: atomic write（mktemp → mv -f）/ fail-continue / single opt-in gate
- 新規コンポーネントの根拠: crashed watcher 状態の検出には marker 経過時間 / slot lock / session 生存の 3 観点判定が必要

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Frontend / CLI | gh CLI | Issue ラベル操作 / Issue 列挙 | GitHub API 経由 |
| Backend / Services | bash module | 判定ロジック / 状態管理 | 単独 bash スクリプト |
| Data / Storage | JSON marker files | 各 Issue 単位の pickup 状態記録 | `$STALE_PICKUP_REAPER_STATE_DIR/` |
| Messaging / Events | gh issue edit | ラベル変更イベント | PATCH 相当 |
| Infrastructure / Runtime | bash / jq / flock | 実行環境 | macOS / Linux 両対応 |

## File Structure Plan

### Directory Structure

```
qwen-watcher/bin/
├── idd-qwen-issue-watcher.sh   # main script (dispatcher 側で更新済み)
└── idd-qwen-modules/
    ├── stale-pickup-reaper.sh  # 新規: Stale Pickup Reaper モジュール
    ├── core_utils.sh           # 既存: 共通ユーティリティ
    └── env-loader.sh            # 既存: Config 変数初期値
```

### Modified Files

- `qwen-watcher/bin/idd-qwen-issue-watcher.sh` — REQUIRED_MODULES に `"stale-pickup-reaper"` を追加、dispatcher に `process_stale_pickup_reaper` 呼び出しを追加

## Requirements Traceability

| Requirement | Summary | Components | Interfaces | Flows |
|-------------|---------|------------|------------|-------|
| 1.1 | 単独 opt-in gate | sr_is_enabled | env var | gate layer |
| 1.2 | false 以外で無効 | sr_is_enabled | env var | gate layer |
| 1.3 | 無効時は API 呼ばない | process_stale_pickup_reaper | gate check | orchestrator |
| 2.1 | marker JSON 保存場所 | sr_marker_path | file path | persistence |
| 2.2 | marker schema | sr_save_marker | JSON schema | persistence |
| 2.3 | atomic write | sr_save_marker | mktemp → mv | persistence |
| 2.4 | 欠落 / 破損時の fail-open | sr_load_marker | jq parse | persistence |
| 3.1 | codex-picked-up 列挙 | sr_fetch_candidates | gh issue list | candidate |
| 3.2 | codex-claimed 列挙 | sr_fetch_candidates | gh issue list | candidate |
| 3.3 | 除外ラベルフィルタ | sr_fetch_candidates | gh search | candidate |
| 3.4 | dedup / truncate | sr_fetch_candidates | jq unique_by | candidate |
| 3.5 | API 失敗時の空配列 | sr_fetch_candidates | fallback [] | candidate |
| 4.1 | marker 経過時間判定 | sr_check_marker_age | date diff | active |
| 4.2 | slot lock 判定 | sr_check_slot_lock | flock -n | active |
| 4.3 | session 生存判定 | sr_check_session | kill -0 | active |
| 4.4 | 3 観点 AND 結合 | sr_is_active | AND logic | active |
| 4.5 | 不確実時は keep | sr_is_active | safe-side | active |
| 4.6 | 判定根拠ログ | sr_is_active | sr_log | active |
| 5.1 | ラベル除去 | sr_revert_to_auto_dev | gh issue edit | recovery |
| 5.2 | codex-auto-dev 付与 | sr_revert_to_auto_dev | gh issue edit | recovery |
| 5.3 | git 操作なし | sr_revert_to_auto_dev | no git | recovery |
| 5.4 | 同サイクル冪等 | SR_PROCESSED_THIS_CYCLE | in-memory set | recovery |
| 5.5 | 復旧ログ | sr_revert_to_auto_dev | sr_log | recovery |
| 6.1 | REQUIRED_MODULES 登録 | main script | module list | orchestrator |
| 6.2 | dispatcher 呼び出し | main script | function call | orchestrator |
| 6.3 | fail-continue | process_stale_pickup_reaper | return 0 | orchestrator |
| 6.4 | 常に 0 返却 | process_stale_pickup_reaper | return 0 | orchestrator |

## Components and Interfaces

### Stale Pickup Reaper

#### Gate Layer

| Field | Detail |
|-------|--------|
| Intent | 単独 opt-in gate で機能の有効無効を判定 |
| Requirements | 1.1, 1.2, 1.3 |

**Responsibilities & Constraints**
- `STALE_PICKUP_REAPER_ENABLED=true` のみ有効
- `FULL_AUTO_ENABLED` は要求しない（failed-recovery との違い）
- 無効時は `gh` API を一切呼ばない

**Dependencies**
- External: `$STALE_PICKUP_REAPER_ENABLED` env var (Criticality: high)

##### Service Interface

```bash
# 0=enabled / 1=disabled
sr_is_enabled()
```

#### Persistence Layer

| Field | Detail |
|-------|--------|
| Intent | 各 Issue 単位の marker JSON を crash-safe に永続化 |
| Requirements | 2.1, 2.2, 2.3, 2.4 |

**Responsibilities & Constraints**
- `$STALE_PICKUP_REAPER_STATE_DIR/<issue>.json` に保存
- schema: `{issue, first_seen_at, last_seen_at, last_known_labels[], status, revert_at}`
- atomic write（mktemp → mv -f）
- 欠落 / parse 失敗時は `{}`（fail-open）

**Dependencies**
- External: `$STALE_PICKUP_REAPER_STATE_DIR` env var (Criticality: high)
- External: `jq` CLI (Criticality: medium)
- External: `mktemp` CLI (Criticality: low)

##### Service Interface

```bash
# 0: marker path 返却
sr_marker_path(issue_number)

# 0: JSON 文字列 stdout / 失敗時は {}
sr_load_marker(issue_number)

# 0: persisted / 1: failure
sr_save_marker(issue_number, first_seen_at, last_seen_at, labels_json, status, revert_at)
```

#### Candidate Selection Layer

| Field | Detail |
|-------|--------|
| Intent | `codex-picked-up` / `codex-claimed` Issue を列挙 |
| Requirements | 3.1, 3.2, 3.3, 3.4, 3.5 |

**Responsibilities & Constraints**
- 除外ラベル: `codex-failed`, `codex-needs-decisions`, `codex-awaiting-design`, `codex-needs-quota-wait`, `codex-blocked`, `codex-staged-for-release`, `codex-awaiting-slot`
- dedup by issue number, truncate to `$STALE_PICKUP_REAPER_MAX_ISSUES`
- API 失敗時は空配列 + warning log

**Dependencies**
- External: `gh` CLI (Criticality: high)
- External: `$REPO` env var (Criticality: high)
- External: `$LABEL_PICKED_UP`, `$LABEL_CLAIMED` env vars (Criticality: high)
- External: `$STALE_PICKUP_REAPER_GH_TIMEOUT` env var (Criticality: medium)
- External: `$STALE_PICKUP_REAPER_MAX_ISSUES` env var (Criticality: low)

##### Service Interface

```bash
# 0: JSON 配列文字列 stdout
sr_fetch_candidates()
```

#### Active Decision Layer

| Field | Detail |
|-------|--------|
| Intent | 3 観点 AND 判定で Issue の active/inactive を判定 |
| Requirements | 4.1, 4.2, 4.3, 4.4, 4.5, 4.6 |

**Responsibilities & Constraints**
- 観点 1: marker 経過時間（`first_seen_at` vs threshold）
- 観点 2: slot lock 保持状態（flock -n）
- 観点 3: session 生存判定（kill -0）
- 3 観点 AND で inactive 確定
- 不確実時は keep（safe-side）

**Dependencies**
- External: `$SLOT_LOCK_DIR` env var (Criticality: high)
- External: `$REPO_SLUG` env var (Criticality: medium)
- External: `flock` CLI (Criticality: medium)
- External: `fuser` / `lsof` CLI (Criticality: medium)
- External: `date` CLI (Criticality: high)

##### Service Interface

```bash
# 0=aged / 1=fresh
sr_check_marker_age(marker_json)

# 0=no lock / 1=held / 2=undetermined
sr_check_slot_lock(marker_json)

# 0=no session / 1=session may be alive
sr_check_session(marker_json)

# 0=active / 1=inactive
sr_is_active(marker_json)
```

#### Recovery Action Layer

| Field | Detail |
|-------|--------|
| Intent | inactive 確定 Issue からラベル除去 + codex-auto-dev 付与 |
| Requirements | 5.1, 5.2, 5.3, 5.4, 5.5 |

**Responsibilities & Constraints**
- `codex-picked-up` / `codex-claimed` を 1 リクエストで除去
- `codex-auto-dev` を欠落時のみ付与
- git 操作は行わない
- 同サイクル内冪等（`SR_PROCESSED_THIS_CYCLE` in-memory set）
- issue 番号の入力検証（数値以外を reject）

**Dependencies**
- External: `gh` CLI (Criticality: high)
- External: `$REPO` env var (Criticality: high)
- External: `$LABEL_PICKED_UP`, `$LABEL_CLAIMED`, `$LABEL_TRIGGER` env vars (Criticality: high)

##### Service Interface

```bash
# 0=reverted / 1=failed
sr_revert_to_auto_dev(issue_number, marker_json)
```

#### Orchestrator Layer

| Field | Detail |
|-------|--------|
| Intent | 1 watcher cycle の単一エントリ |
| Requirements | 6.1, 6.2, 6.3, 6.4 |

**Responsibilities & Constraints**
- gate → candidate → marker update → active 判定 → revert を直列実行
- 全例外を fail-continue で吸収（戻り値常に 0）
- REQUIRED_MODULES に登録
- dispatcher から呼び出し

**Dependencies**
- Inbound: main script (Criticality: high)
- External: `process_stale_pickup_reaper` function (Criticality: high)

##### Service Interface

```bash
# 常に 0 を返す
process_stale_pickup_reaper()
```

## Data Models

### Marker JSON Schema

```json
{
  "issue": 13,
  "first_seen_at": "2026-06-29T10:00:00Z",
  "last_seen_at": "2026-06-29T12:00:00Z",
  "last_known_labels": ["codex-picked-up", "codex-auto-dev"],
  "status": "observing",
  "revert_at": ""
}
```

- `issue`: Issue 番号（number）
- `first_seen_at`: pickup 初観測時刻（ISO 8601）
- `last_seen_at`: 最終観測時刻（ISO 8601）
- `last_known_labels`: 最終観測時のラベル配列
- `status`: `observing`（判定中）または `reverted`（復帰済み）
- `revert_at`: 復帰時刻（reverted 時のみ）

## Error Handling

### Error Strategy

- **fail-continue**: 全エラーを吸収し、後続 Issue 処理を継続
- **fail-open**: marker 欠落 / parse 失敗時は `{}` で処理を継続
- **safe-side**: 判定不確実時は revert せず keep

### Error Categories and Responses

- **API Errors**: `gh` CLI 失敗時は warning log + 空配列 / skip
- **Parse Errors**: JSON parse 失敗時は `{}` fallback
- **File Errors**: mktemp / mv 失敗時は warning log + skip
- **Validation Errors**: 不正な issue 番号は reject + warning log

## Testing Strategy

- **Unit Tests**: 各関数の純粋関数テスト（sr_is_enabled / sr_marker_path / sr_load_marker / sr_check_marker_age）
- **Integration Tests**: marker JSON の atomic write 動作、3 観点 AND 判定の結合
- **E2E Tests**: 全 cycle 実行（gate → candidate → marker → active → revert）
- **Failure Path Tests**: API 失敗 / JSON parse 失敗 / file write 失敗時の graceful degradation

## Optional Sections

### Security Considerations

- issue 番号の入力検証（数値以外を reject）でコマンド注入を防止
- `gh` CLI 経由の API 呼び出しは GitHub token に依存（既存 watcher と同一権限）
- marker JSON は `$STALE_PICKUP_REAPER_STATE_DIR/` に保存（既存 LOG_DIR 配下）

### Performance & Scalability

- 候補列挙は `$STALE_PICKUP_REAPER_MAX_ISSUES`（既定 5）で制限
- 3 観点判定は read-only（gh API を呼ばない）
- 同サイクル内冪等 set で重複処理を防止

### Migration Strategy

既存の failed-recovery モジュールと並行して動作。既存 Issue に影響なし（marker 未作成 Issue は初観測として記録）。

## Supporting References

- 移植元: idd-codex `local-watcher/bin/idd-codex-modules/stale-pickup-reaper.sh`
- 関連 Issue: failed-recovery (#101)