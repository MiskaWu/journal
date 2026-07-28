#!/usr/bin/env python3
"""lib/reduce.py —— 減量·快路徑（python3）

和 reduce.awk 產出**同一種結構**，差別只在忠實度：這裡是真的剖析 JSON，所以
工具呼叫可以帶參數提示（`Bash(git status)`），awk 粗篩只能給工具名。

輸出契約（見 reduce.awk 檔頭，三條路徑必須一致）：
    === session <sid> | project <p> | branch <b> | cwd <c>
    [HH:MM] U> …
    [HH:MM] A> …
    [HH:MM] T> Bash(git status) Read(DESIGN.md)

用法： reduce.py FILE START_UTC END_UTC TZOFF_SECONDS MAXTEXT PROJECT SID
"""

import json
import os
import sys

# 工具參數裡拿哪個欄位當提示 —— 挑「一眼看得出在做什麼」的那個
HINT_KEYS = (
    "description", "command", "file_path", "path", "pattern",
    "query", "url", "prompt", "skill", "name",
)


def hhmm(ts, tzoff):
    """2026-07-28T10:45:09.976Z → 本機 HH:MM"""
    try:
        h, m, s = int(ts[11:13]), int(ts[14:16]), int(ts[17:19])
    except (ValueError, IndexError):
        return "??:??"
    t = (h * 3600 + m * 60 + s + tzoff) % 86400
    return "%02d:%02d" % (t // 3600, (t % 3600) // 60)


def clean(s, maxtext):
    s = " ".join(str(s).split())
    return s[:maxtext] + "…" if len(s) > maxtext else s


def hint(tool, inp, limit=60):
    if not isinstance(inp, dict):
        return ""
    for k in HINT_KEYS:
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            v = " ".join(v.split())
            if k in ("file_path", "path"):
                v = os.path.basename(v) or v
            return v[:limit]
    return ""


def blocks(content):
    """content 可能是字串或區塊陣列 —— 一律正規化成區塊陣列"""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content if isinstance(content, list) else []


def main():
    if len(sys.argv) < 8:
        sys.stderr.write("usage: reduce.py FILE START END TZOFF MAXTEXT PROJECT SID\n")
        return 2
    path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
    tzoff, maxtext = int(sys.argv[4]), int(sys.argv[5])
    project, sid = sys.argv[6], sys.argv[7]

    out = []
    emitted = False
    cwd = branch = ""

    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError as exc:
        sys.stderr.write("reduce.py: %s\n" % exc)
        return 1

    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue          # 半行 / 寫到一半的 transcript —— 跳過，不整批失敗
            if not isinstance(rec, dict):
                continue

            ts = rec.get("timestamp")
            if not isinstance(ts, str) or not (start <= ts < end):
                continue
            # tool_result 是最肥的東西，整筆丟掉（1900:1 壓縮比就靠這步）
            if "toolUseResult" in rec:
                continue

            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            role = msg.get("role")
            if role not in ("user", "assistant"):
                continue

            cwd = rec.get("cwd") or cwd
            branch = rec.get("gitBranch") or branch
            mark = "s" if rec.get("isSidechain") else ""
            t = hhmm(ts, tzoff)

            texts, tools = [], []
            for b in blocks(msg.get("content")):
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text" and isinstance(b.get("text"), str):
                    texts.append(b["text"])
                elif bt == "tool_use":
                    h = hint(b.get("name", "?"), b.get("input"))
                    tools.append("%s(%s)" % (b.get("name", "?"), h) if h else str(b.get("name", "?")))
                # thinking / tool_result / image：不留

            if not texts and not tools:
                continue
            if not emitted:
                emitted = True
                out.append("=== session %s | project %s | branch %s | cwd %s"
                           % (sid or "?", project or "?", branch or "-", cwd or "-"))
            tag = "A" if role == "assistant" else "U"
            if texts:
                body = clean(" ".join(texts), maxtext)
                if body:
                    out.append("[%s] %s%s> %s" % (t, tag, mark, body))
            if tools:
                out.append("[%s] T%s> %s" % (t, mark, clean(" ".join(tools), 400)))

    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
