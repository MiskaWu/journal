#!/bin/sh
# lib/doctor.sh —— 環境自檢與互動補齊
#
# 三種模式（DESIGN §8）：
#   journal doctor          互動：列全貌 → 逐項帶你補 → 每項補完立刻複驗
#   journal doctor --check  只報告，絕不等輸入，exit code 表示（timer/hook 用這條）
#   journal doctor --yes    非互動，自動修「journal 自己能做的」
#
# 分界（D17 + §8）：**journal 自己做**的只有 ~/ 底下的東西（hook、timer、
# symlink、目錄）；需要 sudo 或系統層的（套件、linger）**印指令給你做**，
# journal 永不自行取得或使用 sudo。

jr_doctor_row() {
	case $1 in
		ok)   printf '  %s✅%s %-12s %s\n' "$JR_C_GRN" "$JR_C_OFF" "$2" "$3" ;;
		warn) printf '  %s⚠%s  %-12s %s\n' "$JR_C_YEL" "$JR_C_OFF" "$2" "$3" ;;
		bad)  printf '  %s❌%s %-12s %s\n' "$JR_C_RED" "$JR_C_OFF" "$2" "$3" ;;
	esac
}

# 待補清單：一行一項「代號<TAB>說明」。修復器見 jr_doctor_fix。
jr_doctor_add_fix() { printf '%s\t%s\n' "$1" "$2" >> "$JR_TMPDIR/doctor.fixes"; }

jr_doctor_scan() {
	: > "$JR_TMPDIR/doctor.fixes"
	_fatal=0
	_advice=0

	printf '\n  掃描 %s … 完成\n\n' "$(hostname)"

	printf '  必要 ─────────────────────────────────────\n'
	jr_doctor_row ok  sh "$(jr_sh_flavour)"
	if jr_has git; then jr_doctor_row ok git "$(git --version 2>/dev/null | awk '{print $3}')"
	else jr_doctor_row bad git '找不到'; jr_doctor_add_fix pkg-git '安裝 git'; _fatal=$((_fatal + 1)); fi
	if jr_has awk; then jr_doctor_row ok awk "$(command -v awk)"
	else jr_doctor_row bad awk '找不到'; jr_doctor_add_fix pkg-awk '安裝 awk'; _fatal=$((_fatal + 1)); fi
	if jr_has claude; then jr_doctor_row ok claude "$(claude --version 2>/dev/null | head -1)"
	else jr_doctor_row bad claude '找不到'; jr_doctor_add_fix pkg-claude '安裝 Claude Code'; _fatal=$((_fatal + 1)); fi

	printf '\n  加速器（缺少會降級，不影響正確性）────────\n'
	if jr_has node; then jr_doctor_row ok node "$(node --version 2>/dev/null)"
	else jr_doctor_row warn node '缺'; jr_doctor_add_fix pkg-node '安裝 node（減量快路徑）'; _advice=$((_advice + 1)); fi
	if jr_has python3; then jr_doctor_row ok python3 "$(python3 --version 2>/dev/null | awk '{print $2}')"
	else jr_doctor_row warn python3 '缺'; jr_doctor_add_fix pkg-python3 '安裝 python3（減量快路徑）'; _advice=$((_advice + 1)); fi
	_r=$(jr_pick_reducer)
	if [ "$_r" = 'awk' ]; then
		jr_doctor_row warn reducer 'awk 粗篩 → 無工具參數提示，蒸餾忠實度較低'
	else
		jr_doctor_row ok reducer "$_r"
	fi

	printf '\n  便利（缺少只是走手動路徑）────────────────\n'
	for t in gh jq timeout curl; do
		if jr_has "$t"; then jr_doctor_row ok "$t" "$(command -v "$t")"
		else jr_doctor_row warn "$t" '缺'; fi
	done

	printf '\n  執行環境 ─────────────────────────────────\n'
	if [ -f "$JR_HOST_YML" ]; then
		jr_doctor_row ok host "$(jr_yaml_get "$JR_HOST_YML" host) → $(jr_yaml_get "$JR_HOST_YML" data_dir)"
		_dd=$(jr_yaml_get "$JR_HOST_YML" data_dir)
		if [ -d "$_dd" ]; then jr_doctor_row ok data "$_dd"
		else jr_doctor_row bad data "$_dd 不存在"; jr_doctor_add_fix init '重跑 journal init'; _fatal=$((_fatal + 1)); fi
	else
		jr_doctor_row bad host '未初始化'
		jr_doctor_add_fix init '跑 journal init（建骨架、註冊本機）'
		_fatal=$((_fatal + 1))
	fi
	if [ -d "$JR_PROJECTS_DIR" ]; then
		jr_doctor_row ok transcript "$(find "$JR_PROJECTS_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ') 個 session 檔"
	else
		jr_doctor_row bad transcript "$JR_PROJECTS_DIR 不存在（這台跑過 claude 嗎？）"
		_fatal=$((_fatal + 1))
	fi
	if [ -f "$JR_CLAUDE_HOME/settings.json" ] && grep -qF 'hooks/session-end.sh' "$JR_CLAUDE_HOME/settings.json"; then
		jr_doctor_row ok hook 'SessionEnd 已註冊'
	else
		jr_doctor_row warn hook 'SessionEnd 未註冊 → L1 即時層不會動'
		jr_doctor_add_fix hook '註冊 SessionEnd hook'
		_advice=$((_advice + 1))
	fi
	if [ -n "${JOURNAL_NO_TIMER:-}" ]; then
		jr_doctor_row warn timer '（JOURNAL_NO_TIMER 設定中，不檢查）'
	elif jr_has systemctl && systemctl --user is-enabled journal-rollup.timer > /dev/null 2>&1; then
		jr_doctor_row ok timer 'journal-rollup.timer 已啟用'
	else
		jr_doctor_row warn timer 'journal-rollup.timer 未啟用 → L2 夜間層不會動'
		jr_doctor_add_fix timer '安裝並啟用夜間 timer'
		_advice=$((_advice + 1))
	fi
	if jr_has loginctl; then
		_linger=$(loginctl show-user "$USER" -p Linger 2>/dev/null | cut -d= -f2)
		if [ "$_linger" = 'yes' ]; then
			jr_doctor_row ok linger 'Linger=yes'
		else
			jr_doctor_row warn linger 'Linger=no → 登出後 timer 會被殺'
			jr_doctor_add_fix linger '開 linger（loginctl enable-linger）'
			_advice=$((_advice + 1))
		fi
	fi
	if git -C "$(jr_yaml_get "$JR_HOST_YML" data_dir /nonexistent)" remote get-url origin > /dev/null 2>&1; then
		jr_doctor_row ok remote "$(git -C "$(jr_yaml_get "$JR_HOST_YML" data_dir)" remote get-url origin)"
	else
		jr_doctor_row warn remote '資料 repo 無 origin → 只在本機，不跨機'
		_advice=$((_advice + 1))
	fi

	printf '\n  健康度：%s\n' "$(jr_agent_health)"
	printf '  %d 項必須處理，%d 項建議處理。\n\n' "$_fatal" "$_advice"
	JR_DOCTOR_FATAL=$_fatal
}

# 單項修復。「journal 自己做」的直接做；系統層的印指令。
jr_doctor_fix() {
	case $1 in
		hook)   jr_install_hook ;;
		timer)  jr_load_host 2>/dev/null; jr_install_timer ;;
		init)   jr_info '→ 跑：journal init（或 journal init --local 先離線）' ;;
		linger)
			jr_info "→ 你自己跑（系統層，journal 不碰 sudo）："
			jr_info "   loginctl enable-linger $USER"
			;;
		pkg-claude)
			jr_info '→ 你自己裝：https://claude.com/claude-code'
			;;
		pkg-*)
			_p=${1#pkg-}
			jr_info "→ 你自己裝（要 sudo，journal 不代跑）："
			jr_info "   $(jr_pkg_hint "$_p")"
			;;
	esac
}

jr_cmd_doctor() {
	_mode=interactive
	while [ $# -gt 0 ]; do
		case $1 in
			--check) _mode=check ;;
			--yes)   _mode=yes ;;
			-*)      jr_die "doctor: 未知選項 $1" ;;
		esac
		shift
	done
	# D17：非互動環境自動退到 --check —— 背景行程停下來等 Enter 是這個工具
	# 最該避免的失效模式
	[ "$_mode" = 'interactive' ] && ! jr_interactive && _mode=check

	jr_doctor_scan

	if [ "$_mode" = 'check' ]; then
		[ "$JR_DOCTOR_FATAL" -eq 0 ]
		return
	fi

	[ -s "$JR_TMPDIR/doctor.fixes" ] || { jr_info '沒有要補的，收工。'; return 0; }

	if [ "$_mode" = 'yes' ]; then
		# 只自動修 journal 自己能做的；系統層的照樣印指令
		while IFS="$(printf '\t')" read -r _fid _fdesc; do
			case $_fid in
				hook|timer) jr_info "自動修：$_fdesc"; jr_doctor_fix "$_fid" ;;
				*)          jr_doctor_fix "$_fid" ;;
			esac
		done < "$JR_TMPDIR/doctor.fixes"
	else
		printf '要現在逐項補齊嗎？[Y/n] ' >&2
		read -r _ans
		case $_ans in n|N) return 0 ;; esac
		while IFS="$(printf '\t')" read -r _fid _fdesc; do
			printf '\n· %s —— 處理？[Y/n] ' "$_fdesc" >&2
			read -r _ans < /dev/tty 2>/dev/null || _ans=Y
			case $_ans in n|N) continue ;; esac
			jr_doctor_fix "$_fid"
		done < "$JR_TMPDIR/doctor.fixes"
		jr_info ''
		jr_info '複驗：'
		jr_doctor_scan
	fi
	[ "$JR_DOCTOR_FATAL" -eq 0 ]
}

jr_sh_flavour() {
	_shpath=/bin/sh
	if jr_has readlink; then
		_real=$(readlink -f "$_shpath" 2>/dev/null || readlink "$_shpath" 2>/dev/null)
		[ -n "$_real" ] && _shpath="$_shpath ($(basename "$_real"))"
	fi
	printf '%s' "$_shpath"
}
