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
		JOURNAL_REDUCER="${RED:-}" \
		JR_CLAUDE_TIMEOUT="${TOUT:-60}" \
		JR_MAXTEXT="${MAXT:-1200}" \
		PATH="$T/bin:$PATH" \
		"$BIN" "$@"
}

DAILY="$T/data/daily/2026-07-15__testhost.md"

# ================================================================ 佈景

mkdir -p "$T/bin" "$T/home" "$T/claude/projects" "$T/u"

# --- 假 claude ---------------------------------------------------
cat > "$T/bin/claude" <<'SHIM'
#!/bin/sh
for a in "$@"; do case $a in --version) echo '9.9.9 (shim)'; exit 0 ;; esac; done
printf '1\n' >> "${CLAUDE_SHIM_LOG:-/dev/null}"
case "${CLAUDE_SHIM_MODE:-ok}" in
	reject)
		# 模擬舊版 claude 不認得 --safe-mode：帶了就立刻吐 usage error
		for a in "$@"; do case $a in --safe-mode)
			echo "error: unknown option '--safe-mode'" >&2; exit 1 ;;
		esac; done
		cat > /dev/null
		printf 'goals_touched: bare\n\n## 完成\n- bare 模式完成\n## 拍板\n## 待續\n## 卡住\n' ;;
	ok)
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

# 測試專用 config —— 蓋掉 example 的預留內容
cat > "$T/data/config.yml" <<EOF
timezone: Asia/Taipei
repos:
  - $T/repo-a
git_authors:
  - test@x
slug_map:
  -home-test-proj-a--claude-worktrees-fix: proj-a
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

# ================================================================ 結果

printf '\n════════════════════════════════\n'
printf '  %d 通過，%d 失敗\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '%s\n' "$FAILS"
	exit 1
fi
exit 0
