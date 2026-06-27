# run-summary.sh モジュールの移植（fresh port + watcher 統合）

移植元（idd-codex）の `run-summary.sh` を移植先（idd-qwen）へ **fresh port** する。
namespace 変換は不要（`idd-codex` → `idd-qwen` のパス置換のみ）。

## 前提

- 移植元モジュール（例: `idd-codex/local-watcher/bin/idd-codex-modules/run-summary.sh`）が full implementation として存在
- 移植先モジュール（例: `idd-qwen/qwen-watcher/bin/idd-qwen-modules/run-summary.sh`）は未存在
- 移植先で namespace 変換は不要（プレフィックス `rs_` は共通）
- 移植先の watcher スクリプト（`idd-qwen-issue-watcher.sh`）に統合する

## 手順

### 1. 移植元モジュールの構造理解

移植元モジュールを `read_file` で読み、以下の要素を特定する:

- **public functions**: `rs_init`, `rs_set_mode`, `rs_set_issue`, `rs_record_stage`, `rs_set_scaffolding`, `rs_record_reviewer`, `rs_record_sav`, `rs_record_error`, `rs_sanitize_token`, `rs_record_degraded_event`, `rs_scan_degraded_log`, `rs_set_result`, `rs_emit`
- **private functions**: `rs_sanitize_token`（トークンサニタイズ）
- **dependencies**: 他のモジュールを `source` しているか（通常なし）
- **定数**: `RUN_SUMMARY_DEGRADED_PATTERNS`（デグレードドログスキャンのパターン配列）

```bash
read_file /path/to/idd-codex/local-watcher/bin/idd-codex-modules/run-summary.sh

# 移植元の関数一覧
grep -E '^[a-z_]+\(\)' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/run-summary.sh
```

### 2. 移植先でのファイル新規作成

移植元モジュールを `read_file` で読み、移植先のファイルパスに新規作成:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/run-summary.sh
```

移植時の注意点:
- **パスの置換**: `idd-codex` → `idd-qwen`、`local-watcher` → `qwen-watcher`
- **namespace 変換は不要**: プレフィックス `rs_` は移植元と移植先で共通
- **定数配列**: `RUN_SUMMARY_DEGRADED_PATTERNS` はそのまま移植（"No such file or directory" 等）
- **依存モジュール**: 通常依存なし（独立モジュール）

### 3. watcher スクリプトへの統合

移植先 watcher スクリプト（`idd-qwen-issue-watcher.sh`）に統合する:

#### 3.1 Config 変数の追加

```bash
# RUN_SUMMARY_ENABLED のデフォルト値を Config ブロックに追加
RUN_SUMMARY_ENABLED="${RUN_SUMMARY_ENABLED:-true}"
```

#### 3.2 REQUIRED_MODULES への追加

```bash
# REQUIRED_MODULES 配列に "run-summary" を追加
REQUIRED_MODULES=( ... "run-summary" )
```

#### 3.3 rs_emit ライフサイクルの統合

watcher 実行フローに rs_emit ライフサイクルを挿入する:

| 呼び出し | タイミング | 目的 |
|---|---|---|
| `rs_init` | 初期化直後 | run summary 状態の初期化 |
| `rs_set_mode` | 初期化後 | 実行モードの記録（例: `single`） |
| `rs_set_issue` | 初期化後 | Issue 番号の記録 |
| `rs_record_stage` | 各 stage/gate 前後 | stage/gate 追跡（A, A', B, B', C） |
| `rs_scan_degraded_log` | 実装フェーズ終了後 | デグレードドログスキャン |
| `rs_set_result` | 最終結果決定時 | 最終結果（success / failure / blocked） |
| `rs_emit` | 最終行 | 構造化イベントの出力 |

```bash
# 初期化（Config ブロック直後、Issue 解決後）
if [ "$RUN_SUMMARY_ENABLED" = "true" ]; then
  rs_init
  rs_set_mode "single"
  rs_set_issue "$NUMBER"
fi

# stage/gate 追跡（各フェーズ前後）
if [ "$RUN_SUMMARY_ENABLED" = "true" ]; then
  rs_record_stage "A" "start"
  # ... Triage フェーズ ...
  rs_record_stage "A" "complete"
fi

# デグレードドログスキャン（実装フェーズ終了後）
if [ "$RUN_SUMMARY_ENABLED" = "true" ]; then
  rs_scan_degraded_log "$ISSUE_LOG"
fi

# 最終結果と emit
if [ "$RUN_SUMMARY_ENABLED" = "true" ]; then
  rs_set_result "success"  # または "failure" / "blocked"
  rs_emit
fi
```

### 4. README.md の更新

移植先 README.md のモジュール一覧に新規モジュールを追加:

```bash
read_file /path/to/idd-qwen/README.md
```

追加箇所:
- `qwen-watcher/bin/idd-qwen-modules/` セクションに `run-summary.sh` を追加
- 用途説明（Per-Run Evidence Summary）をコメントとして付与

### 5. 検証

```bash
# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/run-summary.sh
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh

# 移植元との行数比較
echo "移植元: $(wc -l < /path/to/idd-codex/local-watcher/bin/idd-codex-modules/run-summary.sh) 行"
echo "移植先: $(wc -l < /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/run-summary.sh) 行"
```

## 動作原理

run-summary.sh は各 stage/gate の実行履歴を key=value 形式で記録し、最終的に構造化イベントとして出力する:

1. `rs_init` — 内部状態の初期化
2. `rs_set_mode` / `rs_set_issue` — 実行コンテキストの記録
3. `rs_record_stage` — 各 stage（A, A', B, B', C）の start/complete を記録
4. `rs_scan_degraded_log` — 実装ログから既知エラーパターンをスキャン
5. `rs_set_result` — 最終結果（success / failure / blocked）を記録
6. `rs_emit` — 全ての記録を key=value 形式で stdout に出力

## 既存モジュールとの関係

| モジュール | 関係 |
|---|---|
| core_utils.sh | 依存なし（独立モジュール） |
| REQUIRED_MODULES | `run-summary` を含める |
| watcher 実行フロー | rs_emit ライフサイクルで統合 |

## よくある落とし穴

- **REQUIRED_MODULES 忘れ**: ファイルを移植しても REQUIRED_MODULES に追加しないとロードされない（slack-notify.sh の事例）
- **rs_emit 呼び出し漏れ**: rs_emit を呼び出さない場合、記録は内部状態に残るだけで出力されない
- **stage 順序の誤り**: rs_record_stage は stage/gate の順序通りに呼び出す必要がある（A → A' → B → B' → C）
- **rs_scan_degraded_log のタイミング**: 実装フェーズ終了後、rs_set_result より前に呼び出す
- **rs_set_result の値**: 値は lowercase の `success` / `failure` / `blocked` のみ

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-module-integration-check](./auto-skill-module-integration-check/SKILL.md) — REQUIRED_MODULES 等、統合後の確認