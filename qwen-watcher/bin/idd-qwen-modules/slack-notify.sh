#!/usr/bin/env bash
# slack-notify.sh — 介入要求イベントの Slack 外部通知モジュール (#4 / D-18 移植)
#
# 用途:
#   完全自動化（full-auto）下で「人間の介入が必要になった瞬間」を Slack incoming webhook
#   へ能動的に push する。run-summary（per-run の機械可読ログ）を補完し、**介入要求イベント
#   のみ**を通知してノイズを抑える。通知対象（最小）:
#     - failed-recovery の budget 超過 / no-progress 終端（`codex-failed` 据え置き / #101）
#     - needs-decisions 据え置き（human-only 等の人間判断待ち / #102 / Triage 経路）
#     - blocked 依存の cycle 検出（デッドロック / #103）
#
# 著者: idd-qwen contributors
# ライセンス: MIT

_is_slack_notify_loaded() { return 0; }

# ─── 設定 ────────────────────────────────────────────────────────────────────

# SLACK_NOTIFY_ENABLED=true かつ FULL_AUTO_ENABLED=true（二重 opt-in）のときのみ有効
# SLACK_WEBHOOK_URL は env-loader.sh（per-repo .env）または crontab env で設定
# 機密情報: Webhook URL は sn_log で出力しない（*** 置換）

# ─── gate 関数 ──────────────────────────────────────────────────────────────

# slack-notify が有効か判定（二重 opt-in: SLACK_NOTIFY_ENABLED AND full_auto_enabled）
sn_notify_enabled() {
  [ "${SLACK_NOTIFY_ENABLED:-false}" = "true" ] \
    && full_auto_enabled \
    && [ -n "${SLACK_WEBHOOK_URL:-}" ]
}

# ─── payload 構築 ───────────────────────────────────────────────────────────

# GitHub URL を構築
sn_github_url() {
  local issue_number="$1"
  echo "https://github.com/${REPO}/issues/${issue_number}"
}

# Slack payload を構築
sn_build_payload() {
  local issue_number="$1"
  local issue_title="$2"
  local event_type="$3"  # failed-recovery | needs-decisions | cycle-detected
  local detail="$4"

  local url
  url="$(sn_github_url "${issue_number}")"

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  # 機密情報（Webhook URL）はログに出力しない
  local webhook_display="***"

  cat <<EOF
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": ":warning: 介入要求: ${event_type}",
        "emoji": true
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*Issue*\n<${url}|#${issue_number}: ${issue_title}>"
        },
        {
          "type": "mrkdwn",
          "text": "*イベント*\n\`${event_type}\`"
        }
      ]
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*時刻*\n\`${ts}\`"
        },
        {
          "type": "mrkdwn",
          "text": "*Webhook*\n\`${webhook_display}\`"
        }
      ]
    }
  ]
}
EOF
}

# ─── Slack 送信 ─────────────────────────────────────────────────────────────

# Slack incoming webhook へ POST
sn_post() {
  local payload="$1"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "${payload}" \
    "${SLACK_WEBHOOK_URL}" 2>/dev/null) || {
    sn_warn "Slack webhook への POST が curl エラーで失敗: ${SLACK_WEBHOOK_URL}"
    return 1
  }

  if [ "${http_code}" != "200" ]; then
    sn_warn "Slack webhook POST が HTTP ${http_code} を返した: ${SLACK_WEBHOOK_URL}"
    return 1
  fi

  return 0
}

# ─── 介入通知エントリポイント ───────────────────────────────────────────────

# 介入要求イベントを Slack へ通知
# 用途: 外部の gate（failed-recovery / needs-decisions / cycle-detection）から呼び出す
# 引数: issue_number, issue_title, event_type, detail
sn_notify_intervention() {
  local issue_number="$1"
  local issue_title="$2"
  local event_type="$3"
  local detail="${4:-}"

  # gate チェック
  if ! sn_notify_enabled; then
    return 0
  fi

  # payload 構築
  local payload
  payload="$(sn_build_payload "${issue_number}" "${issue_title}" "${event_type}" "${detail}")"

  # 送信
  if sn_post "${payload}"; then
    sn_log "Slack へ介入要求イベントを通知: #${issue_number} (${event_type})"
  else
    sn_warn "Slack 通知に失敗: #${issue_number} (${event_type})"
  fi
}

# ─── モジュール初期化 ───────────────────────────────────────────────────────

sn_init() {
  _qw_log_debug "slack-notify.sh をロードしました"
}