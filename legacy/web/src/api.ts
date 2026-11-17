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

  private _sourcesCache: { at: number; p: Promise<{ sources: { id: string; name: string; writable: boolean; root: string }[]; default: string }> } | null = null

  /// 首屏 App.vue 和各页面都要这份数据：缓存 30 秒 + 并发去重，
  /// 否则打开首页会看到两条一模一样的 /meta/sources 请求。
  sources(opts: { fresh?: boolean } = {}) {
    const now = Date.now()
    if (!opts.fresh && this._sourcesCache && now - this._sourcesCache.at < 30000) {
      return this._sourcesCache.p
    }
    const p = this.send<{ sources: { id: string; name: string; writable: boolean; root: string }[]; default: string }>(
      'GET',
      '/meta/sources',
    ).catch((e) => {
      this._sourcesCache = null // 失败不缓存，下次重试
      throw e
    })
    this._sourcesCache = { at: now, p }
    return p
  }

  storage() {
    return this.send<Storage>('GET', '/meta/storage')
  }

  storageAnalysis(source = 'nas') {
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

  tasks() {
    return this.send<{ tasks: any[]; hubs: Record<string, any> }>('GET', '/tasks')
  }

  addTask(kind: string, urls: string[], dir = '') {
    return this.send('POST', '/tasks/add', { kind, urls, dir, target: 'nas' })
  }

  taskAct(kind: string, id: string, act: string) {
    return this.send('POST', '/tasks/act', { kind, id, act })
  }

  subs() {
    return this.send<{ jobs: any[]; online: boolean; error?: string }>('GET', '/subs')
  }

  /** 翻译源的默认配置（密钥在 NAS 上，客户端拿一次就存本地） */
  /* ---- CloudDrive2 深接入（gRPC，不用 WebDAV）---- */
  cd2Status() {
    return this.send<{ ok: boolean; ready: boolean; login: boolean; user: string; token_set: boolean }>(
      'GET',
      '/cd2/status',
    )
  }
  cd2Token(token: string) {
    return this.send<{ ok: boolean; items: number }>('POST', '/cd2/token', { token })
  }
  cd2List(path = '/115open') {
    return this.send<{ path: string; count: number; entries: any[] }>(
      'GET',
      `/cd2/list?path=${encodeURIComponent(path)}`,
    )
  }
  cd2Offline(urls: string[], path = '/云下载', source = 'nas115') {
    // path 是「源内相对目录」，后端再补上 source.root（/115open）
    return this.send<{ ok: boolean; msg: string }>('POST', '/cd2/offline', { urls, path, source })
  }
  cd2OfflineDel(hash: string, opts: { path?: string; source?: string; deleteFiles?: boolean } = {}) {
    return this.send<{ ok: boolean }>('POST', '/cd2/offline/del', {
      hash,
      path: opts.path || '/',
      source: opts.source || 'nas115',
      delete_files: opts.deleteFiles === true,
    })
  }
  cd2OfflineAll(page = 1) {
    // 跨目录全部云下载任务：设置页的「下载监控」用
    return this.send<{ items: any[]; total: number }>(
      'GET',
      `/cd2/offline/all?page=${page}`,
    )
  }
  cd2OfflineList(path = '/云下载', source = 'nas115') {
    return this.send<{ count: number; tasks: any[] }>(
      'GET',
      `/cd2/offline?path=${encodeURIComponent(path)}&source=${encodeURIComponent(source)}`,
    )
  }

  trCfg() {
    return this.send<{ provider: string; base: string; model: string; key: string }>(
      'GET',
      '/subs/trcfg',
    )
  }

  /** 播放头上报：hub 只翻播放头附近那几句，不上报就一句都不翻 */
  subsAt(id: string, at: number) {
    return this.send<{ ok: boolean }>('POST', '/subs/at', { id, at })
  }

  /** 取任务字幕；since>0 只回新增/改动，客户端自己合并 */
  subGet(id: string, since = 0) {
    return this.send<any>(
      'GET',
      `/subs/${encodeURIComponent(id)}${since ? `?since=${since}` : ''}`,
    )
  }

  /** 内封字幕轨列表（text=false 是 PGS/VobSub 这类图形字幕） */
  embeddedSubs(source: string, path: string) {
    const q = `source=${encodeURIComponent(source)}&path=${encodeURIComponent(path)}`
    return this.send<{ subs: any[]; dur: number }>('GET', `/subs/embedded?${q}`)
  }

  /** 把一条文字内封轨抽成 SRT（首次要顺着读完，边抽边给） */
  embeddedText(source: string, path: string, idx: number) {
    const q = `source=${encodeURIComponent(source)}&path=${encodeURIComponent(path)}&idx=${idx}`
    return this.send<{ state: string; cues: number; text: string; err: string }>(
      'GET',
      `/subs/embedded/text?${q}`,
    )
  }

  /** 图形字幕（PGS）→ 图片时间轴；首次调用开始抽，state=running 时轮询 */
  graphicSub(source: string, path: string, idx: number) {
    const q = `source=${encodeURIComponent(source)}&path=${encodeURIComponent(path)}&idx=${idx}`
    return this.send<{
      state: string
      key: string
      w?: number
      h?: number
      cues?: { s: number; e: number; x: number; y: number; w: number; h: number; i: number }[]
      done?: number
      total?: number
      err?: string
    }>('GET', `/subs/graphic?${q}`)
  }

  /** 字幕图片是 <img> 加载的，带不了 Authorization 头，令牌走 query */
  graphicUrl(key: string, i: number) {
    const t = encodeURIComponent(this.token || '')
    return `${this.origin}/api/v1/subs/graphic/img?key=${key}&i=${i}&t=${t}`
  }

  /** 听译服务地址 + 并发上限（听设置页那几行） */
  subsConfig() {
    return this.send<{ hub: string; max_active: number | null; active: number | null; online: boolean; jobs?: number }>(
      'GET',
      '/subs/config',
    )
  }

  setSubsConfig(body: { max_active?: number }) {
    return this.send<{ ok: boolean; max_active?: number }>('POST', '/subs/config', body)
  }

  /** <img> 用不了 Authorization 头，缩略图令牌走查询串 */
  /** 带鉴权下载二进制（字幕之类），浏览器自己触发保存 */
  async downloadBin(path: string, filename: string) {
    const r = await fetch(this.server + path, {
      headers: this.token ? { Authorization: `Bearer ${this.token}` } : {},
    })
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const blob = await r.blob()
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    setTimeout(() => URL.revokeObjectURL(url), 4000)
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

  subsFor(path: string) {
    return this.send<{ found: boolean; segments?: any[]; lang?: string; name?: string }>(
      'GET',
      '/subs/for?path=' + encodeURIComponent(path),
    )
  }

  subsAdd(path: string, name = '', source = 'nas', model = '', again = false) {
    // again=true 才是「重新转写」：不带它的时候服务端会把已有任务原样复用回来，
    // 界面上看着排进去了，其实一句都没重听
    return this.send('POST', '/subs/add', { path, name, source, model, ...(again ? { again } : {}) })
  }

  /** 只换译文语言：清掉的译文由中枢再补回来（网页端「翻译」走这条） */
  subsLang(id: string, to = 'zh') {
    return this.send('POST', '/subs/lang', { id, to })
  }

  subsDelete(id: string) {
    return this.send('POST', '/subs/delete', { id })
  }

  subsDetail(id: string) {
    return this.send<{ segments_list?: any[]; name?: string; lang?: string }>(
      'GET',
      `/subs/${encodeURIComponent(id)}`,
    )
  }

  subsCancel(id: string) {
    return this.send('POST', '/subs/cancel', { id })
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
