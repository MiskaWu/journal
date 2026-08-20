#!/bin/sh
# tests/task.sh —— 任務機制（journal task）的狀態機測試
#
# 全程假環境：HOME / JR_CONFIG_HOME 指向 mktemp，資料 repo 是本地 git、無 remote。
# 不需要 claude —— task 不呼叫模型，地板只有 sh / git / awk。
#
# 用法： sh tests/task.sh
# 全綠 exit 0；任何失敗 exit 1 並在結尾列出清單。

set -u

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/journal"
T=$(mktemp -d "${TMPDIR:-/tmp}/journal-task.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

PASS=0; FAIL=0; FAILS=''
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILS="$FAILS
    ✖ $1 — $2"; printf '  FAIL %s — %s\n' "$1" "$2"; }

a_grep()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "找不到「$3」於 $2"; fi; }
a_ngrep() { if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "不該出現「$3」於 $2"; else ok "$1"; fi; }
a_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望「$3」，得到「$2」"; fi; }
a_rc()    { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "期望 exit $3，得到 $2"; fi; }
a_nz()    { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" '期望非零 exit，得到 0'; fi; }
a_file()  { if [ -f "$2" ]; then ok "$1"; else bad "$1" "檔案不存在：$2"; fi; }
a_nofile(){ if [ -f "$2" ]; then bad "$1" "檔案不該存在：$2"; else ok "$1"; fi; }

# ---------------------------------------------------------------- 假環境

DATA="$T/data"
mkdir -p "$T/home" "$T/cfg" "$DATA/tasks/archive"
git -C "$DATA" init -q
git -C "$DATA" symbolic-ref HEAD refs/heads/main 2>/dev/null

cat > "$T/cfg/host.yml" <<EOF
host: testhost
data_dir: $DATA
EOF
cat > "$DATA/config.yml" <<'EOF'
timezone: Asia/Taipei
task_prefix: hy
EOF
: > "$DATA/now.md"
git -C "$DATA" add -A
git -C "$DATA" -c user.name=t -c user.email=t@t commit -qm init

J() {
	env HOME="$T/home" \
		JR_CONFIG_HOME="$T/cfg" \
		JOURNAL_NONINTERACTIVE=1 \
		NO_COLOR=1 \
		"$BIN" task "$@"
}

fm() { awk -v k="$2" 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{p=index($0,":"); if(p&&substr($0,1,p-1)==k){v=substr($0,p+1); sub(/^[ \t]+/,"",v); sub(/[ \t\r]+$/,"",v); print v; exit}}' "$1"; }
knob() { # knob KEY VALUE —— 設定 config.yml 的旋鈕（存在則替換，否則附加）
	if grep -q "^$1:" "$DATA/config.yml"; then
		sed "s/^$1:.*/$1: $2/" "$DATA/config.yml" > "$DATA/config.yml.n" && mv "$DATA/config.yml.n" "$DATA/config.yml"
	else
		printf '%s: %s\n' "$1" "$2" >> "$DATA/config.yml"
	fi
}

printf '═ 建立與編號\n'

id1=$(J new '第一件事')
a_eq 'new 回傳第一個編號' "$id1" 'hy-0001'
a_file 'new 建了任務檔' "$DATA/tasks/hy-0001.md"
a_eq 'new 初始狀態是 backlog' "$(fm "$DATA/tasks/hy-0001.md" status)" 'backlog'
git -C "$DATA" log --oneline > "$T/gitlog.txt"
a_grep 'commit 訊息含編號' "$T/gitlog.txt" 'task: 新增 hy-0001'

id2=$(J new '第二件事')
a_eq '編號遞增' "$id2" 'hy-0002'

printf '═ 取件（idle 旋鈕）\n'

J next > "$T/next1.out" 2> "$T/next1.err"; rc=$?
a_rc 'now 空 + idle → exit 3' "$rc" 3
a_grep '空轉原因講人話' "$T/next1.err" '沒事做'

printf '═ ready → next 認領\n'

J ready hy-0001 > /dev/null 2>&1
a_eq 'ready 轉了狀態' "$(fm "$DATA/tasks/hy-0001.md" status)" 'ready'
printf 'hy-0001\n' >> "$DATA/now.md"
J next > "$T/next2.out" 2> /dev/null; rc=$?
a_rc 'now 有 ready → 取到' "$rc" 0
a_grep '回傳完整任務檔' "$T/next2.out" 'id: hy-0001'
a_eq '取件即認領（doing）' "$(fm "$DATA/tasks/hy-0001.md" status)" 'doing'
a_eq '認領者寫入' "$(fm "$DATA/tasks/hy-0001.md" claimed_by)" 'testhost'

printf '═ update 的紀律\n'

J update hy-0001 --status done 2> "$T/done.err"; rc=$?
a_nz '代理標 done 被拒' "$rc"
a_eq '拒絕後狀態不動' "$(fm "$DATA/tasks/hy-0001.md" status)" 'doing'
a_grep '拒絕訊息指路' "$T/done.err" 'journal task done'

J update hy-0001 --status needs-input 2> /dev/null; rc=$?
a_nz 'needs-input 沒留言被拒' "$rc"

J update hy-0001 --status needs-input --comment '卡住：fallback 逾時要設多少？' > /dev/null 2>&1; rc=$?
a_rc '帶留言的 needs-input 過' "$rc" 0
a_eq '狀態轉了' "$(fm "$DATA/tasks/hy-0001.md" status)" 'needs-input'
a_grep '問題寫在任務上' "$DATA/tasks/hy-0001.md" '卡住：fallback 逾時要設多少？'

J update hy-0001 --status needs-input --comment '卡住：fallback 逾時要設多少？' > /dev/null 2>&1
n=$(grep -cF '卡住：fallback 逾時要設多少？' "$DATA/tasks/hy-0001.md")
a_eq '重試不長第二筆留言（冪等）' "$n" '1'

printf '═ 人回應 → 再取件 → review\n'

J ready hy-0001 --comment '回應：逾時 5 秒，逾時走 T2' > /dev/null 2>&1
a_eq '人回應後回 ready' "$(fm "$DATA/tasks/hy-0001.md" status)" 'ready'
a_eq '回 ready 清掉認領' "$(fm "$DATA/tasks/hy-0001.md" claimed_by)" ''
J next > /dev/null 2>&1
J update hy-0001 --status review --comment '已開 MR' > /dev/null 2>&1
a_eq '推進到 review' "$(fm "$DATA/tasks/hy-0001.md" status)" 'review'

printf '═ 待審煞車\n'

knob task_review_limit 1
J ready hy-0002 > /dev/null 2>&1
printf 'hy-0002\n' >> "$DATA/now.md"
J next > /dev/null 2> "$T/brake.err"; rc=$?
a_rc '待審達上限 → exit 3' "$rc" 3
a_grep '煞車訊息講原因' "$T/brake.err" '煞車'
knob task_review_limit 3

printf '═ done 與封存（人的出口）\n'

J done hy-0001 > /dev/null 2>&1
a_eq 'done 由人的指令進' "$(fm "$DATA/tasks/hy-0001.md" status)" 'done'
J archive hy-0001 > /dev/null 2>&1
a_nofile '封存後原位消失' "$DATA/tasks/hy-0001.md"
a_file '封存 = 移進 archive/' "$DATA/tasks/archive/hy-0001.md"
J get hy-0001 > "$T/get.out" 2>&1; rc=$?
a_rc 'get 讀得到封存的' "$rc" 0

printf '═ 租約回收\n'

J next > /dev/null 2>&1        # 認領 hy-0002（now 裡 ready 的下一件）
a_eq '取到 hy-0002' "$(fm "$DATA/tasks/hy-0002.md" status)" 'doing'
sed 's/^heartbeat_epoch:.*/heartbeat_epoch: 1000/' "$DATA/tasks/hy-0002.md" > "$T/x" && mv "$T/x" "$DATA/tasks/hy-0002.md"
J next > /dev/null 2> "$T/reap.err"   # 回收後 hy-0002 回 ready，隨即被重新認領
a_grep '回收有留系統留言' "$DATA/tasks/hy-0002.md" '認領逾時回收'
a_eq '回收後被重新認領' "$(fm "$DATA/tasks/hy-0002.md" status)" 'doing'

printf '═ backlog 旋鈕與編號延續\n'

knob task_stalled backlog
id3=$(J new '第三件事')
a_eq '編號不因封存重用' "$id3" 'hy-0003'
J ready hy-0003 > /dev/null 2>&1      # 不放進 now
J update hy-0002 --status review > /dev/null 2>&1   # now 裡沒有 ready 的了
J next > "$T/next3.out" 2> /dev/null; rc=$?
a_rc 'backlog 旋鈕 → 去池裡撈' "$rc" 0
a_grep '撈到池裡那件' "$T/next3.out" 'id: hy-0003'

printf '═ list\n'

J list > "$T/list.out" 2> /dev/null
a_grep 'list 列出 doing' "$T/list.out" 'hy-0003'
a_grep 'list 列出 review' "$T/list.out" 'hy-0002'
a_ngrep 'list 不列封存的' "$T/list.out" 'hy-0001'

# ---------------------------------------------------------------- 結果

printf '\n%s 通過，%s 失敗\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '%s\n' "$FAILS"
	exit 1
fi
exit 0
