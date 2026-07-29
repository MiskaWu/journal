#!/bin/sh
# hooks/session-end.sh —— L1 觸發點
#
# 鐵則（DESIGN §10）：**絕不讓 journal 拖慢你關視窗。**
# 這個腳本只做一件事：把 stdin 的 payload 轉手給背景的 `journal capture --hook`，
# 然後立刻返回。所有真正的工作（spool、蒸餾、gate、commit）都在背景進程裡。
#
# SessionEnd 的 exit code 本來就會被 Claude Code 忽略（官方文件），
# 但我們仍然保證秒回 —— hook 的 600s 預設 timeout 一毫秒都不該用到。

# 遞迴保護：journal 自己呼叫的 claude -p 帶 --safe-mode（hooks 被跳過），
# 但旗標被拒的 bare 退化路徑不帶 —— 那條路靠這個環境變數擋。
[ -n "${JOURNAL_IN_CAPTURE:-}" ] && exit 0

JR=${JOURNAL_BIN:-"$HOME/.local/bin/journal"}
[ -x "$JR" ] || exit 0

_payload=$(cat 2>/dev/null || true)
[ -n "$_payload" ] || exit 0

if [ -n "${JOURNAL_CAPTURE_SYNC:-}" ]; then
	# 測試用：前景執行，結果可斷言
	printf '%s' "$_payload" | "$JR" capture --hook
	exit 0
fi

printf '%s' "$_payload" | "$JR" capture --hook > /dev/null 2>&1 &
exit 0
