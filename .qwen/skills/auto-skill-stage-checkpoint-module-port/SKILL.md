# Stage Checkpoint Module Port

Stage Checkpoint モジュール（Phase B）を idd-codex 参照実装から idd-qwen に port する手順。

## 背景

idd-codex の `local-watcher/bin/idd-codex-issue-watcher.sh` に Stage Checkpoint モジュールが実装されている。これを idd-qwen の `qwen-watcher/bin/idd-qwen-modules/core_utils.sh` に追加する。

## 追加位置

`core_utils.sh` 内の Phase C（Slot Lock Manager）セクションの **直前** に Phase B セクションを挿入する。

```bash
# 挿入位置: Phase C の手前
# ═══════════════════════════════════════════════════════════════════════════════
# Phase B: Stage Checkpoint
# ═══════════════════════════════════════════════════════════════════════════════
...
# ═══════════════════════════════════════════════════════════════════════════════
# Phase C: Slot Lock Manager
# ═══════════════════════════════════════════════════════════════════════════════
```

## 追加する関数

### 1. Feature Flag 宣言（ファイル先頭、`_is_core_utils_loaded` の直後）

```bash
# shellcheck disable=SC2034
STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-true}"
```

- 値が `true` のみ有効。未設定時は既定 `true`。
- `True` / `TRUE` / `1` / `yes` 等は **無効** として扱う。

### 2. Stage Checkpoint 専用ロガー

```bash
sc_log() {
  echo "[$(date '+%F %T')] stage-checkpoint: $*"
}
sc_warn() {
  echo "[$(date '+%F %T')] stage-checkpoint: WARN: $*" >&2
}
sc_error() {
  echo "[$(date '+%F %T')] stage-checkpoint: ERROR: $*" >&2
}
```

- 既存の `mq_log` / `pi_log` / `rv_log` と同形式。
- `stage-checkpoint:` prefix で grep 抽出可能（NFR 2.2）。
- warn / error は stderr へ。

### 3. stage_checkpoint_has_impl_notes()

```bash
stage_checkpoint_has_impl_notes() {
  local rel="$SPEC_DIR_REL/impl-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 1
  local out
  out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$out" ]
}
```

- Stage A 完了 checkpoint（impl-notes.md）の **当該 Issue branch HEAD 上での tracked** を判定。
- `git ls-tree --name-only HEAD -- <path>` で committed 状態を確認（working tree のみの untracked ファイルは不採用）。
- 入力: 環境変数 `REPO_DIR` / `SPEC_DIR_REL`
- 戻り値: 0 = checkpoint 採用 / 1 = 不採用

### 4. stage_checkpoint_has_review_notes()

```bash
stage_checkpoint_has_review_notes() {
  local rel="$SPEC_DIR_REL/review-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 1
  local out
  out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$out" ]
}
```

- Stage B 完了 checkpoint（review-notes.md）の **当該 Issue branch HEAD 上での tracked** を判定。
- 実装は `stage_checkpoint_has_impl_notes()` と同一パターン（ファイル存在チェック + `git ls-tree`）。
- 入力: 環境変数 `REPO_DIR` / `SPEC_DIR_REL`
- 戻り値: 0 = checkpoint 採用 / 1 = 不採用

### 5. sc_issue_state()

```bash
sc_issue_state() {
  local state
  state=$(gh issue view "$NUMBER" --repo "$REPO" --json state --jq '.state' 2>/dev/null || true)
  case "$state" in
    OPEN|CLOSED) echo "$state"; return 0 ;;
    *)           return 1 ;;
  esac
}
```

- Issue state を 1 トークン（`OPEN` / `CLOSED`）で stdout に返す read-only ヘルパ。
- `stage_checkpoint_find_impl_pr` が MERGED PR を terminal として採用する前に、Issue が reopen されていないかを確認するために使う。
- 入力: 環境変数 `NUMBER` / `REPO`
- 戻り値: 0 = 取得成功 / 1 = API 失敗

### 6. sc_tasks_unchecked_count()

```bash
sc_tasks_unchecked_count() {
  local rel="$SPEC_DIR_REL/tasks.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || { echo 0; return 2; }
  [ -r "$path" ] || { echo 0; return 1; }
  local count
  count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$path" 2>/dev/null) || count=0
  echo "$count"
  return 0
}
```

- `tasks.md` の **最上位 numeric ID 未チェックタスク** 件数を整数で stdout に返す read-only ヘルパ。
- 判定 regex 正本: `.qwen/rules/tasks-generation.md` の「Checkbox 形式の必須化」節および `.qwen/rules/design-review-gate.md` の Budget overflow count 抽出 regex (`^- \[ \]\*? [0-9]+\. `) と **完全一致**。
- 戻り値: 0 = 取得成功 / 1 = I/O 失敗 / 2 = ファイル不在

## 重要なパターン

### `git ls-tree --name-only HEAD -- <path>` の使用

checkpoint 関数では、単に `[ -f "$path" ]` するだけでなく、`git ls-tree` で **committed 状態** を確認する。これは working tree のみに存在し未 commit のファイル（部分実装中の artifact）を checkpoint として採用しないため。

```bash
git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel"
```

- 戻り値 0 + 出力あり → committed（checkpoint 採用）
- 戻り値 1 または空 → untracked / not committed（checkpoint 不採用）

### 環境変数の依存

各関数は `REPO_DIR`, `SPEC_DIR_REL`, `NUMBER`, `REPO` といった環境変数に依存する。これらは呼び出し元（`_slot_run_issue` 等）が事前に設定済みである前提。関数内で export したり validate したりしない。

### shellcheck 警告

`$NUMBER` / `$REPO` 等の環境変数は動的に設定されるため、shellcheck SC2153（possible misspelling）が info レベルで出る。これは意図的な動作であり、修正の必要はない（`_slot_run_issue` が設定済み）。

## 検証

```bash
shellcheck qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

errors / warnings は出ないこと（SC2153 info は許容）。