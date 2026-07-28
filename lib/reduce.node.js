#!/usr/bin/env node
/* lib/reduce.node.js —— 減量·快路徑（node）
 *
 * 與 reduce.py 完全同義，輸出契約見 reduce.awk 檔頭。存在的理由只有一個：
 * 有些機器有 node 沒 python3。三條路徑任一條在就不必退到 awk 粗篩。
 *
 * 用法： reduce.node.js FILE START_UTC END_UTC TZOFF_SECONDS MAXTEXT PROJECT SID
 */

'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const HINT_KEYS = [
	'description', 'command', 'file_path', 'path', 'pattern',
	'query', 'url', 'prompt', 'skill', 'name',
];

function hhmm(ts, tzoff) {
	const h = parseInt(ts.slice(11, 13), 10);
	const m = parseInt(ts.slice(14, 16), 10);
	const s = parseInt(ts.slice(17, 19), 10);
	if (!Number.isFinite(h) || !Number.isFinite(m) || !Number.isFinite(s)) return '??:??';
	let t = (h * 3600 + m * 60 + s + tzoff) % 86400;
	if (t < 0) t += 86400;
	const pad = (n) => String(n).padStart(2, '0');
	return `${pad(Math.floor(t / 3600))}:${pad(Math.floor((t % 3600) / 60))}`;
}

function clean(s, maxtext) {
	const v = String(s).split(/\s+/).filter(Boolean).join(' ');
	return v.length > maxtext ? v.slice(0, maxtext) + '…' : v;
}

function hint(input, limit) {
	if (!input || typeof input !== 'object') return '';
	for (const k of HINT_KEYS) {
		const v = input[k];
		if (typeof v === 'string' && v.trim()) {
			let out = v.split(/\s+/).filter(Boolean).join(' ');
			if (k === 'file_path' || k === 'path') out = path.basename(out) || out;
			return out.slice(0, limit);
		}
	}
	return '';
}

function blocks(content) {
	if (typeof content === 'string') return [{ type: 'text', text: content }];
	return Array.isArray(content) ? content : [];
}

async function main() {
	const [file, start, end, tzoffRaw, maxtextRaw, project, sid] = process.argv.slice(2);
	if (!sid) {
		process.stderr.write('usage: reduce.node.js FILE START END TZOFF MAXTEXT PROJECT SID\n');
		process.exitCode = 2;
		return;
	}
	const tzoff = parseInt(tzoffRaw, 10) || 0;
	const maxtext = parseInt(maxtextRaw, 10) || 1200;

	let emitted = false;
	let cwd = '';
	let branch = '';
	const out = [];

	const rl = readline.createInterface({
		input: fs.createReadStream(file, { encoding: 'utf8' }),
		crlfDelay: Infinity,
	});

	for await (const line of rl) {
		if (!line.trim()) continue;
		let rec;
		try { rec = JSON.parse(line); } catch { continue; }   // 寫到一半的行，跳過即可
		if (!rec || typeof rec !== 'object') continue;

		const ts = rec.timestamp;
		if (typeof ts !== 'string' || ts < start || ts >= end) continue;
		if ('toolUseResult' in rec) continue;                 // 最肥的東西，整筆丟掉

		const msg = rec.message;
		if (!msg || typeof msg !== 'object') continue;
		if (msg.role !== 'user' && msg.role !== 'assistant') continue;

		cwd = rec.cwd || cwd;
		branch = rec.gitBranch || branch;
		const mark = rec.isSidechain ? 's' : '';
		const t = hhmm(ts, tzoff);

		const texts = [];
		const tools = [];
		for (const b of blocks(msg.content)) {
			if (!b || typeof b !== 'object') continue;
			if (b.type === 'text' && typeof b.text === 'string') texts.push(b.text);
			else if (b.type === 'tool_use') {
				const h = hint(b.input, 60);
				tools.push(h ? `${b.name || '?'}(${h})` : String(b.name || '?'));
			}
			// thinking / tool_result / image：不留
		}
		if (!texts.length && !tools.length) continue;

		if (!emitted) {
			emitted = true;
			out.push(`=== session ${sid || '?'} | project ${project || '?'} | branch ${branch || '-'} | cwd ${cwd || '-'}`);
		}
		const tag = msg.role === 'assistant' ? 'A' : 'U';
		if (texts.length) {
			const body = clean(texts.join(' '), maxtext);
			if (body) out.push(`[${t}] ${tag}${mark}> ${body}`);
		}
		if (tools.length) out.push(`[${t}] T${mark}> ${clean(tools.join(' '), 400)}`);
	}

	if (out.length) process.stdout.write(out.join('\n') + '\n');
}

main().catch((err) => {
	process.stderr.write('reduce.node.js: ' + err.message + '\n');
	process.exitCode = 1;
});
