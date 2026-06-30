# モジュール移植時の main スクリプト統合（gate 関数 + dispatcher 登録）

移植元モジュール（idd-codex）から移植先モジュール（idd-qwen）へ移植する際、
main スクリプト（`idd-qwen-issue-watcher.sh`）への統合には 3 種類の追加変更が必要。
移植元モジュールの実装内容に応じて、必要な変更を特定する。

## 前提

- 移植元モジュール（例: `idd-codex/local-watcher/bin/idd-codex-modules/<module>.sh`）が存在する
- 移植先モジュール（例: `idd-qwen/qwen-watcher/bin/idd-qwen-modules/<module>.sh`）は stub または新規作成済み
- 移植先 main スクリプト（`idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh`）が存在する

## 統合パターン

移植元モジュールの実装内容を確認し、以下のパターンに分類する:

### Pattern A: 独立モジュール（REQUIRED_MODULES 登録のみ）

移植元モジュールが `full_auto_enabled()` 等の gate 関数を定義せず、
main スクリプト側で既に定義済みの場合:

```bash
# REQUIRED_MODULES に追加
REQUIRED_MODULES=("core_utils" "env-loader" "..." "<module>" "run-summary")
```

### Pattern B: gate 関数 + REQUIRED_MODULES + dispatcher（auto-merge 等）

移植元モジュールが `full_auto_enabled()` 等の gate 関数を定義し、
main スクリプト側で未定義の場合:

```bash
# 1. gate 関数を REQUIRED_MODULES 宣言前に追加
# ─── Full-auto Kill Switch ──────────────────────────────────────────────
full_auto_enabled() {
  case "${FULL_AUTO_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# 2. REQUIRED_MODULES に追加
REQUIRED_MODULES=("core_utils" "env-loader" "..." "auto-merge" "run-summary")

# 3. dispatcher に呼び出しを追加（pr-reviewer の後、failed-recovery の前）
if declare -f process_<module> &>/dev/null; then
    process_<module> || am_warn "process_<module> が想定外のエラーで終了（後続 Issue 処理は継続）"
fi
```

### Pattern C: 移植元固有の gate 関数（移植先で未定義の場合）

移植元モジュールが独自の gate 関数（例: `am_resolve_gate_enabled`）を定義し、
それが main スクリプトから呼ばれる場合、移植先でも同様に定義する。

## 統合手順

### 1. 移植元モジュールの gate 関数を特定

```bash
# 移植元モジュールから関数定義を抽出
grep -E '^[a-z_]+\(\)\s*\{' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/<module>.sh
```

gate 関数（main スクリプト側で定義すべきもの）を特定:
- `full_auto_enabled()` — 完全自動化 kill switch
- `am_resolve_gate_enabled()` — モジュール個別 gate（移植元モジュール内）

### 2. 移植先 main スクリプトの既存関数を確認

```bash
# 移植先 main スクリプトの関数定義を確認
grep -E '^[a-z_]+\(\)\s*\{' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh
```

移植元で定義されているが移植先で未定義の関数を特定。

### 3. 変更を適用

移植先 main スクリプトを編集:
- gate 関数の追加（未定義の場合）
- REQUIRED_MODULES への追加
- dispatcher への呼び出し追加

### 4. 変数スコープの整合性確認

移植元モジュールで `$REPO` を参照している箇所が、移植先で `$repo` に
変更されていないか確認する:

```bash
# 移植元: $REPO（グローバル変数）
# 移植先: $repo（ローカル変数）— 移植先 main スクリプトの関数シグネチャに合わせる
```

移植先 main スクリプトの関数シグネチャに従うこと:
- `process_<module>()` 内では `local repo="${REPO:-}"` でローカル変数化
- 関数内では `$repo` を使用（`$REPO` を直接使用しない）

## よくある落とし穴

- **変数スコープの混同**: 移植元では `$REPO`（グローバル）を直接使用しているが、
  移植先の関数内では `local repo="${REPO:-}"` でローカル変数化し、
  関数内では `$repo` を使用するのが正しいパターン
- **gate 関数の二重定義**: 移植元モジュール内で gate 関数が定義されている場合、
  移植先 main スクリプトにも同じ gate 関数を定義する必要がある（移植先 main スクリプト
  から gate 関数を呼ぶため）
- **dispatcher 順序**: 移植元の dispatcher 順序を維持すること。特に `process_auto_merge`
  は `process_pr_reviewer` の後、`process_failed_recovery` の前に配置する
- **REQUIRED_MODULES の順序**: `run-summary` の前、`pr-reviewer` の後が正しい順序

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の全体手順
- [auto-skill-auto-shell-var-scope-fix](./auto-skill-auto-shell-var-scope-fix/SKILL.md) — shell 変数スコープ修正