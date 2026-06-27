---
name: auto-skill-module-integration-check
description: モジュール移植後に REQUIRED_MODULES 登録と呼び出し元接続を確認する手順
source: auto-skill
extracted_at: '2026-06-27T03:27:41.669Z'
---

# モジュール移植後の統合チェック

bash モジュールを移植先レポジトリに移植した後、**ファイルが存在するだけでは動かない** ことを確認する。
移植元（idd-codex）から移植先（idd-qwen）へのモジュール移植で、`slack-notify.sh` がファイルだけ移植されて REQUIRED_MODULES 未追加・呼び出し元未接続となり dead code 化した事例（#52）から抽出。

## なぜ必要か

移植元では `REQUIRED_MODULES` に含まれ、他モジュールから呼び出されているモジュールでも、移植先では以下のいずれかが欠落していることがある:

1. `REQUIRED_MODULES` への追加（モジュールがロードされない）
2. 呼び出し元の移植（移植元モジュール自体が移植されていない場合あり）
3. シグネチャの一致（移植元と移植先で引数が異なる場合あり）

ファイルが存在するかだけでなく、**実際にロードされて呼ばれる状態** を確認する。

## チェック手順

### Step 1: REQUIRED_MODULES への追加確認

移植元で `REQUIRED_MODULES` に含まれているモジュールは、移植先でも追加する:

```bash
# 移植元での REQUIRED_MODULES 確認
grep 'REQUIRED_MODULES=' /path/to/idd-codex/local-watcher/bin/idd-codex-issue-watcher.sh

# 移植先での REQUIRED_MODULES 確認
grep 'REQUIRED_MODULES=' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh

# 移植元にあり移植先にないモジュールを特定
SRC_MODULES=$(grep -oP '"[^"]*"' /path/to/idd-codex/local-watcher/bin/idd-codex-issue-watcher.sh | tr -d '"')
DST_MODULES=$(grep -oP '"[^"]*"' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh | tr -d '"')
echo "移植元にあり移植先にないモジュール:"
comm -23 <(echo "$SRC_MODULES" | sort) <(echo "$DST_MODULES" | sort)
```

移植元にあるモジュールが移植先にない場合、`REQUIRED_MODULES` に追加する必要がある。

### Step 2: 呼び出し元の確認

移植したモジュールの関数が、移植先のどこから呼ばれるかを確認する:

```bash
# 移植元での呼び出し元を特定
grep -rn 'sn_notify_intervention\|<module_prefix>_' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/

# 移植先での呼び出し元を確認
grep -rn 'sn_notify_intervention\|<module_prefix>_' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/
grep -rn 'sn_notify_intervention\|<module_prefix>_' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-issue-watcher.sh
```

移植元の呼び出し元が移植先に存在しない場合:

- 移植元の呼び出し元モジュール自体が移植先で移植されていない → その呼び出しは移植対象外
- 移植元の呼び出し元モジュールが移植先にもある → 呼び出しを移植する必要がある

### Step 3: シグネチャの差異確認

移植元と移植先で関数の引数シグネチャが異なる場合がある:

```bash
# 移植元でのシグネチャ
grep -A5 'sn_github_url()' /path/to/idd-codex/local-watcher/bin/idd-codex-modules/slack-notify.sh

# 移植先でのシグネチャ
grep -A5 'sn_github_url()' /path/to/idd-qwen/qwen-watcher/bin/idd-qwen-modules/slack-notify.sh
```

シグネチャが異なる場合、移植元のシグネチャをそのまま移植する必要があるか確認する。

### Step 4: 最終確認

移植後に以下の全てが満たされることを確認する:

- [ ] 移植モジュールが `REQUIRED_MODULES` に含まれている
- [ ] 移植元の呼び出し元が移植先でも存在するか、移植元モジュール自体が移植先で不要
- [ ] シグネチャが移植元と一致している、または移植先での意図的な変更が正当化されている
- [ ] `shellcheck` が clean である

## 事例: slack-notify.sh の dead code 化

移植元（idd-codex）では:
- `REQUIRED_MODULES` に `"slack-notify.sh"` が含まれる
- `failed-recovery.sh` の 649, 667 行目で `sn_notify_intervention` を呼び出し
- `idd-codex-issue-watcher.sh` の 10645, 11141 行目で `sn_notify_intervention` を呼び出し

移植先（idd-qwen）では:
- `REQUIRED_MODULES` に `"slack-notify.sh"` が **含まれていない**
- 呼び出し元が **0 件**
- `failed-recovery.sh` 自体が移植されていない
- `sn_github_url()` のシグネチャが `(issue_number)` 1引数 → 移植元は `(kind, number)` 2引数

結果: ファイルは存在するが **全く機能しない dead code**

## 関連

- [auto-skill-module-migration](./auto-skill-module-migration/SKILL.md) — モジュール移植の基本手順
- [auto-skill-module-provenance](./auto-skill-module-provenance/SKILL.md) — 関数出自追跡