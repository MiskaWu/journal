#!/bin/sh
# lib/common.sh —— 共用基礎：路徑解析、日誌、設定讀取、依賴分層、鎖
#
# POSIX sh only。本機 /bin/sh 是 dash，任何 bashism（[[ ]]、陣列、$'...'）都會爆。

# ---------------------------------------------------------------- 全域

JR_VERSION='0.1.0'
: "${JR_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/journal}"
JR_HOST_YML="$JR_CONFIG_HOME/host.yml"

# 顏色只在 TTY 上開（D17 的同一個精神：背景路徑不要吐控制碼）
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	JR_C_RED=$(printf '\033[31m'); JR_C_YEL=$(printf '\033[33m')
	JR_C_GRN=$(printf '\033[32m'); JR_C_DIM=$(printf '\033[2m')
	JR_C_OFF=$(printf '\033[0m')
else
	JR_C_RED=''; JR_C_YEL=''; JR_C_GRN=''; JR_C_DIM=''; JR_C_OFF=''
fi

jr_log()  { printf '%s%s%s\n' "$JR_C_DIM" "$*" "$JR_C_OFF" >&2; }
jr_info() { printf '%s\n' "$*" >&2; }
jr_ok()   { printf '%s✅%s %s\n' "$JR_C_GRN" "$JR_C_OFF" "$*" >&2; }
jr_warn() { printf '%s⚠%s  %s\n' "$JR_C_YEL" "$JR_C_OFF" "$*" >&2; }
jr_err()  { printf '%s✖%s  %s\n' "$JR_C_RED" "$JR_C_OFF" "$*" >&2; }
jr_die()  { jr_err "$*"; exit 1; }

jr_debug() { [ -n "${JOURNAL_DEBUG:-}" ] && printf '%s· %s%s\n' "$JR_C_DIM" "$*" "$JR_C_OFF" >&2; return 0; }

# 是否為互動路徑（D17）。timer / hook 一律非互動。
jr_interactive() { [ -t 0 ] && [ -t 2 ] && [ -z "${JOURNAL_NONINTERACTIVE:-}" ]; }

jr_has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 路徑

# 解析 $0 的實體目錄（會跟隨 symlink，因為 ~/.local/bin/journal 就是 symlink）
jr_resolve_root() {
	_p=$1
	_n=0
	while [ -L "$_p" ]; do
		_n=$((_n + 1))
		[ "$_n" -gt 32 ] && jr_die "symlink 繞太多圈：$1"
		if jr_has readlink; then
			_l=$(readlink "$_p")
		else
			_l=$(ls -ld "$_p" | sed 's/.*-> //')
		fi
		case $_l in
			/*) _p=$_l ;;
			*)  _p=$(dirname "$_p")/$_l ;;
		esac
	done
	( CDPATH='' cd -P "$(dirname "$_p")/.." && pwd )
}

# ---------------------------------------------------------------- 扁平 YAML
#
# ⚠ 這不是 YAML 剖析器，只吃我們自己定的扁平子集（DESIGN §9：「格式是我們自己
#   定的，定成扁平好剖析」）。支援：
#     key: value                  → jr_yaml_get
#     key:\n  - item              → jr_yaml_list
#     key:\n  sub: value          → jr_yaml_section（輸出 "sub<TAB>value"）
#   不支援錨點、多行字串、巢狀兩層以上。config.example.yml 有註明。

jr_yaml_get() {
	# jr_yaml_get FILE KEY [DEFAULT]
	[ -f "$1" ] || { printf '%s' "${3:-}"; return 0; }
	_v=$(awk -v k="$2" '
		index($0, "#") == 1 { next }
		{
			pos = index($0, ":")
			if (pos == 0) next
			key = substr($0, 1, pos - 1)
			if (key != k) next            # 頂層 key 必須頂格，前導空白即不相符
			val = substr($0, pos + 1)
			sub(/^[ \t]+/, "", val); sub(/[ \t\r]+$/, "", val)
			sub(/[ \t]+#.*$/, "", val)
			gsub(/^["\047]|["\047]$/, "", val)
			print val; exit
		}' "$1")
	if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "${3:-}"; fi
}

jr_yaml_list() {
	# jr_yaml_list FILE KEY  → 一行一個項目
	[ -f "$1" ] || return 0
	awk -v k="$2" '
		index($0, "#") == 1 { next }
		!inside {
			pos = index($0, ":")
			if (pos > 0 && substr($0, 1, pos - 1) == k) inside = 1
			next
		}
		inside {
			if ($0 ~ /^[ \t]*$/) next
			if ($0 !~ /^[ \t]/) { inside = 0; next }
			line = $0
			sub(/^[ \t]*-[ \t]*/, "", line)
			if (line == $0) { inside = 0; next }   # 縮排但不是 "- " → 段落結束
			sub(/[ \t\r]+$/, "", line)
			gsub(/^["\047]|["\047]$/, "", line)
			if (line != "") print line
		}' "$1"
}

jr_yaml_section() {
	# jr_yaml_section FILE KEY  → 一行一個 "sub<TAB>value"
	[ -f "$1" ] || return 0
	awk -v k="$2" '
		index($0, "#") == 1 { next }
		!inside {
			pos = index($0, ":")
			if (pos > 0 && substr($0, 1, pos - 1) == k) inside = 1
			next
		}
		inside {
			if ($0 ~ /^[ \t]*$/) next
			if ($0 !~ /^[ \t]/) { inside = 0; next }
			line = $0
			sub(/^[ \t]+/, "", line)
			# 「- 」開頭是清單項；「-home-…:」開頭是 key —— slug 全都以 - 起頭，
			# 用 index()==1 判斷會把整個 slug_map 區段誤判成清單而吃不到
			if (line ~ /^-([ \t]|$)/) { inside = 0; next }
			pos = index(line, ":")
			if (pos == 0) next
			sub_k = substr(line, 1, pos - 1)
			sub_v = substr(line, pos + 1)
			sub(/^[ \t]+/, "", sub_v); sub(/[ \t\r]+$/, "", sub_v)
			gsub(/^["\047]|["\047]$/, "", sub_v)
			printf "%s\t%s\n", sub_k, sub_v
		}' "$1"
}

# ---------------------------------------------------------------- 本機身分

jr_load_host() {
	[ -f "$JR_HOST_YML" ] || jr_die "找不到 $JR_HOST_YML —— 先跑一次 'journal init'"
	JR_HOST=$(jr_yaml_get "$JR_HOST_YML" host)
	JR_DATA_DIR=$(jr_yaml_get "$JR_HOST_YML" data_dir)
	JR_CODE_DIR=$(jr_yaml_get "$JR_HOST_YML" code_dir "$JR_ROOT")
	JR_ROLE=$(jr_yaml_get "$JR_HOST_YML" role node)
	[ -n "$JR_HOST" ] || jr_die "$JR_HOST_YML 缺 host"
	[ -n "$JR_DATA_DIR" ] || jr_die "$JR_HOST_YML 缺 data_dir"
	[ -d "$JR_DATA_DIR" ] || jr_die "資料目錄不存在：$JR_DATA_DIR"
	JR_CONFIG_YML="$JR_DATA_DIR/config.yml"
	JR_SPOOL="$JR_DATA_DIR/.spool"
	export JR_HOST JR_DATA_DIR JR_CODE_DIR JR_CONFIG_YML JR_SPOOL JR_ROLE
}

# ---------------------------------------------------------------- 依賴分層（§9）
#
# Tier 0 地板  sh / git / claude       缺 → 拒絕執行
# Tier 1 加速器 node → python3 → awk   缺 → 降級
# Tier 2 便利  gh / jq / timeout       缺 → 走手動路徑

jr_pkg_hint() {
	# 發行版感知：只印對應的那一行
	_what=$1
	if   jr_has apt-get; then printf 'sudo apt-get install -y %s\n' "$_what"
	elif jr_has dnf;     then printf 'sudo dnf install -y %s\n' "$_what"
	elif jr_has pacman;  then printf 'sudo pacman -S --noconfirm %s\n' "$_what"
	elif jr_has apk;     then printf 'sudo apk add %s\n' "$_what"
	elif jr_has brew;    then printf 'brew install %s\n' "$_what"
	else printf '（請用你的套件管理器安裝 %s）\n' "$_what"
	fi
}

jr_require_tier0() {
	_missing=''
	jr_has git || _missing="$_missing git"
	jr_has awk || _missing="$_missing awk"
	# claude 只有真的要生成時才是硬依賴；由呼叫端決定要不要帶 --need-claude
	if [ "${1:-}" = '--need-claude' ]; then
		jr_has claude || _missing="$_missing claude"
	fi
	[ -z "$_missing" ] && return 0

	jr_err "Tier 0 缺少：$_missing —— 拒絕執行（DESIGN §9）"
	for _m in $_missing; do
		case $_m in
			claude) jr_info "  claude → https://claude.com/claude-code 安裝後重試" ;;
			*)      jr_info "  $_m → $(jr_pkg_hint "$_m")" ;;
		esac
	done
	return 1
}

# 選出減量路徑：node > python3 > awk（保底）
# JOURNAL_REDUCER=awk 可強制走保底路徑（P1 驗收要用）
jr_pick_reducer() {
	case "${JOURNAL_REDUCER:-}" in
		node|python3|awk) printf '%s' "$JOURNAL_REDUCER"; return 0 ;;
	esac
	if   jr_has node    && [ -f "$JR_ROOT/lib/reduce.node.js" ]; then printf 'node'
	elif jr_has python3 && [ -f "$JR_ROOT/lib/reduce.py" ];      then printf 'python3'
	else printf 'awk'
	fi
}

# 本機健康度：ok | degraded | fail
jr_agent_health() {
	jr_has git && jr_has claude || { printf 'fail'; return; }
	case $(jr_pick_reducer) in
		awk) printf 'degraded' ;;
		*)   printf 'ok' ;;
	esac
}

jr_degraded_reason() {
	[ "$(jr_agent_health)" = 'degraded' ] || { printf ''; return; }
	# 實測 awk 素材反而比 node 小（少了工具參數提示）——代價是蒸餾忠實度，不是 token
	printf '無 node / python3，減量走 awk 粗篩（無工具參數提示，蒸餾忠實度較低）'
}

# ---------------------------------------------------------------- 鎖
#
# mkdir 是 POSIX 保證的原子操作 —— 不依賴 flock（§10）。
# 鎖目錄裡記 PID 與時間，超過 JR_LOCK_STALE 秒視為陳舊鎖自動清除。

: "${JR_LOCK_STALE:=3600}"

jr_lock_acquire() {
	# jr_lock_acquire NAME [WAIT_SECONDS]
	_ldir="$JR_SPOOL/lock.$1"
	_wait=${2:-0}
	mkdir -p "$JR_SPOOL" 2>/dev/null || true
	_t=0
	while :; do
		if mkdir "$_ldir" 2>/dev/null; then
			printf '%s\n%s\n' "$$" "$(jr_now_epoch)" > "$_ldir/owner"
			JR_LOCK_HELD="$_ldir"
			return 0
		fi
		# 陳舊鎖？
		if [ -f "$_ldir/owner" ]; then
			_born=$(sed -n 2p "$_ldir/owner" 2>/dev/null)
			_pid=$(sed -n 1p "$_ldir/owner" 2>/dev/null)
			case $_born in
				''|*[!0-9]*) _born=0 ;;
			esac
			_age=$(( $(jr_now_epoch) - _born ))
			if [ "$_age" -gt "$JR_LOCK_STALE" ] || { [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; }; then
				jr_warn "清除陳舊鎖 $_ldir（pid=$_pid, age=${_age}s）"
				rm -rf "$_ldir"
				continue
			fi
		fi
		[ "$_t" -ge "$_wait" ] && return 1
		sleep 1
		_t=$((_t + 1))
	done
}

jr_lock_release() {
	[ -n "${JR_LOCK_HELD:-}" ] && rm -rf "$JR_LOCK_HELD"
	JR_LOCK_HELD=''
}

# ---------------------------------------------------------------- 逾時
#
# 有 timeout 就用；沒有就「背景執行 + 逾時後 kill」（§10）。
# 用法：jr_timeout SECONDS cmd args...
jr_timeout() {
	_secs=$1; shift
	if jr_has timeout; then
		timeout "$_secs" "$@"
		return $?
	fi
	"$@" &
	_child=$!
	(
		_i=0
		while [ "$_i" -lt "$_secs" ]; do
			kill -0 "$_child" 2>/dev/null || exit 0
			sleep 1
			_i=$((_i + 1))
		done
		kill -TERM "$_child" 2>/dev/null
		sleep 2
		kill -KILL "$_child" 2>/dev/null
	) &
	_watch=$!
	wait "$_child" 2>/dev/null
	_rc=$?
	kill "$_watch" 2>/dev/null
	return $_rc
}

# ---------------------------------------------------------------- 原子寫檔
jr_write_atomic() {
	# jr_write_atomic DEST < content
	_dest=$1
	_tmp="$_dest.tmp.$$"
	mkdir -p "$(dirname "$_dest")"
	cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$_dest"
}
