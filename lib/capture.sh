#!/bin/sh
# lib/capture.sh —— L1 即時層：單一 session 蒸餾 → gate → append → commit
#
# L1 保「不丟」：WSL2 上排程可能整天不觸發（機器關著），SessionEnd hook
# 是唯一保證「資料產生的那一刻就有人在」的觸發點 —— 你在用電腦，它才會響。
#
# 失效語意（DESIGN §10 fail-soft 矩陣）：這裡的任何失敗都只留下
# captured:false，當晚 L2 rollup 重讀原始 transcript 自動補回。
# 所以本檔到處都是「安靜地放棄」—— 那不是偷懶，是設計。

: "${JR_CAPTURE_MIN:=150}"

# ---------------------------------------------------------------- payload

# jr_payload_field FILE KEY —— 從 hook 的 JSON payload 撈頂層字串欄位
jr_payload_field() {
	awk -v k="$2" '
		{
			pat = "\"" k "\":\""
			i = index($0, pat)
			if (i == 0) next
			s = substr($0, i + length(pat))
			out = ""
			for (p = 1; p <= length(s); p++) {
				c = substr(s, p, 1)
				if (c == "\\") { out = out substr(s, p + 1, 1); p++ }
				else if (c == "\"") break
				else out = out c
			}
			print out
			exit
		}' "$1"
}

# ---------------------------------------------------------------- spool

jr_spool_path() { printf '%s/%s__%s.jsonl' "$JR_SPOOL" "$1" "$JR_HOST"; }

jr_spool_append() {
	# jr_spool_append DATE SESSION TRANSCRIPT CWD BRANCH
	mkdir -p "$JR_SPOOL"
	printf '{"session":"%s","transcript":"%s","cwd":"%s","branch":"%s","ended":"%s","captured":false}\n' \
		"$2" "$3" "$4" "$5" "$(jr_now_iso)" >> "$(jr_spool_path "$1")"
}

jr_spool_has_captured() {
	# 同一個 session 只捕捉一次（resume/clear 可能讓同一天多次觸發同 id）
	_sf=$(jr_spool_path "$1")
	[ -f "$_sf" ] && grep -F "\"session\":\"$2\"" "$_sf" | grep -qF '"captured":true'
}

jr_spool_has_line() {
	_sf=$(jr_spool_path "$1")
	[ -f "$_sf" ] && grep -qF "\"session\":\"$2\"" "$_sf"
}

jr_spool_mark() {
	# jr_spool_mark DATE SESSION —— 把該 session 的行標成 captured:true
	_sf=$(jr_spool_path "$1")
	[ -f "$_sf" ] || return 0
	awk -v s="$2" '
		index($0, "\"session\":\"" s "\"") > 0 { gsub(/"captured":false/, "\"captured\":true") }
		{ print }' "$_sf" > "$_sf.tmp.$$" && mv -f "$_sf.tmp.$$" "$_sf"
}

jr_spool_mark_all() {
	# rollup 定稿後全標 captured —— L2 重讀過原始資料，L1 沒做完的也被涵蓋了
	_sf=$(jr_spool_path "$1")
	[ -f "$_sf" ] || return 0
	awk '{ gsub(/"captured":false/, "\"captured\":true"); print }' "$_sf" \
		> "$_sf.tmp.$$" && mv -f "$_sf.tmp.$$" "$_sf"
}

# ---------------------------------------------------------------- 蒸餾（單 session）

jr_capture_sys() {
	cat <<'EOF'
你替使用者記錄一個剛結束的 Claude Code session。輸出是給日誌的即時碎片，
晚上會被完整的整併覆寫 —— 所以求快求真，不求完整。

規則：繁體中文；只寫發生的事；具體（專案、檔案、決定）；
**絕對不要抄任何機密**（token、密碼、金鑰、連線字串）；
不要開場白、不要結語、不要標題。
EOF
}

jr_capture_prompt() {
	cat <<'EOF'
以下是這個 session 的減量紀錄。輸出 1 到 4 行，每行以「- 」開頭：
做成了什麼、拍板了什麼、卡在哪。沒發生的類別不要寫。
EOF
}

# ---------------------------------------------------------------- 主流程

jr_cmd_capture() {
	# 背景路徑：絕不互動（D17），git 也不准停下來問密碼
	export JOURNAL_NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0

	_session=''; _transcript=''; _cwd=''; _from_hook=0
	case ${1:-} in
		--hook)
			_from_hook=1
			_pf="$JR_TMPDIR/payload.json"
			cat > "$_pf" 2>/dev/null
			[ -s "$_pf" ] || exit 0
			_session=$(jr_payload_field "$_pf" session_id)
			_transcript=$(jr_payload_field "$_pf" transcript_path)
			_cwd=$(jr_payload_field "$_pf" cwd)
			;;
		'')
			jr_die 'capture: 要 session id 或 --hook'
			;;
		*)
			_session=$1
			;;
	esac

	jr_require_tier0 --need-claude || exit 1
	jr_load_host
	JR_REDUCER=$(jr_pick_reducer)
	export JR_REDUCER
	_date=$(jr_today)

	[ -n "$_session" ] || exit 0

	# 找 transcript：payload 給的優先，缺了退回 glob（DESIGN §13 步驟 2）
	if [ ! -f "$_transcript" ]; then
		_transcript=$(find "$JR_PROJECTS_DIR" -name "$_session.jsonl" 2>/dev/null | head -1)
	fi
	[ -f "$_transcript" ] || { jr_debug "找不到 transcript：$_session"; exit 0; }
	[ -n "$_cwd" ] || _cwd=$(jr_first_cwd "$_transcript")

	# 同 session 已捕捉過就不重做（冪等）
	if jr_spool_has_captured "$_date" "$_session"; then
		jr_debug "session $_session 已捕捉過"
		exit 0
	fi

	# spool 一個 session 只留一行 —— 重試（上次拿不到鎖）不重複 append
	if ! jr_spool_has_line "$_date" "$_session"; then
		_branch=''
		[ -n "$_cwd" ] && [ -d "$_cwd" ] && _branch=$(git -C "$_cwd" branch --show-current 2>/dev/null)
		jr_spool_append "$_date" "$_session" "$_transcript" "$_cwd" "$_branch"
	fi

	# 減量：只切當天的窗（跨夜 session 昨天的部分由昨天的 rollup 收）
	_win=$(jr_day_window "$_date")
	_slug=$(basename "$(dirname "$_transcript")")
	_project=$(jr_project_of "$_slug" "$_cwd")
	_material="$JR_TMPDIR/capture.material"
	jr_reduce_file "$_transcript" "$_project" "$(printf '%s' "$_session" | cut -c1-8)" \
		"${_win%% *}" "${_win##* }" > "$_material" 2>/dev/null

	_size=$(wc -c < "$_material" | tr -d ' ')
	if [ "$_size" -lt "$JR_CAPTURE_MIN" ]; then
		# 太小的 session（打個招呼、開錯視窗）不值得一次 claude 呼叫
		jr_debug "素材只有 ${_size} bytes（< $JR_CAPTURE_MIN），跳過蒸餾"
		jr_spool_mark "$_date" "$_session"
		exit 0
	fi

	# 鎖：等 8 秒拿不到就放棄 —— L2 或下一次 capture 會補（fail-soft）
	if ! jr_lock_acquire rollup 8; then
		jr_log 'capture: 拿不到鎖，留給 L2 補刷'
		exit 0
	fi

	_sys="$JR_TMPDIR/capture.sys"
	jr_capture_sys > "$_sys"
	_out="$JR_TMPDIR/capture.out"
	_err="$JR_TMPDIR/capture.err"
	_timeout=${JR_CAPTURE_TIMEOUT:-180}

	if ! jr_claude_run "$_sys" "$(jr_capture_prompt)" "$_material" "$_out" "$_err" "$_timeout"; then
		jr_err "capture: 蒸餾失敗（session $_session）—— 留給 L2"
		jr_lock_release
		exit 1
	fi

	# 機密 gate —— L1 會 push，遠端收過就洗不掉（DESIGN §13）
	jr_redact_guard "$_out" > /dev/null

	_daily=$(jr_daily_path "$_date")
	_time=$(date +%H:%M)
	if [ ! -f "$_daily" ]; then
		_n=$(wc -l < "$(jr_spool_path "$_date")" 2>/dev/null | tr -d ' ')
		{
			jr_fm_write "$_date" "$JR_HOST" "${_n:-1}" 0 0 '' capture "$JR_REDUCER" 0
			printf '> L1 即時碎片 —— 今晚的 rollup 會整併覆寫本檔。\n'
		} > "$_daily"
	fi
	{
		printf '\n#### [L1 %s] %s · %s\n' "$_time" "$_project" "$(printf '%s' "$_session" | cut -c1-8)"
		cat "$_out"
	} >> "$_daily"

	jr_spool_mark "$_date" "$_session"
	jr_update_host_yml
	jr_lock_release

	jr_git_commit_data "journal: capture $(printf '%s' "$_session" | cut -c1-8) @ $JR_HOST"
	jr_ok "capture $_session → $_daily"
}
