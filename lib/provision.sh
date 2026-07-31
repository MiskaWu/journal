#!/bin/sh
# lib/provision.sh —— 納管：deploy key、provider、remote、角色、自檢、退場
#
# 憑證原則（DESIGN §8）：**一次性的廣授權用於設定，長期的窄授權用於運行。**
# gh/glab 的帳號級 token 只在 init 當下用來建 repo 上傳金鑰；之後每天在跑的
# 只有這台機器專屬的 deploy key —— 單 repo、可單獨撤銷、筆電掉了只撤那一把。

# ---------------------------------------------------------------- deploy key

jr_deploy_key_path() { printf '%s/.ssh/journal_%s' "$HOME" "$JR_HOST"; }

jr_gen_deploy_key() {
	_key=$(jr_deploy_key_path)
	if [ -f "$_key" ]; then
		jr_ok "deploy key 已存在：$_key"
		return 0
	fi
	jr_has ssh-keygen || { jr_warn '沒有 ssh-keygen，跳過 deploy key（之後可重跑 init）'; return 1; }
	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	ssh-keygen -t ed25519 -f "$_key" -N '' -C "journal@$JR_HOST" -q \
		&& jr_ok "產生 deploy key：$_key（只給資料 repo 寫入權，不碰你的個人金鑰）" \
		|| { jr_err 'ssh-keygen 失敗'; return 1; }
}

# ~/.ssh/config 加 journal 專用 Host alias —— push 走 journal.github.com
# 就一定用這把 key，完全不碰個人金鑰（DESIGN §8 步驟 4）
jr_ssh_alias() {
	_cfg="$HOME/.ssh/config"
	_marker="Host journal.github.com"
	if [ -f "$_cfg" ] && grep -qF "$_marker" "$_cfg"; then
		jr_ok 'ssh alias 已就位（journal.github.com）'
		return 0
	fi
	jr_backup "$_cfg"
	mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
	cat >> "$_cfg" <<EOF

# journal deploy key —— journal init 產生，journal uninstall --purge 移除
Host journal.github.com
	HostName github.com
	User git
	IdentityFile $(jr_deploy_key_path)
	IdentitiesOnly yes
EOF
	chmod 600 "$_cfg"
	jr_ok "ssh alias 寫入 $_cfg（journal.github.com → github.com，專用這把 key）"
}

# ---------------------------------------------------------------- provider

# 兩條路產出相同（DESIGN §8 步驟 5）：gh 已登入就全自動；否則印公鑰與網址。
jr_provider_connect() {
	_pub="$(jr_deploy_key_path).pub"
	[ -f "$_pub" ] || return 0

	if jr_has gh && gh auth status > /dev/null 2>&1; then
		_user=$(gh api user -q .login 2>/dev/null)
		if [ -n "$_user" ]; then
			gh repo view "$_user/journal-data" > /dev/null 2>&1 \
				|| gh repo create journal-data --private > /dev/null 2>&1 \
				&& jr_ok "資料 repo 就緒：$_user/journal-data（私有）"
			if gh repo deploy-key add "$_pub" --repo "$_user/journal-data" \
				--allow-write --title "journal@$JR_HOST" > /dev/null 2>&1; then
				jr_ok 'deploy key 已上傳（write 權限）'
			else
				jr_log 'deploy key 上傳被拒（可能已存在同一把）'
			fi
			printf 'git@journal.github.com:%s/journal-data.git' "$_user"
			return 0
		fi
	fi

	# 手動路徑：印出要貼的東西與直達網址
	jr_info ''
	jr_info '── 手動接 provider（gh 未登入/未安裝）─────────────────'
	jr_info '1) 建私有 repo：https://github.com/new  → 名稱 journal-data，'
	jr_info '   Private，不要勾任何初始化檔案'
	jr_info '2) 加 deploy key（勾 Allow write access）：'
	jr_info '   https://github.com/<你>/journal-data/settings/keys/new'
	jr_info '   公鑰內容：'
	sed 's/^/     /' "$_pub" >&2
	jr_info '3) 完成後重跑：journal init --data-remote git@journal.github.com:<你>/journal-data.git'
	jr_info '──────────────────────────────────────────────────'
	printf ''
}

# ---------------------------------------------------------------- remote 佈線

jr_wire_remote() {
	# jr_wire_remote URL —— 冪等
	_url=$1
	[ -n "$_url" ] || return 1
	_cur=$(git -C "$JR_DATA_DIR" remote get-url origin 2>/dev/null)
	if [ "$_cur" = "$_url" ]; then
		jr_ok "資料 repo remote 已設：$_url"
		return 0
	fi
	if [ -n "$_cur" ]; then
		jr_warn "origin 由 $_cur 改為 $_url"
		git -C "$JR_DATA_DIR" remote set-url origin "$_url"
	else
		git -C "$JR_DATA_DIR" remote add origin "$_url"
	fi
	# 歷史分岔守門：本地是後來 seed 的骨架、遠端已有歷史 → 停手指路，不硬推
	_br=$(git -C "$JR_DATA_DIR" branch --show-current)
	if GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15' 		git -C "$JR_DATA_DIR" fetch -q origin "$_br" 2>/dev/null; then
		if git -C "$JR_DATA_DIR" rev-parse -q --verify "origin/$_br" > /dev/null 2>&1 			&& ! git -C "$JR_DATA_DIR" merge-base HEAD "origin/$_br" > /dev/null 2>&1; then
			jr_err '本地資料 repo 與遠端歷史不相干（本地是後來 seed 出來的骨架？）'
			jr_info "確認本地沒有要保留的東西後：rm -rf $JR_DATA_DIR，再重跑同一個 init（會改用 clone）"
			return 1
		fi
	fi
	jr_ok "資料 repo remote → $_url"
}

# ---------------------------------------------------------------- 角色

# 同時只能有一台 aggregator（O5）。掃註冊表，已有就拒絕（除非 --force-takeover）。
jr_role_assign() {
	# jr_role_assign ROLE FORCE
	_role=$1; _force=$2
	[ "$_role" = 'aggregator' ] || { JR_ROLE='node'; return 0; }

	_other=$(grep -l 'roles:.*aggregator' "$JR_DATA_DIR"/hosts/*.yml 2>/dev/null \
		| while IFS= read -r f; do
			_h=$(jr_yaml_get "$f" host)
			[ "$_h" != "$JR_HOST" ] && printf '%s\n' "$_h"
		done | sed -n 1p)
	if [ -n "$_other" ] && [ "$_force" -ne 1 ]; then
		jr_err "已有 aggregator：$_other —— 同時只能有一台（O5）。要接手就加 --force-takeover"
		return 1
	fi
	if [ -n "$_other" ]; then
		jr_warn "接手 aggregator（原：$_other）—— 記得停掉那台的 aggregate timer"
	fi
	JR_ROLE='aggregator'
	return 0
}

# ---------------------------------------------------------------- 端到端自檢
#
# DESIGN §8 步驟 11：真實往返。沒有這步，你要等到當晚才發現 push 憑證是壞的。
jr_selfcheck() {
	git -C "$JR_DATA_DIR" remote get-url origin > /dev/null 2>&1 || {
		jr_warn '（沒有 remote，跳過端到端自檢 —— 設好 --data-remote 後重跑 init）'
		return 0
	}
	export GIT_TERMINAL_PROMPT=0
	jr_ensure_known_host "$(jr_remote_ssh_host "$(git -C "$JR_DATA_DIR" remote get-url origin 2>/dev/null)")"
	_gitssh=$JR_GIT_SSH

	jr_log '端到端自檢：測試 capture → gate → commit → push → 驗證 → 還原'
	_f="$JR_DATA_DIR/status/.selfcheck-$JR_HOST"
	printf 'selfcheck %s\ntoken 測試：glpat-SELFCHECK0000000000\n' "$(jr_now_iso)" > "$_f"

	# gate 必須把假 token 洗掉 —— 洗不掉就不准推
	jr_redact_guard "$_f" > /dev/null
	if grep -q 'glpat-SELFCHECK' "$_f"; then
		jr_err '自檢失敗：機密 gate 沒有 redact 測試 token'
		rm -f "$_f"
		return 1
	fi

	_branch=$(git -C "$JR_DATA_DIR" branch --show-current)
	git -C "$JR_DATA_DIR" add "$_f"
	git -C "$JR_DATA_DIR" -c user.name=journal -c user.email="journal@$JR_HOST" \
		commit -q -m "journal: selfcheck @ $JR_HOST"
	if ! GIT_SSH_COMMAND=$_gitssh jr_timeout 30 \
		git -C "$JR_DATA_DIR" push -q -u origin "$_branch" 2> "$JR_TMPDIR/push.err"; then
		jr_err "自檢失敗：push 不出去 —— $(sed -n 1p "$JR_TMPDIR/push.err")"
		git -C "$JR_DATA_DIR" reset -q --hard HEAD~1
		return 1
	fi
	_remote_sha=$(GIT_SSH_COMMAND=$_gitssh jr_timeout 15 \
		git -C "$JR_DATA_DIR" ls-remote origin "refs/heads/$_branch" 2>/dev/null | cut -c1-40)
	_local_sha=$(git -C "$JR_DATA_DIR" rev-parse HEAD)
	if [ "$_remote_sha" != "$_local_sha" ]; then
		jr_err "自檢失敗：遠端 HEAD（$_remote_sha）≠ 本地（$_local_sha）"
		return 1
	fi
	# 還原：把自檢檔清掉，遠端也跟著乾淨
	git -C "$JR_DATA_DIR" rm -q "$_f"
	git -C "$JR_DATA_DIR" -c user.name=journal -c user.email="journal@$JR_HOST" \
		commit -q -m "journal: selfcheck 還原 @ $JR_HOST"
	GIT_SSH_COMMAND=$_gitssh jr_timeout 30 git -C "$JR_DATA_DIR" push -q 2>/dev/null
	jr_ok '端到端自檢通過：憑證可寫、gate 有效、遠端收到'
}

# ---------------------------------------------------------------- hosts / 退場

jr_cmd_hosts() {
	jr_load_host
	_now=$(jr_now_epoch)
	printf '%-16s %-12s %-10s %-22s %s\n' HOST ROLES HEALTH LAST_SEEN 備註 >&2
	for f in "$JR_DATA_DIR"/hosts/*.yml; do
		[ -f "$f" ] || continue
		_h=$(jr_yaml_get "$f" host)
		[ -n "$_h" ] || continue
		_r=$(jr_yaml_get "$f" roles '[node]')
		_hp=$(jr_yaml_get "$f" agent_health '?')
		_ls=$(jr_yaml_get "$f" last_seen '-')
		_ret=$(jr_yaml_get "$f" retired '')
		_note=''
		[ -n "$_ret" ] && _note="retired $_ret"
		printf '%-16s %-12s %-10s %-22s %s\n' "$_h" "$_r" "$_hp" "$_ls" "$_note"
	done
}

jr_cmd_revoke() {
	_target=${1:-}
	[ -n "$_target" ] || jr_die 'revoke: 要 host 名稱（journal hosts 可查）'
	jr_load_host
	[ "$_target" = "$JR_HOST" ] && jr_die '不能 revoke 自己 —— 用 journal uninstall'
	_hf="$JR_DATA_DIR/hosts/$_target.yml"
	[ -f "$_hf" ] || jr_die "沒有這台：$_hf"

	grep -q '^retired:' "$_hf" || printf 'retired: %s\n' "$(jr_now_iso)" >> "$_hf"
	jr_ok "$_target 已標記 retired（staleness alert 不再對它發）"
	jr_info "接著到 provider 撤掉它的 deploy key（標題應為 journal@$_target）："
	jr_info '  https://github.com/<你>/journal-data/settings/keys'
	jr_info "歷史的 daily 檔保留 —— 那是你的工作紀錄，不是它的。"
	jr_git_commit_data "journal: revoke $_target"
}

jr_cmd_uninstall() {
	_purge=0
	case ${1:-} in --purge) _purge=1 ;; esac
	jr_load_host

	# timer
	if [ -z "${JOURNAL_NO_TIMER:-}" ] && jr_has systemctl; then
		systemctl --user disable --now journal-rollup.timer > /dev/null 2>&1
		rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/journal-rollup.service" \
			"${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/journal-rollup.timer" \
			"${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/journal-onfail.service"
		systemctl --user daemon-reload 2>/dev/null
		jr_ok 'timer 已移除'
	fi

	# hook
	_settings="$JR_CLAUDE_HOME/settings.json"
	if [ -f "$_settings" ] && grep -qF 'hooks/session-end.sh' "$_settings"; then
		jr_backup "$_settings"
		if jr_has jq; then
			jq '.hooks.SessionEnd = [(.hooks.SessionEnd // [])[] | select((.hooks // []) | any(.command | contains("hooks/session-end.sh")) | not)] | if .hooks.SessionEnd == [] then del(.hooks.SessionEnd) else . end' \
				"$_settings" > "$_settings.tmp.$$" && mv -f "$_settings.tmp.$$" "$_settings"
			jr_ok 'SessionEnd hook 已移除'
		elif jr_has python3; then
			JR_HOOK_SETTINGS="$_settings" python3 - <<'PY'
import json, os
path = os.environ['JR_HOOK_SETTINGS']
with open(path, encoding='utf-8') as fh:
    data = json.load(fh)
ses = data.get('hooks', {}).get('SessionEnd', [])
ses = [e for e in ses if not any('hooks/session-end.sh' in h.get('command', '')
                                 for h in e.get('hooks', []))]
if ses: data['hooks']['SessionEnd'] = ses
else: data.get('hooks', {}).pop('SessionEnd', None)
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2); fh.write('\n')
os.replace(tmp, path)
PY
			jr_ok 'SessionEnd hook 已移除'
		else
			jr_warn '沒有 jq/python3 —— 請手動把 SessionEnd 那段從 settings.json 拿掉'
		fi
	fi

	if [ "$_purge" -ne 1 ]; then
		jr_info '資料與 repo 都保留。要連它們一起刪：journal uninstall --purge'
		return 0
	fi

	# --purge：破壞性 —— 互動時要確認
	if jr_interactive; then
		printf 'purge 會刪掉 %s、%s、deploy key。確定？[y/N] ' "$JR_CONFIG_HOME" "$JR_DATA_DIR" >&2
		read -r _ans
		case $_ans in y|Y) ;; *) jr_info '取消'; return 1 ;; esac
	fi
	rm -f "$HOME/.local/bin/journal"
	rm -f "$(jr_deploy_key_path)" "$(jr_deploy_key_path).pub"
	rm -rf "$JR_CONFIG_HOME"
	rm -rf "$JR_DATA_DIR"
	jr_ok 'purge 完成（程式碼 repo 與 ~/.ssh/config 的 alias 段留給你自己收）'
	jr_info "提醒：provider 上的 deploy key（journal@$JR_HOST）也要撤"
}

# ---------------------------------------------------------------- OnFailure

# systemd 的 OnFailure= 指到這裡 —— 「壞掉了但你不知道」是最糟的失效模式，
# unit 掛了至少要在 hosts/ 留下 fail 標記，aggregator（P5）看得到。
jr_cmd_onfail() {
	_what=${1:-unit}
	jr_load_host
	_hf="$JR_DATA_DIR/hosts/$JR_HOST.yml"
	JR_HEALTH_OVERRIDE=fail \
	JR_HEALTH_REASON="$_what 於 $(jr_now_iso) 失敗（OnFailure 觸發）" \
		jr_update_host_yml
	jr_git_commit_data "journal: $_what 失敗 @ $JR_HOST"
	jr_err "$_what 失敗已記入 hosts/$JR_HOST.yml"
}
