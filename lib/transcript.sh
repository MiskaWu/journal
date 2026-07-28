#!/bin/sh
# lib/transcript.sh —— transcript 探勘、日期切分、減量派工
#
# ⚠ 同一個邏輯 repo 會有多個 slug（DESIGN §13）。本機實測 14 個，其中
#   dev-env-ansible 就散成本體加四個 `--claude-worktrees-*`。slug 必須映回
#   邏輯專案，否則同一件事會被當成四個專案，**別漏、別重複計**。

: "${JR_CLAUDE_HOME:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
JR_PROJECTS_DIR="$JR_CLAUDE_HOME/projects"

# jr_transcript_files DATE —— 列出「有可能」含當日資料的 transcript
#
# 前篩靠 mtime：當日開始之前就不再變動的檔案，不可能含當日的行。
# 用 touch -t + find -newer（兩者都是 POSIX），避開 GNU 專屬的 -newermt。
jr_transcript_files() {
	_date=$1
	[ -d "$JR_PROJECTS_DIR" ] || return 0
	_stamp="$JR_TMPDIR/stamp.$$"
	_y=$(printf '%s' "$_date" | cut -c1-4)
	_m=$(printf '%s' "$_date" | cut -c6-7)
	_d=$(printf '%s' "$_date" | cut -c9-10)
	if touch -t "${_y}${_m}${_d}0000" "$_stamp" 2>/dev/null; then
		find "$JR_PROJECTS_DIR" -name '*.jsonl' -newer "$_stamp" 2>/dev/null | sort
		rm -f "$_stamp"
	else
		# touch -t 不吃就別前篩 —— 慢一點總比漏掉好
		jr_debug 'touch -t 失敗，改掃全部 transcript'
		find "$JR_PROJECTS_DIR" -name '*.jsonl' 2>/dev/null | sort
	fi
}

# jr_first_cwd FILE —— 從 transcript 撈出第一個 cwd（決定它屬於哪個專案）
jr_first_cwd() {
	awk '
		{
			k = index($0, "\"cwd\":\"")
			if (k == 0) next
			s = substr($0, k + 7)
			e = index(s, "\"")
			if (e > 1) { print substr(s, 1, e - 1); exit }
		}' "$1" 2>/dev/null
}

# jr_project_of SLUG CWD —— slug 映射到邏輯專案名
#
# 順序：config.yml 的 slug_map 明確指定 > 由 cwd 推 git toplevel > cwd 的 basename
jr_project_of() {
	_slug=$1
	_cwd=$2
	if [ -f "${JR_CONFIG_YML:-}" ]; then
		_mapped=$(jr_yaml_section "$JR_CONFIG_YML" slug_map | awk -F'\t' -v s="$_slug" '$1 == s { print $2; exit }')
		[ -n "$_mapped" ] && { printf '%s' "$_mapped"; return 0; }
	fi
	if [ -n "$_cwd" ] && [ -d "$_cwd" ]; then
		_top=$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)
		if [ -n "$_top" ]; then
			# worktree 的 toplevel 是 .claude/worktrees/<name>，要還原回主 repo 名
			case $_top in
				*/.claude/worktrees/*) _top=${_top%%/.claude/worktrees/*} ;;
			esac
			printf '%s' "$(basename "$_top")"
			return 0
		fi
	fi
	[ -n "$_cwd" ] && { printf '%s' "$(basename "$_cwd")"; return 0; }
	# 連 cwd 都沒有：從 slug 硬拆，至少把 worktree 後綴收掉
	_s=${_slug%%--claude-worktrees-*}
	printf '%s' "${_s##*-}"
}

# jr_reduce_file FILE PROJECT SID START END —— 把單一 transcript 減量到 stdout
jr_reduce_file() {
	_file=$1; _project=$2; _sid=$3; _start=$4; _end=$5
	_tzoff=$(jr_tz_offset)
	_maxtext=${JR_MAXTEXT:-1200}
	case "$JR_REDUCER" in
		node)
			node "$JR_ROOT/lib/reduce.node.js" "$_file" "$_start" "$_end" "$_tzoff" "$_maxtext" "$_project" "$_sid"
			;;
		python3)
			python3 "$JR_ROOT/lib/reduce.py" "$_file" "$_start" "$_end" "$_tzoff" "$_maxtext" "$_project" "$_sid"
			;;
		*)
			# LC_ALL=C：reduce.awk 要的是位元組語意，截斷再由 utf8_trim 補回字元邊界
			LC_ALL=C awk \
				-v WSTART="$_start" -v WEND="$_end" -v TZOFF="$_tzoff" \
				-v MAXTEXT="$_maxtext" -v PROJECT="$_project" -v SID="$_sid" \
				-f "$JR_ROOT/lib/reduce.awk" "$_file"
			;;
	esac
}

# jr_collect_transcripts DATE OUTFILE —— 產出當日全部 session 的減量素材
#
# 副作用（給 metrics 與 git 擷取用）：
#   JR_STAT_SESSIONS  當日有素材的 session 數
#   JR_STAT_CWDS      當日出現過的 cwd（換行分隔，已去重）
jr_collect_transcripts() {
	_date=$1
	_out=$2
	_win=$(jr_day_window "$_date")
	_start=${_win%% *}
	_end=${_win##* }
	jr_debug "日窗 $_start → $_end"

	: > "$_out"
	_cwdlist="$JR_TMPDIR/cwds"
	: > "$_cwdlist"
	_n=0

	jr_transcript_files "$_date" | while IFS= read -r f; do
		[ -f "$f" ] || continue
		printf '%s\n' "$f"
	done > "$JR_TMPDIR/files"

	while IFS= read -r f; do
		[ -n "$f" ] || continue
		_slug=$(basename "$(dirname "$f")")
		_sid=$(basename "$f" .jsonl)
		_cwd=$(jr_first_cwd "$f")
		_project=$(jr_project_of "$_slug" "$_cwd")
		_chunk="$JR_TMPDIR/chunk"
		jr_reduce_file "$f" "$_project" "$(printf '%s' "$_sid" | cut -c1-8)" "$_start" "$_end" > "$_chunk" 2>/dev/null
		if [ -s "$_chunk" ]; then
			cat "$_chunk" >> "$_out"
			printf '\n' >> "$_out"
			_n=$((_n + 1))
			[ -n "$_cwd" ] && printf '%s\n' "$_cwd" >> "$_cwdlist"
		fi
	done < "$JR_TMPDIR/files"

	JR_STAT_SESSIONS=$_n
	JR_STAT_CWDS=$(sort -u "$_cwdlist" 2>/dev/null)
	export JR_STAT_SESSIONS
}
