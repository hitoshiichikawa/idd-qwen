# 移植元依存関数の core_utils.sh への事前追加

モジュールを idd-codex から idd-qwen 等に移植する際、移植元モジュールが依存している共有関数（`full_auto_enabled` 等）が移植先に存在しない場合、**まず core_utils.sh に共有関数を追加してからモジュールを移植する**。

## 前提

- 移植元モジュールが共有関数（kill switch 述語等）を `source` している
- 移植先の core_utils.sh にその共有関数が未定義
- 移植先モジュール一覧（既存 skill「モジュール移植」の表）に従って移植する

## 手順

### 1. 移植元モジュールの依存関数を特定

移植元モジュールを `read_file` で読み、以下の依存関数を grep:

```bash
grep -E 'full_auto_enabled|gate_enabled|_enabled' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/<module-name>.sh
```

移植元モジュールが参照している共有関数の一覧を記録する。

### 2. 移植先の core_utils.sh に関数が存在するか確認

移植先の core_utils.sh を `read_file` で読み、移植元で使われている共有関数が定義されているか確認:

```bash
grep -E 'full_auto_enabled|gate_enabled|_enabled' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

関数が存在しない場合、**先に core_utils.sh に追加する**。

### 3. core_utils.sh に関数を追加

移植元と同一の署名・挙動で core_utils.sh の末尾（`core_utils_init` の前）に関数を追加:

```bash
# 例: full_auto_enabled() の追加
# ─── full_auto_enabled: 完全自動化 kill switch の述語 (#97 移植) ──────────
#
# 用途: 完全自動化（full-auto）系の外部副作用を安全に制御する。
#   `FULL_AUTO_ENABLED` が `true` の場合のみ true を返す。
#   二重 opt-in gate（例: `SLACK_NOTIFY_ENABLED` AND `full_auto_enabled`）で使用する。
#   既定は false（安全側）。unset / 空 / typo（`True` / `on` / `1`）は全て false。
#
# 戻り値: 0 = FULL_AUTO_ENABLED=true / 1 = それ以外
# ─────────────────────────────────────────────────────────────────────────────
full_auto_enabled() {
  case "${FULL_AUTO_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}
```

追加時の注意点:
- コメントは移植元の意図を記録（Issue 番号、用途、戻り値）
- `core_utils_init` より前に配置（初期化関数の前に依存を置く）
- 移植先の命名慣習に合わせる（日本語コメント可）

### 4. 移植元モジュールを移植

core_utils.sh に共有関数を追加した後に、移植元モジュールを移植:

```bash
write_file /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh
```

移植時の注意点:
- 移植元モジュールの `source` 行は不要（core_utils.sh は watcher 側で source 済み）
- 移植元で使われている共有関数は、移植先の core_utils.sh に追加した関数をそのまま参照

### 5. 検証

```bash
# shellcheck
shellcheck /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module-name>.sh

# core_utils.sh の構文検証
bash -n /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/core_utils.sh
```

## よくある落とし穴

- **依存関数を先に追加しない**: core_utils.sh に共有関数を追加する前にモジュールを移植すると、移植元モジュールが未定義関数を参照したままになる
- **core_utils_init の前に追加しない**: 共有関数は `core_utils_init` より前に配置する（初期化関数の前に依存を置く）
- **移植元の source 行を移植先に残す**: 移植元モジュールの `source core_utils.sh` 行は移植先に含めない（core_utils.sh は watcher 側で source 済み）
- **共有関数の署名不一致**: 移植元の共有関数の署名（引数・戻り値）と移植先の core_utils.sh で一致するか確認

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植全般
- [auto-skill-core-utils-scope-separation](./auto-skill-core-utils-scope-separation/SKILL.md) — core_utils.sh のスコープ分離