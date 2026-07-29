#!/bin/sh
# lib/init.sh —— 納管
#
# P1 只做 `--local`：單機、離線也成立，不碰 provider、不產 deploy key、不裝
# timer 與 hook。完整的十一步精靈是 P4 的事（DESIGN §8）。
#
# 每一步都冪等 —— 重跑不該弄壞既有狀態。動既有檔案前一律先備份。

jr_backup() {
	[ -f "$1" ] || return 0
	_bak="$1.bak.$(date +%Y%m%d%H%M%S)"
	cp -p "$1" "$_bak" && jr_log "已備份 $1 → $_bak"
}

jr_seed_data_repo() {
	_dir=$1
	mkdir -p "$_dir/daily" "$_dir/status" "$_dir/hosts" "$_dir/weekly" "$_dir/web"

	for d in daily status hosts weekly web; do
		[ -f "$_dir/$d/.gitkeep" ] || : > "$_dir/$d/.gitkeep"
	done

	if [ ! -f "$_dir/.gitignore" ]; then
		cat > "$_dir/.gitignore" <<'EOF'
# 本機指標，對別台機器是死連結 —— 永不入庫（DECISIONS D9）
.spool/
*.tmp.*
*.bak.*
EOF
	fi

	if [ ! -f "$_dir/config.yml" ]; then
		if [ -f "$JR_ROOT/config.example.yml" ]; then
			cp "$JR_ROOT/config.example.yml" "$_dir/config.yml"
		else
			printf 'timezone: %s\n' "$(date +%Z)" > "$_dir/config.yml"
		fi
		jr_log "建立 $_dir/config.yml"
	fi

	if [ ! -f "$_dir/GOALS.md" ]; then
		cat > "$_dir/GOALS.md" <<'EOF'
# 目標

> SLI 必須是「一條會回 0/非0 的指令」或「一個便宜可觀察的事實」，不是形容詞。
> 種子播種與 `journal check` 是 P3 的事，這裡先留骨架。

<!--
- id: example-goal
  title: 範例目標
  sli: { kind: checklist, source: /path/to/runbook.md }
  done-when: 端到端驗證通過
  requires: { paths: ["/opt/infra"] }
-->
EOF
	fi

	if [ ! -f "$_dir/README.md" ]; then
		cat > "$_dir/README.md" <<'EOF'
# journal-data

`journal` 產出的日誌資料。**這個 repo 必須私有。**

- `daily/<date>__<host>.md` —— 每台機器每天一份，四段敘事
- `status/<host>.yml` —— SLI 結果與 agent 健康度
- `hosts/<host>.yml` —— 主機註冊表
- `progress.md` —— ★ 僅 aggregator 可寫

工具本體在另一個 repo（`journal`）。
EOF
	fi

	if ! git -C "$_dir" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$_dir" init -q
		jr_log "git init $_dir"
	fi
	if [ -z "$(git -C "$_dir" log -1 --oneline 2>/dev/null)" ]; then
		git -C "$_dir" add -A
		git -C "$_dir" -c user.name="journal" -c user.email="journal@$(hostname)" \
			commit -q -m 'journal: 初始化資料 repo 骨架' 2>/dev/null || true
	fi
}

jr_link_bin() {
	_target="$JR_ROOT/bin/journal"
	_link="$HOME/.local/bin/journal"
	mkdir -p "$HOME/.local/bin"
	if [ -L "$_link" ]; then
		_cur=$(readlink "$_link" 2>/dev/null)
		[ "$_cur" = "$_target" ] && { jr_ok "symlink 已就位 $_link"; return 0; }
		jr_warn "$_link 指向 $_cur，改指到 $_target"
		rm -f "$_link"
	elif [ -e "$_link" ]; then
		jr_backup "$_link"
		rm -f "$_link"
	fi
	ln -s "$_target" "$_link" && jr_ok "建立 symlink $_link → $_target"
	case ":$PATH:" in
		*":$HOME/.local/bin:"*) ;;
		*) jr_warn "$HOME/.local/bin 不在 PATH 裡，加這行到你的 shell rc：export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
	esac
}

jr_cmd_init() {
	_local=0
	_host_id=''
	_data_dir=''
	while [ $# -gt 0 ]; do
		case $1 in
			--local)     _local=1 ;;
			--host-id)   shift; _host_id=${1:-} ;;
			--data-dir)  shift; _data_dir=${1:-} ;;
			-*)          jr_die "init: 未知選項 $1" ;;
		esac
		shift
	done

	if [ "$_local" -ne 1 ]; then
		jr_err '目前只實作 `journal init --local`（P1）。'
		jr_info '完整的十一步納管精靈（provider 授權、deploy key、timer、hook、端到端自檢）是 P4。'
		return 2
	fi

	jr_info ''
	jr_info "journal init --local  (v$JR_VERSION)"
	jr_info ''

	# 1) 環境自檢
	jr_require_tier0 --need-claude || return 1
	_reducer=$(jr_pick_reducer)
	jr_ok "Tier 0 齊備；減量路徑 = $_reducer"
	[ "$_reducer" = 'awk' ] && jr_warn '無 node / python3，走 awk 粗篩（正確但 token 較貴）'

	# 2) host id —— 與 hostname 解耦（D14）
	[ -n "$_host_id" ] || _host_id=$(jr_yaml_get "$JR_HOST_YML" host "$(hostname)")
	[ -n "$_data_dir" ] || _data_dir=$(jr_yaml_get "$JR_HOST_YML" data_dir "$HOME/journal")
	case $_data_dir in "~/"*) _data_dir="$HOME/${_data_dir#\~/}" ;; esac

	# 3) 資料 repo 骨架
	mkdir -p "$_data_dir"
	_data_dir=$( CDPATH='' cd -P "$_data_dir" && pwd )
	if [ "$_data_dir" = "$JR_ROOT" ]; then
		jr_die '資料目錄不可以是程式碼 repo 本身（鐵律 6：兩個 repo 分開）'
	fi
	jr_seed_data_repo "$_data_dir"
	jr_ok "資料 repo：$_data_dir"

	# 4) 本機身分
	# created_at 必須先讀出來 —— redirection 比 heredoc 展開先發生，
	# 寫在 heredoc 裡讀的會是剛被截斷的空檔，重跑一次 created_at 就重置一次
	mkdir -p "$JR_CONFIG_HOME"
	_created=$(jr_yaml_get "$JR_HOST_YML" created_at "$(jr_now_iso)")
	jr_backup "$JR_HOST_YML"
	cat > "$JR_HOST_YML" <<EOF
# journal 本機身分 —— 不入庫
host: $_host_id
code_dir: $JR_ROOT
data_dir: $_data_dir
created_at: $_created
EOF
	jr_ok "本機身分：$JR_HOST_YML（host=$_host_id）"

	# 5) CLI symlink
	jr_link_bin

	# 6) 註冊本機
	JR_HOST=$_host_id
	JR_DATA_DIR=$_data_dir
	JR_CONFIG_YML="$_data_dir/config.yml"
	JR_SPOOL="$_data_dir/.spool"
	JR_REDUCER=$_reducer
	mkdir -p "$JR_SPOOL"
	jr_update_host_yml
	jr_ok "註冊 $_data_dir/hosts/$_host_id.yml"

	git -C "$_data_dir" add -A -- hosts config.yml 2>/dev/null
	git -C "$_data_dir" diff --cached --quiet 2>/dev/null || \
		git -C "$_data_dir" -c user.name="journal" -c user.email="journal@$_host_id" \
			commit -q -m "journal: 註冊主機 $_host_id"

	jr_info ''
	jr_info '完成。下一步：'
	jr_info '  journal rollup --dry-run    # 只看素材，不呼叫 claude'
	jr_info '  journal rollup              # 產出今天的 daily 檔'
	jr_info ''
	jr_warn 'P1 沒有裝 timer 與 SessionEnd hook（那是 P2/P4），現在請手動跑 rollup。'
	return 0
}
