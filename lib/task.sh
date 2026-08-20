#!/bin/sh
# lib/task.sh —— 任務機制（journal task）
#
# 設計定案（2026-08-20 拍板，docs/TASKS.md）：
#   · tasks/<id>.md 一任務一檔；tasks/archive/ = 封存（git mv，位置即狀態）
#   · now.md 僅人可寫、最多三行、行序即優先度；代理每次取件重讀不快取
#   · 代理只能推到 review —— done 唯一入口是人用的 `journal task done`
#   · 封存唯一入口是人用的 `journal task archive`；系統不自動封存，只把老任務浮上來
#   · 全卡住時的行為是旋鈕 task_stalled: idle|backlog（預設 idle）
#
# 狀態集合：backlog | ready | doing | needs-input | review | done
# 頻率低、檔案小 —— 每個動作一個 commit（可 diff、可 revert、看得出誰改的）。

# ---------------------------------------------------------------- 基礎

jr_task_dir()  { printf '%s/tasks' "$JR_DATA_DIR"; }
jr_task_now()  { printf '%s/now.md' "$JR_DATA_DIR"; }

jr_task_id_valid() {
	case $1 in
		''|*[!a-z0-9-]*) return 1 ;;
		*-*) return 0 ;;
		*) return 1 ;;
	esac
}

# 任務檔路徑；找不到時看 archive（get 要能讀封存的）
jr_task_file() {
	_f="$(jr_task_dir)/$1.md"
	[ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
	_a="$(jr_task_dir)/archive/$1.md"
	[ -f "$_a" ] && { printf '%s' "$_a"; return 0; }
	return 1
}

# 旋鈕（config.yml，扁平子集）
jr_task_knobs() {
	TK_STALLED=$(jr_yaml_get "$JR_CONFIG_YML" task_stalled idle)
	TK_REVIEW_LIMIT=$(jr_yaml_get "$JR_CONFIG_YML" task_review_limit 3)
	TK_LEASE_MIN=$(jr_yaml_get "$JR_CONFIG_YML" task_lease_minutes 60)
	TK_STALE_DAYS=$(jr_yaml_get "$JR_CONFIG_YML" task_stale_days 7)
	TK_PREFIX=$(jr_yaml_get "$JR_CONFIG_YML" task_prefix hy)
}

# 改 frontmatter 的一個 key（key 都在建檔時種好，這裡只改不增）
jr_task_fm_set() {
	# jr_task_fm_set FILE KEY VALUE
	_f=$1
	awk -v k="$2" -v v="$3" '
		NR == 1 && $0 == "---" { fm = 1; print; next }
		fm && $0 == "---" { fm = 0; print; next }
		fm {
			pos = index($0, ":")
			if (pos > 0 && substr($0, 1, pos - 1) == k) {
				if (v == "") print k ":"; else print k ": " v
				next
			}
		}
		{ print }
	' "$_f" > "$_f.tmp.$$" && mv -f "$_f.tmp.$$" "$_f"
}

# 留言：附加到檔尾（模板保證「## 留言」永遠是最後一段）。
# 冪等：同樣的留言文字已存在就不再長第二筆 —— 代理重試的保護。
jr_task_comment() {
	# jr_task_comment FILE WHO TEXT
	_f=$1; _who=$2; _txt=$3
	[ -n "$_txt" ] || return 0
	grep -qF -- "] $_txt" "$_f" 2>/dev/null && return 0
	grep -q '^## 留言' "$_f" || printf '\n## 留言\n' >> "$_f"
	printf -- '- %s [%s] %s\n' "$(date +'%Y-%m-%d %H:%M')" "$_who" "$_txt" >> "$_f"
}

# now.md → 依序印出任務編號（# 註解與空行跳過）
jr_task_now_ids() {
	[ -f "$(jr_task_now)" ] || return 0
	awk 'index($0, "#") == 1 { next } NF { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print $1 }' "$(jr_task_now)"
}

# 下一個編號：掃 tasks/ 與 archive/ 取同字首最大序號 + 1
jr_task_next_id() {
	_pre=$1
	_max=$(ls "$(jr_task_dir)" "$(jr_task_dir)/archive" 2>/dev/null \
		| sed -n "s/^$_pre-\([0-9][0-9]*\)\.md$/\1/p" | sort -n | tail -1)
	# 去掉前導零 —— dash 的 $(( )) 會把 0042 當八進位
	_max=$(printf '%s' "$_max" | sed 's/^0*//')
	case $_max in ''|*[!0-9]*) _max=0 ;; esac
	printf '%s-%04d' "$_pre" $(( _max + 1 ))
}

# 認領過期回收：doing 且心跳超過租約 → 放回 ready（R 系統回收）
jr_task_reap() {
	_now_e=$(jr_now_epoch)
	_reaped=''
	for _f in "$(jr_task_dir)"/*.md; do
		[ -f "$_f" ] || continue
		[ "$(jr_fm_get "$_f" status)" = 'doing' ] || continue
		_hb=$(jr_fm_get "$_f" heartbeat_epoch)
		case $_hb in ''|*[!0-9]*) _hb=0 ;; esac
		_age=$(( _now_e - _hb ))
		if [ "$_age" -gt $(( TK_LEASE_MIN * 60 )) ]; then
			_id=$(jr_fm_get "$_f" id)
			jr_task_fm_set "$_f" status ready
			jr_task_fm_set "$_f" claimed_by ''
			jr_task_fm_set "$_f" claimed_at ''
			jr_task_comment "$_f" system "認領逾時回收（心跳 $(( _age / 60 )) 分鐘前，租約 ${TK_LEASE_MIN} 分鐘）"
			jr_warn "回收 $_id（心跳過期）"
			_reaped="$_reaped $_id"
		fi
	done
	[ -n "$_reaped" ] && jr_git_commit_data "task: 租約回收$_reaped"
	return 0
}

jr_task_count() {
	# jr_task_count STATUS
	_n=0
	for _f in "$(jr_task_dir)"/*.md; do
		[ -f "$_f" ] || continue
		[ "$(jr_fm_get "$_f" status)" = "$1" ] && _n=$(( _n + 1 ))
	done
	printf '%s' "$_n"
}

# ---------------------------------------------------------------- 建檔

jr_task_seed_file() {
	# jr_task_seed_file FILE ID TITLE
	cat > "$1" <<EOF
---
id: $2
title: $3
status: backlog
created_at: $(jr_now_iso)
external:
claimed_by:
claimed_at:
heartbeat_at:
heartbeat_epoch:
---

## 描述

$3

## 驗收

（貼 ready 前補上 —— 完成條件寫成看得出對錯的句子）

## 留言
EOF
}

# ---------------------------------------------------------------- 子指令

jr_task_new() {
	_pre=$TK_PREFIX
	case ${1:-} in --prefix) _pre=$2; shift 2 ;; esac
	[ $# -gt 0 ] || jr_die '用法：journal task new [--prefix hy] "一句話標題"'
	_title=$*
	mkdir -p "$(jr_task_dir)/archive"
	_id=$(jr_task_next_id "$_pre")
	_f="$(jr_task_dir)/$_id.md"
	jr_task_seed_file "$_f" "$_id" "$_title"
	jr_git_commit_data "task: 新增 $_id $_title"
	printf '%s\n' "$_id"
}

jr_task_get() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task get <id>'
	_f=$(jr_task_file "$1") || jr_die "沒有這個任務：$1"
	cat "$_f"
}

# 取件：回傳「一件」並一併認領。
#   exit 0 = 取到（stdout 是完整任務檔）
#   exit 3 = 現在沒事做（原因印在 stderr）—— 排程迴圈拿這個碼判斷「這圈空轉」
jr_task_next() {
	jr_lock_acquire task 10 || jr_die '搶不到 task 鎖 —— 同機有另一個取件正在跑？'
	jr_task_reap

	_in_review=$(jr_task_count review)
	if [ "$_in_review" -ge "$TK_REVIEW_LIMIT" ]; then
		jr_info "煞車：待審 $_in_review 件 ≥ 上限 $TK_REVIEW_LIMIT —— 先清積壓再取件"
		return 3
	fi

	# now.md 由上而下第一件 ready 的
	_pick=''
	for _id in $(jr_task_now_ids); do
		_f="$(jr_task_dir)/$_id.md"
		[ -f "$_f" ] || { jr_warn "now.md 指到不存在的 $_id"; continue; }
		if [ "$(jr_fm_get "$_f" status)" = 'ready' ]; then _pick=$_id; break; fi
	done

	# 全卡住（或 now 是空的）→ 看旋鈕
	if [ -z "$_pick" ]; then
		if [ "$TK_STALLED" = 'backlog' ]; then
			for _f in $(ls "$(jr_task_dir)"/*.md 2>/dev/null | sort); do
				[ "$(jr_fm_get "$_f" status)" = 'ready' ] || continue
				_pick=$(jr_fm_get "$_f" id); break
			done
			[ -z "$_pick" ] && { jr_info '沒事做：池裡也沒有 ready 的任務'; return 3; }
		else
			jr_info '沒事做：now 清單無 ready（task_stalled=idle —— 閒置等人清積壓）'
			return 3
		fi
	fi

	_f="$(jr_task_dir)/$_pick.md"
	jr_task_fm_set "$_f" status doing
	jr_task_fm_set "$_f" claimed_by "${JOURNAL_TASK_AGENT:-$JR_HOST}"
	jr_task_fm_set "$_f" claimed_at "$(jr_now_iso)"
	jr_task_fm_set "$_f" heartbeat_at "$(jr_now_iso)"
	jr_task_fm_set "$_f" heartbeat_epoch "$(jr_now_epoch)"
	jr_git_commit_data "task: 認領 $_pick"
	cat "$_f"
}

# 回寫：代理唯一的紀律執行點。
#   · 只接受 doing / needs-input / review —— done 直接拒絕（工具層強制，不是規約）
#   · needs-input 必須帶留言（R5：先把問題寫在任務上，通知只是加速）
#   · 冪等：同字留言不重複、狀態重設同值不多長 commit
jr_task_update() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task update <id> [--status doing|needs-input|review] [--comment "…"]'
	_id=$1; shift
	_st=''; _cm=''
	while [ $# -gt 0 ]; do
		case $1 in
			--status)  _st=$2; shift 2 ;;
			--comment) _cm=$2; shift 2 ;;
			*) jr_die "update 不認得：$1" ;;
		esac
	done
	_f="$(jr_task_dir)/$_id.md"
	[ -f "$_f" ] || jr_die "沒有這個任務（或已封存）：$_id"
	case $_st in
		'') ;;
		done)   jr_die 'done 不歸代理 —— 審過合併後由人跑 journal task done（R4）' ;;
		doing|needs-input|review) ;;
		*) jr_die "update 只接受 doing|needs-input|review，收到：$_st" ;;
	esac
	if [ "$_st" = 'needs-input' ] && [ -z "$_cm" ]; then
		jr_die '轉 needs-input 必須 --comment 把卡住的問題寫在任務上（R5）'
	fi
	[ -n "$_st" ] && jr_task_fm_set "$_f" status "$_st"
	jr_task_comment "$_f" agent "$_cm"
	jr_task_fm_set "$_f" heartbeat_at "$(jr_now_iso)"
	jr_task_fm_set "$_f" heartbeat_epoch "$(jr_now_epoch)"
	jr_git_commit_data "task: $_id${_st:+ → $_st}${_cm:+ 留言}"
}

jr_task_heartbeat() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task heartbeat <id>'
	_f="$(jr_task_dir)/$1.md"
	[ -f "$_f" ] || jr_die "沒有這個任務：$1"
	jr_task_fm_set "$_f" heartbeat_at "$(jr_now_iso)"
	jr_task_fm_set "$_f" heartbeat_epoch "$(jr_now_epoch)"
	jr_git_commit_data "task: $1 心跳"
}

jr_task_ready() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task ready <id> [--comment "…"]'
	_id=$1; shift
	_cm=''
	case ${1:-} in --comment) _cm=$2 ;; esac
	_f="$(jr_task_dir)/$_id.md"
	[ -f "$_f" ] || jr_die "沒有這個任務（或已封存）：$_id"
	jr_task_fm_set "$_f" status ready
	jr_task_fm_set "$_f" claimed_by ''
	jr_task_fm_set "$_f" claimed_at ''
	jr_task_comment "$_f" human "$_cm"
	jr_git_commit_data "task: $_id → ready"
	jr_ok "$_id 已就緒 —— 要排優先就把編號放進 now.md"
}

jr_task_done() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task done <id>'
	_f="$(jr_task_dir)/$1.md"
	[ -f "$_f" ] || jr_die "沒有這個任務（或已封存）：$1"
	jr_task_fm_set "$_f" status done
	jr_git_commit_data "task: $1 → done"
	jr_ok "$1 完成 —— 之後可 journal task archive $1 收進封存"
}

jr_task_archive() {
	jr_task_id_valid "${1:-}" || jr_die '用法：journal task archive <id>'
	_f="$(jr_task_dir)/$1.md"
	[ -f "$_f" ] || jr_die "沒有這個任務（或已封存）：$1"
	mkdir -p "$(jr_task_dir)/archive"
	git -C "$JR_DATA_DIR" mv "tasks/$1.md" "tasks/archive/$1.md" 2>/dev/null \
		|| mv "$_f" "$(jr_task_dir)/archive/$1.md"
	jr_git_commit_data "task: 封存 $1"
	jr_ok "$1 已封存"
}

# 清單：給人看的。needs-input 浮最上面（超過三天的排最前），
# 超過 task_stale_days 沒動靜的標「老」—— 提醒歸系統，封存歸人。
jr_task_list() {
	_today=$(jr_today)
	_now_rank=''
	_i=0
	for _id in $(jr_task_now_ids); do
		_i=$(( _i + 1 ))
		_now_rank="$_now_rank $_id=$_i"
	done
	for _f in "$(jr_task_dir)"/*.md; do
		[ -f "$_f" ] || continue
		_id=$(jr_fm_get "$_f" id)
		_st=$(jr_fm_get "$_f" status)
		_ti=$(jr_fm_get "$_f" title)
		_last=$(jr_fm_get "$_f" heartbeat_at)
		[ -n "$_last" ] || _last=$(jr_fm_get "$_f" created_at)
		_age=$(jr_days_between "$(printf '%s' "$_last" | cut -c1-10)" "$_today" 2>/dev/null)
		case $_age in ''|*[!0-9-]*) _age=0 ;; esac
		_mark=''
		[ "$_age" -gt "$TK_STALE_DAYS" ] && _mark='老'
		_pos=''
		for _kv in $_now_rank; do
			[ "${_kv%%=*}" = "$_id" ] && _pos="now${_kv#*=}"
		done
		# 排序鍵：needs-input 超過 3 天 0 → needs-input 1 → review 2 → doing 3
		#         → ready 4 → backlog 5；now 內的順位再往前提
		case $_st in
			needs-input) _k=1; [ "$_age" -gt 3 ] && _k=0 ;;
			review) _k=2 ;;
			doing)  _k=3 ;;
			ready)  _k=4 ;;
			done)   _k=6 ;;
			*)      _k=5 ;;
		esac
		printf '%s\t%s\t%-12s\t%4s天\t%-4s\t%-4s\t%s\n' "$_k" "$_id" "$_st" "$_age" "${_pos:--}" "${_mark:--}" "$_ti"
	done | sort -t "$(printf '\t')" -k1,1n -k4,4rn | cut -f2- \
		| awk 'BEGIN { n = 0 } { n++; print } END { if (!n) print "（沒有任務 —— journal task new \"一句話\" 開第一張）" }'
}

# ---------------------------------------------------------------- 入口

jr_cmd_task() {
	jr_require_tier0 || exit 1
	jr_load_host
	jr_task_knobs
	mkdir -p "$(jr_task_dir)/archive"

	_sub=${1:-list}
	[ $# -gt 0 ] && shift
	case $_sub in
		next)      jr_data_pull; jr_task_next "$@" ;;
		get)       jr_task_get "$@" ;;
		update)    jr_data_pull; jr_task_update "$@" ;;
		heartbeat) jr_task_heartbeat "$@" ;;
		list)      jr_data_pull; jr_task_list "$@" ;;
		new)       jr_data_pull; jr_task_new "$@" ;;
		ready)     jr_data_pull; jr_task_ready "$@" ;;
		done)      jr_data_pull; jr_task_done "$@" ;;
		archive)   jr_data_pull; jr_task_archive "$@" ;;
		*) jr_die "task 不認得：$_sub（next|get|update|heartbeat|list|new|ready|done|archive）" ;;
	esac
}
