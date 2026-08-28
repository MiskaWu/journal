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
# 目標（SLO）

> SLI 必須是「一條會回 0/非0 的指令」或「一個便宜可觀察的事實」，不是形容詞。
> `journal check` 讀這個檔，逐項檢查後寫 status/<host>.yml。
>
> 區塊文法（<!-- --> 內整段忽略）：
>
>     - id: 短代號
>       title: 一句話
>       sli: { kind: probe|file|checklist|threshold|judge|manual, cmd: "指令", source: 路徑, target: 數字 }
>       done-when: 完成的判準（給人讀）
>       requires: { paths: ["/只有某些機器看得到的路徑"], reach: ["https://端點"] }
>
> 規則：能寫 probe/file/checklist 就別退到 threshold；無 probe 才用 judge；
> 需要密碼的標 manual；**probe 一律 read-only**；requires 不滿足 → na 不是 fail。

<!--
- id: example-goal
  title: 範例：某服務起來
  sli: { kind: probe, cmd: "curl -fsS https://example.com" }
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
		# 預設分支一律 main（symbolic-ref 對老 git 也有效，init -b 要 2.28+）
		git -C "$_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null
		jr_log "git init $_dir（分支 main）"
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

# 註冊 SessionEnd hook 到 Claude Code 的 settings.json（冪等）
# JSON 合併要真剖析器：jq > python3 > 印手動片段。awk 改 JSON 是自找 corrupt。
jr_install_hook() {
	_settings="$JR_CLAUDE_HOME/settings.json"
	_cmd="$JR_ROOT/hooks/session-end.sh"

	if [ -f "$_settings" ] && grep -qF 'hooks/session-end.sh' "$_settings"; then
		jr_ok 'SessionEnd hook 已註冊'
		return 0
	fi

	if jr_has jq; then
		jr_backup "$_settings"
		[ -f "$_settings" ] || printf '{}\n' > "$_settings"
		if jq --arg cmd "$_cmd" \
			'.hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"hooks":[{"type":"command","command":$cmd}]}])' \
			"$_settings" > "$_settings.tmp.$$"; then
			mv -f "$_settings.tmp.$$" "$_settings"
			jr_ok "SessionEnd hook 已註冊（jq）→ $_settings"
		else
			rm -f "$_settings.tmp.$$"
			jr_err 'jq 合併失敗，settings.json 未動'
			return 1
		fi
	elif jr_has python3; then
		jr_backup "$_settings"
		JR_HOOK_SETTINGS="$_settings" JR_HOOK_CMD="$_cmd" python3 - <<'PY' || { jr_err 'python3 合併失敗'; return 1; }
import json, os
path, cmd = os.environ['JR_HOOK_SETTINGS'], os.environ['JR_HOOK_CMD']
data = {}
if os.path.exists(path):
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
hooks = data.setdefault('hooks', {}).setdefault('SessionEnd', [])
hooks.append({'hooks': [{'type': 'command', 'command': cmd}]})
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
os.replace(tmp, path)
PY
		jr_ok "SessionEnd hook 已註冊（python3）→ $_settings"
	else
		jr_warn '沒有 jq / python3，不敢用文字工具改 JSON —— 請把這段手動合併進 settings.json：'
		cat >&2 <<EOF
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$_cmd" } ] }
    ]
  }
EOF
		return 1
	fi
}

# 安裝 L2 夜間 timer（systemd user unit，Persistent=true 是 WSL2 的命脈 D11）
jr_install_timer() {
	if [ -n "${JOURNAL_NO_TIMER:-}" ]; then
		jr_log '（JOURNAL_NO_TIMER 設定中，跳過 timer 安裝）'
		return 0
	fi
	if ! jr_has systemctl || ! systemctl --user show-environment > /dev/null 2>&1; then
		jr_warn 'systemd user bus 不可用，跳過 timer —— 請自行排程每日 journal rollup'
		return 0
	fi

	_when=$(jr_yaml_get "$JR_CONFIG_YML" rollup_time '21:30')
	case $_when in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) jr_warn "rollup_time 格式不對（$_when），用 21:30"; _when='21:30' ;;
	esac

	_unitdir=$JR_UNIT_DIR
	mkdir -p "$_unitdir"
	cat > "$_unitdir/journal-rollup.service" <<EOF
[Unit]
Description=journal L2 nightly rollup
OnFailure=journal-onfail.service

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/journal rollup
ExecStart=-$HOME/.local/bin/journal check
EOF
	# 「壞掉了但你不知道」是最糟的失效模式（§10）—— unit 掛了要留 fail 標記
	cat > "$_unitdir/journal-onfail.service" <<EOF
[Unit]
Description=journal failure marker

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/journal _onfail rollup
EOF
	cat > "$_unitdir/journal-rollup.timer" <<EOF
[Unit]
Description=journal L2 nightly rollup timer

[Timer]
OnCalendar=*-*-* $_when:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
	# aggregator 才有的第二支 timer：排在各機 rollup 之後合成中心
	if [ "${JR_ROLE:-node}" = 'aggregator' ]; then
		_agg=$(jr_yaml_get "$JR_CONFIG_YML" aggregate_time '22:15')
		case $_agg in [0-2][0-9]:[0-5][0-9]) ;; *) _agg='22:15' ;; esac
		cat > "$_unitdir/journal-aggregate.service" <<EOF
[Unit]
Description=journal L3 aggregate
OnFailure=journal-onfail.service

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/journal aggregate
EOF
		cat > "$_unitdir/journal-aggregate.timer" <<EOF
[Unit]
Description=journal L3 aggregate timer

[Timer]
OnCalendar=*-*-* $_agg:00
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF
	fi

	systemctl --user daemon-reload
	systemctl --user enable --now journal-rollup.timer > /dev/null 2>&1 \
		&& jr_ok "timer 已啟用：每日 $_when（Persistent=true，錯過補跑）" \
		|| jr_warn 'timer enable 失敗 —— systemctl --user enable --now journal-rollup.timer 手動跑一次看錯誤'
	if [ "${JR_ROLE:-node}" = 'aggregator' ]; then
		systemctl --user enable --now journal-aggregate.timer > /dev/null 2>&1 \
			&& jr_ok "aggregate timer 已啟用：每日 ${_agg:-22:15}" \
			|| jr_warn 'aggregate timer enable 失敗'
	elif systemctl --user is-enabled journal-aggregate.timer > /dev/null 2>&1; then
		systemctl --user disable --now journal-aggregate.timer > /dev/null 2>&1
		rm -f "$_unitdir/journal-aggregate.service" "$_unitdir/journal-aggregate.timer"
		systemctl --user daemon-reload
		jr_ok '此機不再是 aggregator，aggregate timer 已移除'
	fi
}

jr_cmd_init() {
	_local=0
	_host_id=''
	_data_dir=''
	_remote=''
	_role=''
	_force=0
	while [ $# -gt 0 ]; do
		case $1 in
			--local)          _local=1 ;;
			--host-id)        shift; _host_id=${1:-} ;;
			--data-dir)       shift; _data_dir=${1:-} ;;
			--data-remote)    shift; _remote=${1:-} ;;
			--role)           shift; _role=${1:-node} ;;
			--force-takeover) _force=1 ;;
			-*)               jr_die "init: 未知選項 $1" ;;
		esac
		shift
	done
	case $_role in
		''|node|aggregator) ;;
		*) jr_die "role 只能是 node 或 aggregator，收到：$_role" ;;
	esac

	jr_info ''
	jr_info "journal init$([ "$_local" -eq 1 ] && printf ' --local')  (v$JR_VERSION)"
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

	# 3) 資料 repo：clone（多機）或 seed（第一台／離線）
	#    有 --data-remote 且本地還不是 repo → 一定走 clone —— seed 會生出
	#    與遠端不相干的歷史，之後永遠推不上去
	if [ "$_local" -ne 1 ] && [ -n "$_remote" ] && [ ! -d "$_data_dir/.git" ]; then
		JR_HOST=$_host_id
		if jr_gen_deploy_key; then jr_ssh_alias; fi
		jr_ensure_known_host "$(jr_remote_ssh_host "$_remote")"
		jr_info "clone 資料 repo：$_remote → $_data_dir"
		if ! GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15' 			git clone -q "$_remote" "$_data_dir" 2> "$JR_TMPDIR/clone.err"; then
			jr_err "clone 失敗：$(sed -n 1p "$JR_TMPDIR/clone.err")"
			jr_info '公鑰貼上 provider 了嗎？（上面已印出公鑰與網址）貼好後重跑同一個指令。'
			return 1
		fi
	fi
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
	[ -z "$_role" ] && _role=$(jr_yaml_get "$JR_HOST_YML" role node)
	jr_backup "$JR_HOST_YML"
	cat > "$JR_HOST_YML" <<EOF
# journal 本機身分 —— 不入庫
host: $_host_id
code_dir: $JR_ROOT
data_dir: $_data_dir
role: $_role
created_at: $_created
EOF
	jr_ok "本機身分：$JR_HOST_YML（host=$_host_id, role=$_role）"

	# 5) CLI symlink
	jr_link_bin

	# 6) 環境掛載
	JR_HOST=$_host_id
	JR_DATA_DIR=$_data_dir
	JR_CONFIG_YML="$_data_dir/config.yml"
	JR_SPOOL="$_data_dir/.spool"
	JR_REDUCER=$_reducer
	JR_ROLE=$_role
	mkdir -p "$JR_SPOOL"

	if [ "$_local" -ne 1 ]; then
		# 7) per-host deploy key + ssh alias（DESIGN §8 步驟 4）
		if jr_gen_deploy_key; then
			jr_ssh_alias
		fi

		# 8) provider + remote（步驟 5–6）。gh 已登入全自動；否則印手動指引
		if [ -z "$_remote" ] && ! git -C "$_data_dir" remote get-url origin > /dev/null 2>&1; then
			_remote=$(jr_provider_connect)
		fi
		[ -n "$_remote" ] && jr_wire_remote "$_remote"
	fi

	# 9) 角色（步驟 8）：同時只能有一台 aggregator
	jr_role_assign "$_role" "$_force" || return 1

	# 10) 註冊本機（步驟 7 + 10：含降級狀態）
	jr_update_host_yml
	jr_ok "註冊 $_data_dir/hosts/$_host_id.yml"
	git -C "$_data_dir" add -A -- hosts config.yml 2>/dev/null
	git -C "$_data_dir" diff --cached --quiet 2>/dev/null || \
		git -C "$_data_dir" -c user.name="journal" -c user.email="journal@$_host_id" \
			commit -q -m "journal: 註冊主機 $_host_id"

	# 11) agent：SessionEnd hook + 夜間 timer（步驟 9）
	jr_install_hook || true
	jr_install_timer || true

	# 12) 端到端自檢（步驟 11）—— 有 remote 才跑得了
	if [ "$_local" -ne 1 ]; then
		jr_selfcheck || return 1
	fi

	jr_info ''
	jr_info '完成。之後 session 一關就會自動記錄（L1），每晚自動整併（L2）。'
	jr_info '手動指令：'
	jr_info '  journal standup             # 早會要唸的'
	jr_info '  journal rollup [DATE]       # 手動整併／補跑'
	jr_info '  journal doctor              # 自檢（互動補齊）'
	return 0
}
