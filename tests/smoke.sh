#!/bin/sh
# tests/smoke.sh —— P1 冒煙測試
#
# 全程使用假資料與假 claude，不碰真實環境：
#   · HOME / JR_CONFIG_HOME / CLAUDE_CONFIG_DIR 全指向 mktemp 目錄
#   · claude 是 PATH 上的墊片，行為由 CLAUDE_SHIM_MODE 控制
#     （ok / secret / fail / empty / slow / reject）
# 硬需求只有 P1 的地板：sh、git、awk。node / python3 在場時會多跑等價比對。
#
# 用法： sh tests/smoke.sh
# 全綠 exit 0；任何失敗 exit 1 並在結尾列出清單。

set -u

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/journal"
T=$(mktemp -d "${TMPDIR:-/tmp}/journal-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

PASS=0; FAIL=0; FAILS=''
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILS="$FAILS
    ✖ $1 — $2"; printf '  FAIL %s — %s\n' "$1" "$2"; }

a_grep()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "找不到「$3」於 $2"; fi; }
a_ngrep() { if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "不該出現「$3」於 $2"; else ok "$1"; fi; }
a_egrep() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "找不到 pattern「$3」於 $2"; fi; }
a_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望「$3」，得到「$2」"; fi; }
a_rc()    { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "期望 exit $3，得到 $2"; fi; }
a_nz()    { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" '期望非零 exit，得到 0'; fi; }

# 統一入口：完全隔離的環境跑 journal
J() {
	env HOME="$T/home" \
		JR_CONFIG_HOME="$T/cfg" \
		CLAUDE_CONFIG_DIR="$T/claude" \
		CLAUDE_SHIM_LOG="$T/shim.log" \
		CLAUDE_SHIM_MODE="${MODE:-ok}" \
		CLAUDE_SHIM_ARGLOG="${ARGLOG:-}" \
		JOURNAL_REDUCER="${RED:-}" \
		JR_CLAUDE_TIMEOUT="${TOUT:-60}" \
		JR_MAXTEXT="${MAXT:-1200}" \
		JOURNAL_TODAY="${TODAY:-}" \
		JOURNAL_NO_TIMER=1 \
		PATH="$T/bin:$PATH" \
		"$BIN" "$@"
}

# hook 入口：模擬 Claude Code 觸發 SessionEnd（同步模式，結果可斷言）
JH() {
	env HOME="$T/home" \
		JR_CONFIG_HOME="$T/cfg" \
		CLAUDE_CONFIG_DIR="$T/claude" \
		CLAUDE_SHIM_LOG="$T/shim.log" \
		CLAUDE_SHIM_MODE="${MODE:-ok}" \
		CLAUDE_SHIM_ARGLOG="${ARGLOG:-}" \
		JOURNAL_REDUCER="${RED:-}" \
		JR_CLAUDE_TIMEOUT=60 \
		JOURNAL_TODAY="${TODAY:-}" \
		JOURNAL_NO_TIMER=1 \
		JOURNAL_CAPTURE_SYNC=1 \
		JR_CAPTURE_MIN="${CAPMIN:-150}" \
		JOURNAL_BIN="$BIN" \
		JOURNAL_IN_CAPTURE="${INCAP:-}" \
		PATH="$T/bin:$PATH" \
		sh "$ROOT/hooks/session-end.sh"
}

mkpayload() {
	# mkpayload SESSION SLUG CWD
	printf '{"session_id":"%s","transcript_path":"%s/claude/projects/%s/%s.jsonl","cwd":"%s","hook_event_name":"SessionEnd","reason":"other"}' \
		"$1" "$T" "$2" "$1" "$3"
}

DAILY="$T/data/daily/2026-07-15__testhost.md"

# ================================================================ 佈景

mkdir -p "$T/bin" "$T/home" "$T/claude/projects" "$T/u"

# --- 假 claude ---------------------------------------------------
cat > "$T/bin/claude" <<'SHIM'
#!/bin/sh
for a in "$@"; do case $a in --version) echo '9.9.9 (shim)'; exit 0 ;; esac; done
printf '1\n' >> "${CLAUDE_SHIM_LOG:-/dev/null}"
[ -n "${CLAUDE_SHIM_ARGLOG:-}" ] && printf '%s\n' "$@" >> "$CLAUDE_SHIM_ARGLOG"
case "${CLAUDE_SHIM_MODE:-ok}" in
	reject)
		# 模擬舊版 claude 不認得 --safe-mode：帶了就立刻吐 usage error
		for a in "$@"; do case $a in --safe-mode)
			echo "error: unknown option '--safe-mode'" >&2; exit 1 ;;
		esac; done
		cat > /dev/null
		printf 'goals_touched: bare\n\n## 完成\n- bare 模式完成\n## 拍板\n## 待續\n## 卡住\n' ;;
	ok)
		for a in "$@"; do case $a in *週報*)
			cat > /dev/null
			printf '## 本週主線\n- proj-a：從壞到好\n## 拍板\n- 決定 W\n## 未解\n- 還卡著 Z\n'
			exit 0 ;;
		esac; done
		for a in "$@"; do case $a in *"SLI 裁決"*)
			cat > /dev/null
			printf 'PARTIAL: 大致就位但未收尾\n'
			exit 0 ;;
		esac; done
		# capture 的 prompt 含「剛結束」—— 回單 session 的碎片格式
		for a in "$@"; do case $a in *剛結束*)
			cat > /dev/null
			printf -- '- 修好了 utf8_trim 的截斷\n- 拍板：截斷走 byte 邊界\n'
			exit 0 ;;
		esac; done
		cat > /dev/null
		printf 'goals_touched: proj-a, proj-b\n\n## 早會\n- 今天把冒煙測試抓到的問題修掉了\n- 授權還卡在外部\n\n## 摘要\n- proj-a | 修復 | proj-a | 冒煙測試抓到的 bug 已修\n- proj-b | 卡住 |  | 等待外部授權\n\n## 完成\n- 修好 utf8_trim（abc1234）\n## 拍板\n- 決定採 X 案\n## 待續\n- 還有 Y\n## 卡住\n' ;;
	secret)
		cat > /dev/null
		printf 'goals_touched: proj-a\n\n## 完成\n- token 是 glpat-FAKEFAKEFAKE12345678 值 SuperSecretValue123 另 MYCORP_123456\n## 拍板\n## 待續\n## 卡住\n' ;;
	empty) cat > /dev/null ;;
	fail)  cat > /dev/null; echo 'boom' >&2; exit 1 ;;
	slow)  cat > /dev/null; sleep 30 ;;
esac
SHIM
chmod +x "$T/bin/claude"

# --- transcript fixtures（目標日 2026-07-15，本機 +08 → 日窗 07-14T16Z 起）---
mkfx() { mkdir -p "$T/claude/projects/$1"; cat > "$T/claude/projects/$1/$2.jsonl"; }

# session A：字串型 user（含跳脫）、thinking、tool_use、tool_result、壞行、窗外行
mkfx -home-test-proj-a aaaaaaaa-0001 <<'FX'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"幫我修 bug 測試 \"引號\" 與 \\ 反斜線"},"timestamp":"2026-07-15T04:00:00.000Z","cwd":"/nonexistent/proj-a","gitBranch":"main","uuid":"u1"}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"THINKING_LEAK 不該出現"},{"type":"text","text":"好，我看一下。"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la","description":"列出檔案"}}]},"timestamp":"2026-07-15T04:01:00.000Z","cwd":"/nonexistent/proj-a","gitBranch":"main","uuid":"a1"}
{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"TOOL_RESULT_LEAK 一大堆輸出"}]},"toolUseResult":{"stdout":"TOOL_RESULT_LEAK"},"timestamp":"2026-07-15T04:01:30.000Z","cwd":"/nonexistent/proj-a","uuid":"r1"}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"修好了，是 utf8_trim 的問題。"}]},"timestamp":"2026-07-15T04:02:00.000Z","cwd":"/nonexistent/proj-a","gitBranch":"main","uuid":"a2"}
this line is not json at all
{"type":"user","isSidechain":false,"message":{"role":"user","content":"OUT_OF_WINDOW 不該出現"},"timestamp":"2026-07-16T04:00:00.000Z","cwd":"/nonexistent/proj-a","uuid":"u9"}
FX

# session B：sidechain 標記
mkfx -home-test-proj-b bbbbbbbb-0001 <<'FX'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"proj-b 的問題"},"timestamp":"2026-07-15T05:00:00.000Z","cwd":"/nonexistent/proj-b","gitBranch":"dev","uuid":"b1"}
{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"子任務回報完成"}]},"timestamp":"2026-07-15T05:01:00.000Z","cwd":"/nonexistent/proj-b","uuid":"b2"}
FX

# session C：worktree slug —— 靠 slug_map 映回 proj-a（cwd 故意指向會推錯的名字）
mkfx -home-test-proj-a--claude-worktrees-fix cccccccc-0001 <<'FX'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"worktree 裡修東西"},"timestamp":"2026-07-15T06:00:00.000Z","cwd":"/nonexistent/wt-x","uuid":"c1"}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"OK 改好了"}]},"timestamp":"2026-07-15T06:01:00.000Z","cwd":"/nonexistent/wt-x","uuid":"c2"}
FX

# session D：整份都在窗外 —— 不得計入 sessions
mkfx -home-test-proj-c dddddddd-0001 <<'FX'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"OUT_OF_WINDOW_D"},"timestamp":"2026-07-14T10:00:00.000Z","cwd":"/nonexistent/proj-c","uuid":"d1"}
FX

# session E：超長 CJK —— 驗 utf8_trim 截斷不產生斷字
CJK=$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "中文長度測試" }')
printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"%s"},"timestamp":"2026-07-15T07:00:00.000Z","cwd":"/nonexistent/proj-a","uuid":"e1"}\n' "$CJK" \
	> "$T/claude/projects/-home-test-proj-a/eeeeeeee-0001.jsonl"

# --- git fixture repo：窗內兩個 commit，一個是別人的 -----------------
mkdir -p "$T/repo-a"
git -C "$T/repo-a" init -q
echo hello > "$T/repo-a/a.txt"
git -C "$T/repo-a" add a.txt
GIT_AUTHOR_DATE='2026-07-15T12:00:00+08:00' GIT_COMMITTER_DATE='2026-07-15T12:00:00+08:00' \
	git -C "$T/repo-a" -c user.name=T -c user.email=test@x commit -q -m 'INCLUDED_COMMIT feat: fixture'
echo world > "$T/repo-a/b.txt"
git -C "$T/repo-a" add b.txt
GIT_AUTHOR_DATE='2026-07-15T13:00:00+08:00' GIT_COMMITTER_DATE='2026-07-15T13:00:00+08:00' \
	git -C "$T/repo-a" -c user.name=O -c user.email=other@x commit -q -m 'EXCLUDED_COMMIT other author'

# --- secrets 值檔 -------------------------------------------------
printf 'db_pass: SuperSecretValue123\nshort: abc\n' > "$T/secrets.yml"

# ================================================================ 0 · 純函式

printf '\n== 0 · 純函式 ==\n'
JR_ROOT="$ROOT"; JR_TMPDIR="$T/u"
. "$ROOT/lib/common.sh"; . "$ROOT/lib/timeutil.sh"

a_eq 'day_window 跨年' "$(jr_day_window 2026-01-01)" '2025-12-31T16:00:00Z 2026-01-01T16:00:00Z'
a_eq 'date_shift 閏日' "$(jr_date_shift 2024-02-28 1)" '2024-02-29'
a_eq 'date_shift 負向跨月' "$(jr_date_shift 2026-03-01 -1)" '2026-02-28'

cat > "$T/u/map.yml" <<'EOF'
slug_map:
  -home-x--claude-worktrees-y: proj
  normal: alpha
alist:
  - item1
EOF
a_eq 'yaml_section 吃得下 - 開頭的 slug key' \
	"$(jr_yaml_section "$T/u/map.yml" slug_map | awk -F'\t' '$1 == "-home-x--claude-worktrees-y" { print $2 }')" 'proj'
a_eq 'yaml_section 一般 key 不受影響' \
	"$(jr_yaml_section "$T/u/map.yml" slug_map | awk -F'\t' '$1 == "normal" { print $2 }')" 'alpha'
a_eq 'yaml_list 清單照舊' "$(jr_yaml_list "$T/u/map.yml" alist)" 'item1'

# ================================================================ 1 · init

printf '\n== 1 · init --local ==\n'
MODE=ok J init --local --host-id testhost --data-dir "$T/data" > "$T/init1.log" 2>&1
a_rc 'init 首跑成功' $? 0
[ -f "$T/cfg/host.yml" ] && ok 'host.yml 落地' || bad 'host.yml 落地' "缺 $T/cfg/host.yml"
[ -d "$T/data/.git" ] && ok '資料 repo git init' || bad '資料 repo git init' '缺 .git'
c1=$(awk -F': ' '/^created_at:/ { print $2 }' "$T/cfg/host.yml")
sleep 1
MODE=ok J init --local --host-id testhost --data-dir "$T/data" > "$T/init2.log" 2>&1
a_rc 'init 重跑成功（冪等）' $? 0
c2=$(awk -F': ' '/^created_at:/ { print $2 }' "$T/cfg/host.yml")
a_eq 'created_at 重跑不重置' "$c2" "$c1"
a_eq 'SessionEnd hook 註冊且不重複（跑兩次 init 仍一筆）' \
	"$(grep -cF 'hooks/session-end.sh' "$T/claude/settings.json" 2>/dev/null)" '1'

# 測試專用 config —— 蓋掉 example 的預留內容
cat > "$T/data/config.yml" <<EOF
timezone: Asia/Taipei
repos:
  - $T/repo-a
git_authors:
  - test@x
slug_map:
  -home-test-proj-a--claude-worktrees-fix: proj-a
model_rollup: test-model-heavy
model_capture: test-model-light
secrets_file: $T/secrets.yml
redact_patterns:
  - MYCORP_[0-9]{6}
claude_timeout: 60
EOF
# config 是使用者維護的檔，rollup 的 commit 路徑刻意不碰它 —— 像使用者一樣自己 commit
git -C "$T/data" add config.yml
git -C "$T/data" -c user.name=T -c user.email=test@x commit -q -m 'test: 測試用 config'

# ================================================================ 2 · 減量

printf '\n== 2 · 減量（dry-run 素材）==\n'
for r in awk node python3; do
	case $r in awk) : ;; *) command -v "$r" > /dev/null 2>&1 || continue ;; esac
	RED=$r J rollup 2026-07-15 --dry-run > "$T/mat.$r" 2> /dev/null
done

M="$T/mat.awk"
a_grep 'U> 使用者訊息 + 時區換算（04:00Z→12:00）' "$M" '[12:00] U> 幫我修 bug 測試 "引號" 與 \ 反斜線'
a_grep 'A> 助理訊息' "$M" '修好了，是 utf8_trim 的問題。'
a_grep 'T> 工具行' "$M" 'T> Bash'
a_grep 'sidechain 標記 As>' "$M" 'As> 子任務回報完成'
a_ngrep 'thinking 不落地' "$M" 'THINKING_LEAK'
a_ngrep 'tool_result 不落地' "$M" 'TOOL_RESULT_LEAK'
a_ngrep '窗外行被切掉' "$M" 'OUT_OF_WINDOW'
a_eq 'slug_map 把 worktree 映回 proj-a（含 A、C、E 三份）' \
	"$(grep -cF 'project proj-a' "$M")" '3'
a_ngrep '沒有 slug_map 失效的 wt-x' "$M" 'project wt-x'
a_grep 'git 素材：自己人的 commit 進來' "$M" 'INCLUDED_COMMIT'
a_ngrep 'git 素材：別人的 commit 被作者過濾' "$M" 'EXCLUDED_COMMIT'

if [ -f "$T/mat.node" ]; then
	a_grep 'node 路徑帶工具參數提示' "$T/mat.node" 'Bash(列出檔案)'
	a_eq 'awk 與 node 行數一致' "$(wc -l < "$M" | tr -d ' ')" "$(wc -l < "$T/mat.node" | tr -d ' ')"
fi
if [ -f "$T/mat.node" ] && [ -f "$T/mat.python3" ]; then
	if cmp -s "$T/mat.node" "$T/mat.python3"; then ok 'py 與 node 逐位元組相同'
	else bad 'py 與 node 逐位元組相同' "diff: $T/mat.node vs $T/mat.python3"; fi
fi

if command -v python3 > /dev/null 2>&1; then
	RED=awk MAXT=100 J rollup 2026-07-15 --dry-run > "$T/mat.trim" 2> /dev/null
	if python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' < "$T/mat.trim" 2> /dev/null; then
		ok 'utf8_trim 截斷後仍是合法 UTF-8'
	else
		bad 'utf8_trim 截斷後仍是合法 UTF-8' '截出斷字'
	fi
fi

# ================================================================ 3 · rollup 主流程

printf '\n== 3 · rollup 主流程 ==\n'
MODE=ok RED=awk J rollup 2026-07-15 > "$T/roll.log" 2>&1
a_rc 'rollup 成功' $? 0
[ -f "$DAILY" ] || bad 'daily 檔存在' "缺 $DAILY"
a_grep 'frontmatter: date' "$DAILY" 'date: 2026-07-15'
a_grep 'frontmatter: host' "$DAILY" 'host: testhost'
a_grep 'frontmatter: metrics 全對（4 session、1 commit、1 檔）' "$DAILY" 'metrics: { sessions: 4, commits: 1, files_touched: 1 }'
a_grep 'frontmatter: goals_touched' "$DAILY" 'goals_touched: [proj-a, proj-b]'
a_grep 'frontmatter: reduced_by' "$DAILY" 'reduced_by: awk'
a_grep 'frontmatter: status ok' "$DAILY" 'status: ok'
a_grep '內文四段' "$DAILY" '## 卡住'
a_grep '內文來自蒸餾' "$DAILY" '修好 utf8_trim（abc1234）'
a_grep '摘要段落地' "$DAILY" '## 摘要'
J brief 2026-07-15 > "$T/brief.out" 2>&1
a_rc 'brief 指令成功' $? 0
a_grep '  brief 印出摘要條目' "$T/brief.out" '冒煙測試抓到的 bug 已修'
a_grep '  brief 欄位格式化（類型在前）' "$T/brief.out" '修復'
a_grep '早會段落地' "$DAILY" '## 早會'
J standup 2026-07-15 > "$T/standup.out" 2>&1
a_rc 'standup 指令成功' $? 0
a_grep '  standup 印出口語短句' "$T/standup.out" '今天把冒煙測試抓到的問題修掉了'
a_ngrep '  standup 不含四段細節' "$T/standup.out" 'utf8_trim'
a_eq '資料 repo 工作區乾淨（已 commit）' "$(git -C "$T/data" status --porcelain | wc -l | tr -d ' ')" '0'
a_eq '.spool 沒被 track' "$(git -C "$T/data" ls-files | grep -c spool)" '0'
a_grep 'hosts 檔更新 reducer' "$T/data/hosts/testhost.yml" 'reducer: awk'

# ================================================================ 4 · 失敗路徑

printf '\n== 4 · 失敗路徑 ==\n'
MODE=fail J rollup 2026-07-15 > /dev/null 2>&1
a_nz 'claude 失敗 → exit 非零' $?
a_grep '  佔位 + generate-failed' "$DAILY" 'status: generate-failed'
a_grep '  失敗不靜默漏' "$DAILY" '生成失敗'

MODE=empty J rollup 2026-07-15 > /dev/null 2>&1
a_nz 'claude 回空 → exit 非零' $?
a_grep '  空輸出也標 generate-failed' "$DAILY" 'status: generate-failed'

t0=$(date +%s)
MODE=slow TOUT=2 J rollup 2026-07-15 > /dev/null 2>&1
rc=$?
t1=$(date +%s)
a_nz 'claude 逾時 → exit 非零' $rc
[ $((t1 - t0)) -lt 15 ] && ok '  逾時真的有踢掉（<15s）' || bad '  逾時真的有踢掉' "花了 $((t1 - t0))s"

MODE=reject J rollup 2026-07-15 > "$T/reject.log" 2>&1
a_rc '旗標被拒 → 退最小旗標重試成功' $? 0
a_grep '  bare 模式的內容有落地' "$DAILY" 'bare 模式完成'

MODE=ok RED=awk J rollup 2026-07-15 > /dev/null 2>&1
a_rc '失敗後補跑恢復 ok' $? 0
a_grep '  status 回到 ok' "$DAILY" 'status: ok'

# ================================================================ 5 · 機密 gate

printf '\n== 5 · 機密 gate ==\n'
MODE=secret J rollup 2026-07-15 > /dev/null 2>&1
a_rc '含機密的 rollup 照樣完成（redact-and-keep）' $? 0
a_grep '有 redact 記號' "$DAILY" '«REDACTED»'
a_ngrep 'glpat（內建 pattern）洗掉' "$DAILY" 'glpat-FAKEFAKEFAKE12345678'
a_ngrep 'secrets_file 的值洗掉' "$DAILY" 'SuperSecretValue123'
a_ngrep 'config 自訂 pattern 洗掉' "$DAILY" 'MYCORP_123456'
a_egrep 'redactions 回填 ≥3' "$DAILY" '^redactions: [3-9]'
a_grep 'redact 後仍是 ok 不是拒收' "$DAILY" 'status: ok'

# ================================================================ 6 · 邊界

printf '\n== 6 · 邊界 ==\n'
rm -f "$T/shim.log"
MODE=ok J rollup 2026-07-01 > /dev/null 2>&1
a_rc '無素材日 exit 0' $? 0
a_grep '  佔位 + no-material' "$T/data/daily/2026-07-01__testhost.md" 'status: no-material'
a_eq '  沒素材就不呼叫 claude' "$([ -f "$T/shim.log" ] && wc -l < "$T/shim.log" | tr -d ' ' || echo 0)" '0'

J rollup 15-07-2026 > /dev/null 2>&1; a_nz '壞日期格式被擋' $?
J rollup 2026-07-15 --wat > /dev/null 2>&1; a_nz '未知選項被擋' $?
J show 2026-06-01 > /dev/null 2>&1; a_nz 'show 不存在的日子報錯' $?
J frobnicate > /dev/null 2>&1; a_nz '未知指令 exit 非零' $?
J doctor --check > /dev/null 2>&1; a_rc 'doctor --check 全綠' $? 0

# 陳舊鎖自動清除
mkdir -p "$T/data/.spool/lock.rollup"
printf '999999\n1000\n' > "$T/data/.spool/lock.rollup/owner"
MODE=ok J rollup 2026-07-01 > /dev/null 2>&1
a_rc '陳舊鎖（死 PID + 過期）自動清除後照跑' $? 0
[ -d "$T/data/.spool/lock.rollup" ] && bad '  鎖有釋放' '鎖目錄還在' || ok '  鎖有釋放'

# dry-run 與 --no-commit 都不准動 git
head0=$(git -C "$T/data" rev-parse HEAD)
MODE=ok J rollup 2026-07-02 --dry-run > /dev/null 2>&1
[ -f "$T/data/daily/2026-07-02__testhost.md" ] && bad 'dry-run 不寫 daily' '寫了' || ok 'dry-run 不寫 daily'
a_eq 'dry-run 不動 HEAD' "$(git -C "$T/data" rev-parse HEAD)" "$head0"
MODE=ok J rollup 2026-07-02 --no-commit > /dev/null 2>&1
[ -f "$T/data/daily/2026-07-02__testhost.md" ] && ok '--no-commit 有寫 daily' || bad '--no-commit 有寫 daily' '沒寫'
a_eq '--no-commit 不動 HEAD' "$(git -C "$T/data" rev-parse HEAD)" "$head0"

# ================================================================ 7 · L1 capture

printf '\n== 7 · L1 capture（SessionEnd hook）==\n'
SPOOL="$T/data/.spool/2026-07-15__testhost.jsonl"
DAILY15="$T/data/daily/2026-07-15__testhost.md"

# 先把 daily 恢復成 rollup 定稿（前面失敗路徑測試動過它）
MODE=ok RED=awk J rollup 2026-07-15 > /dev/null 2>&1

# 正常捕捉：session A
mkpayload aaaaaaaa-0001 -home-test-proj-a /nonexistent/proj-a > "$T/payload.a"
TODAY=2026-07-15 MODE=ok JH < "$T/payload.a" > /dev/null 2>&1
a_rc 'hook → capture 成功' $? 0
a_grep 'spool 有這個 session 且 captured:true' "$SPOOL" '"session":"aaaaaaaa-0001","transcript"'
a_grep '  captured 已翻真' "$SPOOL" 'captured":true'
a_grep 'daily append 了 L1 碎片' "$DAILY15" '#### [L1 '
a_grep '  碎片內容來自單 session 蒸餾' "$DAILY15" '修好了 utf8_trim 的截斷'
a_grep '  rollup 定稿仍在（append 不是覆寫）' "$DAILY15" '## 摘要'
a_eq  '  資料 repo 已 commit' "$(git -C "$T/data" status --porcelain | wc -l | tr -d ' ')" '0'

# 冪等：同一個 session 再觸發一次
TODAY=2026-07-15 MODE=ok JH < "$T/payload.a" > /dev/null 2>&1
a_eq '同 session 重複觸發只留一份碎片' "$(grep -cF 'aaaaaaaa' "$DAILY15")" '1'
a_eq '  spool 也只一行' "$(grep -cF '"session":"aaaaaaaa-0001"' "$SPOOL")" '1'

# 太小的 session：不呼叫 claude，直接標 captured
rm -f "$T/shim.log"
mkpayload dddddddd-0001 -home-test-proj-c /nonexistent/proj-c > "$T/payload.d"
TODAY=2026-07-15 MODE=ok JH < "$T/payload.d" > /dev/null 2>&1
a_grep '小 session 標 captured 不蒸餾' "$SPOOL" '"session":"dddddddd-0001"'
a_eq  '  沒呼叫 claude' "$([ -f "$T/shim.log" ] && wc -l < "$T/shim.log" | tr -d ' ' || echo 0)" '0'

# 鎖被佔：安靜放棄，captured:false 留給 L2
sleep 60 & LOCKPID=$!
mkdir -p "$T/data/.spool/lock.rollup"
printf '%s\n%s\n' "$LOCKPID" "$(date +%s)" > "$T/data/.spool/lock.rollup/owner"
mkpayload cccccccc-0001 -home-test-proj-a--claude-worktrees-fix /nonexistent/wt-x > "$T/payload.c"
TODAY=2026-07-15 MODE=ok CAPMIN=10 JH < "$T/payload.c" > /dev/null 2>&1
a_rc '鎖被佔時 capture 安靜退出' $? 0
a_grep '  spool 留下 captured:false' "$SPOOL" '"session":"cccccccc-0001"'
if grep -F '"session":"cccccccc-0001"' "$SPOOL" | grep -qF '"captured":false'; then
	ok '  確認未被標 captured'
else
	bad '  確認未被標 captured' '被標了'
fi
kill $LOCKPID 2>/dev/null; rm -rf "$T/data/.spool/lock.rollup"

# 重試：鎖釋放後同 payload 再來 → 這次做完
TODAY=2026-07-15 MODE=ok CAPMIN=10 JH < "$T/payload.c" > /dev/null 2>&1
if grep -F '"session":"cccccccc-0001"' "$SPOOL" | grep -qF '"captured":true'; then
	ok '鎖釋放後重試補完（captured:true）'
else
	bad '鎖釋放後重試補完（captured:true）' '仍是 false'
fi
a_eq '  重試沒有重複 spool 行' "$(grep -cF '"session":"cccccccc-0001"' "$SPOOL")" '1'

# 遞迴保護：JOURNAL_IN_CAPTURE 設定時 hook 直接退出
_lines_before=$(wc -l < "$SPOOL" | tr -d ' ')
TODAY=2026-07-15 MODE=ok INCAP=1 JH < "$T/payload.a" > /dev/null 2>&1
a_eq '遞迴保護：IN_CAPTURE 時 hook 不做事' "$(wc -l < "$SPOOL" | tr -d ' ')" "$_lines_before"

# L2 收尾：rollup 覆寫掉碎片、spool 全標 captured
printf '{"session":"leftover-0001","transcript":"/nope","cwd":"","branch":"","ended":"x","captured":false}\n' >> "$SPOOL"
MODE=ok RED=awk J rollup 2026-07-15 > /dev/null 2>&1
a_ngrep 'rollup 覆寫清掉 L1 碎片' "$DAILY15" '#### [L1 '
a_eq  'rollup 後 spool 全標 captured' "$(grep -cF '"captured":false' "$SPOOL" || true)" '0'

# 模型旋鈕：rollup 用 model_rollup、capture 用 model_capture、環境變數蓋過一切
rm -f "$T/args.rollup"
ARGLOG="$T/args.rollup" MODE=ok RED=awk J rollup 2026-07-15 > /dev/null 2>&1
if grep -A1 -xF -- '--model' "$T/args.rollup" | grep -qxF 'test-model-heavy'; then
	ok 'rollup 帶 config 的 model_rollup'
else
	bad 'rollup 帶 config 的 model_rollup' "$(grep -c . "$T/args.rollup") 個引數中找不到"
fi
rm -f "$T/args.capture" "$SPOOL"
ARGLOG="$T/args.capture" TODAY=2026-07-15 MODE=ok CAPMIN=10 JH < "$T/payload.a" > /dev/null 2>&1
if grep -A1 -xF -- '--model' "$T/args.capture" | grep -qxF 'test-model-light'; then
	ok 'capture 帶 config 的 model_capture'
else
	bad 'capture 帶 config 的 model_capture' '引數裡找不到'
fi
rm -f "$T/args.env"
ARGLOG="$T/args.env" MODE=ok RED=awk env JOURNAL_MODEL=override-model \
	HOME="$T/home" JR_CONFIG_HOME="$T/cfg" CLAUDE_CONFIG_DIR="$T/claude" \
	CLAUDE_SHIM_MODE=ok CLAUDE_SHIM_ARGLOG="$T/args.env" JOURNAL_NO_TIMER=1 \
	PATH="$T/bin:$PATH" "$BIN" rollup 2026-07-15 > /dev/null 2>&1
if grep -A1 -xF -- '--model' "$T/args.env" | grep -qxF 'override-model'; then
	ok 'JOURNAL_MODEL 環境變數蓋過 config'
else
	bad 'JOURNAL_MODEL 環境變數蓋過 config' '引數裡找不到'
fi

# ================================================================ 8 · SLI check

printf '\n== 8 · SLI check ==\n'
STATUS="$T/data/status/testhost.yml"

printf -- '- [x] 一\n- [x] 二\n- [ ] 三\n' > "$T/checklist.md"
printf '目標 X 的證據：大部分完成，文件缺最後一節。\n' > "$T/evidence.md"

cat > "$T/data/GOALS.md" <<EOF
# 測試目標

- id: g-pass
  title: probe 會過
  sli: { kind: probe, cmd: "true" }
- id: g-fail
  title: probe 會掛
  sli: { kind: probe, cmd: "exit 3" }
- id: g-file
  title: file 型
  sli: { kind: file, cmd: "grep -q hello $T/repo-a/a.txt" }
- id: g-list
  title: checklist 2/3
  sli: { kind: checklist, source: $T/checklist.md }
- id: g-th-pass
  title: threshold 過
  sli: { kind: threshold, cmd: "echo 7", target: 5 }
- id: g-th-part
  title: threshold 未達
  sli: { kind: threshold, cmd: "echo 3", target: 9 }
- id: g-judge
  title: judge 軟評
  sli: { kind: judge, source: $T/evidence.md }
- id: g-manual
  title: 要密碼的
  sli: { kind: manual }
  done-when: 人工登入後驗證
- id: g-na
  title: 只有 infra 機看得到
  sli: { kind: probe, cmd: "true" }
  requires: { paths: ["/nonexistent/infra"] }

<!--
- id: g-commented
  title: 註解掉的不該跑
  sli: { kind: probe, cmd: "true" }
-->
EOF
git -C "$T/data" add GOALS.md
git -C "$T/data" -c user.name=T -c user.email=test@x commit -q -m 'test: goals'

MODE=ok J check > "$T/check.log" 2>&1
a_nz 'check 有 fail 時 exit 非零' $?
a_grep 'probe pass' "$STATUS" 'g-pass: { state: pass'
a_grep 'probe fail + exit code' "$STATUS" 'g-fail: { state: fail, kind: probe, detail: "exit 3'
a_grep 'file 型 pass' "$STATUS" 'g-file: { state: pass'
a_grep 'checklist partial 2/3' "$STATUS" 'g-list: { state: partial, kind: checklist, detail: "2/3" }'
a_grep 'threshold pass 7/5' "$STATUS" 'g-th-pass: { state: pass, kind: threshold, detail: "7/5" }'
a_grep 'threshold partial 3/9' "$STATUS" 'g-th-part: { state: partial, kind: threshold, detail: "3/9" }'
a_grep 'judge 軟評帶 ~ 前綴' "$STATUS" 'g-judge: { state: partial, kind: judge, detail: "~'
a_grep 'manual 不自動跑' "$STATUS" 'g-manual: { state: manual'
a_grep 'requires 不滿足 → na 不是 fail' "$STATUS" 'g-na: { state: na, kind: probe, detail: "此機看不到 /nonexistent/infra"'
a_ngrep '<!-- --> 區塊不執行' "$STATUS" 'g-commented'
a_grep 'agent_health 一併寫入' "$STATUS" 'agent_health: ok'
a_eq  'check 結果已 commit' "$(git -C "$T/data" status --porcelain | wc -l | tr -d ' ')" '0'

# ================================================================ 9 · 納管（P4）

printf '\n== 9 · 納管 ==\n'

# 端到端自檢：拿本地 bare repo 當 origin，全鏈真 push
git init -q --bare "$T/origin.git"
git --git-dir "$T/origin.git" symbolic-ref HEAD refs/heads/main
MODE=ok J init --data-remote "$T/origin.git" > "$T/init-full.log" 2>&1
a_rc '完整 init（含端到端自檢）成功' $? 0
a_grep '  自檢真的跑了' "$T/init-full.log" '端到端自檢通過'
a_eq  '  遠端與本地同步' "$(git -C "$T/data" rev-parse HEAD)" "$(git --git-dir "$T/origin.git" rev-parse refs/heads/main 2>/dev/null)"
if git --git-dir "$T/origin.git" log refs/heads/main --format=%s | grep -qF 'selfcheck 還原'; then
	ok '  自檢檔已還原（遠端也乾淨）'
else
	bad '  自檢檔已還原（遠端也乾淨）' '沒看到還原 commit'
fi
[ -f "$T/data/status/.selfcheck-testhost" ] && bad '  工作區沒留自檢檔' '留了' || ok '  工作區沒留自檢檔'

MODE=ok J init --data-remote "$T/origin.git" > /dev/null 2>&1
a_rc '完整 init 重跑冪等' $? 0

# deploy key（假 HOME 裡）
[ -f "$T/home/.ssh/journal_testhost" ] && ok 'deploy key 已產生' || bad 'deploy key 已產生' '缺'
a_grep 'ssh alias 已寫入' "$T/home/.ssh/config" 'Host journal.github.com'
_alias_n=$(grep -cF 'Host journal.github.com' "$T/home/.ssh/config")
a_eq 'ssh alias 不重複' "$_alias_n" '1'

# 角色：已有 aggregator 就拒絕，--force-takeover 放行
cat > "$T/data/hosts/otherhost.yml" <<'EOF'
host: otherhost
roles: [node, aggregator]
agent_health: ok
last_seen: 2026-07-15T00:00:00+08:00
EOF
MODE=ok J init --data-remote "$T/origin.git" --role aggregator > "$T/agg.log" 2>&1
a_nz 'aggregator 已存在 → 拒絕' $?
a_grep '  拒絕訊息點名對方' "$T/agg.log" '已有 aggregator：otherhost'
MODE=ok J init --data-remote "$T/origin.git" --role aggregator --force-takeover > /dev/null 2>&1
a_rc '--force-takeover 放行' $? 0
a_grep '  角色寫進 hosts' "$T/data/hosts/testhost.yml" 'roles: [node, aggregator]'

# hosts 指令
MODE=ok J hosts > "$T/hosts.out" 2>&1
a_grep 'hosts 列出本機' "$T/hosts.out" 'testhost'
a_grep 'hosts 列出他機' "$T/hosts.out" 'otherhost'

# revoke（從「這台」revoke 他機）
MODE=ok J revoke otherhost > /dev/null 2>&1
a_rc 'revoke 成功' $? 0
a_grep '  retired 標記落地' "$T/data/hosts/otherhost.yml" 'retired: '
MODE=ok J revoke testhost > /dev/null 2>&1
a_nz 'revoke 自己被擋' $?

# _onfail：unit 掛掉 → hosts 留 fail 標記；下一次 rollup 蓋回真實健康度
MODE=ok J _onfail rollup > /dev/null 2>&1
a_grep 'OnFailure 標記 fail' "$T/data/hosts/testhost.yml" 'agent_health: fail'
a_grep '  原因帶時間' "$T/data/hosts/testhost.yml" 'OnFailure 觸發'
MODE=ok J rollup 2026-07-15 > /dev/null 2>&1
a_grep '成功的 rollup 蓋回健康度' "$T/data/hosts/testhost.yml" 'agent_health: ok'

# doctor --yes：拔掉 hook 後自動補回
python3 - "$T/claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.get('hooks', {}).pop('SessionEnd', None)
json.dump(d, open(p, 'w'))
PY2
grep -qF 'session-end.sh' "$T/claude/settings.json" && bad 'doctor 前置：hook 已拔' '沒拔掉' || ok 'doctor 前置：hook 已拔'
MODE=ok J doctor --yes > /dev/null 2>&1
a_grep 'doctor --yes 自動補回 hook' "$T/claude/settings.json" 'hooks/session-end.sh'

# uninstall：拆 hook 保資料
MODE=ok J uninstall > /dev/null 2>&1
grep -qF 'session-end.sh' "$T/claude/settings.json" && bad 'uninstall 移除 hook' '還在' || ok 'uninstall 移除 hook'
[ -f "$T/data/daily/2026-07-15__testhost.md" ] && ok '  資料保留' || bad '  資料保留' 'daily 不見了'
[ -f "$T/cfg/host.yml" ] && ok '  本機身分保留' || bad '  本機身分保留' '被刪了'

# ================================================================ 10 · 中心（P5）

printf '\n== 10 · 中心 ==\n'

# 佈景：第二台機器 hostb（infra 角色的模擬）——
#   entra 目標：hosta（本機 testhost）的 na 比 hostb 的 partial「新」，
#   優勝者仍必須是 hostb 的 partial —— na 永遠選不上
cat > "$T/data/status/hostb.yml" <<'EOF'
host: hostb
checked_at: 2026-07-13T22:10:00+08:00
agent_health: degraded
degraded_reason: "無 node / python3"
results:
  entra: { state: partial, kind: checklist, detail: "4/6" }
  all-na-goal: { state: na, kind: probe, detail: "hostb 也看不到" }
EOF
cat > "$T/data/status/testhost.yml.extra" <<'EOF'
EOF
rm -f "$T/data/status/testhost.yml.extra"
# 本機 status 補 entra 的 na（較新）與 all-na-goal 的 na
cat >> "$T/data/status/testhost.yml" <<'EOF'
  entra: { state: na, kind: checklist, detail: "此機看不到 /opt/infra" }
  all-na-goal: { state: na, kind: probe, detail: "此機也看不到" }
EOF
cat > "$T/data/hosts/hostb.yml" <<'EOF'
host: hostb
registered_at: 2026-07-01T00:00:00+08:00
os: linux
roles: [node]
agent_version: 0.1.0
agent_health: degraded
degraded_reason: "無 node / python3，減量走 awk 粗篩"
reducer: awk
last_seen: 2026-07-10T23:00:00+08:00
EOF
# hostb 的 daily（供 trace 跨機）
cat > "$T/data/daily/2026-07-14__hostb.md" <<'EOF'
---
date: 2026-07-14
host: hostb
metrics: { sessions: 1, commits: 1, files_touched: 1 }
goals_touched: [proj-a]
generated_by: rollup
reduced_by: awk
redactions: 0
status: ok
---
## 早會
- hostb 這天把 proj-a 的環境弄好了
## 摘要
- proj-a | 進度 | proj-a | hostb 上環境就緒
## 完成
- 環境設定
## 拍板
## 待續
## 卡住
EOF
git -C "$T/data" add -A
git -C "$T/data" -c user.name=T -c user.email=test@x commit -q -m 'test: 第二台機器的資料'

# aggregate（testhost 在 phase 9 已是 aggregator）
TODAY=2026-07-15 MODE=ok J aggregate > "$T/agg2.log" 2>&1
a_rc 'aggregate 成功' $? 0
PROG="$T/data/progress.md"
a_grep '優勝者是最新的非 na（partial 4/6，即使 na 比較新）' "$PROG" '4/6'
a_grep '  由 hostb 量測' "$PROG" 'hostb'
a_grep '全 na 的目標標 unchecked 不是 fail' "$PROG" 'unchecked'
a_ngrep '  沒有把全 na 誤報成 fail' "$PROG" 'all-na-goal**（fail'
a_grep 'host staleness：hostb 沉默 5 天（>3）' "$PROG" '沉默 5 天'
a_grep 'agent unhealthy：hostb 降級被標出' "$PROG" 'hostb 降級運行'
a_ngrep 'retired 的 otherhost 不進沉默 alert' "$PROG" 'otherhost 沉默'
a_grep '最近 7 天有兩台的早會' "$PROG" '（hostb）hostb 這天把 proj-a 的環境弄好了'
a_grep 'progress 有目標總表' "$PROG" '| 燈 | 目標 |'
a_eq  'aggregate 後 repo 乾淨（已 commit）' "$(git -C "$T/data" status --porcelain | wc -l | tr -d ' ')" '0'

# render 一併產出
HTML="$T/data/web/progress.html"
[ -f "$HTML" ] && ok 'render 產出 progress.html' || bad 'render 產出 progress.html' '缺'
a_grep '  html 有目標與狀態' "$HTML" 'class="tag s-warn">partial'
a_grep '  html 有 O9 旋鈕表' "$HTML" 'standup_lines'
a_grep '  html 是自足的（沒有外部資源）' "$HTML" '<style>'
a_ngrep '  html 無外連 script' "$HTML" 'src="http'

# 非 aggregator 被擋
sed -i 's/^role: aggregator/role: node/' "$T/cfg/host.yml"
TODAY=2026-07-15 MODE=ok J aggregate > "$T/agg3.log" 2>&1
a_nz '非 aggregator 寫 progress 被擋' $?
a_grep '  錯誤訊息引用規則' "$T/agg3.log" '不是 aggregator'
TODAY=2026-07-15 MODE=ok J aggregate --preview > "$T/agg4.log" 2>&1
a_rc '--preview 任何機器可跑' $? 0
sed -i 's/^role: node/role: aggregator/' "$T/cfg/host.yml"

# trace：跨天跨機串線
TODAY=2026-07-15 MODE=ok J trace proj-a > "$T/trace.out" 2>&1
a_grep 'trace 串到本機那天' "$T/trace.out" '2026-07-15 @ testhost'
a_grep 'trace 串到 hostb 那天' "$T/trace.out" '2026-07-14 @ hostb'
a_grep '  條目帶內容' "$T/trace.out" 'hostb 上環境就緒'

# digest：該週（2026-07-15 落在 2026-W29）
TODAY=2026-07-15 MODE=ok J digest 2026-W29 > "$T/digest.out" 2>&1
a_rc 'digest 成功' $? 0
WEEKF="$T/data/weekly/2026-W29.md"
a_grep '週報檔落地' "$WEEKF" '## 本週主線'
a_grep '  frontmatter 有週起點' "$WEEKF" 'week_start: 2026-07-13'
a_grep 'progress 指令可讀' "$PROG" '# progress'

# ================================================================ 11 · 第二台機器（infra 模擬）

printf '\n== 11 · 第二台機器 ==\n'

# 全新身分 + --data-remote → 必須 clone 既有歷史，不是 seed 分岔
J2() {
	env HOME="$T/home2" JR_CONFIG_HOME="$T/cfg2" CLAUDE_CONFIG_DIR="$T/claude" \
		CLAUDE_SHIM_MODE=ok JOURNAL_NO_TIMER=1 JOURNAL_TODAY=2026-07-15 \
		PATH="$T/bin:$PATH" "$BIN" "$@"
}
mkdir -p "$T/home2" "$T/cfg2"
J2 init --host-id host2 --data-dir "$T/data2" --data-remote "$T/origin.git" > "$T/init2.log" 2>&1
a_rc '第二台 init（clone 路徑）成功' $? 0
a_grep '  真的走了 clone' "$T/init2.log" 'clone 資料 repo'
[ -f "$T/data2/daily/2026-07-15__testhost.md" ] && ok '  clone 到既有歷史（看得到第一台的 daily）' \
	|| bad '  clone 到既有歷史' '沒有第一台的 daily'
a_grep '  自檢通過' "$T/init2.log" '端到端自檢通過'
a_grep '  第二台已註冊進 hosts/' "$T/data2/hosts/host2.yml" 'host: host2'

# 兩台聚合驗收：第二台 push 的註冊，第一台 pull 後 aggregate 看得到
MODE=ok J rollup 2026-07-15 > /dev/null 2>&1   # 觸發第一台 pull
a_grep '第一台 pull 到第二台的註冊' "$T/data/hosts/host2.yml" 'host: host2'
TODAY=2026-07-15 MODE=ok J aggregate > /dev/null 2>&1
a_grep 'progress 同時反映兩台' "$T/data/progress.md" 'host2'

# 歷史分岔守門：先 seed 本地、再接不相干 remote → 必須被擋
mkdir -p "$T/cfg3" "$T/home3"
env HOME="$T/home3" JR_CONFIG_HOME="$T/cfg3" CLAUDE_CONFIG_DIR="$T/claude" \
	CLAUDE_SHIM_MODE=ok JOURNAL_NO_TIMER=1 PATH="$T/bin:$PATH" \
	"$BIN" init --local --host-id host3 --data-dir "$T/data3" > /dev/null 2>&1
env HOME="$T/home3" JR_CONFIG_HOME="$T/cfg3" CLAUDE_CONFIG_DIR="$T/claude" \
	CLAUDE_SHIM_MODE=ok JOURNAL_NO_TIMER=1 PATH="$T/bin:$PATH" \
	"$BIN" init --host-id host3 --data-dir "$T/data3" --data-remote "$T/origin.git" > "$T/init3.log" 2>&1
a_nz '分岔守門：seed 過的本地接既有 remote 被擋' $?
a_grep '  指路訊息' "$T/init3.log" '歷史不相干'

# 降級：aggregator → node
sed -i 's/^role: aggregator/role: node/' "$T/cfg/host.yml" 2>/dev/null || true
MODE=ok J init --data-remote "$T/origin.git" --role node > /dev/null 2>&1
a_grep '--role node 真的降級' "$T/cfg/host.yml" 'role: node'
MODE=ok J init --data-remote "$T/origin.git" --role aggregator --force-takeover > /dev/null 2>&1
a_grep '  再升回 aggregator（收尾）' "$T/cfg/host.yml" 'role: aggregator'

# ================================================================ 結果

printf '\n════════════════════════════════\n'
printf '  %d 通過，%d 失敗\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '%s\n' "$FAILS"
	exit 1
fi
exit 0
