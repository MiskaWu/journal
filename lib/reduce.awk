# lib/reduce.awk —— 減量·保底路徑（POSIX awk）
#
# 這是 §9 依賴階梯的最底層：沒有 node、沒有 python3、沒有 jq 時走這裡。
# **它是正確性的基準，不是選配。**
#
# 手法是「粗篩」不是剖析（DESIGN §9 明列：token 約增 3–5 倍）。做法是靠 JSON 的
# 一個性質：字串內部的引號一定被跳脫成 \" ，所以 `"text":"` 這種字面只可能命中
# 真正的 key，不會命中別人字串裡的內容。剩下的就是逐位元組掃到未跳脫的收尾引號。
#
# 輸入：一個 transcript .jsonl（一行一則訊息）
# 變數：
#   WSTART/WEND  UTC ISO 字串，半開區間 [WSTART, WEND)
#   TZOFF      本機時區偏移（秒），只用來把 UTC 時刻換成本機 HH:MM
#   MAXTEXT    單則文字截斷位元組數
#   PROJECT    這個 transcript 對應的邏輯專案名
#   SID        session id
#
# 輸出契約（三條路徑必須一致，見 reduce.py / reduce.node.js）：
#   === session <sid> | project <p> | branch <b> | cwd <c>
#   [HH:MM] U> 使用者說的話
#   [HH:MM] A> 助理說的話
#   [HH:MM] T> Bash Read Edit
#
# ⚠ 呼叫端必須設 LC_ALL=C —— 我們要的是位元組語意，截斷再用 utf8_trim 補回邊界。

BEGIN {
	if (MAXTEXT + 0 <= 0) MAXTEXT = 1200
	# UTF-8 邊界判定表：POSIX awk 沒有 ord()，用 sprintf("%c") 現場造。
	for (i = 128; i < 192; i++) CONT = CONT sprintf("%c", i)
	for (i = 192; i < 245; i++) LEAD = LEAD sprintf("%c", i)
	emitted = 0
}

# ---------------------------------------------------------------- 工具函式

# 把 UTF-8 位元組串截到 n 個位元組，且不留半個字
function utf8_trim(s, n,    t, k, lead, want, byte) {
	if (length(s) <= n) return s
	t = substr(s, 1, n)
	# 先剝掉尾端的延續位元組（最多 3 個 —— UTF-8 一個字最長 4 位元組）
	k = 0
	while (k < 3 && length(t) > 0 && index(CONT, substr(t, length(t), 1)) > 0) {
		t = substr(t, 1, length(t) - 1)
		k++
	}
	if (length(t) == 0) return ""
	lead = substr(t, length(t), 1)
	if (index(LEAD, lead) > 0) {
		# index 位置 1..53 對應位元組 192..244，據此推算這個字該有幾個位元組
		byte = index(LEAD, lead) + 191
		if (byte >= 240)      want = 4
		else if (byte >= 224) want = 3
		else                  want = 2
		# 剛好完整就留著；被切斷才連 lead byte 一起丟
		if (k + 1 != want) t = substr(t, 1, length(t) - 1)
	}
	return t
}

# 從 s 的第 p 個位元組（開頭引號的下一個）掃出 JSON 字串值
function scan_str(s, p,    out, c, e, n) {
	out = ""
	n = length(s)
	while (p <= n) {
		c = substr(s, p, 1)
		if (c == "\\") {
			e = substr(s, p + 1, 1)
			if (e == "n" || e == "r" || e == "t") { out = out " "; p += 2 }
			else if (e == "u") { out = out unesc_u(substr(s, p + 2, 4)); p += 6 }
			else if (e == "b" || e == "f") { out = out " "; p += 2 }
			else { out = out e; p += 2 }
		} else if (c == "\"") {
			return out
		} else {
			out = out c
			p++
		}
		# 早退：超過上限就不必再掃了（長字串在 awk 裡累加是二次成本）
		if (length(out) > MAXTEXT + 8) return out "…"
	}
	return out
}

# \uXXXX → UTF-8 位元組。實測 transcript 的 CJK 是裸 UTF-8，\u 只出現在控制字元，
# 但還是把 BMP 完整實作，免得哪天格式變了就默默吐亂碼。
function unesc_u(h,    v, i, c, d) {
	v = 0
	for (i = 1; i <= 4; i++) {
		c = substr(h, i, 1)
		d = index("0123456789abcdef", tolower(c)) - 1
		if (d < 0) return ""
		v = v * 16 + d
	}
	if (v < 32) return " "
	if (v < 128) return sprintf("%c", v)
	if (v < 2048) return sprintf("%c%c", 192 + int(v / 64), 128 + (v % 64))
	return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int((v % 4096) / 64), 128 + (v % 64))
}

function clean(s) {
	gsub(/[ \t]+/, " ", s)
	sub(/^ +/, "", s)
	sub(/ +$/, "", s)
	return s
}

function hhmm(ts,    h, m, s, t) {
	# ts = 2026-07-28T10:45:09.976Z（UTC）
	h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; s = substr(ts, 18, 2) + 0
	t = (h * 3600 + m * 60 + s + TZOFF) % 86400
	if (t < 0) t += 86400
	return sprintf("%02d:%02d", int(t / 3600), int((t % 3600) / 60))
}

function header(cwd, branch) {
	if (emitted) return
	emitted = 1
	printf "=== session %s | project %s | branch %s | cwd %s\n",
		(SID == "" ? "?" : SID), (PROJECT == "" ? "?" : PROJECT),
		(branch == "" ? "-" : branch), (cwd == "" ? "-" : cwd)
}

function field(line, key,    k) {
	k = index(line, "\"" key "\":\"")
	if (k == 0) return ""
	return scan_str(line, k + length(key) + 4)
}

# ---------------------------------------------------------------- 主迴圈

{
	# 1) 只留有時間戳、且落在目標日的行
	tk = index($0, "\"timestamp\":\"")
	if (tk == 0) next
	ts = substr($0, tk + 13, 24)
	if (ts < WSTART || ts >= WEND) next

	# 2) tool_result 是整份 transcript 最肥的東西 —— 整行丟掉。
	#    這一步就是 1900:1 壓縮比的來源，也是為什麼粗篩仍然夠用。
	if (index($0, "\"toolUseResult\":") > 0) next
	if (index($0, "\"type\":\"tool_result\"") > 0) next

	is_asst = (index($0, "\"role\":\"assistant\"") > 0)
	is_user = (!is_asst && index($0, "\"role\":\"user\"") > 0)
	if (!is_asst && !is_user) next

	cwd = field($0, "cwd")
	branch = field($0, "gitBranch")
	sub_mark = (index($0, "\"isSidechain\":true") > 0) ? "s" : ""
	t = hhmm(ts)

	if (is_user) {
		# 字串型："role":"user","content":"…"
		k = index($0, "\"role\":\"user\",\"content\":\"")
		if (k > 0) {
			txt = clean(scan_str($0, k + 25))
		} else {
			# 陣列型：抓 text 區塊
			txt = ""
			rest = $0
			while ((k = index(rest, "\"type\":\"text\",\"text\":\"")) > 0) {
				rest = substr(rest, k + 22)
				txt = txt (txt == "" ? "" : " ") clean(scan_str(rest, 1))
				if (length(txt) > MAXTEXT) break
			}
		}
		# system-reminder 之類的注入不是使用者說的話，但粗篩分不出來 —— 只做長度保護
		if (txt != "") {
			header(cwd, branch)
			printf "[%s] U%s> %s\n", t, sub_mark, utf8_trim(txt, MAXTEXT)
		}
		next
	}

	# 助理：文字區塊 + 工具名。thinking 用的是 "thinking" key，天生不會被抓到。
	txt = ""
	rest = $0
	while ((k = index(rest, "\"type\":\"text\",\"text\":\"")) > 0) {
		rest = substr(rest, k + 22)
		txt = txt (txt == "" ? "" : " ") clean(scan_str(rest, 1))
		if (length(txt) > MAXTEXT) break
	}
	if (clean(txt) != "") {
		header(cwd, branch)
		printf "[%s] A%s> %s\n", t, sub_mark, utf8_trim(clean(txt), MAXTEXT)
	}

	tools = ""
	rest = $0
	while ((k = index(rest, "\"type\":\"tool_use\"")) > 0) {
		rest = substr(rest, k + 17)
		kn = index(rest, "\"name\":\"")
		if (kn == 0) break
		nm = scan_str(rest, kn + 8)
		if (nm != "") tools = tools (tools == "" ? "" : " ") nm
	}
	if (tools != "") {
		header(cwd, branch)
		printf "[%s] T%s> %s\n", t, sub_mark, utf8_trim(tools, 400)
	}
}
