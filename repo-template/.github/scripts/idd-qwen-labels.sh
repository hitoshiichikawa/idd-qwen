#!/usr/bin/env bash
# idd-qwen-labels.sh - GitHub ラベル管理スクリプト
#
# 用途: idd-qwen で使用する GitHub ラベルを自動作成・更新
#
# 著者: idd-qwen contributors
# ライセンス: MIT

set -euo pipefail

# ラベル定義
LABELS=(
    "codex-auto-dev:1f77b4:自動開発対象"
    "codex-claimed:c39bd3:Qwen Code が claim 済"
    "codex-picked-up:9b59b6:Qwen Code 実行中"
    "codex-ready-for-review:2ecc71:PR 作成完了"
    "codex-failed:e74c3c:自動実行が失敗"
    "codex-blocked:f39c12:阻塞中"
    "codex-awaiting-slot:e67e22:スロット待ち"
    "codex-awaiting-design-review:3498db:設計レビュー待ち"
    "codex-needs-decisions:9b59b6:人間判断必要"
    "codex-needs-rebase:1abc9c:Rebase 必要"
    "codex-needs-iteration:8e44ad:反復必要"
    "codex-needs-quota-wait:34495e:クォータ待ち"
    "codex-staged-for-release:27ae60:リリース待ち"
    "codex-st-failed:c0392b:Stage 失敗"
    "codex-skip-triage:7f8c8d:Triage 省略"
    "codex-hotfix:e74c3c:Hotfix"
)

# 引数処理
REPO="${REPO:?REPO 環境変数が設定されていません}"
DRY_RUN="${DRY_RUN:-false}"

for label_def in "${LABELS[@]}"; do
    IFS=':' read -r label_color label_desc <<< "${label_def}"
    color="${label_color}"
    desc="${label_desc}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY-RUN] gh label create ${label} --color ${color} --description \"${desc}\" --repo ${REPO}"
    else
        gh label create "${label}" --color "${color}" --description "${desc}" --repo "${REPO}" 2>/dev/null || {
            echo "ラベルが既に存在します: ${label}"
        }
    fi
done

echo "ラベル作成が完了しました: ${REPO}"