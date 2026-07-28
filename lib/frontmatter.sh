#!/bin/sh
# lib/frontmatter.sh —— daily 檔的 frontmatter 讀寫
#
# 格式是我們自己定的，所以刻意定成扁平、單行、好剖析（DESIGN §9）：
# 不需要 YAML 剖析器，awk 就夠。metrics 用 inline map 是為了「一行看完」。

# jr_fm_write —— 印出 frontmatter 區塊
# 用法： jr_fm_write DATE HOST SESSIONS COMMITS FILES GOALS GENERATED_BY REDUCED_BY REDACTIONS
jr_fm_write() {
	cat <<EOF
---
date: $1
host: $2
metrics: { sessions: $3, commits: $4, files_touched: $5 }
goals_touched: [$6]
generated_by: $7
reduced_by: $8
redactions: $9
generated_at: $(jr_now_iso)
journal_version: $JR_VERSION
---
EOF
}

# jr_fm_get FILE KEY —— 只讀 frontmatter 區（不掃內文）
jr_fm_get() {
	[ -f "$1" ] || return 0
	awk -v k="$2" '
		NR == 1 && $0 == "---" { inside = 1; next }
		inside && $0 == "---" { exit }
		inside {
			pos = index($0, ":")
			if (pos == 0) next
			if (substr($0, 1, pos - 1) != k) next
			v = substr($0, pos + 1)
			sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
			print v; exit
		}' "$1"
}
