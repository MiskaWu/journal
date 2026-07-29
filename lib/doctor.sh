#!/bin/sh
# lib/doctor.sh —— 環境自檢
#
# P1 只做 `--check`（只報告、絕不等輸入，以 exit code 表示）。互動式逐項補齊是 P4。
#
# D17：背景路徑一律走 --check。這裡即使被叫成互動模式，只要 stdin 不是 tty
# 就自動退到 --check —— 背景行程停下來等 Enter 是這工具最該避免的失效模式。

jr_doctor_row() {
	# jr_doctor_row STATUS LABEL DETAIL
	case $1 in
		ok)   printf '  %s✅%s %-12s %s\n' "$JR_C_GRN" "$JR_C_OFF" "$2" "$3" ;;
		warn) printf '  %s⚠%s  %-12s %s\n' "$JR_C_YEL" "$JR_C_OFF" "$2" "$3" ;;
		bad)  printf '  %s❌%s %-12s %s\n' "$JR_C_RED" "$JR_C_OFF" "$2" "$3" ;;
	esac
}

jr_cmd_doctor() {
	_check=0
	while [ $# -gt 0 ]; do
		case $1 in
			--check) _check=1 ;;
			--yes)   jr_warn '--yes（自動修復）是 P4，本階段等同 --check'; _check=1 ;;
			-*)      jr_die "doctor: 未知選項 $1" ;;
		esac
		shift
	done
	jr_interactive || _check=1

	_fatal=0
	_advice=0

	printf '\n  掃描 %s … 完成\n\n' "$(hostname)"

	printf '  必要 ─────────────────────────────────────\n'
	jr_doctor_row ok  sh "$(jr_sh_flavour)"
	if jr_has git; then jr_doctor_row ok git "$(git --version 2>/dev/null | awk '{print $3}')"
	else jr_doctor_row bad git '找不到'; _fatal=$((_fatal + 1)); fi
	if jr_has awk; then jr_doctor_row ok awk "$(command -v awk)"
	else jr_doctor_row bad awk '找不到'; _fatal=$((_fatal + 1)); fi
	if jr_has claude; then jr_doctor_row ok claude "$(claude --version 2>/dev/null | head -1)"
	else jr_doctor_row bad claude '找不到 → https://claude.com/claude-code'; _fatal=$((_fatal + 1)); fi

	printf '\n  加速器（缺少會降級，不影響正確性）────────\n'
	if jr_has node; then jr_doctor_row ok node "$(node --version 2>/dev/null)"
	else jr_doctor_row warn node '缺'; _advice=$((_advice + 1)); fi
	if jr_has python3; then jr_doctor_row ok python3 "$(python3 --version 2>/dev/null | awk '{print $2}')"
	else jr_doctor_row warn python3 '缺'; _advice=$((_advice + 1)); fi
	_r=$(jr_pick_reducer)
	if [ "$_r" = 'awk' ]; then
		jr_doctor_row warn reducer    'awk 粗篩 → 無工具參數提示，蒸餾忠實度較低'
	else
		jr_doctor_row ok reducer    "$_r"
	fi

	printf '\n  便利（缺少只是走手動路徑）────────────────\n'
	for t in gh jq timeout curl; do
		if jr_has "$t"; then jr_doctor_row ok "$t" "$(command -v "$t")"
		else jr_doctor_row warn "$t" '缺'; fi
	done

	printf '\n  執行環境 ─────────────────────────────────\n'
	if [ -f "$JR_HOST_YML" ]; then
		jr_doctor_row ok host       "$(jr_yaml_get "$JR_HOST_YML" host) → $(jr_yaml_get "$JR_HOST_YML" data_dir)"
		_dd=$(jr_yaml_get "$JR_HOST_YML" data_dir)
		if [ -d "$_dd" ]; then jr_doctor_row ok data       "$_dd"
		else jr_doctor_row bad data       "$_dd 不存在"; _fatal=$((_fatal + 1)); fi
	else
		jr_doctor_row bad host       "未初始化 → journal init --local"
		_fatal=$((_fatal + 1))
	fi
	if [ -d "$JR_PROJECTS_DIR" ]; then
		jr_doctor_row ok transcript "$(find "$JR_PROJECTS_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ') 個 session 檔"
	else
		jr_doctor_row bad transcript "$JR_PROJECTS_DIR 不存在"
		_fatal=$((_fatal + 1))
	fi
	jr_doctor_row warn hook 'SessionEnd 未註冊（P2）'
	jr_doctor_row warn timer 'journal-rollup.timer 未安裝（P4）'
	_advice=$((_advice + 2))

	printf '\n  健康度：%s\n' "$(jr_agent_health)"
	printf '  %d 項必須處理，%d 項建議處理。\n\n' "$_fatal" "$_advice"

	if [ "$_check" -eq 0 ]; then
		jr_info '（互動式逐項補齊是 P4；目前僅報告。）'
	fi
	[ "$_fatal" -eq 0 ]
}

jr_sh_flavour() {
	_shpath=/bin/sh
	if jr_has readlink; then
		_real=$(readlink -f "$_shpath" 2>/dev/null || readlink "$_shpath" 2>/dev/null)
		[ -n "$_real" ] && _shpath="$_shpath ($(basename "$_real"))"
	fi
	printf '%s' "$_shpath"
}
