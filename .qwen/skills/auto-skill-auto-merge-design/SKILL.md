# 設計 PR 版 auto-merge モジュールの実装

設計 PR（`head ^codex/issue-.*-design`）を対象に、GitHub ネイティブ auto-merge を有効化するモジュールを作成する。実装 PR 版（`auto-merge.sh`）と異なり、positive な ready ラベルを必須とせず、head pattern + 否定ラベル + mergeable で判定する。

## 設計 PR auto-merge の特徴

- **positive ready ラベル不要**: 設計 PR は `codex-ready-for-review` ラベルを持たないため、head pattern + 否定ラベル + mergeable で判定
- **否定ラベル**: `codex-failed`, `codex-needs-decisions`, `codex-needs-iteration` の 3 種
- **AND 二重 opt-in kill switch**: `FULL_AUTO_ENABLED` AND `AUTO_MERGE_DESIGN_ENABLED` の両方が true のみで動作
- **GitHub native auto-merge**: `gh pr merge --auto --squash --delete-branch`（実 merge は GitHub 任せ）

## 実装手順

### 1. モジュールファイルの作成

`qwen-watcher/bin/idd-qwen-modules/auto-merge-design.sh` を新規作成。

#### 命名規則

- 関数名は `amd_*` prefix を使用（例: `amd_resolve_gate_enabled`, `amd_should_enable_for_pr`, `amd_enable_auto_merge_for_pr`）
- dispatcher 関数は `process_auto_merge_design`

#### 必須変数

```bash
AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"
AUTO_MERGE_DESIGN_MAX_PRS="${AUTO_MERGE_DESIGN_MAX_PRS:-10}"
AUTO_MERGE_DESIGN_GIT_TIMEOUT="${AUTO_MERGE_DESIGN_GIT_TIMEOUT:-60}"
AUTO_MERGE_DESIGN_HEAD_PATTERN="${AUTO_MERGE_DESIGN_HEAD_PATTERN:-^codex/issue-.*-design}"
```

#### 必須関数

| 関数 | 戻り値 | 説明 |
|------|--------|------|
| `amd_resolve_gate_enabled` | 0=ON / 1=OFF | `AUTO_MERGE_DESIGN_ENABLED` が `true` のみ有効（厳密一致） |
| `amd_should_enable_for_pr` | 0=enable / 1=skip / 2=already | 1 設計 PR の auto-merge 有効化対象判定 |
| `amd_enable_auto_merge_for_pr` | 0=success / 1=failure | GitHub native auto-merge 有効化 |
| `process_auto_merge_design` | 0（固定） | dispatcher エントリポイント |

### 2. amd_should_enable_for_pr の判定ロジック

設計 PR 固有の判定（positive ready ラベル不要）:

```bash
# 1. head pattern 一致（設計 PR のみ）
if ! printf '%s' "$head_ref" | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    return 1
fi

# 2. draft 除外
if [ "$is_draft" = "true" ]; then
    return 1
fi

# 3. 否定ラベルチェック
if [ "$has_failed" != "no" ]; then return 1; fi
if [ "$has_nd" != "no" ]; then return 1; fi
if [ "$has_iter" != "no" ]; then return 1; fi

# 4. MERGEABLE 以外（CONFLICTING / UNKNOWN）は触らない
if [ "$mergeable" != "MERGEABLE" ]; then
    return 1
fi

# 5. 既に auto-merge 有効なら冪等 skip
if [ "$auto_merge" != "null" ]; then
    return 2
fi

return 0
```

### 3. process_auto_merge_design の判定ロジック

AND 二重 opt-in kill switch:

```bash
process_auto_merge_design() {
  # AND 二重 opt-in
  if ! full_auto_enabled; then return 0; fi
  if ! amd_resolve_gate_enabled; then
    amd_log "suppressed by AUTO_MERGE_DESIGN_ENABLED gate (no-op)"
    return 0
  fi

  # gh pr list で設計 PR を取得（否定ラベル + draft 除外）
  prs_json=$(timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" gh pr list \
    --repo "$REPO" --state open \
    --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\" -draft:true" \
    --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest \
    --limit 50 2>/dev/null)

  # client-side: draft 除外 + head pattern + fork 除外
  filtered=$(printf '%s' "$prs_json" | jq -c --arg pat "$AUTO_MERGE_DESIGN_HEAD_PATTERN" --arg owner "$repo_owner" \
    '[ .[] | select((.isDraft // false) == false) | select((.headRefName // "") | test($pat)) | select((.headRepositoryOwner.login // "") == $owner) ]')

  # ... should_enable_for_pr で各 PR を判定して auto-merge 有効化
}
```

**重要**: fork 除外は `amd_should_enable_for_pr` 内ではなく、jq filter で行う（`.headRepositoryOwner.login` で repo owner と比較）。

### 4. main スクリプトへの統合

`idd-qwen-issue-watcher.sh` への追加:

```bash
# REQUIRED_MODULES に追加
REQUIRED_MODULES=("core_utils" "env-loader" "..." "auto-merge" "auto-merge-design" "run-summary")

# dispatcher に呼び出しを追加（auto-merge の後）
if declare -f process_auto_merge_design &>/dev/null; then
    process_auto_merge_design || am_warn "process_auto_merge_design が想定外のエラーで終了（後続 Issue 処理は継続）"
fi
```

### 5. ユニットテストの作成

`qwen-watcher/test/test-auto-merge-design.sh` を新規作成。

#### テストパターン

| テストケース | 期待値 | 説明 |
|-------------|--------|------|
| 有効な設計 PR | 0 | 全て MERGEABLE, ラベルなし, draft=false |
| draft PR | 1 | isDraft=true |
| codex-failed ラベル | 1 | 否定ラベル付き |
| codex-needs-decisions ラベル | 1 | 否定ラベル付き |
| codex-needs-iteration ラベル | 1 | 否定ラベル付き |
| 既に auto-merge 有効 | 2 | 冪等 skip |
| impl PR pattern | 1 | head pattern 不一致 |
| CONFLICTING | 1 | mergeable != MERGEABLE |
| 不正 pr_number | 1 | 数値以外 |

#### テストヘルパー

```bash
# jq で PR JSON を生成（テスト用）
VALID_DESIGN_PR=$(jq -n '{
  number: 42,
  headRefName: "codex/issue-42-design-foo",
  headRefOid: "abc123",
  baseRefName: "main",
  mergeable: "MERGEABLE",
  labels: [],
  url: "https://github.com/test/repo/pull/42",
  isDraft: false,
  headRepositoryOwner: { login: "owner" },
  autoMergeRequest: null
}')

# amd_should_enable_for_pr の戻り値テスト
if amd_should_enable_for_pr "$VALID_DESIGN_PR"; then
    # return 0
else
    # return 1 または 2
fi
```

#### 注意: fork 除外のテスト

`amd_should_enable_for_pr` 内で fork 除外は行わない（jq filter で既に除外済み）。テストで fork 除外を検証する場合、jq filter レベルでテストするか、テストから除外する。

### 6. shellcheck

info-level warnings のみ許容（SC1091, SC2015 は既知の警告として許容）。

## よくある落とし穴

- **fork 除外の場所**: `amd_should_enable_for_pr` 内ではなく、jq filter で行う
- **positive ready ラベル不要**: 設計 PR は `codex-ready-for-review` ラベルを持たないため、head pattern + 否定ラベル + mergeable で判定
- **codex-needs-iteration の追加**: 設計 PR 特有の除外ラベルとして追加
- **AND 二重 opt-in**: `FULL_AUTO_ENABLED` AND `AUTO_MERGE_DESIGN_ENABLED` の両方が true のみで動作
- **テストで fork 除外を検証しない**: `amd_should_enable_for_pr` 内では fork 除外を行わないため、テストでも検証しない

## 関連

- [auto-skill-module-integration](./auto-skill-module-integration/SKILL.md) — モジュール移植時の gate 関数 + dispatcher 登録
- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順