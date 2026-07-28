#!/bin/sh
# lib/distill.sh —— 呼叫本機 claude 做語意蒸餾
#
# 這是整條管線裡唯一的「聚合函數」。業界那層是 sum/count，我們這層是 LLM —— 也
# 就是壓縮比 1900:1 而不是 100:1 的原因（DESIGN §5）。
#
# ⚠ 旗標會隨 Claude Code 版本變。這裡一律先探測 `claude --help` 再決定要不要帶，
#   版本一改是「少一個旗標」而不是「整條管線爆掉」。

# 素材上限。實測忙碌的一天（30 個 session、26 個 commit）減量後約 450 KB ≈ 120k
# token，還塞得進 context；設 500 KB 是留給輸出的餘裕，不是省錢。超過就掐頭留尾
# 並留記號 —— 寧可明講截斷，也不要默默丟資料。
: "${JR_MAXMATERIAL:=500000}"

# 逾時優先序：環境變數 > config.yml > 300
jr_claude_timeout() {
	if [ -n "${JR_CLAUDE_TIMEOUT:-}" ]; then printf '%s' "$JR_CLAUDE_TIMEOUT"; return 0; fi
	_t=$(jr_yaml_get "${JR_CONFIG_YML:-}" claude_timeout 300)
	case $_t in
		''|*[!0-9]*) _t=300 ;;
	esac
	printf '%s' "$_t"
}

# 旗標策略：try-then-degrade，不是 probe-then-guess。
#
# 一開始是拿 `claude --help` 探測旗標存在與否，實測踩到雷 —— 同一台機器上
# `claude --help` 偶爾會吐出截短版，探測就整組誤判成「不支援」，於是
# --no-session-persistence 沒帶上，蒸餾自己留下一份 transcript，明天的 rollup
# 又把它讀進來。改成直接帶上完整旗標去跑：參數解析在任何 API 呼叫**之前**就會
# 失敗，所以退化的代價只是一次立即失敗，不是一次白花的生成。
#
# full 模式帶的旗標：
#   --tools ""                 不需要工具；它只該讀 stdin 然後寫字
#   --no-session-persistence   ★ 缺了會出事：蒸餾本身會留下一份 transcript，
#                              明天的 rollup 就把它當素材讀進來，愈滾愈大
#   --safe-mode                關掉 CLAUDE.md / skills / plugins / hooks / MCP。
#                              除了讓輸出穩定，也是 P2 的前置 —— SessionEnd hook
#                              裡再叫起 claude 而不關 hook，就是遞迴
jr_claude_try() {
	# jr_claude_try MODE TIMEOUT SYSFILE PROMPT INFILE OUTFILE ERRFILE
	_mode=$1; _to=$2; _sysf=$3; _pr=$4; _in=$5; _o=$6; _e=$7
	set -- -p --output-format text
	if [ "$_mode" = 'full' ]; then
		set -- "$@" --tools '' --no-session-persistence --safe-mode \
			--system-prompt "$(cat "$_sysf")"
	else
		# 連 --system-prompt 都不敢假設，直接併進使用者訊息
		_pr="$(cat "$_sysf")

$_pr"
	fi
	jr_timeout "$_to" claude "$@" "$_pr" < "$_in" > "$_o" 2>"$_e"
}

# 這次失敗是「旗標不認得」還是別的？只有前者值得退化重試。
jr_flag_rejected() {
	[ -s "$1" ] || return 1
	grep -qi -e 'unknown option' -e 'unknown argument' -e "error: option" -e 'Usage:' "$1"
}

jr_system_prompt() {
	cat <<'EOF'
你是一位替使用者整理「今天做了什麼」的紀錄者。輸入是當日 Claude Code session
的減量紀錄與 git commit。你的工作是蒸餾，不是評論、不是稱讚、不是建議。

規則：
- 用繁體中文。
- 寫「發生了什麼」，不要寫「你做得很好」。
- 具體：指名專案、檔案、決策內容。能附 commit 短雜湊就附。
- 沒發生的事不要編。某個段落沒有內容就留空標題，不要填充。
- **絕對不要抄任何機密**：token、密碼、金鑰、連線字串一律不得出現，
  必要時寫「（機密已略）」。
- 不要輸出 frontmatter、不要用程式碼區塊包住整份輸出、不要加開場白或結語。
EOF
}

jr_user_prompt() {
	cat <<EOF
以下是 $1 這一天、在主機 $2 上的活動素材。

請只輸出這個格式，不多不少：

goals_touched: 用逗號分隔的短代號，取自當天實際碰到的專案或主題，最多 5 個
## 完成
- 當天真正做完、可驗證的事（一行一件，附 commit 短雜湊）
## 拍板
- 當天做出的決定與其理由（沒有就留空）
## 待續
- 已經開頭但沒結束的事，以及下一步是什麼
## 卡住
- 卡住的點與卡在哪（沒有就留空）
EOF
}

# jr_distill DATE HOST MATERIAL_FILE OUTFILE —— 成功回 0；失敗回非 0 且 OUTFILE 為空
jr_distill() {
	_date=$1; _host=$2; _material=$3; _out=$4

	if [ ! -s "$_material" ]; then
		jr_debug '素材是空的，不呼叫 claude'
		return 1
	fi

	# 素材上限：超過就掐頭留尾，並在接縫留記號，免得默默丟資料
	_size=$(wc -c < "$_material" | tr -d ' ')
	_input="$JR_TMPDIR/material.in"
	if [ "$_size" -gt "$JR_MAXMATERIAL" ]; then
		jr_warn "素材 ${_size} bytes 超過上限 ${JR_MAXMATERIAL}，將截斷"
		{
			head -c $((JR_MAXMATERIAL / 2)) "$_material"
			printf '\n\n…（素材過大，中間省略）…\n\n'
			tail -c $((JR_MAXMATERIAL / 2)) "$_material"
		} > "$_input"
	else
		cp "$_material" "$_input"
	fi

	_sys="$JR_TMPDIR/system.txt"
	jr_system_prompt > "$_sys"

	_prompt=$(jr_user_prompt "$_date" "$_host")
	_err="$JR_TMPDIR/claude.err"
	_timeout=$(jr_claude_timeout)
	jr_debug "蒸餾：逾時 ${_timeout}s、素材 $(wc -c < "$_input" | tr -d ' ') bytes"

	if jr_claude_try full "$_timeout" "$_sys" "$_prompt" "$_input" "$_out" "$_err"; then
		[ -s "$_out" ] && return 0
		jr_err 'claude 回了空字串'
		: > "$_out"
		return 1
	fi
	_rc=$?

	if [ "$_rc" -eq 124 ]; then
		jr_err "claude 逾時（${_timeout}s）"
	elif jr_flag_rejected "$_err"; then
		jr_warn "這個 claude 版本不吃某個旗標，退到最小旗標重試（$(sed -n 1p "$_err")）"
		if jr_claude_try bare "$_timeout" "$_sys" "$_prompt" "$_input" "$_out" "$_err"; then
			[ -s "$_out" ] && { jr_warn '已用最小旗標完成 —— 注意：蒸餾這次會留下自己的 transcript'; return 0; }
		fi
		jr_err '最小旗標也失敗'
	else
		jr_err "claude 失敗（exit $_rc）"
	fi
	[ -s "$_err" ] && sed -n '1,10p' "$_err" >&2
	: > "$_out"
	return 1
}

# jr_parse_distilled INFILE —— 從模型輸出撈出 goals_touched（印到 stdout）
jr_parse_goals() {
	awk '
		/^goals_touched:/ {
			v = $0
			sub(/^goals_touched:[ \t]*/, "", v)
			gsub(/[][]/, "", v)
			sub(/[ \t\r]+$/, "", v)
			print v
			exit
		}' "$1" 2>/dev/null
}

# jr_strip_goals INFILE —— 去掉 goals_touched 行與開頭空白，只留四段內文
jr_strip_goals() {
	awk '
		/^goals_touched:/ && !seen { seen = 1; next }
		!started && $0 ~ /^[ \t]*$/ { next }
		{ started = 1; print }
	' "$1" 2>/dev/null
}
