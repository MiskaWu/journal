#!/bin/sh
# lib/gitlog.sh —— 當日 git 素材擷取
#
# D1：只看 git commit 會漏掉「討論／決定／調查」，所以 transcript 才是主素材；
# 但 commit 是唯一客觀、可驗證的產出，metrics 從這裡來。

# jr_git_repos DATE —— 要掃哪些 repo
#
# 兩個來源聯集：config.yml 明列的，加上當日 transcript 出現過的 cwd 所屬 repo。
# 後者讓「零設定也能跑」成立 —— 你在哪工作，它就掃哪。
jr_git_repos() {
	_list="$JR_TMPDIR/repos"
	: > "$_list"

	if [ -f "${JR_CONFIG_YML:-}" ]; then
		jr_yaml_list "$JR_CONFIG_YML" repos | while IFS= read -r r; do
			[ -n "$r" ] || continue
			case $r in "~/"*) r="$HOME/${r#\~/}" ;; esac
			[ -d "$r" ] && printf '%s\n' "$r"
		done >> "$_list"
	fi

	printf '%s\n' "${JR_STAT_CWDS:-}" | while IFS= read -r c; do
		[ -n "$c" ] || continue
		[ -d "$c" ] || continue
		_top=$(git -C "$c" rev-parse --show-toplevel 2>/dev/null) || continue
		[ -n "$_top" ] && printf '%s\n' "$_top"
	done >> "$_list"

	sort -u "$_list"
}

# 這個 repo 該把哪些作者算成「你」
jr_git_authors() {
	_repo=$1
	if [ -f "${JR_CONFIG_YML:-}" ]; then
		_a=$(jr_yaml_list "$JR_CONFIG_YML" git_authors)
		[ -n "$_a" ] && { printf '%s\n' "$_a"; return 0; }
	fi
	git -C "$_repo" config user.email 2>/dev/null
}

# jr_collect_git DATE OUTFILE —— 產出當日 git 素材
#
# 副作用：JR_STAT_COMMITS、JR_STAT_FILES
jr_collect_git() {
	_date=$1
	_out=$2
	_win=$(jr_day_window "$_date")
	_since=${_win%% *}
	_until=${_win##* }

	: > "$_out"
	_files="$JR_TMPDIR/gitfiles"
	: > "$_files"
	_commits=0

	jr_git_repos "$_date" > "$JR_TMPDIR/repolist"
	while IFS= read -r repo; do
		[ -n "$repo" ] || continue
		_name=$(basename "$repo")

		# 作者過濾：不篩的話，一次 rebase 或 pull 就會把別人的 commit 灌進當天
		set --
		for a in $(jr_git_authors "$repo"); do
			set -- "$@" --author="$a"
		done

		_log=$(git -C "$repo" log --all --no-merges \
			--since="$_since" --until="$_until" "$@" \
			--date=format-local:%H:%M --pretty=format:'%h %ad %s' 2>/dev/null)
		[ -n "$_log" ] || continue

		printf '## repo %s\n' "$_name" >> "$_out"
		printf '%s\n' "$_log" >> "$_out"

		# 動到的檔案：只留路徑，不留 diff（diff 進 prompt 是壓縮比的敵人）
		git -C "$repo" log --all --no-merges \
			--since="$_since" --until="$_until" "$@" \
			--name-only --pretty=format: 2>/dev/null \
			| awk 'NF' | sort -u > "$JR_TMPDIR/repofiles"
		if [ -s "$JR_TMPDIR/repofiles" ]; then
			printf '檔案：' >> "$_out"
			awk '{ printf "%s ", $0 } END { print "" }' "$JR_TMPDIR/repofiles" \
				| cut -c1-800 >> "$_out"
			awk -v p="$_name" '{ print p "/" $0 }' "$JR_TMPDIR/repofiles" >> "$_files"
		fi
		printf '\n' >> "$_out"

		_c=$(printf '%s\n' "$_log" | awk 'NF' | wc -l | tr -d ' ')
		_commits=$((_commits + _c))
	done < "$JR_TMPDIR/repolist"

	JR_STAT_COMMITS=$_commits
	JR_STAT_FILES=$(sort -u "$_files" 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')
	export JR_STAT_COMMITS JR_STAT_FILES
}
