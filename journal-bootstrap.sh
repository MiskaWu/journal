#!/bin/sh
# journal-bootstrap.sh —— 新機器一行接入
#
# 用法（程式碼 repo 是公開的，O8 —— curl 拿得到這個檔就能跑）：
#   curl -fsSL https://raw.githubusercontent.com/MiskaWu/journal/main/journal-bootstrap.sh | sh
#   或先下載再帶參數：sh journal-bootstrap.sh --role aggregator
#
# 它只做三件事：確認 git 在、取得程式碼 repo、把後續交給 journal init。
# 所有真正的納管邏輯（deploy key、provider、hook、timer、自檢）都在 init 裡 ——
# 這個檔案薄到可以用眼睛審完再跑。

set -u

REPO=${JOURNAL_CODE_REPO:-https://github.com/MiskaWu/journal.git}
DEST=${JOURNAL_CODE_DIR:-$HOME/.local/share/journal}

command -v git > /dev/null 2>&1 || {
	echo 'bootstrap: 需要 git —— 先裝（apt/dnf/pacman/apk/brew install git）' >&2
	exit 1
}

if [ -d "$DEST/.git" ]; then
	echo "bootstrap: $DEST 已存在，更新中…" >&2
	git -C "$DEST" pull --ff-only -q || {
		echo 'bootstrap: pull 失敗 —— 本地有改動？程式碼 repo 對 agent 應該是唯讀的（鐵律 6）' >&2
		exit 1
	}
else
	echo "bootstrap: clone $REPO → $DEST" >&2
	mkdir -p "$(dirname "$DEST")"
	git clone -q "$REPO" "$DEST" || exit 1
fi

exec "$DEST/bin/journal" init "$@"
