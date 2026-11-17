export interface PlayItem {
  path: string
  name: string
  pos: number
  dur: number
  pct: number
  updated?: number
}

export interface Entry {
  name: string
  path: string
  is_dir: boolean
  size: number
  mtime: number
  kind: string
  ext: string
}

export interface Listing {
  source: string
  path: string
  parent: string | null
  entries: Entry[]
  allow_upload: boolean
  allow_delete: boolean
}

export interface Storage {
  total: number
  used: number
  free: number
  root: string
}

/* ---------- 听译（本机 faster-whisper 转写 + OpenAI 兼容翻译） ---------- */

/** 一句字幕：[起, 止, 原文, 译文?]。译文可能要等翻译跑完才有。 */
export type SubSeg = [number, number, string, string?]

export type SubJobState = 'queued' | 'asr' | 'translating' | 'done' | 'error' | 'cancelled'

export interface SubJob {
  id: string
  name: string
  source: string
  path: string
  state: SubJobState
  pct: number
  msg: string
  lang: string
  dur: number
  /** 已有句数 */
  segments: number
  /** 还没翻的句数 */
  pending: number
  model: string
  created: number
  error: string
}

export interface SubState {
  enabled: boolean
  model: string
  device: string
  compute_type: string
  language: string
  max_active: number
  deps: { faster_whisper: boolean; av: boolean }
  translate: { ready: boolean; to: string; model: string; base: string }
}

/** /subs/for：播放器按 来源+路径 找现成字幕 */
export interface SubFor extends Partial<SubState> {
  found: boolean
  id?: string
  lang?: string
  dur?: number
  segments?: SubSeg[]
}

/** 文件源：local（服务器磁盘）/ dufs（电脑上的 dufs）/ webdav（CloudDrive2 等） */
export interface SourceInfo {
  id: string
  name: string
  sub?: string
  kind: string
  writable: boolean
  root: string
  local?: boolean
}

/** /meta/sources：文件源列表 + 各功能开关 */
export interface MetaSources {
  sources: SourceInfo[]
  default: string
  chat?: { enabled: boolean }
  /** 听译开关（服务端 config.json 的 subs.enabled）。老服务端没有这一项 */
  subs?: { enabled: boolean; model?: string }
}

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
  get isAuth() {
    return this.status === 401 || this.status === 403
  }
}

const TOKEN_KEY = 'yunxia.token'
const SERVER_KEY = 'yunxia.server'

export class Api {
  server = localStorage.getItem(SERVER_KEY) || location.origin
  token: string | null = localStorage.getItem(TOKEN_KEY)

  get origin() {
    return this.server.replace(/\/$/, '')
  }

  setServer(s: string) {
    this.server = s.replace(/\/$/, '')
    localStorage.setItem(SERVER_KEY, this.server)
  }

  setToken(t: string | null) {
    this.token = t
    if (t) localStorage.setItem(TOKEN_KEY, t)
    else localStorage.removeItem(TOKEN_KEY)
  }

  absolute(path: string) {
    return path.startsWith('http') ? path : `${this.origin}${path}`
  }

  private async send<T>(method: string, path: string, body?: unknown, query?: Record<string, string>): Promise<T> {
    const url = new URL(`${this.origin}/api/v1${path}`)
    if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v)
    const headers: Record<string, string> = {}
    if (this.token) headers.Authorization = `Bearer ${this.token}`
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    const res = await fetch(url.toString(), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    if (res.status === 401 || res.status === 403) {
      // 只读也能用：写操作没口令时把口令框叫出来（设置页那张大卡片是同一条路）
      try {
        window.dispatchEvent(new Event('yunxia:pwd'))
      } catch {}
    }
    if (!res.ok) {
      let msg = `HTTP ${res.status}`
      try {
        const j = JSON.parse(text)
        if (j.detail) msg = String(j.detail)
      } catch {
        /* 保持默认 */
      }
      throw new ApiError(res.status, msg)
    }
    return (text ? JSON.parse(text) : {}) as T
  }

  login(password: string, device = 'web') {
    return this.send<{ token: string; expires_at: number; device: string }>('POST', '/auth/login', {
      password,
      device,
    })
  }

  me() {
    return this.send<{ device: string }>('GET', '/auth/me')
  }

  list(source: string, path: string, sort = 'name', order = 'asc') {
    return this.send<Listing>('GET', '/fs/list', undefined, { source, path, sort, order })
  }

  /** 上传：走 XHR 才能拿到进度事件（fetch 拿不到上传进度） */
  upload(
    source: string,
    path: string,
    file: File,
    onProgress?: (sent: number, total: number) => void,
  ): Promise<{ size: number; path: string }> {
    return new Promise((resolve, reject) => {
      const url = new URL(`${this.origin}/api/v1/fs/upload`)
      url.searchParams.set('source', source)
      url.searchParams.set('path', path)
      url.searchParams.set('name', file.name)
      const xhr = new XMLHttpRequest()
      xhr.open('PUT', url.toString())
      if (this.token) xhr.setRequestHeader('Authorization', `Bearer ${this.token}`)
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable && onProgress) onProgress(e.loaded, e.total)
      }
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            resolve(JSON.parse(xhr.responseText || '{}'))
          } catch {
            resolve({ size: file.size, path: `${path}/${file.name}` })
          }
        } else {
          if (xhr.status === 401 || xhr.status === 403) {
            try {
              window.dispatchEvent(new Event('yunxia:pwd'))
            } catch {}
          }
          reject(new ApiError(xhr.status, `HTTP ${xhr.status}`))
        }
      }
      xhr.onerror = () => reject(new ApiError(0, '网络中断'))
      xhr.send(file)
    })
  }

  link(source: string, path: string) {
    return this.send<{ url: string; expires: number; size: number }>('GET', '/fs/link', undefined, {
      source,
      path,
    })
  }

  mkdir(source: string, path: string, name: string) {
    return this.send('POST', '/fs/mkdir', { source, path, name })
  }

  move(source: string, src: string, dst: string) {
    return this.send('POST', '/fs/move', { source, src, dst })
  }

  remove(source: string, paths: string[]) {
    return this.send('POST', '/fs/delete', { source, paths })
  }

  search(q: string, kind?: string, limit = 60, offset = 0) {
    return this.send<{ total: number; took_ms: number; items: Entry[] }>('GET', '/search', undefined, {
      q,
      limit: String(limit),
      offset: String(offset),
      ...(kind ? { kind } : {}),
    })
  }

  private _sourcesCache: {
    at: number
    p: Promise<MetaSources>
  } | null = null

  /// 首屏 App.vue 和各页面都要这份数据：缓存 30 秒 + 并发去重，
  /// 否则打开首页会看到两条一模一样的 /meta/sources 请求。
  sources(opts: { fresh?: boolean } = {}) {
    const now = Date.now()
    if (!opts.fresh && this._sourcesCache && now - this._sourcesCache.at < 30000) {
      return this._sourcesCache.p
    }
    const p = this.send<MetaSources>('GET', '/meta/sources').catch((e) => {
      this._sourcesCache = null // 失败不缓存，下次重试
      throw e
    })
    this._sourcesCache = { at: now, p }
    return p
  }

  storage() {
    return this.send<Storage>('GET', '/meta/storage')
  }

  storageAnalysis(source = '') {
    return this.send<{
      source: string
      name: string
      local: boolean
      disk: { total: number; used: number; free: number; root: string } | null
      scan: {
        files: number
        dirs: number
        bytes: number
        by_kind: { kind: string; count: number; bytes: number }[]
        top_dirs: { name: string; bytes: number }[]
        scanned_at: number
        elapsed: number
      } | null
      scanning: boolean
      stale: boolean
      note: string
    }>('GET', '/meta/storage/analysis', undefined, { source })
  }

  // 继续观看
  playList(limit = 8) {
    return this.send<{ items: PlayItem[] }>('GET', '/play', undefined, { limit: String(limit) })
  }

  playOne(path: string) {
    return this.send<PlayItem & { found: boolean }>(
      'GET',
      '/play/one',
      undefined,
      { path },
    )
  }

  playSave(path: string, pos: number, dur: number, name: string) {
    return this.send('PUT', '/play', { path, pos, dur, name })
  }

  playForget(path: string) {
    return this.send('DELETE', '/play', undefined, { path })
  }

  thumbUrl(path: string, w = 320) {
    const t = encodeURIComponent(this.token ?? '')
    return `${this.server}/api/v1/thumb/t?w=${w}&t=${t}&path=${encodeURIComponent(path)}`
  }

  searchStatus() {
    return this.send<{ files: number; dirs: number; last_scan: string; scanning: boolean }>(
      'GET',
      '/search/status',
    )
  }

  reindex() {
    return this.send('POST', '/search/reindex')
  }

  /* ---------- 听译 ---------- */

  /** 队列快照 + 服务端配置（模型/设备/并发/翻译是否配好） */
  subsList() {
    return this.send<{ jobs: SubJob[] } & SubState>('GET', '/subs')
  }

  /** 提交一条视频转写。同一条视频重复提交是复用，跑着时返回当前状态 */
  subsAdd(source: string, path: string, name = '', lang = '') {
    return this.send<SubJob>('POST', '/subs/add', { source, path, name, lang })
  }

  subsCancel(id: string) {
    return this.send<{ ok: boolean }>('POST', '/subs/cancel', { id })
  }

  subsDelete(id: string) {
    return this.send<{ ok: boolean; deleted: string }>('POST', '/subs/delete', { id })
  }

  /** 整片翻译（后台线程跑，接口立刻返回；409 = 还没转写完或没配翻译） */
  subsTranslate(id: string, to = '') {
    return this.send<SubJob>('POST', '/subs/translate', { id, to })
  }

  subsSetMaxActive(n: number) {
    return this.send<{ ok: boolean; max_active: number }>('POST', '/subs/config', { max_active: n })
  }

  /** 播放器用：这条视频有没有现成字幕 */
  subsFor(source: string, path: string) {
    return this.send<SubFor>('GET', '/subs/for', undefined, { source, path })
  }

  /** since>0 时只回新增的段落（服务端按序号切片），用于边转边显示 */
  subsDetail(id: string, since = 0) {
    return this.send<SubJob & { since: number; segments_list: SubSeg[] }>(
      'GET',
      `/subs/${encodeURIComponent(id)}`,
      undefined,
      { since: String(Math.max(0, since)) },
    )
  }

  /// SRT 导出：<a download> 带不了 Authorization 头，只能把令牌放查询串
  /// （服务端 current_device 认 ?t=，和缩略图同一条路）。
  subsSrtUrl(id: string, trans = true) {
    const q = new URLSearchParams({ trans: trans ? '1' : '0' })
    if (this.token) q.set('t', this.token)
    return `${this.origin}/api/v1/subs/${encodeURIComponent(id)}/srt?${q.toString()}`
  }
}

export const api = new Api()

export function humanSize(bytes: number): string {
  if (!bytes || bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = bytes
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`
}

export function humanTime(sec: number): string {
  if (!sec) return '—'
  const d = new Date(sec * 1000)
  const now = new Date()
  const sameDay =
    d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  if (sameDay) return `今天 ${hm}`
  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (
    d.getFullYear() === yesterday.getFullYear() &&
    d.getMonth() === yesterday.getMonth() &&
    d.getDate() === yesterday.getDate()
  )
    return `昨天 ${hm}`
  if (d.getFullYear() === now.getFullYear()) return `${d.getMonth() + 1}月${d.getDate()}日`
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`
}
