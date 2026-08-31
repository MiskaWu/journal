// GitHub API 客戶端 —— 零後端語意（O9）：瀏覽器直連 contents API，
// PAT 只存 localStorage、不出這台瀏覽器。key 沿用舊版（jc.*），
// 從單檔版升級的使用者不用重貼 token。

export class AuthErr extends Error {}

export interface Settings {
  pat: string
  owner: string
  repo: string
  branch: string
  /** PAT 到期日（YYYY-MM-DD，選填）。GitHub 的 CORS 沒曝露到期標頭給瀏覽器，
   *  後端又拍板不碰憑證，所以由使用者建 token 時抄一次，提醒全在前端算。 */
  patExpiry: string
}

const LS = { pat: 'jc.pat', owner: 'jc.owner', repo: 'jc.repo', branch: 'jc.branch', axis: 'jc.axis', patExpiry: 'jc.patexp' }

function lsGet(key: string): string {
  try { return localStorage.getItem(key) ?? '' } catch { return '' }
}
function lsSet(key: string, val: string) {
  try { localStorage.setItem(key, val) } catch { /* 私密視窗等情境：存不住就算了 */ }
}

export function loadSettings(): Settings {
  return {
    pat: lsGet(LS.pat),
    owner: lsGet(LS.owner) || 'MiskaWu',
    repo: lsGet(LS.repo) || 'journal-data',
    branch: lsGet(LS.branch) || 'main',
    patExpiry: lsGet(LS.patExpiry),
  }
}
export function saveSettings(s: Settings) {
  lsSet(LS.pat, s.pat); lsSet(LS.owner, s.owner)
  lsSet(LS.repo, s.repo); lsSet(LS.branch, s.branch)
  lsSet(LS.patExpiry, s.patExpiry)
}
export function forgetPat() {
  try { localStorage.removeItem(LS.pat) } catch { /* 同上 */ }
}
export type Axis = 'project' | 'kind' | 'tag'
export function loadAxis(): Axis {
  const a = lsGet(LS.axis)
  return a === 'kind' || a === 'tag' ? a : 'project'
}
export function saveAxis(a: Axis) { lsSet(LS.axis, a) }

interface GhOpts {
  method?: string
  raw?: boolean
  soft?: boolean
  body?: unknown
}

export async function gh(s: Settings, path: string, opts: GhOpts = {}): Promise<any> {
  const r = await fetch(`https://api.github.com/repos/${s.owner}/${s.repo}/${path}`, {
    method: opts.method || 'GET',
    headers: {
      'Authorization': `Bearer ${s.pat}`,
      'Accept': opts.raw ? 'application/vnd.github.raw+json' : 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(opts.body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  })
  if (r.status === 401 || r.status === 403) throw new AuthErr(`GitHub 拒絕（${r.status}）—— PAT 過期或權限不足`)
  if (r.status === 404 && opts.soft) return null
  if (!r.ok) throw new Error(`${r.status} ${path}`)
  return opts.raw ? r.text() : r.json()
}

export const ghRaw = (s: Settings, p: string): Promise<string | null> =>
  gh(s, `contents/${p}?ref=${s.branch}`, { raw: true, soft: true })
export const ghDir = (s: Settings, p: string): Promise<{ name: string }[] | null> =>
  gh(s, `contents/${p}?ref=${s.branch}`, { soft: true })

export function b64utf8(str: string): string {
  const b = new TextEncoder().encode(str)
  let out = ''
  for (let i = 0; i < b.length; i += 0x8000)
    out += String.fromCharCode.apply(null, Array.from(b.subarray(i, i + 0x8000)))
  return btoa(out)
}

export function b64decodeUtf8(b64: string): string {
  return new TextDecoder().decode(Uint8Array.from(atob(b64.replace(/\n/g, '')), c => c.charCodeAt(0)))
}
