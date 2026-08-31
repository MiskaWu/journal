// 剖析器（與 shell 端同一套子集）與聚合邏輯（與 lib/aggregate.sh 同一套規則）。
// 全部從單檔版逐行移植——改格式要三邊同步：這裡、shell 端、資料 repo。

export interface BriefItem { project: string; kind: string; tags: string[]; text: string }
export interface Daily {
  date: string; host: string; status: string
  goals: string[]
  metrics: { sessions: number; commits: number; files: number }
  standup: string[]
  brief: BriefItem[]
  sections: Record<string, string[]>
  reducer: string; generatedAt: string
}
export interface StatusRow { host: string; ts: string; id: string; state: string; kind: string; detail: string }
export interface HostInfo { host: string; roles: string; health: string; reason: string; lastSeen: string; retired: string }
export interface GoalDef { id: string; title: string; done: string }
export interface Winner { id: string; state: string; detail: string; host: string; ts: string }
export interface Alert { sev: 'bad' | 'warn'; tag: string; text: string }

export function esc(s: unknown): string {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

// `code` 與 commit hash 的行內標記 —— 輸入先 esc 再上標記，輸出當 innerHTML 用
export function inlineHtml(s: string): string {
  let o = esc(s)
  o = o.replace(/`([^`]+)`/g, (_, c) => `<code>${c}</code>`)
  o = o.replace(/(^|[（(、\s])([0-9a-f]{7,10})(?=[）)、\s]|$)/g, (_, p, h) => `${p}<code class="hash">${h}</code>`)
  return o
}

export function yGet(raw: string, key: string, dflt = ''): string {
  const m = raw.match(new RegExp(`^${key}:[ \\t]*"?([^"#\\n]*?)"?[ \\t]*(?:#.*)?$`, 'm'))
  return m ? m[1].trim() : dflt
}
export function ySet(raw: string, key: string, val: string): string {
  const re = new RegExp(`^${key}:.*$`, 'm')
  const line = `${key}: ${/[:#]|^$|\s/.test(String(val)) ? `"${val}"` : val}`
  return re.test(raw) ? raw.replace(re, line) : raw.replace(/\s*$/, `\n${line}\n`)
}

export function parseDaily(raw: string): Daily | null {
  const m = raw.match(/^\s*---\n([\s\S]*?)\n---\n([\s\S]*)$/)
  if (!m) return null
  const fm: Record<string, string> = {}
  m[1].split('\n').forEach(l => {
    const i = l.indexOf(':')
    if (i > 0) fm[l.slice(0, i).trim()] = l.slice(i + 1).trim()
  })
  const sections: Record<string, string[]> = {}
  let cur: string | null = null
  m[2].split('\n').forEach(l => {
    const h = l.match(/^##\s+(.+?)\s*$/)
    if (h) { cur = h[1]; sections[cur] = []; return }
    const li = l.match(/^-\s+(.*)$/)
    if (li && cur) sections[cur].push(li[1])
  })
  const brief: BriefItem[] = (sections['摘要'] || []).map(r => {
    const p = r.split('|')
    if (p.length < 4) return { project: '—', kind: '其他', tags: [], text: r.trim() }
    return {
      project: p[0].trim() || '—', kind: p[1].trim() || '其他',
      tags: p[2].split(',').map(t => t.trim()).filter(Boolean),
      text: p.slice(3).join('|').trim(),
    }
  })
  const mm = (fm.metrics || '').match(/sessions:\s*(\d+).*commits:\s*(\d+).*files_touched:\s*(\d+)/)
  return {
    date: fm.date, host: fm.host, status: fm.status || 'ok',
    goals: (fm.goals_touched || '').replace(/[\[\]]/g, '').split(',').map(g => g.trim()).filter(Boolean),
    metrics: mm ? { sessions: +mm[1], commits: +mm[2], files: +mm[3] } : { sessions: 0, commits: 0, files: 0 },
    standup: sections['早會'] || [], brief, sections,
    reducer: fm.reduced_by || '?', generatedAt: fm.generated_at || '',
  }
}

export function parseStatus(raw: string): StatusRow[] {
  const host = yGet(raw, 'host'), ts = yGet(raw, 'checked_at')
  const results: StatusRow[] = []
  for (const l of raw.split('\n')) {
    const m = l.match(/^  ([A-Za-z0-9_-]+): \{ state: ([a-z]+), kind: ([a-z?]+)(?:, detail: "([^"]*)")?/)
    if (m) results.push({ host, ts, id: m[1], state: m[2], kind: m[3], detail: m[4] || '' })
  }
  return results
}

export function parseHost(raw: string): HostInfo {
  return {
    host: yGet(raw, 'host'), roles: yGet(raw, 'roles', '[node]'),
    health: yGet(raw, 'agent_health', '?'), reason: yGet(raw, 'degraded_reason'),
    lastSeen: yGet(raw, 'last_seen'), retired: yGet(raw, 'retired'),
  }
}

export function parseGoalDefs(raw: string): GoalDef[] {
  const out: GoalDef[] = []
  let cur: GoalDef | null = null
  let inc = false
  for (const l of (raw || '').split('\n')) {
    if (l.includes('<!--')) inc = true
    if (inc) { if (l.includes('-->')) inc = false; continue }
    const id = l.match(/^-\s+id:\s*(\S+)/)
    if (id) { cur = { id: id[1], title: '', done: '' }; out.push(cur); continue }
    if (!cur) continue
    if (/^\S/.test(l)) { cur = null; continue }
    const t = l.match(/^\s+title:\s*(.+)$/); if (t) cur.title = t[1].trim()
    const d = l.match(/^\s+done-when:\s*(.+)$/); if (d) cur.done = d[1].trim()
  }
  return out
}

/* ─── 聚合 ─── */

export function goalWinners(statuses: StatusRow[]): Winner[] {
  const best: Record<string, StatusRow> = {}
  const naD: Record<string, string> = {}
  const seen = new Set<string>()
  for (const r of statuses) {
    seen.add(r.id)
    if (r.state === 'na') { if (!(r.id in naD)) naD[r.id] = r.detail; continue }
    if (!best[r.id] || r.ts > best[r.id].ts) best[r.id] = r
  }
  return [...seen].sort().map(id => best[id] ||
    ({ id, state: 'unchecked', detail: `全部 host 皆 na（${naD[id] || ''}）`, host: '-', ts: '-' }))
}

export function daysBetween(d1: string, d2: string): number {
  return Math.round((+new Date(d2 + 'T12:00') - +new Date(d1 + 'T12:00')) / 86400000)
}

export const pad2 = (n: number) => String(n).padStart(2, '0')
export const localDateKey = (d: Date) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`

export function buildAlerts(configRaw: string, hosts: HostInfo[], dailies: Daily[], statuses: StatusRow[]): Alert[] {
  const today = localDateKey(new Date())
  const stale = +yGet(configRaw, 'stale_days', '3')
  const gStale = +yGet(configRaw, 'goal_stale_days', '7')
  const out: Alert[] = []
  for (const h of hosts) {
    if (h.retired) continue
    const seen = (h.lastSeen || '').slice(0, 10)
    if (seen) {
      const gap = daysBetween(seen, today)
      if (gap > stale) out.push({ sev: 'bad', tag: '沉默', text: `${h.host} 沉默 ${gap} 天（last_seen ${seen}）—— 機器關著？agent 死了？` })
    }
    if (h.health === 'fail') out.push({ sev: 'bad', tag: '紅燈', text: `${h.host} 不健康：${h.reason || '無原因'}` })
    if (h.health === 'degraded') out.push({ sev: 'warn', tag: '降級', text: `${h.host} 降級運行：${h.reason || ''}` })
  }
  const lastTouched: Record<string, string> = {}
  for (const d of dailies) for (const g of d.goals)
    if (!lastTouched[g] || d.date > lastTouched[g]) lastTouched[g] = d.date
  for (const w of goalWinners(statuses)) {
    if (w.state === 'fail') out.push({ sev: 'bad', tag: '紅燈', text: `目標 ${w.id} fail：${w.detail}（${w.host} 量測）` })
    if (w.state === 'pass' || w.state === 'manual') continue
    const lt = lastTouched[w.id]
    if (lt && daysBetween(lt, today) > gStale)
      out.push({ sev: 'warn', tag: '停滯', text: `目標 ${w.id} 已 ${daysBetween(lt, today)} 天沒動（最後出現 ${lt}）` })
  }
  return out
}
