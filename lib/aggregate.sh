#!/bin/sh
# lib/aggregate.sh —— L3 中心層：aggregate / trace / digest
#
# 中心真正稀缺的是「唯一的聚合權責」，不是一顆 DB（D6）。**只有 aggregator
# 能寫 progress.md** —— 否則看不見 infra 服務的機器會把真實結果覆蓋成 na
# （§7 那個真 bug）。合成規則：每個 goal 取所有 host 中**最新的非 na** 結果；
# 全部 na → 標 unchecked，**不得誤報成 fail**。

# ---------------------------------------------------------------- 收集器

# status/*.yml → 一行一結果：host US checked_at US id US state US kind US detail
jr_collect_status() {
	for f in "$JR_DATA_DIR"/status/*.yml; do
		[ -f "$f" ] || continue
		awk '
			/^host:/       { host = $2 }
			/^checked_at:/ { ts = $2 }
			/^  [A-Za-z0-9_-]+: \{/ {
				line = $0
				sub(/^  /, "", line)
				id = line; sub(/:.*/, "", id)
				state = line; sub(/.*state:[ \t]*/, "", state); sub(/[,}].*/, "", state)
				kind = line
				if (sub(/.*kind:[ \t]*/, "", kind)) sub(/[,}].*/, "", kind); else kind = "?"
				detail = ""
				if (match(line, /detail:[ \t]*"/)) {
					detail = substr(line, RSTART + RLENGTH)
					sub(/".*$/, "", detail)
				}
				gsub(/\037/, " ", detail)
				printf "%s\037%s\037%s\037%s\037%s\037%s\n", host, ts, id, state, kind, detail
			}' "$f"
	done
}

# hosts/*.yml → host US roles US health US reason US last_seen US retired
jr_collect_hosts() {
	for f in "$JR_DATA_DIR"/hosts/*.yml; do
		[ -f "$f" ] || continue
		_h=$(jr_yaml_get "$f" host); [ -n "$_h" ] || continue
		printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
			"$_h" "$(jr_yaml_get "$f" roles '[node]')" \
			"$(jr_yaml_get "$f" agent_health '?')" \
			"$(jr_yaml_get "$f" degraded_reason '')" \
			"$(jr_yaml_get "$f" last_seen '')" \
			"$(jr_yaml_get "$f" retired '')"
	done
}

# 每個 goal 的優勝結果：**最新的非 na**。全 na → unchecked。
# 輸出：id US state US detail US host US checked_at
jr_goal_winners() {
	jr_collect_status | awk -F'\037' '
		{
			id = $3
			seen[id] = 1
			if ($4 == "na") {
				# na 只當「有人跑過但跑不了」的證據，永遠選不上
				if (!(id in na_d)) { na_d[id] = $6 }
				next
			}
			if ($2 > best_ts[id]) {
				best_ts[id] = $2; best_state[id] = $4
				best_detail[id] = $6; best_host[id] = $1
			}
		}
		END {
			for (id in seen) {
				if (id in best_state)
					printf "%s\037%s\037%s\037%s\037%s\n", id, best_state[id], best_detail[id], best_host[id], best_ts[id]
				else
					printf "%s\037unchecked\037全部 host 皆 na（%s）\037-\037-\n", id, na_d[id]
			}
		}' | sort
}

# 每個 goal 最後一次在 daily 的 goals_touched 出現的日期（goal staleness 用）
jr_goal_last_touched() {
	for f in "$JR_DATA_DIR"/daily/*.md; do
		[ -f "$f" ] || continue
		_d=$(jr_fm_get "$f" date)
		_g=$(jr_fm_get "$f" goals_touched | tr -d '[]' )
		[ -n "$_g" ] || continue
		printf '%s' "$_g" | tr ',' '\n' | while IFS= read -r g; do
			g=$(printf '%s' "$g" | sed 's/^ *//; s/ *$//')
			[ -n "$g" ] && printf '%s\037%s\n' "$g" "$_d"
		done
	done | sort | awk -F'\037' '{ last[$1] = $2 } END { for (g in last) printf "%s\037%s\n", g, last[g] }'
}

jr_state_icon() {
	case $1 in
		pass) printf '🟢' ;;
		partial) printf '🟡' ;;
		fail) printf '🔴' ;;
		unchecked) printf '⚪' ;;
		manual) printf '🔵' ;;
		*) printf '⚫' ;;
	esac
}

# ---------------------------------------------------------------- aggregate

jr_build_progress() {
	# 印出 progress.md 內容到 stdout
	_today=$(jr_today)
	_stale_days=$(jr_yaml_get "$JR_CONFIG_YML" stale_days 3)
	_goal_stale=$(jr_yaml_get "$JR_CONFIG_YML" goal_stale_days 7)

	jr_goal_winners > "$JR_TMPDIR/winners"
	jr_collect_hosts > "$JR_TMPDIR/hostrows"
	jr_goal_last_touched > "$JR_TMPDIR/touched"
	jr_goals_parse "$JR_DATA_DIR/GOALS.md" > "$JR_TMPDIR/goaldefs" 2>/dev/null || true

	printf '# progress\n\n'
	printf '> 產生於 %s，由 %s 聚合。真相在各 daily 與 status/，這裡只是導航。\n\n' \
		"$(jr_now_iso)" "$JR_HOST"

	# ---- 三種 alert，分開列（§5：goal staleness / host staleness / agent unhealthy）
	_alerts="$JR_TMPDIR/alerts"
	: > "$_alerts"
	_us=$(printf '\037')

	while IFS=$_us read -r _h _roles _health _reason _seen _retired; do
		[ -n "$_retired" ] && continue
		_seen_d=$(printf '%s' "$_seen" | cut -c1-10)
		if [ -n "$_seen_d" ]; then
			_gap=$(jr_days_between "$_seen_d" "$_today")
			[ "$_gap" -gt "$_stale_days" ] && \
				printf -- '- ⚫ **%s 沉默 %s 天**（last_seen %s）—— 機器關著？agent 死了？\n' \
					"$_h" "$_gap" "$_seen_d" >> "$_alerts"
		fi
		case $_health in
			fail)     printf -- '- 🔴 **%s 不健康**：%s\n' "$_h" "${_reason:-無原因}" >> "$_alerts" ;;
			degraded) printf -- '- 🟡 %s 降級運行：%s\n' "$_h" "${_reason:-無原因}" >> "$_alerts" ;;
		esac
	done < "$JR_TMPDIR/hostrows"

	while IFS=$_us read -r _id _state _detail _host _ts; do
		case $_state in pass|manual) continue ;; esac
		_last=$(awk -F'\037' -v g="$_id" '$1 == g { print $2 }' "$JR_TMPDIR/touched")
		if [ -n "$_last" ]; then
			_gap=$(jr_days_between "$_last" "$_today")
			[ "$_gap" -gt "$_goal_stale" ] && \
				printf -- '- 🕳 目標 **%s** 已 %s 天沒動（最後出現 %s，狀態 %s）\n' \
					"$_id" "$_gap" "$_last" "$_state" >> "$_alerts"
		fi
	done < "$JR_TMPDIR/winners"
	grep -F 'state: fail' "$JR_DATA_DIR"/status/*.yml > /dev/null 2>&1 && \
		awk -F'\037' '$2 == "fail" { printf "- 🔴 目標 **%s** fail：%s（%s 量測）\n", $1, $3, $4 }' \
			"$JR_TMPDIR/winners" >> "$_alerts"

	printf '## 需要注意\n\n'
	if [ -s "$_alerts" ]; then
		sort -u "$_alerts"
	else
		printf '（都好，沒有紅燈）\n'
	fi

	# ---- 目標總表
	printf '\n## 目標\n\n'
	printf '| 燈 | 目標 | 進度 | 由誰量 | 何時 |\n|---|---|---|---|---|\n'
	while IFS=$_us read -r _id _state _detail _host _ts; do
		_title=$(awk -F'\037' -v g="$_id" '$1 == g { print $8; exit }' "$JR_TMPDIR/goaldefs")
		printf '| %s %s | **%s**%s | %s | %s | %s |\n' \
			"$(jr_state_icon "$_state")" "$_state" "$_id" \
			"${_title:+ —— $_title}" "${_detail:--}" "$_host" "$(printf '%s' "$_ts" | cut -c1-16)"
	done < "$JR_TMPDIR/winners"

	# ---- 機器
	printf '\n## 機器\n\n| host | 角色 | 健康 | last_seen |\n|---|---|---|---|\n'
	while IFS=$_us read -r _h _roles _health _reason _seen _retired; do
		_note=''
		[ -n "$_retired" ] && _note="（retired $_retired）"
		printf '| %s%s | %s | %s | %s |\n' "$_h" "$_note" "$_roles" "$_health" "$_seen"
	done < "$JR_TMPDIR/hostrows"

	# ---- 最近七天的早會（回憶的入口）
	printf '\n## 最近 7 天\n'
	_i=0
	while [ $_i -lt 7 ]; do
		_d=$(jr_date_shift "$_today" "-$_i")
		_i=$((_i + 1))
		_any=0
		for f in "$JR_DATA_DIR"/daily/${_d}__*.md; do
			[ -f "$f" ] || continue
			_h=$(jr_fm_get "$f" host)
			_lines=$(awk '/^## 早會/ { s = 1; next } /^## / { s = 0 } s && /^- /' "$f")
			[ -n "$_lines" ] || continue
			[ "$_any" -eq 0 ] && { printf '\n### %s\n' "$_d"; _any=1; }
			printf '%s\n' "$_lines" | sed "s/^- /- （$_h）/"
		done
	done
}

jr_cmd_aggregate() {
	export JOURNAL_NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
	_preview=0
	case ${1:-} in --preview) _preview=1 ;; esac

	jr_require_tier0 || exit 1
	jr_load_host
	jr_data_pull

	if [ "$_preview" -eq 1 ]; then
		jr_build_progress
		return 0
	fi

	# 權責規則 2：非 aggregator 絕不寫 progress.md（會用「看不見的機器」蓋掉真實結果）
	if [ "${JR_ROLE:-node}" != 'aggregator' ]; then
		jr_err "這台是 ${JR_ROLE:-node}，不是 aggregator —— 不寫 progress.md（DESIGN §7 規則 2）"
		jr_info '想看合成結果：journal aggregate --preview（只印不寫）'
		jr_info '要指派這台：journal init --role aggregator（已有聚合者需 --force-takeover）'
		return 1
	fi

	jr_build_progress > "$JR_TMPDIR/progress.md"
	jr_write_atomic "$JR_DATA_DIR/progress.md" < "$JR_TMPDIR/progress.md"
	jr_ok "寫入 progress.md"
	jr_cmd_render --no-commit
	jr_update_host_yml
	jr_git_commit_data "journal: aggregate @ $JR_HOST"
}

# ---------------------------------------------------------------- trace

# 一個目標的整條推進線：trace_id = goal id，靠 daily 的 goals_touched 推斷
# 串起來（§5：掛接是模型推斷，trace 只當導覽、不當證據）。
jr_cmd_trace() {
	_goal=${1:-}
	[ -n "$_goal" ] || jr_die 'trace: 要 goal id（journal check 或 GOALS.md 可查）'
	jr_load_host

	_found=0
	for f in "$JR_DATA_DIR"/daily/*.md; do
		[ -f "$f" ] || continue
		jr_fm_get "$f" goals_touched | grep -qF "$_goal" || continue
		_d=$(jr_fm_get "$f" date)
		_h=$(jr_fm_get "$f" host)
		printf '%s── %s @ %s ──%s\n' "$JR_C_DIM" "$_d" "$_h" "$JR_C_OFF"
		# 摘要裡專案或標籤吻合的條目；沒有就至少給早會第一行
		_hits=$(awk -F'[ \t]*\\|[ \t]*' -v g="$_goal" '
			/^## 摘要/ { s = 1; next } /^## / { s = 0 }
			s && /^- / { line = $0; sub(/^- /, "", line)
				if (index($1, g) || index($3, g)) { print "  " line; n++ } }
			END { exit n == 0 }' "$f") && printf '%s\n' "$_hits" || \
			awk '/^## 早會/ { s = 1; next } /^## / { s = 0 }
				s && /^- / { sub(/^- /, "  （早會）"); print; exit }' "$f"
		_found=1
	done
	[ "$_found" -eq 1 ] || jr_warn "沒有任何 daily 的 goals_touched 提到「$_goal」"
}

# ---------------------------------------------------------------- digest

jr_digest_sys() {
	cat <<'EOF'
你替使用者把一週的每日工作日誌整併成週報。輸入是各天各機器的早會與摘要段。
規則：繁體中文；只寫發生的事；跨天重複出現的主題合併成一條進展線；
不抄機密；不要開場白結語。
EOF
}

jr_cmd_digest() {
	export JOURNAL_NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
	jr_require_tier0 --need-claude || exit 1
	jr_load_host
	_week=${1:-$(jr_iso_week "$(jr_today)")}
	case $_week in
		[0-9][0-9][0-9][0-9]-W[0-9][0-9]) ;;
		*) jr_die "週格式要 YYYY-Www，收到：$_week" ;;
	esac

	# 找出該週的七天：從週字串反推 —— 掃當年頭到尾太笨，直接用「該週週四」法
	_y=${_week%%-W*}
	_w=${_week##*-W}
	_jan4="${_y}-01-04"
	_mon1=$(jr_week_dates "$_jan4" | sed -n 1p)
	_mon=$(jr_date_shift "$_mon1" "$(( (_w - 1) * 7 ))")

	_material="$JR_TMPDIR/digest.material"
	: > "$_material"
	_i=0
	_days=0
	while [ $_i -lt 7 ]; do
		_d=$(jr_date_shift "$_mon" "$_i")
		_i=$((_i + 1))
		for f in "$JR_DATA_DIR"/daily/${_d}__*.md; do
			[ -f "$f" ] || continue
			printf '# %s @ %s\n' "$_d" "$(jr_fm_get "$f" host)" >> "$_material"
			awk '/^## (早會|摘要)/ { s = 1 } /^## (完成|拍板|待續|卡住)/ { s = 0 } s' "$f" >> "$_material"
			printf '\n' >> "$_material"
			_days=$((_days + 1))
		done
	done
	[ -s "$_material" ] || { jr_warn "$_week（$_mon 起）沒有任何 daily"; return 1; }

	_sys="$JR_TMPDIR/digest.sys"
	jr_digest_sys > "$_sys"
	_out="$JR_TMPDIR/digest.out"
	JR_CLAUDE_MODEL=$(jr_pick_model model_rollup)
	export JR_CLAUDE_MODEL
	_prompt="以上是 $_week（$_mon 起）共 $_days 份日誌。請輸出週報，格式：
## 本週主線
- 每條主題一行：這週從哪推進到哪
## 拍板
- 本週的關鍵決策
## 未解
- 週末仍卡著或沒收尾的"
	if ! jr_claude_run "$_sys" "$_prompt" "$_material" "$_out" "$JR_TMPDIR/digest.err" "$(jr_claude_timeout)"; then
		jr_err '週報生成失敗'
		return 1
	fi
	jr_redact_guard "$_out" > /dev/null

	mkdir -p "$JR_DATA_DIR/weekly"
	_wf="$JR_DATA_DIR/weekly/$_week.md"
	{
		printf -- '---\nweek: %s\nweek_start: %s\ngenerated_at: %s\nby: %s\n---\n' \
			"$_week" "$_mon" "$(jr_now_iso)" "$JR_HOST"
		cat "$_out"
	} > "$_wf"
	jr_ok "寫入 $_wf"
	git -C "$JR_DATA_DIR" add weekly 2>/dev/null
	jr_git_commit_data "journal: digest $_week @ $JR_HOST"
	cat "$_wf"
}
