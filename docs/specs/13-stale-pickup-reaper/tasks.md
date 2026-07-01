# Implementation Plan

- [ ] 1. spec 作成（requirements.md / design.md / tasks.md）
  - Issue #13 の spec ディレクトリを作成
  - requirements.md を EARS 形式で記述（6 要件 + 3 NFR）
  - design.md を既存実装に合わせた設計書として記述
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, 5.3, 5.4, 5.5, 6.1, 6.2, 6.3, 6.4_
  - _Boundary: docs/specs/13-stale-pickup-reaper/_

- [ ] 2. 実装ファイルのコミット
  - `qwen-watcher/bin/idd-qwen-modules/stale-pickup-reaper.sh` を git add
  - `feat(watcher): add stale-pickup-reaper.sh module` で commit
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, 5.3, 5.4, 5.5, 6.1, 6.2, 6.3, 6.4_
  - _Boundary: qwen-watcher/bin/idd-qwen-modules/stale-pickup-reaper.sh_

- [ ] 3. 既存統合の検証
  - main script に REQUIRED_MODULES 登録済みを確認
  - main script に dispatcher 呼び出し済みを確認
  - Config variables（STALE_PICKUP_REAPER_*) が定義済みを確認
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Boundary: qwen-watcher/bin/idd-qwen-issue-watcher.sh_

## Verify

```sh
bash -n qwen-watcher/bin/idd-qwen-modules/stale-pickup-reaper.sh && bash -n qwen-watcher/bin/idd-qwen-issue-watcher.sh
```