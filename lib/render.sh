#!/bin/sh
# lib/render.sh —— 檢視面：資料 → web/progress.html（自足靜態頁）
#
# 掛在既有邊緣 Caddy 底下的那一頁（§7 檢視面）。零外部資源、零 JS 依賴的
# 靜態 HTML —— 它是衍生產物，真相永遠在 markdown 與 yml 裡。
#
# O9（可控旋鈕）走「零新服務」路徑：檢視類旋鈕根本不存在於這頁（它是靜態的），
# 生成類旋鈕列出目前值 + 直連 git provider 的 config.yml 編輯頁 ——
# 改完 commit，各機下一輪 pull 就生效。不架任何寫入端點，不違鐵律 4。

jr_html_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

jr_state_css() {
	case $1 in
		pass) printf 'ok' ;;
		partial) printf 'warn' ;;
		fail) printf 'bad' ;;
		manual) printf 'info' ;;
		*) printf 'mute' ;;
	esac
}

# origin URL → provider 網頁編輯連結（推不出來就空字串，區塊直接不顯示）
jr_config_edit_url() {
	_u=$(git -C "$JR_DATA_DIR" remote get-url origin 2>/dev/null)
	_b=$(git -C "$JR_DATA_DIR" branch --show-current 2>/dev/null)
	case $_u in
		git@*github.com:*)
			_path=${_u##*github.com:}; _path=${_path%.git}
			printf 'https://github.com/%s/edit/%s/config.yml' "$_path" "${_b:-main}" ;;
		https://github.com/*)
			_path=${_u#https://github.com/}; _path=${_path%.git}
			printf 'https://github.com/%s/edit/%s/config.yml' "$_path" "${_b:-main}" ;;
		git@*gitlab.com:*)
			_path=${_u##*gitlab.com:}; _path=${_path%.git}
			printf 'https://gitlab.com/%s/-/edit/%s/config.yml' "$_path" "${_b:-main}" ;;
		*) printf '' ;;
	esac
}

jr_cmd_render() {
	_commit=1
	case ${1:-} in --no-commit) _commit=0 ;; esac
	[ -n "${JR_HOST:-}" ] || jr_load_host

	jr_goal_winners > "$JR_TMPDIR/r.winners"
	jr_collect_hosts > "$JR_TMPDIR/r.hosts"
	jr_goals_parse "$JR_DATA_DIR/GOALS.md" > "$JR_TMPDIR/r.defs" 2>/dev/null || true
	_edit=$(jr_config_edit_url)
	_today=$(jr_today)
	_us=$(printf '\037')

	mkdir -p "$JR_DATA_DIR/web"
	{
	cat <<'HTMLHEAD'
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>journal · progress</title>
<style>
:root { --paper:#F6F7F3; --panel:#FDFDFB; --ink:#232820; --muted:#6C7365;
	--line:#DFE3D6; --accent:#35684A; --soft:#E3ECE4;
	--ok:#35684A; --warn:#8A6B33; --bad:#96453D; --info:#4A5880; --mute:#9AA090; }
@media (prefers-color-scheme: dark) {
	:root { --paper:#171A15; --panel:#1E221C; --ink:#E1E5DA; --muted:#98A08E;
		--line:#2E332A; --accent:#82B394; --soft:#24352B;
		--ok:#82B394; --warn:#CBA65E; --bad:#D08A80; --info:#9FAED4; --mute:#6E7565; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--paper); color:var(--ink); line-height:1.75;
	font: 15px/1.75 "Noto Sans TC","PingFang TC","Microsoft JhengHei",system-ui,sans-serif; }
.wrap { max-width: 880px; margin: 0 auto; padding: 24px 20px 80px; }
h1 { font-size:1.4rem; border-bottom:1px solid var(--line); padding-bottom:12px; }
h1 small { color:var(--muted); font-weight:400; font-size:.75rem; margin-left:10px; }
h2 { font-size:.95rem; letter-spacing:.1em; color:var(--accent); margin:30px 0 10px; }
table { border-collapse:collapse; width:100%; background:var(--panel);
	border:1px solid var(--line); border-radius:8px; overflow:hidden; font-size:.9rem; }
th,td { text-align:left; padding:7px 12px; border-top:1px solid var(--line); vertical-align:top; }
th { font-size:.75rem; color:var(--muted); border-top:none; }
.tag { display:inline-block; border-radius:5px; padding:0 8px; font-size:.75rem; font-weight:700; }
.s-ok{color:var(--ok);background:color-mix(in srgb,var(--ok) 14%,transparent);}
.s-warn{color:var(--warn);background:color-mix(in srgb,var(--warn) 14%,transparent);}
.s-bad{color:var(--bad);background:color-mix(in srgb,var(--bad) 14%,transparent);}
.s-info{color:var(--info);background:color-mix(in srgb,var(--info) 14%,transparent);}
.s-mute{color:var(--mute);background:color-mix(in srgb,var(--mute) 14%,transparent);}
.alert { background:var(--panel); border:1px solid var(--line);
	border-left:4px solid var(--bad); border-radius:8px; padding:8px 14px; margin:8px 0; }
.calm { border-left-color:var(--ok); color:var(--muted); }
ul.standup { list-style:none; padding:0; }
ul.standup li { background:var(--panel); border:1px solid var(--line);
	border-radius:8px; padding:7px 12px; margin:6px 0; }
ul.standup .h { color:var(--muted); font-size:.78rem; margin-right:6px; }
.knobs td code { background:var(--soft); border-radius:4px; padding:1px 6px; }
a { color:var(--accent); }
footer { margin-top:40px; color:var(--mute); font-size:.75rem;
	border-top:1px solid var(--line); padding-top:10px; }
</style>
</head>
<body><div class="wrap">
HTMLHEAD

	printf '<h1>journal · progress <small>%s 由 %s 產生</small></h1>\n' \
		"$(jr_now_iso)" "$JR_HOST"

	# ---- 需要注意（跟 progress.md 同一套判斷，直接借 build 的 alert 段落）
	printf '<h2>需要注意</h2>\n'
	jr_build_progress > "$JR_TMPDIR/r.progress" 2>/dev/null
	_alerts=$(awk '/^## 需要注意/ { s = 1; next } /^## / { s = 0 } s && /^- /' "$JR_TMPDIR/r.progress")
	if [ -n "$_alerts" ]; then
		printf '%s\n' "$_alerts" | sed 's/\*\*//g' | jr_html_esc | \
			awk '{ printf "<div class=\"alert\">%s</div>\n", substr($0, 3) }'
	else
		printf '<div class="alert calm">都好，沒有紅燈。</div>\n'
	fi

	# ---- 目標
	printf '<h2>目標</h2>\n<table><tr><th>狀態</th><th>目標</th><th>進度</th><th>由誰量</th><th>何時</th></tr>\n'
	while IFS=$_us read -r _id _state _detail _host _ts; do
		_title=$(awk -F'\037' -v g="$_id" '$1 == g { print $8; exit }' "$JR_TMPDIR/r.defs")
		printf '<tr><td><span class="tag s-%s">%s</span></td><td><b>%s</b>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
			"$(jr_state_css "$_state")" "$_state" \
			"$(printf '%s' "$_id" | jr_html_esc)" \
			"$(printf '%s' "${_title:+<br><small>$_title</small>}" )" \
			"$(printf '%s' "${_detail:--}" | jr_html_esc)" \
			"$(printf '%s' "$_host" | jr_html_esc)" \
			"$(printf '%s' "$_ts" | cut -c1-16)"
	done < "$JR_TMPDIR/r.winners"
	printf '</table>\n'

	# ---- 機器
	printf '<h2>機器</h2>\n<table><tr><th>host</th><th>角色</th><th>健康</th><th>last_seen</th></tr>\n'
	while IFS=$_us read -r _h _roles _health _reason _seen _retired; do
		_cls=mute
		case $_health in ok) _cls=ok ;; degraded) _cls=warn ;; fail) _cls=bad ;; esac
		printf '<tr><td>%s%s</td><td>%s</td><td><span class="tag s-%s">%s</span>%s</td><td>%s</td></tr>\n' \
			"$_h" "${_retired:+（retired）}" "$_roles" "$_cls" "$_health" \
			"$(printf '%s' "${_reason:+ <small>$_reason</small>}" )" "$_seen"
	done < "$JR_TMPDIR/r.hosts"
	printf '</table>\n'

	# ---- 最近 7 天早會
	printf '<h2>最近 7 天</h2>\n<ul class="standup">\n'
	_i=0
	while [ $_i -lt 7 ]; do
		_d=$(jr_date_shift "$_today" "-$_i")
		_i=$((_i + 1))
		for f in "$JR_DATA_DIR"/daily/${_d}__*.md; do
			[ -f "$f" ] || continue
			_h=$(jr_fm_get "$f" host)
			awk '/^## 早會/ { s = 1; next } /^## / { s = 0 } s && /^- / { sub(/^- /, ""); print }' "$f" | \
				jr_html_esc | \
				awk -v d="$_d" -v h="$_h" '{ printf "<li><span class=\"h\">%s · %s</span>%s</li>\n", d, h, $0 }'
		done
	done
	printf '</ul>\n'

	# ---- O9：可控旋鈕（零新服務 —— 直連 provider 的檔案編輯頁）
	printf '<h2>旋鈕（中心可控）</h2>\n<table class="knobs"><tr><th>鍵</th><th>目前值</th><th>作用</th></tr>\n'
	for _k in standup_lines model_rollup model_capture model_check rollup_time stale_days goal_stale_days; do
		_v=$(jr_yaml_get "$JR_CONFIG_YML" "$_k" '')
		case $_k in
			standup_lines)   _desc='早會層力度（行數）' ;;
			model_rollup)    _desc='L2 夜間蒸餾的模型' ;;
			model_capture)   _desc='L1 即時蒸餾的模型' ;;
			model_check)     _desc='judge 型 SLI 的模型' ;;
			rollup_time)     _desc='夜間整併時間（改後各機重跑 init）' ;;
			stale_days)      _desc='機器沉默幾天算 stale' ;;
			goal_stale_days) _desc='目標幾天沒動算 stale' ;;
		esac
		printf '<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td></tr>\n' \
			"$_k" "$(printf '%s' "${_v:-（預設）}" | jr_html_esc)" "$_desc"
	done
	printf '</table>\n'
	if [ -n "$_edit" ]; then
		printf '<p><a href="%s">✏️ 在 GitHub 上編輯 config.yml</a> —— commit 後各機下一輪 pull 即生效（O9 零新服務路徑）。</p>\n' "$_edit"
	fi

	printf '<footer>靜態頁，由 journal render 產生。真相在 journal-data 的 markdown 與 yml；這一頁只是導航。</footer>\n'
	printf '</div></body></html>\n'
	} > "$JR_TMPDIR/progress.html"

	jr_write_atomic "$JR_DATA_DIR/web/progress.html" < "$JR_TMPDIR/progress.html"
	jr_ok '寫入 web/progress.html'
	[ "$_commit" -eq 1 ] && jr_git_commit_data "journal: render @ $JR_HOST"
	return 0
}
