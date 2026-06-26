# Implementation Notes — Issue #4: slack-notify.sh モジュール追加

## 概要

`idd-codex/local-watcher/bin/idd-codex-modules/slack-notify.sh` から `idd-qwen` への移植。
Slack incoming webhook へ介入要求イベントを通知するモジュール。

## 実装内容

### 新規作成

- `qwen-watcher/bin/idd-qwen-modules/slack-notify.sh`
  - `sn_notify_enabled()` — 二重 opt-in gate 判定
  - `sn_github_url()` — Issue URL 構築
  - `sn_build_payload()` — Slack payload 生成（blocks API）
  - `sn_post()` — Webhook 送信
  - `sn_notify_intervention()` — エントリポイント
  - `sn_init()` — モジュール初期化

### 修正

- `qwen-watcher/bin/idd-qwen-modules/core_utils.sh`
  - `full_auto_enabled()` 関数を追加（#97 移植）
  - 完全自動化 kill switch の述語関数
  - `FULL_AUTO_ENABLED=true` のみ true を返す（既定 false）

## テスト結果

- shellcheck: clean（exit code 0）
- モジュール構文: `bash -n` で検証済み

## 実装上の判断

- `full_auto_enabled()` は core_utils.sh に配置（共有 gate 関数として再利用可能性を考慮）
- Slack payload は blocks API 形式（rich formatting 対応）
- Webhook URL は機密情報としてログに出力しない（`***` 置換）

## 確認事項

- なし

## STATUS: complete