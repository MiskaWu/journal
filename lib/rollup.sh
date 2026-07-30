#!/bin/sh
# lib/rollup.sh —— L2 夜間層：重讀當天全部 session，整併成當日定稿
#
# L1 保「不丟」，L2 保「好讀」。L2 是**覆寫**不是 append —— 它每次都從原始
# transcript 重算，所以可以無限次補跑，這也是它能修正 L1 碎片的原因。

jr_daily_path() { printf '%s/daily/%s__%s.md' "$JR_DATA_DIR" "$1" "$JR_HOST"; }

# 沒素材 / 生成失敗都要留檔。靜默漏掉等於騙你說那幾天沒做事（DESIGN §10）。
jr_placeholder_body() {
	cat <<EOF
## 完成
- （$1）
## 拍板
## 待續
## 卡住
EOF
}

jr_update_host_yml() {
	# JR_HEALTH_OVERRIDE：OnFailure 路徑用 —— unit 掛了要留 fail 標記，
	# 下一次成功的 rollup/check 會自然蓋回真實健康度
	_health=${JR_HEALTH_OVERRIDE:-$(jr_agent_health)}
	_reason=${JR_HEALTH_REASON:-$(jr_degraded_reason)}
	_hf="$JR_DATA_DIR/hosts/$JR_HOST.yml"
	_registered=$(jr_yaml_get "$_hf" registered_at "$(jr_now_iso)")
	_retired=$(jr_yaml_get "$_hf" retired '')
	_roles="[${JR_ROLE:-node}]"
	[ "${JR_ROLE:-node}" = 'aggregator' ] && _roles='[node, aggregator]'
	mkdir -p "$JR_DATA_DIR/hosts"
	cat > "$_hf" <<EOF
host: $JR_HOST
registered_at: $_registered
os: $(jr_detect_os)
roles: $_roles
agent_version: $JR_VERSION
agent_health: $_health
degraded_reason: "$_reason"
reducer: ${JR_REDUCER:-}
last_seen: $(jr_now_iso)
EOF
	[ -n "$_retired" ] && printf 'retired: %s\n' "$_retired" >> "$_hf"
	return 0
}

jr_detect_os() {
	case $(uname -s 2>/dev/null) in
		Darwin) printf 'darwin' ;;
		Linux)
			if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
				printf 'wsl2'
			else
				printf 'linux'
			fi
			;;
		*) printf 'unknown' ;;
	esac
}

# 生成前先拉一次 —— 中心（config.yml）改的旋鈕（模型、力度…）要在這一輪
# 就生效，而不是等 push 時才 rebase 進來。失敗不阻塞：離線照跑，用舊設定。
jr_data_pull() {
	git -C "$JR_DATA_DIR" remote get-url origin > /dev/null 2>&1 || return 0
	# --autostash：人剛編到一半的 GOALS.md 不該把每日同步整個擋死；
	# 真正的 rebase 衝突仍然停手（fail-soft 矩陣：衝突不自動硬解）
	GIT_TERMINAL_PROMPT=0 jr_timeout 20 \
		git -C "$JR_DATA_DIR" pull --rebase --autostash -q 2>/dev/null \
		|| jr_log 'pull 失敗（離線？）—— 用本地既有設定繼續'
}

jr_git_commit_data() {
	_msg=$1
	git -C "$JR_DATA_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
		jr_warn "$JR_DATA_DIR 不是 git repo，跳過 commit"
		return 0
	}
	# 只 add 存在的路徑 —— pathspec 指到不存在的東西，整個 add 會報錯放棄。
	# GOALS.md / config.yml / checklists 是人編的，但它們住在資料 repo 裡：
	# 不 commit 的話 pull --rebase 永遠被工作區擋住，中心旋鈕的傳播就斷了。
	set --
	for _p in daily hosts status weekly progress.md web GOALS.md config.yml checklists; do
		[ -e "$JR_DATA_DIR/$_p" ] && set -- "$@" "$_p"
	done
	[ $# -gt 0 ] && git -C "$JR_DATA_DIR" add -A -- "$@" 2>/dev/null
	if git -C "$JR_DATA_DIR" diff --cached --quiet 2>/dev/null; then
		jr_log '沒有變更，不 commit'
		return 0
	fi
	git -C "$JR_DATA_DIR" -c user.name="journal" \
		-c user.email="journal@$JR_HOST" \
		commit -q -m "$_msg" || { jr_err 'commit 失敗'; return 1; }
	jr_ok "已 commit：$_msg"

	# P1 是單機離線層 —— 沒有 remote 就到此為止，不是錯誤。
	if git -C "$JR_DATA_DIR" remote get-url origin >/dev/null 2>&1; then
		if git -C "$JR_DATA_DIR" pull --rebase -q 2>/dev/null; then
			git -C "$JR_DATA_DIR" push -q 2>/dev/null \
				&& jr_ok ' 已 push' || jr_warn 'push 失敗，commit 留在本地，下次重試'
		else
			jr_warn 'pull --rebase 失敗（可能有衝突）—— 不自動硬解，請人工處理'
		fi
	fi
}

jr_cmd_rollup() {
	_date=''
	_dry=0
	_commit=1
	while [ $# -gt 0 ]; do
		case $1 in
			--dry-run)   _dry=1 ;;
			--no-commit) _commit=0 ;;
			-*)          jr_die "rollup: 未知選項 $1" ;;
			*)           _date=$1 ;;
		esac
		shift
	done
	[ -n "$_date" ] || _date=$(jr_today)
	jr_date_valid "$_date" || jr_die "日期格式要 YYYY-MM-DD，收到：$_date"

	jr_require_tier0 --need-claude || exit 1
	jr_load_host
	jr_data_pull
	JR_REDUCER=$(jr_pick_reducer)
	export JR_REDUCER
	jr_log "rollup $_date @ $JR_HOST（reducer=$JR_REDUCER）"

	# 不在這裡設 trap —— bin/journal 的 EXIT trap 已經同時清 JR_TMPDIR 與釋放鎖。
	# 在這裡再 trap 一次會把那個 trap 蓋掉，暫存目錄就會漏。
	jr_lock_acquire rollup 30 || jr_die '拿不到 rollup 鎖（另一個 rollup / capture 正在跑）'

	_material="$JR_TMPDIR/material"
	_tmat="$JR_TMPDIR/material.transcript"
	_gmat="$JR_TMPDIR/material.git"

	jr_collect_transcripts "$_date" "$_tmat"
	jr_collect_git "$_date" "$_gmat"

	{
		if [ -s "$_tmat" ]; then
			printf '# Claude session 紀錄（%s）\n\n' "$_date"
			cat "$_tmat"
			printf '\n'
		fi
		if [ -s "$_gmat" ]; then
			printf '# git commit（%s）\n\n' "$_date"
			cat "$_gmat"
		fi
	} > "$_material"

	jr_log "素材：session ${JR_STAT_SESSIONS:-0}、commit ${JR_STAT_COMMITS:-0}、檔案 ${JR_STAT_FILES:-0}、$(wc -c < "$_material" | tr -d ' ') bytes"

	if [ "$_dry" -eq 1 ]; then
		jr_lock_release
		cat "$_material"
		return 0
	fi

	_body="$JR_TMPDIR/body"
	_goals=''
	_status='ok'
	if [ ! -s "$_material" ]; then
		jr_warn "$_date 沒有任何素材"
		jr_placeholder_body '這天沒有素材：沒有 session 紀錄，也沒有 commit' > "$_body"
		_status='no-material'
	elif jr_distill "$_date" "$JR_HOST" "$_material" "$JR_TMPDIR/distilled"; then
		_goals=$(jr_parse_goals "$JR_TMPDIR/distilled")
		jr_strip_goals "$JR_TMPDIR/distilled" > "$_body"
		[ -s "$_body" ] || {
			jr_placeholder_body '生成失敗：模型輸出無法解析' > "$_body"
			_status='generate-failed'
		}
	else
		jr_placeholder_body "生成失敗：claude 未產出內容（$(jr_now_iso)）" > "$_body"
		_status='generate-failed'
	fi

	_daily=$(jr_daily_path "$_date")
	_draft="$JR_TMPDIR/daily.md"
	{
		jr_fm_write "$_date" "$JR_HOST" \
			"${JR_STAT_SESSIONS:-0}" "${JR_STAT_COMMITS:-0}" "${JR_STAT_FILES:-0}" \
			"$_goals" rollup "$JR_REDUCER" 0
		cat "$_body"
	} > "$_draft"

	# 機密 gate —— 過了才准落地（DESIGN §13）
	_hits=$(jr_redact_guard "$_draft")
	if [ "$_hits" -gt 0 ]; then
		# redactions 是事後才知道的，回填進 frontmatter
		awk -v n="$_hits" '
			/^redactions: / && !done { print "redactions: " n; done = 1; next }
			{ print }' "$_draft" > "$_draft.2" && mv -f "$_draft.2" "$_draft"
	fi
	awk -v s="$_status" '
		/^journal_version: / && !done { print "status: " s; done = 1 }
		{ print }' "$_draft" > "$_draft.3" && mv -f "$_draft.3" "$_draft"

	mkdir -p "$JR_DATA_DIR/daily"
	jr_write_atomic "$_daily" < "$_draft"
	jr_ok "寫入 $_daily"

	# L2 重讀過當天全部原始資料 —— spool 裡 L1 沒做完的這下也被涵蓋了
	jr_spool_mark_all "$_date"

	jr_update_host_yml

	jr_lock_release


	[ "$_commit" -eq 1 ] && jr_git_commit_data "journal: rollup $_date @ $JR_HOST"

	case $_status in
		ok) return 0 ;;
		no-material) return 0 ;;
		*) return 1 ;;
	esac
}
