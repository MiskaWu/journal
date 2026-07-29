#!/bin/sh
# lib/sli.sh —— 目標 / SLI（DESIGN §12）
#
# 鐵則：**SLI 必須是「一條會回 0/非0 的指令」或「一個便宜可觀察的事實」，
# 不是形容詞。** 所有 probe 一律 read-only —— 這是慣例不是強制，寫 GOALS.md
# 的人要自律；需要密碼的標 manual，機密不進 GOALS.md。
#
# 跨機語意：probe 只在跑得動的機器上跑；requires 不滿足 → **na 不是 fail**
# （dev 機看不到 /opt/infra 不代表 infra 壞了）。每機只寫自己的
# status/<host>.yml，聚合是 aggregator 的事（P5）。

# ---------------------------------------------------------------- GOALS.md 剖析
#
# 區塊文法（<!-- --> 註解區整段跳過）：
#   - id: <slug>
#     title: <text>
#     sli: { kind: probe|file|checklist|threshold|judge|manual, cmd: "<sh>", source: <path>, target: <n> }
#     done-when: <text>
#     requires: { paths: ["/a", "/b"], reach: ["https://x"] }
#
# 輸出以 \037（ASCII US）分隔的欄位：id kind cmd source target paths reach title
# ⚠ 不能用 tab —— tab 是 IFS 的空白類字元，read 會把連續 tab 摺疊成一個
#   分隔符，空欄位（例如 checklist 沒有 cmd）會讓後面全部位移。
jr_goals_parse() {
	[ -f "$1" ] || return 0
	awk '
		function jflush() {
			if (id != "") {
				gsub(/\037/, " ", cmd); gsub(/\037/, " ", title)
				printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
					id, kind, cmd, source, target, paths, reach, title
			}
			id = ""; kind = ""; cmd = ""; source = ""; target = ""
			paths = ""; reach = ""; title = ""
		}
		# 掃出 s 裡第一個「key: "quoted"」或「key: bare」的值
		function inline_val(s, key,    i, p, out, c, e) {
			i = match(s, key "[ \t]*:")
			if (i == 0) return ""
			p = i + RLENGTH
			while (substr(s, p, 1) == " " || substr(s, p, 1) == "\t") p++
			if (substr(s, p, 1) == "\"") {
				p++; out = ""
				while (p <= length(s)) {
					c = substr(s, p, 1)
					if (c == "\\") { e = substr(s, p + 1, 1); out = out e; p += 2 }
					else if (c == "\"") break
					else { out = out c; p++ }
				}
				return out
			}
			out = ""
			while (p <= length(s)) {
				c = substr(s, p, 1)
				if (c == "," || c == "}" || c == "]") break
				out = out c; p++
			}
			sub(/[ \t]+$/, "", out)
			return out
		}
		# 收集 s 裡 key: [ "a", "b" ] 的每個引號項，逗號串接
		function inline_list(s, key,    i, p, out, item, c, e) {
			i = match(s, key "[ \t]*:[ \t]*\\[")
			if (i == 0) return ""
			p = i + RLENGTH
			out = ""
			while (p <= length(s)) {
				c = substr(s, p, 1)
				if (c == "]") break
				if (c == "\"") {
					p++; item = ""
					while (p <= length(s)) {
						c = substr(s, p, 1)
						if (c == "\\") { e = substr(s, p + 1, 1); item = item e; p += 2 }
						else if (c == "\"") break
						else { item = item c; p++ }
					}
					out = out (out == "" ? "" : ",") item
				}
				p++
			}
			return out
		}
		/<!--/ { inc = 1 }
		inc { if (/-->/) inc = 0; next }
		/^-[ \t]+id:[ \t]*/ {
			jflush()
			id = $0
			sub(/^-[ \t]+id:[ \t]*/, "", id); sub(/[ \t\r]+$/, "", id)
			next
		}
		id == "" { next }
		/^[^ \t]/ { jflush(); next }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line ~ /^title:/) {
				title = line; sub(/^title:[ \t]*/, "", title); sub(/[ \t\r]+$/, "", title)
			} else if (line ~ /^sli:/) {
				kind = inline_val(line, "kind")
				cmd = inline_val(line, "cmd")
				source = inline_val(line, "source")
				target = inline_val(line, "target")
			} else if (line ~ /^requires:/) {
				paths = inline_list(line, "paths")
				reach = inline_list(line, "reach")
			}
		}
		END { jflush() }
	' "$1"
}

# ---------------------------------------------------------------- 單項檢查
#
# 結果經由全域變數帶回（POSIX sh 沒有回傳多值的好方法）：
#   JR_SLI_STATE  pass | partial | fail | na | manual
#   JR_SLI_DETAIL 一句話（會進 status/<host>.yml 的 detail）

jr_sli_expand() {
	case $1 in
		"~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
		*)     printf '%s' "$1" ;;
	esac
}

jr_sli_set() { JR_SLI_STATE=$1; JR_SLI_DETAIL=$2; }

jr_check_goal() {
	# jr_check_goal KIND CMD SOURCE TARGET PATHS REACH
	_kind=$1; _cmd=$2; _source=$3; _tgt=$4; _paths=$5; _reach=$6

	# requires gate —— 不滿足是 na，永遠不是 fail（DESIGN §12 跨機語意）
	if [ -n "$_paths" ]; then
		_oldifs=$IFS; IFS=,
		for _p in $_paths; do
			IFS=$_oldifs
			_pe=$(jr_sli_expand "$_p")
			if [ ! -e "$_pe" ]; then
				jr_sli_set na "此機看不到 $_p"
				return 0
			fi
		done
		IFS=$_oldifs
	fi
	if [ -n "$_reach" ]; then
		if ! jr_has curl; then
			jr_sli_set na '此機無 curl，無法測 reachability'
			return 0
		fi
		_oldifs=$IFS; IFS=,
		for _u in $_reach; do
			IFS=$_oldifs
			if ! curl -fsS --max-time 5 -o /dev/null "$_u" 2>/dev/null; then
				jr_sli_set na "此機無法觸及 $_u"
				return 0
			fi
		done
		IFS=$_oldifs
	fi

	case $_kind in
		probe|file)
			[ -n "$_cmd" ] || { jr_sli_set na '缺 cmd'; return 0; }
			_out=$(jr_timeout 30 sh -c "$_cmd" < /dev/null 2>&1)
			_rc=$?
			if [ "$_rc" -eq 0 ]; then
				jr_sli_set pass 'exit 0'
			else
				_line=$(printf '%s' "$_out" | sed -n 1p | cut -c1-80)
				jr_sli_set fail "exit $_rc${_line:+：$_line}"
			fi
			;;
		checklist)
			_src=$(jr_sli_expand "$_source")
			[ -f "$_src" ] || { jr_sli_set na "找不到 $_source"; return 0; }
			_done=$(grep -c -- '- \[[xX]\]' "$_src")
			_todo=$(grep -c -- '- \[ \]' "$_src")
			_total=$((_done + _todo))
			if [ "$_total" -eq 0 ]; then
				jr_sli_set na '來源裡沒有 checklist 項目'
			elif [ "$_done" -eq "$_total" ]; then
				jr_sli_set pass "$_done/$_total"
			else
				jr_sli_set partial "$_done/$_total"
			fi
			;;
		threshold)
			[ -n "$_cmd" ] || { jr_sli_set na '缺 cmd'; return 0; }
			_v=$(jr_timeout 30 sh -c "$_cmd" < /dev/null 2>/dev/null | tr -d ' \n')
			case $_v in
				''|*[!0-9]*) jr_sli_set fail "cmd 沒吐出數字（拿到「$(printf '%s' "$_v" | cut -c1-30)」）"; return 0 ;;
			esac
			case $_tgt in
				''|*[!0-9]*) jr_sli_set na 'target 不是數字'; return 0 ;;
			esac
			if [ "$_v" -ge "$_tgt" ]; then
				jr_sli_set pass "$_v/$_tgt"
			else
				jr_sli_set partial "$_v/$_tgt"
			fi
			;;
		judge)
			jr_check_judge "$_source"
			;;
		manual)
			jr_sli_set manual '需人工驗證（含憑證，不自動跑）'
			;;
		*)
			jr_sli_set na "不認得的 kind：$_kind"
			;;
	esac
}

# judge：無 probe 可寫時的最後手段。LLM 讀證據給軟評，detail 帶 ~ 前綴
# 提醒「這是意見不是量測」。
jr_check_judge() {
	_src=$(jr_sli_expand "$1")
	[ -f "$_src" ] || { jr_sli_set na "找不到證據檔 $1"; return 0; }
	jr_has claude || { jr_sli_set na '此機無 claude，judge 跑不了'; return 0; }

	_jsys="$JR_TMPDIR/judge.sys"
	cat > "$_jsys" <<'EOF'
你是 SLI 裁決者。讀完證據後只輸出一行，格式嚴格為下列三種之一：
PASS: 十五字內的理由
PARTIAL: 十五字內的理由
FAIL: 十五字內的理由
不要輸出任何其他文字。
EOF
	_jin="$JR_TMPDIR/judge.in"
	head -c 50000 "$_src" > "$_jin"
	_jout="$JR_TMPDIR/judge.out"
	JR_CLAUDE_MODEL=$(jr_pick_model model_check)
	export JR_CLAUDE_MODEL
	if ! jr_claude_run "$_jsys" '請依據以上證據裁決這個目標的狀態。' \
		"$_jin" "$_jout" "$JR_TMPDIR/judge.err" 120; then
		jr_sli_set na 'judge 生成失敗'
		return 0
	fi
	_verdict=$(sed -n 1p "$_jout" | tr -d '\r')
	case $_verdict in
		PASS:*)    jr_sli_set pass "~${_verdict#PASS:}" ;;
		PARTIAL:*) jr_sli_set partial "~${_verdict#PARTIAL:}" ;;
		FAIL:*)    jr_sli_set fail "~${_verdict#FAIL:}" ;;
		*)         jr_sli_set na "judge 輸出不合格式：$(printf '%s' "$_verdict" | cut -c1-40)" ;;
	esac
}

# ---------------------------------------------------------------- journal check

jr_cmd_check() {
	export JOURNAL_NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
	_commit=1
	case ${1:-} in --no-commit) _commit=0 ;; esac

	jr_require_tier0 || exit 1
	jr_load_host
	jr_data_pull
	JR_REDUCER=$(jr_pick_reducer)
	export JR_REDUCER

	_goals="$JR_DATA_DIR/GOALS.md"
	if [ ! -f "$_goals" ]; then
		jr_warn "沒有 $_goals —— 先寫目標（格式見檔頭），check 沒事可做"
		return 0
	fi

	jr_goals_parse "$_goals" > "$JR_TMPDIR/goals.tsv"
	_n=$(grep -c . "$JR_TMPDIR/goals.tsv" 2>/dev/null)
	if [ "${_n:-0}" -eq 0 ]; then
		jr_warn 'GOALS.md 裡沒有任何 goal 區塊'
		return 0
	fi
	jr_log "check：$_n 個目標 @ $JR_HOST"

	_results="$JR_TMPDIR/results"
	: > "$_results"
	_worst=0
	_us=$(printf '\037')
	while IFS=$_us read -r _id _kind _cmd _source _tgt _paths _reach _title; do
		[ -n "$_id" ] || continue
		jr_check_goal "$_kind" "$_cmd" "$_source" "$_tgt" "$_paths" "$_reach"
		_d=$(printf '%s' "$JR_SLI_DETAIL" | sed 's/"/\\"/g')
		printf '  %s: { state: %s, kind: %s, detail: "%s" }\n' \
			"$_id" "$JR_SLI_STATE" "${_kind:-?}" "$_d" >> "$_results"
		case $JR_SLI_STATE in
			pass)    jr_ok  "$_id  pass  $JR_SLI_DETAIL" ;;
			partial) jr_warn "$_id  partial  $JR_SLI_DETAIL" ;;
			fail)    jr_err "$_id  fail  $JR_SLI_DETAIL"; _worst=1 ;;
			na)      jr_log "$_id  na  $JR_SLI_DETAIL" ;;
			manual)  jr_log "$_id  manual  $JR_SLI_DETAIL" ;;
		esac
	done < "$JR_TMPDIR/goals.tsv"

	# 只寫自己 host 命名的檔 —— per-host 檔名永不衝突（DESIGN §7 權責 1）
	mkdir -p "$JR_DATA_DIR/status"
	jr_write_atomic "$JR_DATA_DIR/status/$JR_HOST.yml" <<EOF
host: $JR_HOST
checked_at: $(jr_now_iso)
agent_health: $(jr_agent_health)
degraded_reason: "$(jr_degraded_reason)"
results:
$(cat "$_results")
EOF
	jr_ok "寫入 status/$JR_HOST.yml"
	jr_update_host_yml

	[ "$_commit" -eq 1 ] && jr_git_commit_data "journal: check @ $JR_HOST"
	return "$_worst"
}
