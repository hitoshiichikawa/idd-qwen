---
name: auto-shell-var-scope-fix
description: Shell script function内でのローカル変数とグローバル変数の混同を修正する
source: auto-skill
extracted_at: '2026-06-27T08:33:39.537Z'
---

# Shell スクリプトの関数内変数スコープ修正

Shell 関数内でローカル変数（`local`）を定義した後、関数内の他の場所でグローバル変数を参照してしまうバグを修正する。

## 典型的なパターン

```bash
process_auto_merge() {
  local repo="${REPO:-}"   # ローカル変数 repo を定義
  
  # ... 他の処理 ...
  
  # NG: 関数内では local repo を使うべきだが、グローバル $REPO を参照している
  _am_gh pr list --repo "$REPO" ...
  _am_gh pr list --repo "$REPO" ... --jq "... select(.repository.nameWithOwner == \"$REPO\") ..."
  
  # NG: 関数呼び出しでもグローバル $REPO を渡している
  if am_process_single_pr "$REPO" "$pr_number"; then
```

## 修正手順

1. **関数内の `local` 変数宣言を探す**: `local varname="${GLOBAL_VAR:-}"` のようなパターン
2. **関数内のその変数参照箇所を特定する**: グローバル変数（`$GLOBAL_VAR`）を参照している箇所を grep
3. **すべてをローカル変数に置換する**: `$GLOBAL_VAR` → `$varname`
4. **関数呼び出し引数も確認する**: 関数呼び出し時にグローバル変数を渡していないか確認し、ローカル変数に統一

## 検証

- `grep -n '\$GLOBAL_VAR' file.sh` で関数内に残っていないか確認
- `grep -n '\$local_var' file.sh` でローカル変数が正しく使われているか確認
- 変数名の一致（大文字小文字）を注意深く確認（`$REPO` vs `$repo`）

## 注意点

- `local` 変数のスコープは関数内のみ。関数外から参照してもグローバル変数の値が返る場合がある
- 変数名の大文字小文字の違い（`REPO` vs `repo`）は別の変数として扱われる
- 関数呼び出しの引数渡しでもグローバル変数を使わないよう注意