// journal 控制台 —— 零後端：瀏覽器直連 GitHub API（O9 拍板 2026-07-30，
// 2026-08-31 討論後維持不翻案）。讀 = contents API 拉 journal-data 即時渲染；
// 寫 = PUT config.yml（一個 commit），各機下一輪 pull 生效。PAT 只存
// localStorage，不出這台瀏覽器。UI 語言對齊 taskwire 設計稿（2026-08-28 拍板）。
import { useCallback, useEffect, useRef, useState } from 'react'
import type { Axis, Settings } from './api'
import {
  AuthErr, b64decodeUtf8, forgetPat, gh, ghDir, ghRaw,
  loadAxis, loadSettings, saveAxis, saveSettings,
} from './api'
import type { Daily } from './parse'
import { parseDaily, parseGoalDefs, parseHost, parseStatus, pad2 } from './parse'
import { ErrBox, Icon, Spin } from './ui'
import type { IconName } from './ui'
import type { Data } from './views'
import { DailyView, Knobs, Overview, Setup, Trace, Weekly } from './views'

type Tab = 'overview' | 'daily' | 'trace' | 'weekly' | 'knobs' | 'setup'
const TABS: [Tab, string, IconName, string][] = [
  ['overview', '總攬', 'gauge', '警報、目標與機器一眼看完'],
  ['daily', '日誌', 'file', '每天的早會、摘要與細節'],
  ['trace', '軌跡', 'board', '單一目標的推進線'],
  ['weekly', '週報', 'calendar', 'aggregator 生成的每週 digest'],
  ['knobs', '旋鈕', 'sliders', '改 config.yml，各機下一輪 pull 生效'],
  ['setup', '連線', 'plug', 'GitHub PAT 與資料 repo'],
]

async function fetchMonth(s: Settings, idx: string[], mo: string): Promise<Daily[]> {
  const names = idx.filter(n => n.startsWith(mo))
  return (await Promise.all(names.map(n => ghRaw(s, `daily/${n}`))))
    .filter((x): x is string => !!x)
    .map(parseDaily)
    .filter((d): d is Daily => !!d)
}

export default function App() {
  const [settings, setSettings] = useState(loadSettings)
  const [tab, setTab] = useState<Tab>(() => (loadSettings().pat ? 'overview' : 'setup'))
  const [data, setData] = useState<Data | null>(null)
  const [loading, setLoading] = useState(false)
  const [loadErr, setLoadErr] = useState('')
  const [toastMsg, setToastMsg] = useState('')
  const toastTimer = useRef(0)

  const [currentDate, setCurrentDate] = useState('')
  const [cal, setCal] = useState<{ y: number; m: number } | null>(null)
  const [calBusy, setCalBusy] = useState(false)
  const [axis, setAxis] = useState<Axis>(loadAxis)
  const [traceGoal, setTraceGoal] = useState('')

  const toast = useCallback((m: string) => {
    setToastMsg(m)
    clearTimeout(toastTimer.current)
    toastTimer.current = window.setTimeout(() => setToastMsg(''), 2600)
  }, [])

  const handleErr = useCallback((e: unknown, inView: boolean) => {
    if (e instanceof AuthErr) {
      setTab('setup'); toast(e.message)
    } else if (inView) {
      setLoadErr((e as Error).message)
    } else {
      toast(`錯誤：${(e as Error).message}`)
    }
    console.error(e)
  }, [toast])

  const loadAll = useCallback(async (s: Settings): Promise<boolean> => {
    setLoading(true); setLoadErr('')
    try {
      const cfgMeta = await gh(s, `contents/config.yml?ref=${s.branch}`)
      const configRaw = b64decodeUtf8(cfgMeta.content)
      const [goalsRaw, stDir, hoDir, daDir, wkDir] = await Promise.all([
        ghRaw(s, 'GOALS.md'), ghDir(s, 'status'), ghDir(s, 'hosts'), ghDir(s, 'daily'), ghDir(s, 'weekly')])
      const yml = (f: { name: string }) => f.name.endsWith('.yml')
      const statuses = (await Promise.all((stDir || []).filter(yml).map(f => ghRaw(s, `status/${f.name}`))))
        .filter((x): x is string => !!x).flatMap(parseStatus)
      const hosts = (await Promise.all((hoDir || []).filter(yml).map(f => ghRaw(s, `hosts/${f.name}`))))
        .filter((x): x is string => !!x).map(parseHost)
      const dailyIdx = (daDir || []).filter(f => f.name.endsWith('.md')).map(f => f.name).sort().reverse()
      const months = [...new Set(dailyIdx.map(n => n.slice(0, 7)))].slice(0, 2)
      let dailies: Daily[] = []
      for (const mo of months) dailies = dailies.concat(await fetchMonth(s, dailyIdx, mo))
      dailies.sort((a, b) => (a.date < b.date ? 1 : -1))
      const weeklies = await Promise.all(
        (wkDir || []).filter(f => f.name.endsWith('.md')).map(f => f.name).sort().reverse().slice(0, 12)
          .map(async n => ({ name: n.replace('.md', ''), raw: (await ghRaw(s, `weekly/${n}`)) || '' })))
      setData({
        configRaw, configSha: cfgMeta.sha,
        goalDefs: parseGoalDefs(goalsRaw || ''), statuses, hosts,
        dailies, dailyIdx, loadedMonths: months, weeklies, loadedAt: new Date(),
      })
      if (dailies.length) {
        setCurrentDate(d => d || dailies[0].date)
        setCal(c => c ?? { y: +dailies[0].date.slice(0, 4), m: +dailies[0].date.slice(5, 7) })
      }
      return true
    } catch (e) {
      handleErr(e, true)
      return false
    } finally {
      setLoading(false)
    }
  }, [handleErr])

  useEffect(() => {
    if (settings.pat) void loadAll(settings)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // 換月：翻到還沒載入的月份先抓再畫；抓過的月份快取不重抓
  const goMonth = useCallback(async (y: number, m: number) => {
    setCal({ y, m })
    const mo = `${y}-${pad2(m)}`
    if (!data || data.loadedMonths.includes(mo)) return
    setCalBusy(true)
    try {
      const more = await fetchMonth(settings, data.dailyIdx, mo)
      setData(d => d && ({
        ...d,
        dailies: [...d.dailies, ...more].sort((a, b) => (a.date < b.date ? 1 : -1)),
        loadedMonths: [...d.loadedMonths, mo],
      }))
    } catch (e) {
      handleErr(e, true)
    } finally {
      setCalBusy(false)
    }
  }, [data, settings, handleErr])

  const connect = useCallback(async (s: Settings) => {
    saveSettings(s); setSettings(s)
    if (await loadAll(s)) { setTab('overview'); toast('連上了') }
  }, [loadAll, toast])

  const refresh = useCallback(async () => {
    if (await loadAll(settings)) toast('已更新')
  }, [loadAll, settings, toast])

  const active = TABS.find(t => t[0] === tab)!

  let body
  if (tab === 'setup') {
    body = <Setup settings={settings} onConnect={connect}
      onForget={() => { forgetPat(); setSettings(x => ({ ...x, pat: '' })); toast('已清除') }} />
  } else if (loading) {
    body = <div className="loading"><Spin />從 GitHub 拉取中…</div>
  } else if (loadErr) {
    body = <ErrBox detail={loadErr} />
  } else if (!data) {
    body = <p className="empty">尚未載入 —— 先在「連線」分頁連上 GitHub。</p>
  } else if (tab === 'overview') {
    body = <Overview data={data} patExpiry={settings.patExpiry} />
  } else if (tab === 'daily') {
    body = <DailyView data={data} currentDate={currentDate} onPick={setCurrentDate}
      cal={cal ?? { y: new Date().getFullYear(), m: new Date().getMonth() + 1 }}
      onMonth={goMonth} calBusy={calBusy}
      axis={axis} onAxis={a => { setAxis(a); saveAxis(a) }} />
  } else if (tab === 'trace') {
    body = <Trace data={data} goal={traceGoal} onGoal={setTraceGoal} />
  } else if (tab === 'weekly') {
    body = <Weekly data={data} />
  } else {
    body = <Knobs data={data} settings={settings} toast={toast}
      onConfig={(raw, sha) => setData(d => d && ({ ...d, configRaw: raw, configSha: sha }))} />
  }

  return (
    <div className="shell">
      <aside className="side">
        <div className="brand"><Icon name="book" size={20} /><span className="name">Journal</span></div>
        <nav className="nav">
          {TABS.map(([k, l, ic]) => (
            <button key={k} className={`nav-item ${tab === k ? 'on' : ''}`} onClick={() => setTab(k)}>
              <Icon name={ic} />{l}
            </button>
          ))}
        </nav>
        <div className="side-foot">
          <span className="row">
            {data ? `拉取於 ${data.loadedAt.toTimeString().slice(0, 5)}` : ''}
          </span>
          <span className="repo">
            {data ? `${settings.owner}/${settings.repo}@${settings.branch}` : '未連線'}
          </span>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <h1>{active[1]}</h1>
          <span className="sub">{active[3]}</span>
          <span className="acts">
            <button className="btn" title="重新拉取" onClick={refresh}>更新</button>
          </span>
        </header>
        <main className="content">{body}</main>
      </div>
      <div className={`toast ${toastMsg ? 'show' : ''}`}>{toastMsg}</div>
    </div>
  )
}
