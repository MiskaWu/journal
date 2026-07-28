#!/bin/sh
# lib/secrets.sh —— 機密 gate（DESIGN §13）
#
# 兩道防線的第二道。第一道是生成 prompt 裡的明令，但那是「請模型自律」，
# 不能當唯一防線 —— 這一道是產出後掃描，命中就 redact-and-keep。
#
# 為什麼是 redact 不是整篇拒收：整篇拒收等於那天沒有日誌，而這工具最糟的
# 失效模式就是「壞掉了但你不知道」。replace + 印警告，摘要留著。
#
# ⚠ L1 與 L2 都要跑。L1 會 push，遠端一旦收過機密，git 歷史就洗不乾淨了。

JR_REDACT_MARK='«REDACTED»'

# 內建 pattern。高信心的廠商格式優先；通用高熵字串放寬門檻避免誤傷。
# ⚠ 長 hex 門檻刻意設在 48：SHA-1 commit hash 是 40 個 hex，設 40 會把
#   每一個 commit 參照都洗掉。SHA-256 的 64 位元組仍會被打到，這是已知取捨，
#   要調就改 config.yml 的 redact_patterns。
jr_builtin_patterns() {
	cat <<'PATTERNS'
glpat-[A-Za-z0-9_-]{16,}
gh[pousr]_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
AKIA[0-9A-Z]{12,}
ASIA[0-9A-Z]{12,}
sk-[A-Za-z0-9_-]{20,}
xox[abprs]-[A-Za-z0-9-]{10,}
AIza[0-9A-Za-z_-]{30,}
eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
[0-9a-fA-F]{48,}
PATTERNS
}

jr_redact_patterns() {
	jr_builtin_patterns
	[ -f "${JR_CONFIG_YML:-}" ] && jr_yaml_list "$JR_CONFIG_YML" redact_patterns
	return 0
}

# 從 secrets 檔撈出**值**（不是 key）。檔不存在就靜靜跳過 —— dev 機沒有 /opt/infra。
jr_secret_values() {
	_sf=$(jr_yaml_get "${JR_CONFIG_YML:-}" secrets_file '/opt/infra/secrets.yml')
	case $_sf in "~/"*) _sf="$HOME/${_sf#\~/}" ;; esac
	[ -n "$_sf" ] && [ -f "$_sf" ] || return 0
	awk '
		index($0, "#") == 1 { next }
		{
			pos = index($0, ":")
			if (pos == 0) next
			v = substr($0, pos + 1)
			sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
			gsub(/^["\047]|["\047]$/, "", v)
			# 太短的值當不了機密，只會製造誤傷（"true"、"80"、"main"…）
			if (length(v) >= 8 && v !~ /^[0-9]+$/) print v
		}' "$_sf"
}

# jr_redact FILE —— 就地 redact。印出命中次數（0 = 乾淨）
jr_redact() {
	_target=$1
	[ -f "$_target" ] || { printf '0'; return 0; }

	_pf="$JR_TMPDIR/redact.patterns"
	_vf="$JR_TMPDIR/redact.values"
	jr_redact_patterns | awk 'NF' > "$_pf"
	jr_secret_values   | awk 'NF' > "$_vf"

	_tmp="$JR_TMPDIR/redact.out"
	awk -v mark="$JR_REDACT_MARK" -v pf="$_pf" -v vf="$_vf" '
		BEGIN {
			np = 0
			while ((getline line < pf) > 0) if (line != "") pats[++np] = line
			close(pf)
			nv = 0
			while ((getline line < vf) > 0) if (line != "") vals[++nv] = line
			close(vf)
			hits = 0
		}
		{
			# 1) 字面值：不能當 regex 丟進去，值裡的 . * [ 會變成萬用字元
			for (i = 1; i <= nv; i++) {
				v = vals[i]
				while ((p = index($0, v)) > 0) {
					$0 = substr($0, 1, p - 1) mark substr($0, p + length(v))
					hits++
				}
			}
			# 2) pattern
			for (i = 1; i <= np; i++) {
				n = gsub(pats[i], mark)
				hits += n
			}
			print
		}
		END { printf "%d\n", hits > "/dev/stderr" }
	' "$_target" > "$_tmp" 2>"$JR_TMPDIR/redact.count"

	if [ -s "$_tmp" ] || [ ! -s "$_target" ]; then
		mv -f "$_tmp" "$_target"
	fi
	_hits=$(tr -d ' \n' < "$JR_TMPDIR/redact.count" 2>/dev/null)
	case $_hits in
		''|*[!0-9]*) _hits=0 ;;
	esac
	printf '%s' "$_hits"
}

# jr_redact_guard FILE —— redact + 警告。回傳命中次數（供 frontmatter 記錄）
jr_redact_guard() {
	_n=$(jr_redact "$1")
	if [ "$_n" -gt 0 ]; then
		jr_warn "機密 gate 命中 $_n 處，已替換成 $JR_REDACT_MARK（檔案：$1）"
	fi
	printf '%s' "$_n"
}
