// 共用元件 —— taskwire 設計語言（2026-08-28 拍板色票）的元件層
import type { ReactNode } from 'react'
import { inlineHtml } from './parse'

const P = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round' } as const

export type IconName = 'gauge' | 'file' | 'board' | 'calendar' | 'sliders' | 'plug' | 'book' | 'chevL' | 'chevR'

const ICON_BODY: Record<IconName, ReactNode> = {
  gauge: <><path d="M12 14l3.5-4.5" /><path d="M20.2 16a8.5 8.5 0 1 0-16.4 0" /></>,
  file: <><path d="M6 3.5h8l4 4v13H6z" /><path d="M14 3.5v4h4M9 12h6M9 15.5h6" /></>,
  board: <path d="M5 4.5v15M12 4.5v10M19 4.5v6" />,
  calendar: <><rect x="3.5" y="5" width="17" height="15.5" rx="1.5" /><path d="M3.5 9.5h17M8 3v4M16 3v4" /></>,
  sliders: <><path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h9M17 17h3" /><circle cx="15" cy="7" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="15" cy="17" r="2" /></>,
  plug: <><path d="M9 3.5V7M15 3.5V7" /><path d="M6.5 7h11v3.5a5.5 5.5 0 0 1-11 0z" /><path d="M12 16v4.5" /></>,
  book: <><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15.5H6.5A2.5 2.5 0 0 0 4 21z" /><path d="M4 18.5A2.5 2.5 0 0 1 6.5 16H20" /></>,
  chevL: <path d="M14 6l-6 6 6 6" />,
  chevR: <path d="M10 6l6 6-6 6" />,
}

export const Icon = ({ name, size = 18 }: { name: IconName; size?: number }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} {...P}>{ICON_BODY[name]}</svg>
)

export type BadgeKind = 'ok' | 'accent' | 'warn' | 'bad' | 'idle'
export const Badge = ({ k, children }: { k: BadgeKind; children: ReactNode }) => (
  <span className={`badge b-${k}`}>{children}</span>
)

export const STATE_BADGE: Record<string, BadgeKind> = {
  pass: 'ok', partial: 'warn', fail: 'bad', manual: 'accent', unchecked: 'idle',
}
export const KINDS = ['功能', '修復', '進度', '拍板', '卡住']
export const KIND_BADGE: Record<string, BadgeKind> = {
  '功能': 'ok', '修復': 'accent', '進度': 'warn', '拍板': 'idle', '卡住': 'bad', '其他': 'idle',
}
export const KindBadge = ({ kind }: { kind: string }) => (
  <Badge k={KIND_BADGE[kind] ?? 'idle'}>{KINDS.includes(kind) ? kind : '其他'}</Badge>
)

// `code` 與 hash 標記：inlineHtml 內部先 esc 再上標記，這裡才敢餵 innerHTML
export const Inline = ({ s }: { s: string }) => (
  <span dangerouslySetInnerHTML={{ __html: inlineHtml(s) }} />
)

export const Spin = () => <span className="spin" />

export const ErrBox = ({ title = '查詢失敗', detail }: { title?: string; detail: string }) => (
  <div className="err"><strong>{title}</strong><pre>{detail}</pre></div>
)
