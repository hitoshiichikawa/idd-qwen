---
name: auto-skill-module-config-vars
description: モジュール移植時に main スクリプト Config ブロックに変数定義が不足する問題を特定・修正する
source: auto-skill
extracted_at: '2026-06-27T14:08:31.176Z'
---

# モジュール移植時の Config ブロック変数定義不足の修正

bash モジュールを移植する際、モジュール内で参照する環境変数（`STALE_PICKUP_REAPER_*` 等）が
main スクリプトの Config ブロックに定義されていないと、`set -euo pipefail` により
**起動時に即座に失敗する**。ファイル移植・REQUIRED_MODULES 登録だけでは不十分。

## 背景

移植元（idd-codex）では main スクリプトの Config ブロックに変数が定義されているが、
移植先（idd-qwen）への移植時に以下の理由で見落としが起きる:

1. 移植元では `env-loader.sh` 経由で env ファイルから供給される変数が多い（main 側で default を書かない）
2. 移植先では `env-loader.sh` が導入済みだが、移植先の Config ブロックには反映されていない
3. モジュール内のコメントに「Config ブロックで定義済み」と書かれているが、移植先には存在しない

## 検出手順

### Step 1: モジュール内の未定義変数参照を特定

モジュール内で参照されているが、main スクリプトの Config ブロックに定義されていない変数を特定する:

```bash
# モジュール内の全変数参照を抽出（${...} 形式）
grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' /path/to/module.sh | sort -u

# main スクリプトの Config ブロック（REQUIRED_MODULES 宣言前）の変数定義を抽出
awk '/^# -{40,}/,/^REQUIRED_MODULES=' /path/to/main.sh | grep -oE '\b[A-Z_]+="?\$\{?[A-Z_]+' | sort -u
```

より簡易に、module 内の `_init` 関数や関数内で参照される変数を grep:

```bash
# モジュール内で参照される変数（${VAR} / $VAR 形式）
grep -oE '\$[A-Za-z_][A-Za-z0-9_]*|\\$\{[A-Za-z_][A-Za-z0-9_]*\}' /path/to/module.sh | sort -u
```

### Step 2: main スクリプトの Config ブロック範囲を特定

Config ブロックは通常、REQUIRED_MODULES 宣言の前まで:

```bash
# REQUIRED_MODULES 行の行番号を取得
grep -n 'REQUIRED_MODULES=' /path/to/main.sh

# その行より前で定義されている変数を確認
head -<N-1> /path/to/main.sh | grep -E '^[A-Z_]+='
```

### Step 3: 不足変数の特定と既定値の決定

不足している変数について、各変数の用途と適切な既定値を決定する:

| 変数 | 用途 | 既定値の決め方 |
|---|---|---|
| `<MODULE>_ENABLED` | 機能 ON/OFF gate | 移植元の既定値をコピー（通常 `false`） |
| `<MODULE>_STATE_DIR` | 状態ファイル保存先 | `${LOG_DIR}/<module>` 等、既存変数で参照 |
| `<MODULE>_THRESHOLD_*` | 閾値 | 移植元の既定値をコピー |
| `SLOT_LOCK_DIR` | slot 状態保存先 | `${LOCK_FILE}.slots` 等、既存変数で参照 |

### Step 4: 変数定義を追加

Config ブロックの末尾（REQUIRED_MODULES 宣言の前）に変数定義を追加する:

```bash
# ─── <Module> Config ──────────────────────────────────────────────────────
# <module>.sh モジュールが参照する変数群。
<MODULE>_ENABLED="${<MODULE>_ENABLED:-false}"
<MODULE>_STATE_DIR="${<MODULE>_STATE_DIR:-${LOG_DIR}/<module>}"
<MODULE>_THRESHOLD_MINUTES="${<MODULE>_THRESHOLD_MINUTES:-<value>}"

# Slot lock 用ディレクトリ。
SLOT_LOCK_DIR="${SLOT_LOCK_DIR:-${LOCK_FILE}.slots}"
```

**順序の重要**: `${LOG_DIR}` や `${LOCK_FILE}` を参照する場合、これらの変数が先に定義されていることを確認する。

## よくある落とし穴

- **env ファイル依存の過信**: 移植元では `env-loader.sh` 経由で env ファイルから供給される変数を、
  移植先でも「env ファイルで設定されるから main 側に書かなくていい」と誤解する。
  `env-loader.sh` は既存 env の上書きを防ぐため、main 側に既定値がなければ `set -u` で失敗する
- **移植元の `_init` 関数内での初期化**: 移植元モジュールの `_init` 関数内で `VAR="${VAR:-default}"` を
  行っている場合、移植先でも同様に `_init` で初期化する必要があるか確認する
- **SLOT_LOCK_DIR 等の共有変数**: 複数のモジュールが参照する共有変数（`SLOT_LOCK_DIR` 等）は、
  最初に参照するモジュールの Config ブロックで定義する（後から追加するモジュールも参照する可能性がある）

## 事例: stale-pickup-reaper.sh

移植元（idd-codex）では Config ブロックに `STALE_PICKUP_REAPER_*` と `SLOT_LOCK_DIR` が定義されていたが、
移植先（idd-qwen）では Config ブロックの末尾（CONTEXT_INDEXER_MAX_TURNS の後）に変数定義が不足していた。

修正内容:

```bash
# ─── Stale Pickup Reaper Config ──────────────────────────────────────────────
STALE_PICKUP_REAPER_ENABLED="${STALE_PICKUP_REAPER_ENABLED:-false}"
STALE_PICKUP_REAPER_STATE_DIR="${STALE_PICKUP_REAPER_STATE_DIR:-${LOG_DIR}/reaper}"
STALE_PICKUP_REAPER_THRESHOLD_MINUTES="${STALE_PICKUP_REAPER_THRESHOLD_MINUTES:-120}"
STALE_PICKUP_REAPER_GH_TIMEOUT="${STALE_PICKUP_REAPER_GH_TIMEOUT:-30}"
STALE_PICKUP_REAPER_MAX_ISSUES="${STALE_PICKUP_REAPER_MAX_ISSUES:-5}"
SLOT_LOCK_DIR="${SLOT_LOCK_DIR:-${LOCK_FILE}.slots}"
```

順序: `LOG_DIR` → `LOCK_FILE` → 本変数（参照先が先に定義されていることを確認）。

## 関連

- [auto-skill-module-integration](./auto-skill-module-integration/SKILL.md) — モジュール統合の手順
- [auto-skill-module-integration-check](./auto-skill-module-integration-check/SKILL.md) — 移植後の統合チェック
- [auto-skill-env-loader-port](./auto-skill-env-loader-port/SKILL.md) — env-loader モジュール移植