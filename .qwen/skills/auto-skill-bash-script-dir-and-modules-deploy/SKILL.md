---
name: auto-skill-bash-script-dir-and-modules-deploy
description: BASH_SOURCE[0] 由来のディレクトリ取得イディオムとインストーラによる companion directory デプロイ
source: auto-skill
extracted_at: '2026-06-27T13:23:00.655Z'
---

# bash スクリプトのディレクトリ取得とインストーラでの companion directory デプロイ

## 問題

`BASH_SOURCE[0]` を使ったディレクトリ抽出で、相対パスでスクリプトを呼んだ場合に失敗する。

### NG: `%` パターンマッチング

```bash
# ❌ 相対パス "bash install.sh" で BASH_SOURCE[0] = "install.sh" の場合、
#    パターン "%/install.sh" はマッチせず、結果は空文字列になる
local script_dir="${BASH_SOURCE[0]%/install.sh}"
```

`BASH_SOURCE[0]` が `install.sh`（パス区切り `/` なし）の場合、`%/install.sh` は
末尾の `/install.sh` を探すためマッチせず、元の文字列 `install.sh` が返る。
`dirname` が `/` を含まないため `${dirname}` は空にならず、ディレクトリ取得に失敗する。

### OK: dirname + cd + pwd イディオム

```bash
# ✅ 常に正しく絶対パスのディレクトリを取得
local script_dir
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

このイディオムは POSIX sh 互換で、以下のいずれでも正しく動作する:

| 呼び出し方 | dirname 結果 | cd 結果 |
|---|---|---|
| `bash /abs/path/install.sh` | `/abs/path` | `/abs/path` |
| `bash install.sh` (cwd に存在) | `.` | `$(pwd)` |
| `bash ./subdir/install.sh` | `./subdir` | `$(pwd)/subdir` |

## インストーラでの companion directory デプロイ

watcher スクリプトが `MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/idd-qwen-modules" && pwd)"`
でモジュールディレクトリを参照する場合、インストーラは modules ディレクトリもコピーする必要がある。

### 実装パターン

```bash
install_files() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 本体スクリプト
    local script_src="${script_dir}/qwen-watcher/bin/idd-qwen-issue-watcher.sh"
    local script_dst="${INSTALL_DIR}/idd-qwen-issue-watcher.sh"
    cp "${script_src}" "${script_dst}"
    chmod +x "${script_dst}"

    # companion directory (modules)
    local modules_src="${script_dir}/qwen-watcher/bin/idd-qwen-modules"
    local modules_dst="${INSTALL_DIR}/idd-qwen-modules"
    if [[ -d "${modules_src}" ]]; then
        cp -R "${modules_src}" "${modules_dst}"
    else
        log_error "Modules ディレクトリが見つかりません: ${modules_src}"
        exit 1
    fi

    # plist 等、他のファイルも同様に...
}
```

### ドライラン対応

```bash
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] インストール: ${modules_src} → ${modules_dst}/"
else
    cp -R "${modules_src}" "${modules_dst}"
    log_info "インストール完了: ${modules_dst}/"
fi
```

## 確認 Checklist

- [ ] `script_dir` の取得に `dirname` + `cd` + `pwd` イディオムを使っている
- [ ] `${BASH_SOURCE[0]%/xxx}` パターンでディレクトリを抽出していない
- [ ] 本体スクリプト以外に、参照先の companion directory も `cp -R` でコピーしている
- [ ] companion directory 不在時は `exit 1` で失敗する（silent failure にならない）
- [ ] ドライラン時に modules のコピー先が表示される