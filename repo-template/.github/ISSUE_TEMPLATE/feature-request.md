name: Feature Request
description: 新機能のリクエスト
title: "[Feature]: "
labels: ["enhancement", "codex-auto-dev"]
body:
  - type: markdown
    attributes:
      value: |
        ## 新機能リクエスト

        以下の項目に記入してください。

  - type: textarea
    id: problem
    attributes:
      label: 問題・背景
      description: どのような問題を感じていますか、またはどのような背景がありますか？
      placeholder: 例：現在のワークフローでは〜に時間がかかりすぎる
    validations:
      required: true

  - type: textarea
    id: solution
    attributes:
      label: 解決策・提案
      description: どのような解決を望んでいますか？
      placeholder: 例：自動で〜してくれる機能があれば解決する
    validations:
      required: true

  - type: textarea
    id: acceptance
    attributes:
      label: 受入基準
      description: 機能が満たすべき条件是いですか？
      placeholder: 例：〜が 30 秒以内に完了すること
    validations:
      required: true

  - type: textarea
    id: out_of_scope
    attributes:
      label: スコープ外
      description: 今回のリクエストで扱わない事項
      placeholder: 例：UI のデザイン変更は含まない
    validations:
      required: false