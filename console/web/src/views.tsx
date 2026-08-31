// 六個分頁的視圖 —— 行為逐一從單檔版移植，語意不變：
// 空狀態與查詢失敗分開呈現（失敗是紅框，永遠不裝成空清單）。
import { useMemo, useState } from 'react'
import type { Settings } from './api'
import { gh, b64utf8 } from './api'
import type { Axis } from './api'
import type { Daily, HostInfo, GoalDef, StatusRow, Winner } from './parse'
import {
  buildAlerts, daysBetween, goalWinners, yGet, ySet, pad2, localDateKey,
} from './parse'
import { Badge, ErrBox, Icon, Inline, KindBadge, KINDS, Spin, STATE_BADGE } from './ui'

export interface Data {
  configRaw: string; configSha: string
  goalDefs: GoalDef[]; statuses: StatusRow[]; hosts: HostInfo[]
  dailies: Daily[]; dailyIdx: string[]; loadedMonths: string[]
  weeklies: { name: string; raw: string }[]
  loadedAt: Date
}

/* ─── 早會／摘要／細節（日誌卡片的三層）─── */

export const Standup = ({ d }: { d: Daily }) => {
  if (!d.standup.length) return <p className="empty">（無早會段）</p>
  return (
    <div className="standup">
      {d.standup.map((l, i) => {
        const red = /^紅燈[：:]/.test(l)
        return (
          <p key={i} className={red ? 'red' : ''}>
            {red && <span className="dot" style={{ background: 'var(--bad)' }} />}
            <Inline s={l} />
          </p>
        )
      })}
    </div>
  )
}

const AXES: [Axis, string][] = [['project', '專案'], ['kind', '類型'], ['tag', '標籤']]

const BriefView = ({ d, axis, onAxis }: { d: Daily; axis: Axis; onAxis: (a: Axis) => void }) => {
  if (!d.brief.length) return null
  const groups = new Map<string, typeof d.brief>()
  const put = (k: string, it: (typeof d.brief)[number]) => {
    if (!groups.has(k)) groups.set(k, [])
    groups.get(k)!.push(it)
  }
  for (const it of d.brief) {
    if (axis === 'project') put(it.project, it)
    else if (axis === 'kind') put(it.kind, it)
    else it.tags.length ? it.tags.forEach(t => put('#' + t, it)) : put('（無標籤）', it)
  }
  const keys = [...groups.keys()]
  if (axis === 'kind') keys.sort((a, b) => (KINDS.indexOf(a) + 99) % 100 - (KINDS.indexOf(b) + 99) % 100)
  else keys.sort((a, b) =>
    (groups.get(a)!.every(i => i.kind === '卡住') ? 1 : 0) - (groups.get(b)!.every(i => i.kind === '卡住') ? 1 : 0))
  return (
    <>
      <div className="card-head" style={{ margin: '16px 0 4px' }}>
        <div className="t">摘要</div>
        <div className="right">
          <div className="seg">
            {AXES.map(([k, l]) => (
              <button key={k} className={axis === k ? 'on' : ''} onClick={() => onAxis(k)}>{l}</button>
            ))}
          </div>
        </div>
      </div>
      {keys.map(k => (
        <div key={k}>
          <div className="ghead">{k} <span className="cnt">{groups.get(k)!.length}</span></div>
          {groups.get(k)!.map((it, i) => (
            <div key={i} className="lrow">
              <KindBadge kind={it.kind} />
              <span>
                {axis !== 'project' && it.project !== '—' && <><span className="who">{it.project}</span> · </>}
                <Inline s={it.text} />
              </span>
            </div>
          ))}
        </div>
      ))}
    </>
  )
}

const SEC: [string, 'ok' | 'accent' | 'warn' | 'bad'][] =
  [['完成', 'ok'], ['拍板', 'accent'], ['待續', 'warn'], ['卡住', 'bad']]

const DetailsView = ({ d }: { d: Daily }) => {
  const counts = SEC.map(([k]) => `${k} ${(d.sections[k] || []).length}`).join(' · ')
  return (
    <details className="raw" style={{ marginTop: 16 }}>
      <summary>細節 — {counts}</summary>
      {SEC.map(([k, b]) => {
        const items = d.sections[k] || []
        return (
          <div key={k}>
            <div className="ghead"><Badge k={b}>{k}</Badge><span className="cnt">{items.length}</span></div>
            {items.length
              ? items.map((it, i) => <div key={i} className="lrow"><span><Inline s={it} /></span></div>)
              : <p className="empty">—</p>}
          </div>
        )
      })}
    </details>
  )
}

const DayCard = ({ d, axis, onAxis }: { d: Daily; axis: Axis; onAxis: (a: Axis) => void }) => (
  <div className="card">
    <div className="card-head">
      <div>
        <div className="t">{d.date} · {d.host}</div>
        <div className="s mono">{d.metrics.sessions} sessions · {d.metrics.commits} commits</div>
      </div>
    </div>
    {d.status === 'no-material'
      ? <p className="empty">這天沒有素材。</p>
      : <><Standup d={d} /><BriefView d={d} axis={axis} onAxis={onAxis} /><DetailsView d={d} /></>}
  </div>
)

/* ─── 分頁：總攬 ─── */

export const Overview = ({ data, patExpiry }: { data: Data; patExpiry: string }) => {
  const alerts = buildAlerts(data.configRaw, data.hosts, data.dailies, data.statuses)
  // PAT 到期提醒（taskwire 同款門檻：30 天內示警）—— 到期日是使用者在連線頁填的
  if (patExpiry) {
    const days = daysBetween(localDateKey(new Date()), patExpiry)
    if (days < 0)
      alerts.unshift({ sev: 'bad', tag: 'PAT', text: `PAT 已於 ${patExpiry} 過期 —— 去 GitHub 續期後在「連線」頁換新 token` })
    else if (days <= 7)
      alerts.unshift({ sev: 'bad', tag: 'PAT', text: `PAT 再 ${days} 天過期（${patExpiry}）—— 先去 GitHub 續期，過期當天控制台會直接連不上` })
    else if (days <= 30)
      alerts.unshift({ sev: 'warn', tag: 'PAT', text: `PAT 再 ${days} 天過期（${patExpiry}）` })
  }
  const winners: Winner[] = goalWinners(data.statuses)
  const defs = Object.fromEntries(data.goalDefs.map(g => [g.id, g]))
  const latest = data.dailies[0]
  return (
    <>
      <div className="card">
        <div className="card-head"><div className="t">需要注意</div></div>
        {alerts.length
          ? alerts.map((a, i) => (
              <div key={i} className="arow"><Badge k={a.sev}>{a.tag}</Badge><span>{a.text}</span></div>
            ))
          : <div className="okmsg">都好，沒有紅燈。</div>}
      </div>
      <div className="card-head" style={{ margin: '4px 0 -6px' }}><div className="t">目標</div></div>
      <div className="gtiles">
        {winners.map(w => {
          const d = defs[w.id]
          return (
            <div key={w.id} className="tile">
              <div className="lab">
                <span className="id">{w.id}</span>
                <Badge k={STATE_BADGE[w.state] ?? 'idle'}>{w.state}</Badge>
              </div>
              {d?.title && <div className="ttl">{d.title}</div>}
              <div className="meta">{w.detail || '-'}<br />{w.host} · {String(w.ts).slice(0, 16)}</div>
            </div>
          )
        })}
      </div>
      <div className="card">
        <div className="card-head"><div className="t">機器</div></div>
        {data.hosts.map(x => {
          const c = x.retired ? '#8892a0' : x.health === 'ok' ? 'var(--ok)' : x.health === 'degraded' ? '#c98a00' : 'var(--bad)'
          return (
            <div key={x.host} className="hrow">
              <span className="dot" style={{ background: c }} />
              <span><span className="nm">{x.host}</span> <span className="muted">{x.roles}{x.retired ? ' · retired' : ''}</span></span>
              <span className="meta">{(x.lastSeen || '').slice(0, 16)}</span>
            </div>
          )
        })}
      </div>
      {latest && (
        <div className="card">
          <div className="card-head">
            <div>
              <div className="t">最新早會</div>
              <div className="s mono">{latest.date} · {latest.host}</div>
            </div>
          </div>
          <Standup d={latest} />
        </div>
      )}
    </>
  )
}

/* ─── 分頁：日誌（日曆導覽）─── */

interface DailyProps {
  data: Data
  currentDate: string; onPick: (d: string) => void
  cal: { y: number; m: number }; onMonth: (y: number, m: number) => void
  calBusy: boolean
  axis: Axis; onAxis: (a: Axis) => void
}

const Calendar = ({ data, currentDate, onPick, cal, onMonth, calBusy }: Omit<DailyProps, 'axis' | 'onAxis'>) => {
  const byDate = useMemo(() => {
    const m = new Map<string, { red: boolean }>()
    for (const d of data.dailies) {
      const e = m.get(d.date) ?? { red: false }
      if (d.standup.some(l => /^紅燈[：:]/.test(l))) e.red = true
      m.set(d.date, e)
    }
    return m
  }, [data.dailies])
  const { y, m } = cal
  const todayKey = localDateKey(new Date())
  const first = new Date(y, m - 1, 1).getDay()
  const dim = new Date(y, m, 0).getDate()
  const dimPrev = new Date(y, m - 1, 0).getDate()
  const cells = []
  for (let i = 0; i < 42; i++) {
    const dn = i - first + 1
    if (dn < 1 || dn > dim) {
      cells.push(
        <button key={i} className="cal-day out" disabled>
          <span>{dn < 1 ? dimPrev + dn : dn - dim}</span><span className="cd" />
        </button>,
      )
      continue
    }
    const key = `${y}-${pad2(m)}-${pad2(dn)}`
    const e = byDate.get(key)
    const cls = ['cal-day', e ? 'has' : '', e?.red ? 'red' : '',
      key === currentDate ? 'on' : '', key === todayKey ? 'today' : ''].filter(Boolean).join(' ')
    cells.push(
      <button key={i} className={cls} onClick={() => onPick(key)}>
        <span>{dn}</span><span className="cd" />
      </button>,
    )
  }
  const yrs = [...new Set([...data.dailyIdx.map(n => +n.slice(0, 4)), y, +todayKey.slice(0, 4)])].sort()
  const monthCount = [...byDate.keys()].filter(k => k.startsWith(`${y}-${pad2(m)}`)).length
  const nav = (dy: number) => {
    let nm = m + dy, ny = y
    if (nm < 1) { nm = 12; ny-- } if (nm > 12) { nm = 1; ny++ }
    onMonth(ny, nm)
  }
  return (
    <div className="card cal">
      <div className="cal-head">
        <button className="cal-nav" title="上個月" onClick={() => nav(-1)}><Icon name="chevL" size={14} /></button>
        <span className="sel">
          <select value={y} onChange={e => onMonth(+e.target.value, m)}>
            {yrs.map(v => <option key={v} value={v}>{v}</option>)}
          </select>
          <select value={m} onChange={e => onMonth(y, +e.target.value)}>
            {Array.from({ length: 12 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} 月</option>)}
          </select>
        </span>
        <button className="cal-nav" title="下個月" onClick={() => nav(1)}><Icon name="chevR" size={14} /></button>
      </div>
      <div className="cal-grid">
        {['日', '一', '二', '三', '四', '五', '六'].map(w => <span key={w} className="cal-wd">{w}</span>)}
      </div>
      <div className="cal-grid">{cells}</div>
      <div className="cal-foot">
        <span>本月 <b className="mono">{monthCount}</b> 天有記錄{calBusy && <> <Spin /></>}</span>
        <span style={{ marginLeft: 'auto' }}>
          <button className="btn" style={{ padding: '3px 10px', fontSize: '11.5px' }} onClick={() => {
            const t = new Date()
            onPick(localDateKey(t))
            onMonth(t.getFullYear(), t.getMonth() + 1)
          }}>今天</button>
        </span>
      </div>
      <div className="cal-legend">
        <span><span className="cd" style={{ background: 'var(--ok)' }} />有記錄</span>
        <span><span className="cd" style={{ background: 'var(--bad)' }} />含紅燈</span>
      </div>
    </div>
  )
}

export const DailyView = (p: DailyProps) => {
  if (!p.data.dailies.length && !p.calBusy) return <p className="empty">還沒有 daily。</p>
  const todays = p.data.dailies.filter(x => x.date === p.currentDate)
  return (
    <div className="dgrid">
      <Calendar {...p} />
      <div className="dcol">
        {!todays.length && (
          <div className="card" style={{ textAlign: 'center', color: '#8892a0', fontSize: '12.5px', padding: '28px 18px' }}>
            {p.currentDate} 沒有記錄 —— 挑個有圓點的日子看看。
          </div>
        )}
        {todays.map(d => <DayCard key={d.host} d={d} axis={p.axis} onAxis={p.onAxis} />)}
      </div>
    </div>
  )
}

/* ─── 分頁：軌跡 ─── */

export const Trace = ({ data, goal, onGoal }: { data: Data; goal: string; onGoal: (g: string) => void }) => {
  const all = new Set(data.goalDefs.map(g => g.id))
  for (const d of data.dailies) for (const g of d.goals) all.add(g)
  const goals = [...all].sort()
  const cur = goal || goals[0] || ''
  const hits = data.dailies.filter(d => d.goals.includes(cur)).sort((a, b) => a.date < b.date ? 1 : -1)
  return (
    <div className="card">
      <div className="card-head">
        <div className="t">目標推進線</div>
        <div className="right">
          <select value={cur} onChange={e => onGoal(e.target.value)}>
            {goals.map(g => <option key={g}>{g}</option>)}
          </select>
        </div>
      </div>
      <p className="muted" style={{ margin: '0 0 6px' }}>
        靠 goals_touched 推斷串線 —— 導覽用，不是證據。範圍：已載入的 {data.loadedMonths.length} 個月（在日誌頁翻月會多載）
      </p>
      {!hits.length && <p className="empty">沒有任何 daily 標記過這個目標。</p>}
      {hits.map(d => {
        const items = d.brief.filter(b => b.project.includes(cur) || b.tags.some(t => t.includes(cur)))
        const shown = items.length ? items : d.brief.slice(0, 1)
        return (
          <div key={d.date + d.host}>
            <div className="ghead">
              <span className="mono" style={{ fontSize: '11.5px', color: 'var(--ink2)' }}>{d.date}</span>
              <span className="cnt">{d.host}</span>
            </div>
            {shown.map((b, i) => (
              <div key={i} className="lrow"><KindBadge kind={b.kind} /><span><Inline s={b.text} /></span></div>
            ))}
          </div>
        )
      })}
    </div>
  )
}

/* ─── 分頁：週報 ─── */

export const Weekly = ({ data }: { data: Data }) => {
  if (!data.weeklies.length)
    return <p className="empty">還沒有週報 —— aggregator 上跑 <code>journal digest</code> 生成。</p>
  return (
    <>
      {data.weeklies.map(w => {
        const body = (w.raw || '').replace(/^\s*---[\s\S]*?---\n/, '')
        return (
          <div key={w.name} className="card">
            <div className="card-head"><div className="t mono">{w.name}</div></div>
            {body.split('\n').map((l, i) => {
              if (/^##\s/.test(l)) return <div key={i} className="ghead">{l.replace(/^##\s*/, '')}</div>
              if (/^-\s/.test(l)) return <div key={i} className="lrow"><span><Inline s={l.slice(2)} /></span></div>
              return l.trim() ? <div key={i} className="lrow"><span><Inline s={l} /></span></div> : null
            })}
          </div>
        )
      })}
    </>
  )
}

/* ─── 分頁：旋鈕（唯一會寫入的分頁）─── */

interface Knob {
  key: string; label: string; desc: string
  type: 'range' | 'text' | 'time' | 'number'
  min?: number; max?: number; placeholder?: string
}
const KNOBS: Knob[] = [
  { key: 'standup_lines', type: 'range', min: 1, max: 10, label: '早會力度',
    desc: '站立會議短句最多幾行。改完下一次 rollup 生效；舊日子重跑 rollup 套用。' },
  { key: 'model_rollup', type: 'text', label: 'L2 夜間模型', placeholder: '（該機預設）',
    desc: '一天一次、整併全天素材 —— 品質優先。別名（opus/sonnet/haiku）或完整型號。' },
  { key: 'model_capture', type: 'text', label: 'L1 即時模型', placeholder: '（該機預設）',
    desc: '每關一個 session 跑一次 —— 便宜模型很合理（如 haiku）。' },
  { key: 'model_check', type: 'text', label: 'SLI judge 模型', placeholder: '（該機預設）',
    desc: '只有 judge 型 SLI 會用到。' },
  { key: 'rollup_time', type: 'time', label: '夜間整併時間',
    desc: '挑「通常還開著機」的時段。改了要在各機重跑 journal init 讓 timer 重寫。' },
  { key: 'aggregate_time', type: 'time', label: '聚合時間',
    desc: 'aggregator 合成 progress 的時間，排在 rollup 之後。改了 aggregator 重跑 init。' },
  { key: 'stale_days', type: 'number', min: 1, max: 30, label: '機器沉默門檻（天）',
    desc: '超過幾天沒回報算沉默警報。' },
  { key: 'goal_stale_days', type: 'number', min: 1, max: 60, label: '目標停滯門檻（天）',
    desc: '目標幾天沒出現在 daily 算停滯。' },
]

export const Knobs = ({ data, settings, onConfig, toast }: {
  data: Data; settings: Settings
  onConfig: (raw: string, sha: string) => void
  toast: (m: string) => void
}) => {
  const initial = useMemo(() => {
    const v: Record<string, string> = {}
    for (const k of KNOBS) v[k.key] = yGet(data.configRaw, k.key, '')
    return v
  }, [data.configRaw])
  const [vals, setVals] = useState(initial)
  const [saving, setSaving] = useState(false)
  const [hint, setHint] = useState('')
  const set = (k: string, v: string) => setVals(x => ({ ...x, [k]: v }))

  const save = async () => {
    const changes: Record<string, string> = {}
    for (const k of KNOBS) {
      const cur = yGet(data.configRaw, k.key, '')
      if (String(vals[k.key]) !== String(cur)) changes[k.key] = vals[k.key]
    }
    if (!Object.keys(changes).length) return toast('沒有變更')
    setSaving(true)
    try {
      let raw = data.configRaw
      for (const [k, v] of Object.entries(changes)) raw = ySet(raw, k, v)
      const res = await gh(settings, 'contents/config.yml', {
        method: 'PUT',
        body: {
          message: `web: 調整 ${Object.keys(changes).join(', ')}`,
          content: b64utf8(raw), sha: data.configSha, branch: settings.branch,
        },
      })
      onConfig(raw, res.content.sha)
      toast(`已 commit ${res.commit.sha.slice(0, 7)} —— 各機下一輪 pull 生效`)
      setHint(Object.keys(changes).some(k => k.endsWith('_time'))
        ? '注意：改了時間類旋鈕，要在對應機器重跑 journal init 讓 timer 重寫' : '')
    } catch (e) {
      toast(`錯誤：${(e as Error).message}`)
    }
    setSaving(false)
  }

  return (
    <>
      <div className="card">
        <div className="card-head">
          <div>
            <div className="t">旋鈕</div>
            <div className="s">改完按儲存 = 直接 commit 到 config.yml，各機下一輪 pull 生效</div>
          </div>
        </div>
        {KNOBS.map(k => (
          <div key={k.key} className="knob">
            <span className="kname">{k.key}</span>
            <span>
              {k.type === 'range' && (
                <>
                  <input type="range" min={k.min} max={k.max} value={vals[k.key] || '3'}
                    onChange={e => set(k.key, e.target.value)} />
                  <b className="mono" style={{ marginLeft: 8 }}>{vals[k.key] || '3'}</b>
                </>
              )}
              {k.type === 'time' && (
                <input type="time" value={vals[k.key]} style={{ width: 130 }}
                  onChange={e => set(k.key, e.target.value)} />
              )}
              {k.type === 'number' && (
                <input type="number" min={k.min} max={k.max} value={vals[k.key]} style={{ width: 90 }}
                  onChange={e => set(k.key, e.target.value)} />
              )}
              {k.type === 'text' && (
                <input type="text" value={vals[k.key]} placeholder={k.placeholder} list="models"
                  style={{ width: 230 }} onChange={e => set(k.key, e.target.value)} />
              )}
            </span>
            <span className="kdesc">{k.label} —— {k.desc}</span>
          </div>
        ))}
      </div>
      <datalist id="models">
        <option value="haiku" /><option value="sonnet" /><option value="opus" /><option value="fable" />
      </datalist>
      <div className="savebar">
        <button className="btn primary" disabled={saving} onClick={save}>儲存（commit）</button>
        <span className="muted">{hint}</span>
      </div>
    </>
  )
}

/* ─── 分頁：連線設定 ─── */

export const Setup = ({ settings, onConnect, onForget }: {
  settings: Settings
  onConnect: (s: Settings) => void
  onForget: () => void
}) => {
  const [owner, setOwner] = useState(settings.owner)
  const [repo, setRepo] = useState(settings.repo)
  const [branch, setBranch] = useState(settings.branch)
  const [pat, setPat] = useState(settings.pat)
  const [expiry, setExpiry] = useState(settings.patExpiry)
  return (
    <div className="setup card">
      <div className="card-head"><div className="t">連線 GitHub</div></div>
      <ol>
        <li>到 <a href="https://github.com/settings/personal-access-tokens/new" target="_blank" rel="noopener">建 fine-grained PAT</a></li>
        <li>Repository access → <b>Only select repositories</b> → 只勾 <code>journal-data</code></li>
        <li>Permissions → <b>Contents: Read and write</b>（其餘都不用）</li>
        <li>貼進來。PAT 只存這個瀏覽器的 localStorage，不會被送到 GitHub 以外的任何地方。</li>
      </ol>
      <label>Owner / Repo / Branch</label>
      <div style={{ display: 'flex', gap: 8 }}>
        <input value={owner} onChange={e => setOwner(e.target.value)} style={{ flex: 1 }} />
        <input value={repo} onChange={e => setRepo(e.target.value)} style={{ flex: 1 }} />
        <input value={branch} onChange={e => setBranch(e.target.value)} style={{ width: 90 }} />
      </div>
      <label>Fine-grained PAT</label>
      <input type="password" value={pat} placeholder="github_pat_…" onChange={e => setPat(e.target.value)} />
      <label>PAT 到期日（選填 —— 建 token 時 GitHub 顯示的 Expiration，填了總攬會在到期前 30 天提醒）</label>
      <input type="date" value={expiry} style={{ width: 170 }} onChange={e => setExpiry(e.target.value)} />
      <div className="savebar" style={{ marginTop: 14 }}>
        <button className="btn primary" onClick={() =>
          onConnect({ owner: owner.trim(), repo: repo.trim(), branch: branch.trim() || 'main', pat: pat.trim(), patExpiry: expiry })}>
          連線並載入
        </button>
        <button className="btn danger" onClick={() => { setPat(''); onForget() }}>清除本機 PAT</button>
      </div>
    </div>
  )
}

export { ErrBox }
