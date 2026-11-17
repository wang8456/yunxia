<script setup lang="ts">
/* 云匣 · 对话 —— 1:1 照旧前端 5020（dufs/assets/chat.js 的 MFM_CHAT）。
   后端同一套：/hermes/api/*（SSE + Basic 口令）。

   旧前端的规矩（别自己改回去）：
   - 记录存 localStorage['mfm.chat.v1']，形状 {prevId, since, messages[{role,ts,rid,text,imgs,files,steps,think,elapsed}]}
   - 口令存 localStorage['mfm.chat.auth']（Basic b64），401 时顶部出一条黄条让人重输
   - 气泡：用户右侧蓝底、底部右角 7px；助手左侧白底描边、底部左角 7px；系统消息居中灰胶囊
   - 日期分隔线（今天 / 年/月/日）、用时 N 秒、正在输入三个跳动的点
   - 工具步骤一行一条，跑着是蓝点 + 「运行中 Ns」，完成后 ✓/✕ + 耗时，点一下展开完整输出
   - 思考文字默认两行，点「展开全文」看不截断的
   - 危险命令出审批卡：允许一次 / 本会话都允许 / 以后都允许 / 拒绝
   - 长按消息 → 复制文字 / 重新发送 / 删除这条
   - 斜杠命令 /new /stop /retry /status /help 本地处理，不发网络
   - 附件：图片压到 1600px JPEG 0.82 再发，文件走 XHR 上传拿路径，60MB 上限
*/
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import Ico from '../components/Ico.vue'
import ImageViewer from './ImageViewer.vue'

const API = '/hermes/api/'
const STORE = 'mfm.chat.v1'
const AUTH = 'mfm.chat.auth'

type Step = {
  name: string
  arg: string
  run: boolean
  call?: string
  t0?: number
  out?: string
  bad?: boolean
  dur?: number | null
}

type Approval = {
  run_id: string
  request_id: string
  command: string
  description: string
  choices: string[]
  choice: string | null
  error: string | null
  pending?: string | null
}

type Msg = {
  id?: string          // 同步用的全局 id
  sent?: boolean       // 已经推进共享库
  role: 'user' | 'assistant' | 'system'
  ts?: number
  rid?: string
  text: string
  think?: string
  steps?: Step[]
  approval?: Approval | null
  imgs?: string[]
  files?: { name: string; size: string; path?: string }[]
  wait?: boolean
  elapsed?: number
  /** 服务端托管状态：running / done / failed / stopped / interrupted */
  status?: string
}

const messages = ref<Msg[]>([])
const prevId = ref<string | null>(null)
const since = ref(0)
const busy = ref(false)
const draft = ref('')
const locked = ref(false)
const nearBottom = ref(true)
const tick = ref(0)
const inputEl = ref<HTMLTextAreaElement | null>(null)
const logEl = ref<HTMLElement | null>(null)

const sheetOpen = ref(false)
const sheetIdx = ref(-1)
const openSteps = ref<Record<string, boolean>>({})
const openThinks = ref<Record<string, boolean>>({})
const boxes = ref({ left: 0, width: 0, bottom: 0 })

type Att = {
  id: string
  name: string
  size: number
  isImg: boolean
  preview?: string | null
  path?: string | null
  saved?: string | null
  thumbUrl?: string | null
  dataUrl?: string | null
  progress?: number | null
  error?: boolean
  errMsg?: string
}
const atts = ref<Att[]>([])
const fileEl = ref<HTMLInputElement | null>(null)

let abortCtl: AbortController | null = null
let live: { id: string } | null = null
/* 上下文损坏后置位：在拿到一条新的、健康的 response id 之前，不要从库里把坏的 prevId 捞回来 */
let ctxReset = false
let ticker: number | undefined
let syncTimer: number | undefined

/* ---------- 口令 ---------- */
function authB64() {
  try {
    const a = localStorage.getItem(AUTH)
    if (a) return a
    // 云匣登录时存下的那份也能用
    const k = localStorage.getItem('yunxia.chatkey') || ''
    return k.replace(/^Basic\s+/i, '')
  } catch {
    return ''
  }
}

function api(path: string, opts: RequestInit = {}) {
  const h: Record<string, string> = { ...((opts.headers as Record<string, string>) || {}) }
  const a = authB64()
  if (a) h.Authorization = 'Basic ' + a
  opts.headers = h
  return fetch(API + path.replace(/^\//, ''), opts).then((r) => {
    if (r.status === 401) {
      // 两份口令一起作废：只删一份会出现「设置说已填、对话仍要重输」
      try {
        localStorage.removeItem(AUTH)
        localStorage.removeItem('yunxia.chatkey')
      } catch {}
      locked.value = true
    }
    return r
  })
}

/* ---------- 存取 ---------- */
const SAVE_KEEP = 80 // 只留最近这些条：localStorage 就 5MB，攒上千条必然 QuotaExceeded

function packMsg(m: Msg) {
  return {
    role: m.role,
    ts: m.ts,
    rid: m.rid,
    // 单条超长正文/工具输出会把配额吃光，落盘前砍一刀（服务端账本里是全的）
    text: (m.text || '').slice(0, 20000),
    imgs: m.imgs || [],
    files: m.files || [],
    steps: (m.steps || []).map((st) => ({
      ...st,
      arg: (st.arg || '').slice(0, 400),
      out: (st.out || '').slice(0, 800),
    })),
    think: (m.think || '').slice(0, 4000),
    elapsed: m.elapsed,
    approval: m.approval || null,
    id: m.id,
    sent: m.sent,
  }
}

function saveLocal() {
  const base = () => ({
    prevId: prevId.value,
    ctxReset,
    since: since.value || 0,
  })
  const all = messages.value
  // 配额不够就逐级缩水，最差也把 prevId/since 存下来，别让下次进来看空
  for (const keep of [SAVE_KEEP, 30, 0]) {
    try {
      const msgs = keep === 0 ? [] : all.slice(Math.max(0, all.length - keep)).map(packMsg)
      localStorage.setItem(STORE, JSON.stringify({ ...base(), messages: msgs }))
      return
    } catch (e) {
      // 继续试更小的档位
      void e
    }
  }
  console.warn('chat saveLocal: 本地存储写不进去，已放弃缓存这一屏消息')
}

/** 本地落盘 + 稍后把新消息推给共享库（同一轮多个改动只推一次） */
function save() {
  saveLocal()
  clearTimeout(pushTimer)
  pushTimer = window.setTimeout(() => {
    void pushLog()
  }, 350)
}

function load() {
  try {
    const d = JSON.parse(localStorage.getItem(STORE) || '{}')
    prevId.value = d.prevId || null
    ctxReset = !!d.ctxReset
    // 历史里有「上下文坏了」的报错：这条 prevId 链已经废了，别再拿它发第一条
    if (
      (d.messages || []).some(
        (m: any) =>
          m.role !== 'user' &&
          /Invalid base64 data|rejected this request as malformed/i.test(m.text || ''),
      )
    ) {
      ctxReset = true
      prevId.value = null
    }
    since.value = d.since || 0
    messages.value = (d.messages || []).map((m: Msg) => {
      const steps = (m.steps || []).map((s) => {
        // 断线时还在转的那一步：别一直转下去
        if (s.run) return { ...s, run: false, bad: true, out: s.out || '（页面断开，这一步的结果没收到）' }
        return s
      })
      return { ...m, steps }
    })
  } catch {}
}

/* ---------- 文本工具 ---------- */
function esc(s: unknown) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

function humanSize(n: number) {
  if (n < 1024) return n + ' B'
  if (n < 1048576) return Math.round(n / 1024) + ' KB'
  return (n / 1048576).toFixed(1) + ' MB'
}

function dayLabel(ts?: number) {
  if (!ts) return ''
  const d = new Date(ts)
  const t = new Date()
  return d.toDateString() === t.toDateString() ? '今天' : `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`
}

/** 缩略图地址：服务端按宽度缩放并缓存，对话里不拉原图 */
function thumbHref(p: string, w = 240) {
  const href = dlHref(p)
  if (!href) return ''
  return href.replace('/api/dl?', '/api/thumb?') + '&w=' + w
}

function dlHref(path: string) {
  const p = String(path || '').trim()
  if (!/^(?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\//.test(p)) return ''
  if (!/\.[A-Za-z0-9]{1,8}$/.test(p)) return ''
  // 路径里允许空格（歌名/文件名常见）；只挡控制字符和引号
  if (/[<>"'`\n\r\t]/.test(p)) return ''
  return '/hermes/api/dl?path=' + encodeURIComponent(p)
}

const URL_RE = /\b((?:https?:\/\/|www\.)[^\s<>"'`（）()【】[\]，。；;、]+)/gi
const PATH_RE =
  /(^|[\s(（:：])((?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\/[^\s<>'`()（）]*?\.[A-Za-z0-9]{1,8})(?=$|[\s)）。,，;；:：])/g
const IMG_PATH_RE =
  /(?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\/[^\s<>"'`()（）,，。；;：:]+?\.(?:png|jpe?g|webp|gif)/gi

function linkifyUrls(p: string) {
  return p.replace(URL_RE, (m) => {
    let tail = ''
    const mm = /[.,;:!?、。；：！？]+$/.exec(m)
    if (mm) {
      tail = mm[0]
      m = m.slice(0, -tail.length)
    }
    if (!m) return tail
    const href = /^https?:\/\//i.test(m) ? m : 'https://' + m
    return `<a class="cx-a" href="${href}" target="_blank" rel="noopener noreferrer">${m}</a>${tail}`
  })
}

const IMG_EXT_RE = /\.(?:png|jpe?g|webp|gif|bmp|avif)$/i

function dlLink(path: string) {
  // 图片交给缩略图 + 查看器，不再出一行「📎 文件名」
  if (IMG_EXT_RE.test(path)) return ''
  const name = path.split('/').pop() || path
  return `<a class="cx-dl" href="/hermes/api/dl?path=${encodeURIComponent(path)}" download>📎 ${esc(name)}</a>`
}

function linkifyPaths(p: string) {
  return p.replace(PATH_RE, (_m, pre: string, path: string) => pre + dlLink(path))
}

function inline(seg: string) {
  return seg
    .split(/(`[^`\n]+`)/)
    .map((part) => {
      if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) {
        const inner = part.slice(1, -1)
        if (/^(?:https?:\/\/|www\.)\S+$/i.test(inner)) return linkifyUrls(inner)
        const href = dlHref(inner)
        return href
          ? `<a class="cx-dl" href="${href}" download>📎 ${esc(inner)}</a>`
          : '<code>' + esc(inner) + '</code>'
      }
      let x = part
      // 图片：![alt](url 或本地路径) → 缩略图，点开内置查看器
      x = x.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_m, alt, src) => {
        const full = /^https?:\/\//i.test(src) ? src : dlHref(src) || src
        const thumb = /^https?:\/\//i.test(src) ? full : thumbHref(src) || full
        return `<img class="cx-mi" src="${thumb}" data-raw="${thumb}" data-full="${full}" loading="lazy" alt="${alt || ''}" />`
      })
      x = x.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a class="cx-a" href="$2" target="_blank" rel="noreferrer">$1</a>')
      x = x.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
      x = x.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<i>$2</i>')
      x = x.replace(/~~([^~]+)~~/g, '<s>$1</s>')
      return linkifyPaths(linkifyUrls(x))
    })
    .join('')
}

/** 轻量 markdown：标题 / 列表 / 引用 / 分隔线 / 粗斜删 / 行内代码 / 链接，段落按行 */
const foldSteps = ref<Record<number, boolean>>({})

function hhmm(ts?: number) {
  const d = new Date(ts || Date.now())
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** 同一个人 5 分钟内算一组：只有组尾那条把靠自己的下角收小 */
function grp(i: number) {
  const m = messages.value[i]
  const p = messages.value[i - 1]
  const n = messages.value[i + 1]
  const near = (a?: Msg, b?: Msg) =>
    !!a && !!b && a.role === b.role && (a.ts || 0) - (b.ts || 0) < 5 * 60 * 1000 && (b.ts || 0) - (a.ts || 0) < 5 * 60 * 1000
  return { first: !near(p, m), last: !near(m, n) }
}

/** 泡内右下：正在输出 · N 字 · Ns / 用时 N 秒（自己发的不显示） */
function statusText(m: Msg) {
  if (m.role === 'user') return ''
  if (m.wait) {
    const sec = m.ts ? Math.max(0, Math.round((Date.now() - m.ts) / 1000)) : 0
    const n = (m.text || '').length
    const size = n >= 1000 ? `${(n / 1000).toFixed(1)}k 字` : `${n} 字`
    void tick.value // 依赖它，每秒重算
    return `正在输出 · ${size} · ${sec}s`
  }
  if (m.elapsed && m.elapsed >= 1) {
    const s = Math.round(m.elapsed)
    return s >= 60 ? `用时 ${Math.floor(s / 60)} 分 ${s % 60} 秒` : `用时 ${s} 秒`
  }
  return ''
}

function runCount(m: Msg) {
  return (m.steps || []).filter((s) => s.run).length
}

/** 回复里常见的 MEDIA:/path 只是投递指令，正文里不该出现这两个字 */
const MEDIA_LINE_RE = /(^|\n)[ \t]*MEDIA:[ \t]*([^\n]+)/g

/** 「MEDIA:」行里真正的路径（整行取，路径里可能有空格和中文） */
function mediaPaths(t: string) {
  const out: string[] = []
  for (const m of String(t || '').matchAll(MEDIA_LINE_RE)) {
    const p = m[2].trim().replace(/[.,;:!?、。；：！？]+$/, '')
    if (p && !out.includes(p)) out.push(p)
  }
  return out
}

/** MEDIA 行里不是图片的文件 —— 在气泡下面出一行「📎 下载」 */
const WIN_LINE_RE = /([A-Za-z]:[\\/][^\n]+)$/

/** 正文里只写了 Windows 路径（常带空格和中文）时，也给它出一行下载 */
function winFilePaths(t: string) {
  const out: string[] = []
  for (const line of String(t || '').split(/\r?\n/)) {
    const m = WIN_LINE_RE.exec(line.trim())
    if (!m) continue
    const p = m[1].trim().replace(/[.,;:!?、。；：！？）)】]+$/, '')
    if (!/\.[A-Za-z0-9]{1,5}$/.test(p)) continue
    const conv =
      '/mnt/' + p[0].toLowerCase() + '/' + p.slice(3).replace(/\\/g, '/')
    if (!out.includes(conv)) out.push(conv)
  }
  return out
}


function mediaFilesOf(m: Msg) {
  const key = 'mf:' + (m.text || '')
  const hit = thumbCache.get(key)
  if (hit) return hit as any[]
  const rows = [...mediaPaths(m.text || ''), ...winFilePaths(m.text || '')]
    .filter((p) => !IMG_EXT_RE.test(p))
    .map((p) => ({ path: p, name: p.split('/').pop() || p, href: dlHref(p) }))
    .filter((r) => r.href)
  if (thumbCache.size > 400) thumbCache.clear()
  thumbCache.set(key, rows)
  return rows
}

function stripMedia(t: string) {
  // 整行去掉（连路径）：路径已经在缩略图或下载行里出现过了，
  // 留在正文里只会被 PATH_RE 切成半截。
  return String(t || '').replace(MEDIA_LINE_RE, '$1')
}

/* 渲染结果按文本缓存：tick 每秒刷新时不用把整页 Markdown 重新解析一遍 */
const mdCache = new Map<string, string>()
const thumbCache = new Map<string, any[]>()

function memo<T>(cache: Map<string, T>, key: string, fn: () => T): T {
  const hit = cache.get(key)
  if (hit !== undefined) return hit
  const v = fn()
  if (cache.size > 400) {
    const oldest = cache.keys().next().value
    if (oldest !== undefined) cache.delete(oldest)
  }
  cache.set(key, v)
  return v
}

function md(t: string) {
  return memo(mdCache, t || '', () => mdRender(t))
}

function mdRender(t: string) {
  return esc(stripMedia(t))
    .split(/```/)
    .map((p, i) => {
      if (i % 2 === 1) return '<pre><code>' + p.replace(/^\w*\n/, '') + '</code></pre>'
      const out: string[] = []
      let list: 'ul' | 'ol' | null = null
      const close = () => {
        if (list) out.push(list === 'ul' ? '</ul>' : '</ol>')
        list = null
      }
      for (const ln of p.split('\n')) {
        const h = ln.match(/^(#{1,4})\s+(.*)$/)
        const ul = ln.match(/^\s*[-*+]\s+(.*)$/)
        const ol = ln.match(/^\s*\d+[.)]\s+(.*)$/)
        const q = ln.match(/^&gt;\s?(.*)$/)
        if (/^\s*(?:---+|\*\*\*+|___+)\s*$/.test(ln)) {
          close()
          out.push('<hr/>')
          continue
        }
        if (h) {
          close()
          const lvl = h[1].length + 2
          out.push(`<h${lvl}>${inline(h[2])}</h${lvl}>`)
          continue
        }
        if (ul) {
          if (list !== 'ul') {
            close()
            out.push('<ul>')
            list = 'ul'
          }
          out.push(`<li>${inline(ul[1])}</li>`)
          continue
        }
        if (ol) {
          if (list !== 'ol') {
            close()
            out.push('<ol>')
            list = 'ol'
          }
          out.push(`<li>${inline(ol[1])}</li>`)
          continue
        }
        if (q) {
          close()
          out.push(`<blockquote>${inline(q[1])}</blockquote>`)
          continue
        }
        if (!ln.trim()) {
          close()
          out.push('')
          continue
        }
        close()
        out.push(inline(ln))
      }
      close()
      return out.join('\n')
    })
    .join('')
}

function bodyHtml(m: Msg) {
  const body = String(m.text || '').replace(/^[\s\u00a0]+/, '')
  return body ? md(body) : ''
}

function imgPathsOf(t: string) {
  const out: string[] = []
  let m: RegExpExecArray | null
  IMG_PATH_RE.lastIndex = 0
  while ((m = IMG_PATH_RE.exec(String(t || ''))) && out.length < 6) {
    if (!out.includes(m[0])) out.push(m[0])
  }
  return out
}

/** 正文里已经用 ![..](..) 显式贴过的图，不再重复出缩略图 */
function thumbsOf(m: Msg) {
  return memo(thumbCache, stripMedia(m.text || ''), () => thumbsRender(stripMedia(m.text || '')))
}

function thumbsRender(text: string) {
  const mdHref = new Set(
    [...text.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/g)]
      .map((x) => (dlHref(x[1]) || x[1]).trim())
      .filter(Boolean),
  )
  // Windows 盘符路径（G:\hermes\a.jpg）也认，换算成同一台机器的 /mnt/g/...
  const winPaths = [...text.matchAll(/([A-Za-z]):\\[^\s<>"'`]+?\.(?:png|jpe?g|webp|gif)/g)].map(
    (m) => '/mnt/' + m[1].toLowerCase() + '/' + m[0].slice(3).replace(/\\/g, '/'),
  )
  const seen = new Set<string>()
  const mediaImgs = mediaPaths(text).filter((p) => IMG_EXT_RE.test(p))
  return [...imgPathsOf(text), ...winPaths, ...mediaImgs]
    .filter((p) => {
      const h = (dlHref(p) || p).trim()
      return !mdHref.has(h)
    })
    .map((p) => ({ href: thumbHref(p), full: dlHref(p), name: p.split('/').pop() || '' }))
    .filter((t) => {
      if (!t.href || !t.full || seen.has(t.full)) return false
      seen.add(t.full)
      return true
    })
}

function shortArg(raw?: string) {
  let o: any = null
  try {
    o = typeof raw === 'string' ? JSON.parse(raw) : raw
  } catch {}
  let v = ''
  if (o && typeof o === 'object') {
    const keys = [
      'command', 'file_path', 'path', 'query', 'pattern', 'url', 'goal', 'prompt',
      'description', 'skill', 'name', 'text', 'code', 'reason',
    ]
    for (const k of keys) {
      if (typeof o[k] === 'string' && o[k]) {
        v = o[k]
        break
      }
    }
    if (!v) {
      for (const k in o) {
        if (typeof o[k] === 'string' && o[k]) {
          v = o[k]
          break
        }
      }
    }
  }
  if (!v) v = typeof raw === 'string' ? raw : ''
  v = String(v).replace(/\s+/g, ' ').trim()
  return v.length > 140 ? v.slice(0, 140) + '…' : v
}

function outOf(item: any) {
  let raw = item.output
  if (Array.isArray(raw)) raw = raw.map((p: any) => (p && (p.text || p.content)) || '').join('\n')
  else if (raw && typeof raw === 'object') raw = raw.text || JSON.stringify(raw)
  let s = String(raw || '')
  let o: any = null
  let bad = false
  let code: number | null = null
  try {
    o = JSON.parse(s)
  } catch {}
  if (o && typeof o === 'object') {
    if (typeof o.exit_code === 'number') code = o.exit_code
    let txt = o.output || o.stdout || o.text || o.result || o.message || ''
    if (!txt && o.error) {
      txt = typeof o.error === 'string' ? o.error : JSON.stringify(o.error)
      bad = true
    }
    if (typeof txt !== 'string') txt = JSON.stringify(txt)
    if (txt) s = txt
    if (code !== null && code !== 0) bad = true
    if (o.error && !code) bad = true
  }
  s = s.replace(/\r/g, '').replace(/\n{3,}/g, '\n\n').trim()
  if (s.length > 1600) s = s.slice(0, 1600) + '…'
  return { text: s, bad }
}

function errText(e: any) {
  const m = String((e && e.message) || e || '')
  const c = (m.match(/HTTP (\d{3})/) || [])[1]
  if (c) {
    if (c === '401' || c === '403') return '口令失效了，重新输一下口令'
    if (c === '429') return '发得太快了，缓一分钟再试'
    if (c.charAt(0) === '5') return `服务器出错了（${c}），过一会儿再试`
    return `这次没成功（${c}），重发试试`
  }
  if (/Failed to fetch|NetworkError|Load failed|network/i.test(m)) return '网络断了，检查一下网络再发一次'
  if (/abort/i.test(m)) return '已取消'
  return '出了点问题，重发试试'
}

/* ---------- 滚动 ---------- */
function scrollDown(force = false) {
  const el = logEl.value
  if (!el) return
  const near = el.scrollHeight - el.scrollTop - el.clientHeight < 260
  if (force || near) el.scrollTop = el.scrollHeight
  onLogScroll()
}

function onLogScroll() {
  const el = logEl.value
  if (!el) return
  nearBottom.value = el.scrollHeight - el.scrollTop - el.clientHeight <= 320
}

function backToLatest() {
  const el = logEl.value
  if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
}

/* ---------- 渲染后的装饰：代码复制按钮 / 缩略图 ---------- */

/** 回复里的图片要口令，<img> 带不了 Basic 头 → 先取 blob 再换 src */
const blobCache = new Map<string, string>()

/** 图多了就淘汰已经滚出屏幕的 blob，避免正文里图片看一圈内存一直涨 */
function putBlob(key: string, url: string) {
  blobCache.set(key, url)
  if (blobCache.size <= 80) return
  const alive = new Set<string>()
  document.querySelectorAll('img').forEach((i) => {
    if (i.getAttribute('src')) alive.add(i.getAttribute('src')!)
  })
  for (const [k, v] of [...blobCache]) {
    if (blobCache.size <= 60) break
    if (alive.has(v)) continue
    blobCache.delete(k)
    try {
      URL.revokeObjectURL(v)
    } catch {
      /* 已释放 */
    }
  }
}

async function loadOneImg(el: HTMLImageElement, auth: string) {
  if (el.dataset.hyd === '1') return
  el.dataset.hyd = '1'
  const cand = [
    el.getAttribute('data-hx') || '',
    el.getAttribute('data-raw') || '',
    el.getAttribute('data-full') || '',
  ].filter((u, i, a) => u && u.includes('/hermes/api/') && a.indexOf(u) === i)
  for (const u of cand) {
    const hit = blobCache.get(u)
    if (hit) {
      el.src = hit
      return
    }
    try {
      const r = await fetch(u, { headers: auth ? { Authorization: 'Basic ' + auth } : {}, cache: 'force-cache' })
      if (!r.ok) continue
      const b = await r.blob()
      if (!b.size) continue
      const obj = URL.createObjectURL(b)
      putBlob(u, obj)
      el.src = obj
      return
    } catch {
      /* 换下一个地址试 */
    }
  }
  // 缩略图和原图都拿不到（多半是文件已被清掉）：给个占位，别留个空 img
  el.classList.add('cx-mi-bad')
  el.removeAttribute('src')
  el.alt = '图片已失效'
}

async function hydrateImgs() {
  const log = logEl.value
  if (!log) return
  const auth = authB64()
  const list = [...log.querySelectorAll<HTMLImageElement>('img.cx-mi, .cx-imgs img')]
  for (const el of list) await loadOneImg(el, auth)
}

async function decorate() {
  await nextTick()
  const log = logEl.value
  if (!log) return
  void hydrateImgs()
  log.querySelectorAll<HTMLPreElement>('.cx-b pre:not([data-cp])').forEach((pre) => {
    pre.setAttribute('data-cp', '1')
    const b = document.createElement('button')
    b.type = 'button'
    b.className = 'cx-cp'
    b.textContent = '复制'
    b.onclick = (ev) => {
      ev.stopPropagation()
      const code = pre.querySelector('code')
      copyText(code ? code.innerText : pre.innerText).then(() => {
        b.textContent = '已复制'
        setTimeout(() => (b.textContent = '复制'), 1400)
      })
    }
    pre.appendChild(b)
  })
}

function copyText(t: string) {
  const fb = () => {
    const ta = document.createElement('textarea')
    ta.value = t
    ta.style.position = 'fixed'
    ta.style.opacity = '0'
    ta.style.left = '-9999px'
    document.body.appendChild(ta)
    ta.select()
    try {
      document.execCommand('copy')
    } catch {}
    ta.remove()
    return Promise.resolve()
  }
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(t).catch(fb)
  return fb()
}

/* ---------- 附件 ---------- */
function pickFile() {
  fileEl.value?.click()
}

function onFilePick(ev: Event) {
  const input = ev.target as HTMLInputElement
  const fs = Array.from(input.files || [])
  input.value = ''
  fs.forEach(addAttachment)
}

function downscale(file: File, max: number, q: number) {
  return new Promise<string | null>((resolve) => {
    const img = new Image()
    img.onload = () => {
      const s = Math.min(1, max / Math.max(img.width, img.height))
      const c = document.createElement('canvas')
      c.width = Math.round(img.width * s)
      c.height = Math.round(img.height * s)
      c.getContext('2d')?.drawImage(img, 0, 0, c.width, c.height)
      try {
        resolve(c.toDataURL('image/jpeg', q))
      } catch {
        resolve(null)
      }
    }
    img.onerror = () => resolve(null)
    img.src = URL.createObjectURL(file)
  })
}

function addAttachment(f: File) {
  const id = Math.random().toString(36).slice(2)
  const isImg = /^image\//.test(f.type || '')
  const item: Att = { id, name: f.name, size: f.size, isImg, preview: null, path: null, thumbUrl: null }
  if (isImg) item.preview = URL.createObjectURL(f)
  if (f.size > 60 * 1024 * 1024) {
    item.error = true
    item.errMsg = '超过 60MB 上限'
    atts.value.push(item)
    return
  }
  atts.value.push(item)

  const up = (body: Blob | File, ctype: string) =>
    new Promise<any>((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open('POST', API + 'upload?name=' + encodeURIComponent(f.name) + '&kind=' + (isImg ? 'image' : 'file'))
      const a = authB64()
      if (a) xhr.setRequestHeader('Authorization', 'Basic ' + a)
      xhr.setRequestHeader('Content-Type', ctype || 'application/octet-stream')
      xhr.upload.onprogress = (e) => {
        if (!e.lengthComputable) return
        item.progress = Math.min(99, Math.round((e.loaded / e.total) * 100))
      }
      xhr.onload = () => {
        item.progress = null
        try {
          resolve(JSON.parse(xhr.responseText || '{}'))
        } catch (e) {
          reject(e)
        }
      }
      xhr.onerror = () => {
        item.progress = null
        reject(new Error('upload failed'))
      }
      xhr.send(body)
    })

  const imgP = isImg ? downscale(f, 1600, 0.82) : Promise.resolve(null)
  Promise.all([imgP, up(f, f.type || 'application/octet-stream')])
    .then(([dataUrl, res]) => {
      item.dataUrl = dataUrl
      if (res && res.ok) {
        item.path = res.path
        item.saved = res.name
        item.thumbUrl = res.url ? '/hermes/' + String(res.url).replace(/^\/+/, '') : null
      } else {
        item.error = true
      }
    })
    .catch(() => (item.error = true))
}

/**
 * 输入框里直接粘贴：截图 / 复制的图片 / 资源管理器里复制的文件，
 * 都按「点加号选文件」那条路走（同一个上传 + 缩略图流程）。
 */
function onPaste(e: ClipboardEvent) {
  const dt = e.clipboardData
  if (!dt) return
  const files: File[] = []
  for (const it of Array.from(dt.items || [])) {
    if (it.kind !== 'file') continue
    const f = it.getAsFile()
    if (!f) continue
    // 粘贴的截图常常没有像样的文件名，按时间补一个
    if (!f.name || f.name === 'blob') {
      const ext = (f.type.split('/')[1] || 'png').replace('jpeg', 'jpg')
      const stamp = new Date().toISOString().slice(11, 19).replace(/:/g, '')
      files.push(new File([f], '粘贴_' + stamp + '.' + ext, { type: f.type }))
    } else {
      files.push(f)
    }
  }
  if (!files.length) return          // 纯文字粘贴：交给浏览器默认行为
  e.preventDefault()
  const room = 8 - atts.value.length
  files.slice(0, Math.max(0, room)).forEach((f) => addAttachment(f))
  if (files.length > room) sysMsg('一次最多 8 个附件，多的这次没加上。')
  autoGrow()
}

function removeAtt(id: string) {
  atts.value = atts.value.filter((a) => a.id !== id)
}

function attState(a: Att) {
  return a.error ? ' · ' + (a.errMsg || '失败') : a.progress != null ? ' · ' + a.progress + '%' : a.path ? ' · 已存' : ' · 上传中'
}

/* ---------- 审批 ---------- */
const AP_LABEL: Record<string, string> = {
  once: '允许一次',
  session: '本会话都允许',
  always: '以后都允许',
  deny: '拒绝',
}

function apButtons(ap: Approval) {
  return ap.choices && ap.choices.length ? ap.choices : ['once', 'deny']
}

async function answerApproval(choice: string) {
  let m: Msg | null = null
  for (let i = messages.value.length - 1; i >= 0; i--) {
    const x = messages.value[i]
    if (x.approval && !x.approval.choice) {
      m = x
      break
    }
  }
  if (!m || !m.approval) return
  const ap = m.approval
  ap.error = null
  ap.pending = choice
  try {
    const r = await api('approval', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ run_id: ap.run_id, request_id: ap.request_id, choice }),
    })
    if (r.ok) ap.choice = choice
    else {
      const t = await r.text()
      throw new Error('HTTP ' + r.status + ' ' + (t || '').slice(0, 120))
    }
  } catch (e: any) {
    ap.error = e?.message || String(e)
  } finally {
    ap.pending = null
    save()
  }
}

/* ---------- 斜杠命令 ---------- */
const CMDS: Record<string, string> = {
  '/new': '新对话，清空当前记录',
  '/stop': '停掉正在跑的这一轮',
  '/retry': '重发上一条消息',
  '/status': '看当前会话状态',
  '/help': '看这个命令列表',
}

function sysMsg(text: string) {
  messages.value.push({ role: 'system', text })
  save()
  decorate()
}

function lastUserText() {
  for (let i = messages.value.length - 1; i >= 0; i--) {
    if (messages.value[i].role === 'user') return messages.value[i].text || ''
  }
  return ''
}

function runCommand(raw: string) {
  const c = String(raw || '').trim().toLowerCase()
  if (!CMDS[c]) return false
  if (c === '/new') {
    messages.value = []
    prevId.value = null
    since.value = Math.floor(Date.now() / 1000)
    atts.value = []
    saveLocal()
    decorate()
    // 清空对所有 web 端生效
    void api('log/clear', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    }).then(async (r) => {
      if (r.ok) applyCursor(await r.json())
    })
    return true
  }
  if (c === '/stop') {
    if (busy.value) {
      stop()
      sysMsg('已发出停止。')
    } else sysMsg('现在没有在跑的任务。')
    return true
  }
  if (c === '/retry') {
    const t = lastUserText()
    if (!t) {
      sysMsg('还没有发过消息。')
      return true
    }
    if (busy.value) {
      sysMsg('上一轮还在跑，先 /stop 再 /retry。')
      return true
    }
    draft.value = t
    send()
    return true
  }
  if (c === '/status') {
    let done = 0
    let steps = 0
    messages.value.forEach((m) => {
      if (m.role !== 'user' && m.role !== 'system') {
        steps += (m.steps || []).length
        if (m.elapsed) done++
      }
    })
    sysMsg(
      `消息 ${messages.value.length} 条 · 回答 ${done} 条 · 工具步骤 ${steps} 个\n` +
        `当前${busy.value ? '在跑（可以 /stop）' : '空闲'}\n` +
        `多轮续接：${prevId.value ? '开' : '关'}\n记在这台设备的 localStorage 里，换设备看不到`,
    )
    return true
  }
  if (c === '/help') {
    sysMsg(
      '可用命令：\n' +
        Object.keys(CMDS)
          .map((k) => `${k} — ${CMDS[k]}`)
          .join('\n') +
        '\n（以 / 开头但不是命令的文字照常发给助手）',
    )
    return true
  }
  return false
}

/* ---------- 通知 ---------- */
function askNotifyPermission() {
  try {
    if (!('Notification' in window)) return
    if (Notification.permission === 'default') Notification.requestPermission()
  } catch {}
}

function notifyDone(ai: Msg) {
  try {
    if (!document.hidden) return
    if (!('Notification' in window) || Notification.permission !== 'granted') return
    const body = (ai.text || '').replace(/\s+/g, ' ').trim().slice(0, 80) || '回云匣看结果'
    new Notification('云匣 · 回答好了', { body, tag: 'yunxia-chat' })
  } catch {}
}

/* ---------- 发送 ---------- */
function stop() {
  const rid = live?.id
  if (rid) api('cancel?id=' + encodeURIComponent(rid)).catch(() => {})
  abortCtl?.abort()
}

/* 当前正在流式的那条回答；发新消息时要把它掐掉换成「已中断」 */
let curAi: Msg | null = null
let killed: Msg | null = null

/**
 * 像 TG 一样：没有暂停按钮，直接发下一条就打断上一轮。
 * 被打断的那条留在原地、标成「已中断」，正在跑的后端连接一起关掉（不再烧 token）。
 */
function interrupt() {
  if (!busy.value) return
  const rid = live?.id
  if (rid) api('cancel?id=' + encodeURIComponent(rid)).catch(() => {})
  abortCtl?.abort()
  const ai = curAi
  if (ai) {
    killed = ai
    ai.wait = false
    ai.status = 'interrupted'
    ;(ai.steps || []).forEach((s) => (s.run = false))
    if (!(ai.text || '').trim()) ai.text = '（已中断）'
    // 和 WSL 终端一模一样的一句提示（agent/i18n: cli.chat.new_message_interrupting）
    sysMsg('⚡ 检测到新消息，正在中断...')
    if (!ai.elapsed && ai.ts) ai.elapsed = Math.max(1, Math.round((Date.now() - ai.ts) / 1000))
  }
  busy.value = false
  abortCtl = null
  stopTick()
  live = null
  curAi = null
  save()
  decorate()
}

function startTick() {
  clearInterval(ticker)
  ticker = window.setInterval(() => (tick.value = Date.now()), 1000)
}

function stopTick() {
  clearInterval(ticker)
  ticker = undefined
}

function stepRunText(s: Step) {
  if (!s.run) return s.dur ? Number(s.dur).toFixed(1) + 's' : ''
  void tick.value
  const sec = s.t0 ? Math.max(0, Math.round((Date.now() - s.t0) / 1000)) : 0
  return `运行中 ${sec}s`
}

function findStep(ai: Msg, call?: string) {
  const steps = ai.steps || []
  if (call) {
    for (let i = steps.length - 1; i >= 0; i--) if (steps[i].call === call) return steps[i]
    return null
  }
  for (let i = steps.length - 1; i >= 0; i--) if (steps[i].run) return steps[i]
  return null
}

function handle(ev: any, ai: Msg) {
  const t = ev.type || ''
  // 别一有事件就撤掉「正在输入」：只有真出字、结束或报错时才收
  if (/output_text\.delta|reasoning_summary_text\.delta|response\.completed|response\.failed|^error$/.test(t)) {
    ai.wait = false
  }
  if (t === 'response.created') {
    const rid0 = ev.response?.id || ev.id || ''
    if (rid0) {
      live = { id: rid0 }
      ai.rid = rid0
    }
  } else if (t === 'response.output_text.delta') {
    const d = ev.delta || ''
    ai.text += ai.text ? d : d.replace(/^\s+/, '')
  } else if (t === 'response.reasoning_summary_text.delta') {
    ai.think = (ai.think || '') + (ev.delta || '')
  } else if (t === 'response.output_item.added' || t === 'response.output_item.done') {
    const it = ev.item || {}
    if (it.type === 'function_call') {
      let st = findStep(ai, it.call_id)
      if (!st) {
        st = { name: it.name || 'tool', arg: shortArg(it.arguments), run: true, call: it.call_id, t0: Date.now() }
        ai.steps!.push(st)
      } else if (!st.arg) st.arg = shortArg(it.arguments)
    } else if (it.type === 'function_call_output') {
      let st = findStep(ai, it.call_id)
      if (!st) {
        st = { name: 'tool', arg: '', run: true, call: it.call_id, t0: Date.now() }
        ai.steps!.push(st)
      }
      const o = outOf(it)
      st.out = o.text
      st.bad = o.bad
      st.run = false
      st.dur = st.t0 ? Math.max(0.1, (Date.now() - st.t0) / 1000) : null
    }
  } else if (t === 'approval.request') {
    ai.approval = {
      run_id: ev.run_id || '',
      request_id: ev.request_id || '',
      command: ev.command || '',
      description: ev.description || '',
      choices: ev.choices && ev.choices.length ? ev.choices : ['once', 'session', 'deny'],
      choice: null,
      error: null,
    }
    ai.wait = false
  } else if (t === 'response.completed') {
    ;(ai.steps || []).forEach((s) => (s.run = false))
    // 有的回复只发 completed、不发 delta：不兜底的话气泡只剩「思考过程」，正文永远空着
    if (!(ai.text || '').trim() && Array.isArray(ev.response?.output)) {
      const buf: string[] = []
      for (const item of ev.response.output) {
        for (const seg of item?.content || []) {
          if (seg?.type === 'output_text' && seg.text) buf.push(seg.text)
        }
      }
      if (buf.length) {
        ai.text = buf.join('')
        decorate()
      }
    }
    if (ev.response?.id) {
      // 这一轮本身就是「上下文坏了」的报错：它的 id 也不能当下一次的上下文，
      // 否则永远在坏链上打转（表现就是每条都回 Invalid base64）。
      if (/Invalid base64 data|rejected this request as malformed/i.test(ai.text || '')) {
        ctxReset = true
        prevId.value = ''
      } else {
        prevId.value = ev.response.id
        if (ctxReset) ctxReset = false
      }
      save()
    }
  } else if (t === 'response.failed') {
    const err = ev.response?.error || ev.error || {}
    ai.text += (ai.text ? '\n' : '') + '⚠️ ' + (err.message || JSON.stringify(err))
    ;(ai.steps || []).forEach((s) => (s.run = false))
  }
}

async function pollRun(ai: Msg, rid: string, tries: number): Promise<boolean> {
  const r = await api('runs?limit=30', { cache: 'no-store' })
  const d = await r.json()
  const run = (d.runs || []).filter((x: any) => x.id === rid)[0]
  if (run) {
    if (run.text) ai.text = run.text
    if (run.think) ai.think = run.think
    ai.rid = rid
    if (run.done) return true
  }
  if (tries <= 0) return !!(run && run.text)
  await new Promise((res) => setTimeout(res, 4000))
  return pollRun(ai, rid, tries - 1)
}

/* 打开页面/切回前台：把后端跑完但没送到这里的回答补进来 */
async function syncRuns() {
  try {
    const r = await api('runs?limit=20', { cache: 'no-store' })
    const d = await r.json()
    const floor = since.value || 0
    const runs = (d.runs || [])
      .filter((x: any) => !floor || (x.ts || 0) > floor)
      .sort((a: any, b: any) => a.ts - b.ts)
    const known: Record<string, boolean> = {}
    const texts: Record<string, boolean> = {}
    let pending = 0
    messages.value.forEach((m) => {
      if (m.rid) known[m.rid] = true
      if (m.role !== 'user' && m.text) texts[String(m.text).replace(/\s+/g, ' ').trim()] = true
    })
    const byRid: Record<string, Msg> = {}
    messages.value.forEach((m) => {
      if (m.rid) byRid[m.rid] = m
    })
    let added = 0
    let touched = 0
    runs.forEach((run: any) => {
      if (!run.text && !run.think) return
      const key = String(run.text || '').replace(/\s+/g, ' ').trim()
      const m = byRid[run.id]
      if (m) {
        if (run.text && m.text !== run.text) {
          m.text = run.text
          touched++
        }
        if (run.think && m.think !== run.think) {
          m.think = run.think
          touched++
        }
        const w = !run.done
        if (!!m.wait !== w) {
          m.wait = w
          touched++
        }
        if (!run.done) pending++
        return
      }
      if (known[run.id]) return
      if (key && texts[key]) return
      const msg: Msg = {
        role: 'assistant',
        ts: (run.ts || 0) * 1000 || Date.now(),
        text: run.text || '',
        think: run.think || '',
        rid: run.id,
        steps: [],
      }
      if (!run.done) msg.wait = true
      messages.value.push(msg)
      if (key) texts[key] = true
      added++
      if (!run.done) pending++
    })
    if (added || touched) {
      save()
      decorate()
      scrollDown(added > 0)
    }
    if (pending) {
      clearTimeout(syncTimer)
      syncTimer = window.setTimeout(syncRuns, 8000)
    }
  } catch (e) {
    console.warn('syncRuns failed', e)
  }
}

/* ---------- 多端同步 ----------
   所有 web 端（手机浏览器、电脑浏览器、外网域名）共用 PC 上这一份对话；
   App 那边是不同的东西，各终端自己存自己的，不在这里。          */
const SINCE_KEY = 'mfm.chat.since'
let syncCursor = 0
let pushTimer: number | undefined
let logTimer: number | undefined

function uid(): string {
  try {
    return crypto.randomUUID()
  } catch {
    return 'm' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  }
}

function ensureIds() {
  for (const m of messages.value) if (!m.id) m.id = uid()
}

function toWire(m: Msg) {
  return {
    id: m.id,
    ts: Math.floor((m.ts || Date.now()) / 1000),
    role: m.role,
    text: m.text || '',
    think: m.think || '',
    steps: m.steps || [],
    rid: m.rid || '',
  }
}

function applyCursor(j: any) {
  if (j && typeof j.cursor === 'number') {
    syncCursor = j.cursor
    try {
      localStorage.setItem(SINCE_KEY, String(syncCursor))
    } catch {}
  }
}

async function pushLog() {
  if (!authB64()) return
  ensureIds()
  const out = messages.value.filter((m) => !m.sent && !m.wait)
  if (!out.length) return
  try {
    const r = await api('log', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: 'web', msgs: out.map(toWire), since: syncCursor }),
    })
    if (!r.ok) return
    const j = await r.json()
    for (const m of out) m.sent = true
    applyCursor(j)
    saveLocal()
  } catch (e) {
    console.warn('pushLog failed', e)
  }
}

function applyOps(ops: any[]): boolean {
  let touched = false
  for (const op of ops || []) {
    if (op.kind === 'clear') {
      messages.value = []
      touched = true
      continue
    }
    if (op.kind === 'del') {
      const n = messages.value.length
      messages.value = messages.value.filter((m) => m.id !== op.id)
      if (messages.value.length !== n) touched = true
      continue
    }
    if ((op.kind !== 'add' && op.kind !== 'upd') || !op.msg) continue
    const m = op.msg
    const cur = messages.value.find((x) => x.id === m.id)
    if (cur) {
      cur.sent = true
      if (cur.wait) {
        // SSE 中途漏了 delta（断了/被取消）：本地正文空着，但服务端已经写好答案了，
        // 这时不能因为 wait=true 就整条跳过，否则气泡只剩思考过程。
        if (!(cur.text || '').trim() && (m.text || '').trim()) {
          cur.text = m.text
          cur.think = cur.think || m.think || ''
          if ((m.steps || []).length) cur.steps = m.steps
          cur.status = m.status || cur.status
          touched = true
        }
        continue
      }
      const st = m.status || 'done'
      if (
        cur.text !== m.text ||
        (cur.think || '') !== (m.think || '') ||
        cur.status !== st
      ) {
        cur.text = m.text
        cur.think = m.think || ''
        // 服务端还没落步骤（旧一轮 / 刚升级）时保留本地已有的终端过程
        if ((m.steps || []).length || !(cur.steps || []).length) cur.steps = m.steps || []
        cur.status = st
        if (m.rid) cur.rid = m.rid
        touched = true
      }
    } else {
      // 本地那条还没推到服务端时，id 可能和运行结束后的 run id 对不上
      // （占位用的是 uid，服务端记的是 rXXXX）：不当成新消息，直接认领过来。
      const tsMs = (m.ts || 0) * 1000
      const twin = messages.value.find(
        (x) =>
          !x.sent &&
          x.role === (m.role || 'assistant') &&
          (x.text || '').trim() === (m.text || '').trim() &&
          Math.abs((x.ts || 0) - tsMs) <= 5000,
      )
      if (twin) {
        twin.id = m.id
        twin.rid = m.rid || twin.rid
        twin.status = m.status || twin.status
        twin.sent = true
        if ((m.steps || []).length) twin.steps = m.steps
        touched = true
        continue
      }
      messages.value.push({
        id: m.id,
        role: m.role,
        ts: tsMs,
        text: m.text || '',
        think: m.think || '',
        steps: m.steps || [],
        rid: m.rid || '',
        status: m.status || 'done',
        sent: true,
      })
      touched = true
    }
  }
  if (touched) {
    messages.value.sort((a, b) => (a.ts || 0) - (b.ts || 0))
    const lastRid = [...messages.value]
      .reverse()
      .find(
        (m) =>
          m.rid &&
          !/Invalid base64 data|rejected this request as malformed/i.test(m.text || ''),
      )?.rid
    // ctxReset：上一段上下文里有坏数据，别再把它捡回来当上下文
    if (lastRid && !ctxReset) prevId.value = lastRid
    saveLocal()
    decorate()
    scrollDown(false)
  }
  return touched
}

async function pullLog() {
  if (!authB64()) return
  try {
    const r = await api(`log?since=${syncCursor}`)
    if (!r.ok) return
    const j = await r.json()
    const ops = j.ops || []
    if (!ops.length) return
    if (!applyOps(ops)) decorate()
    applyCursor(j)
  } catch (e) {
    console.warn('pullLog failed', e)
  }
}

/** 第一次进来：库里没有就把本地历史搬上去；库里有了就以库为准 */
async function bootLog() {
  if (!authB64()) {
    // 新设备 / 清了缓存进来：以前是一片空白，用户不知道是「没消息」还是「没口令」
    if (!messages.value.length) {
      sysMsg('这台设备还没填对话口令 —— 去「设置」点一下口令卡片，历史消息和发送都会通。')
    }
    return
  }
  try {
    const r = await api('log?since=0')
    if (!r.ok) return
    const j = await r.json()
    syncCursor = 0
    if (!j.ops || !j.ops.length) {
      ensureIds()
      await pushLog()
      return
    }
    applyOps(j.ops)
    applyCursor(j)
  } catch (e) {
    console.warn('bootLog failed', e)
  }
}

async function send() {
  // 以前这里有一句 `if (busy.value) return`：上一轮在跑时点发送/回车完全没反应，
  // 用户看到的就是「不能继续发送」。终端那边是「发新消息 = 打断当前这轮」，这里照做。
  if (!authB64()) {
    // 口令统一在设置那张大卡片里填，这里只负责把它叫出来
    window.dispatchEvent(new Event('yunxia:pwd'))
    sysMsg('先在「设置」一点那张卡片填口令，再发消息。')
    return
  }
  const text = draft.value.trim()
  const list = atts.value.slice()
  if (!text && !list.length) return
  // 上一轮还在跑：不拦着用户（TG 就是这么做的），先把它打断再发新的
  if (busy.value) interrupt()
  if (text.charAt(0) === '/' && runCommand(text)) {
    draft.value = ''
    autoGrow()
    return
  }
  askNotifyPermission()

  const userMsg: Msg = {
    role: 'user',
    ts: Date.now(),
    text,
    imgs: list.filter((a) => a.isImg).map((a) => a.thumbUrl || a.preview).filter(Boolean) as string[],
    files: list.filter((a) => !a.isImg).map((a) => ({ name: a.saved || a.name, size: humanSize(a.size), path: a.path || '' })),
  }
  messages.value.push(userMsg)
  draft.value = ''
  autoGrow()
  atts.value = []

  const ai: Msg = { role: 'assistant', ts: Date.now(), text: '', steps: [], think: '', wait: true }
  messages.value.push(ai)
  curAi = ai
  save()
  decorate()
  scrollDown(true)

  const content: any[] = []
  if (text) content.push({ type: 'input_text', text })
  list.forEach((a) => {
    if (a.isImg && a.dataUrl) content.push({ type: 'input_image', image_url: a.dataUrl })
  })
  const lines = list
    .filter((a) => a.path)
    .map((a) => `（附件已保存到服务器：${a.path}，文件名 ${a.name}，${humanSize(a.size)}）`)
  if (lines.length) content.push({ type: 'input_text', text: lines.join('\n') + '\n需要时你可以直接读取这些路径。' })
  // 用户定的规矩：云匣对话产生的文件只放在 /mnt/g/hermes/云匣文件/<日期>/
  content.push({
    type: 'input_text',
    text: '【文件存放规矩】这次对话里你要给我的任何文件（图片、音频、视频、文档、安装包），一律直接写到 /mnt/g/hermes/云匣文件/<今天日期>/ 下面再用完整路径告诉我；不要放进 ~/.hermes/audio_cache、image_cache 等缓存目录，也不要复制副本。',
  })
  if (!content.length) content.push({ type: 'input_text', text: '（空消息）' })

/** 把一轮 SSE 喂进气泡；断线/失败由外层 catch 处理 */
async function consume(resp: Response, ai: Msg) {
  if (!resp.ok || !resp.body) throw new Error('HTTP ' + resp.status)
  // 服务端托管这一轮：拿它给的 run id 当这条消息的全局 id，
  // 之后无论是本页流式、还是别的设备/重开页面轮询，都是同一条。
  const runId = resp.headers.get('X-Run-Id') || ''
  if (runId) {
    ai.id = runId
    ai.sent = true
    ai.status = 'running'
  }
  const reader = resp.body.getReader()
  const dec = new TextDecoder()
  let buf = ''
  for (;;) {
    const r = await reader.read()
    if (r.done) break
    buf += dec.decode(r.value, { stream: true })
    const blocks = buf.split('\n\n')
    buf = blocks.pop() || ''
    blocks.forEach((b) => {
      const line = b.split('\n').filter((l) => l.indexOf('data:') === 0)[0]
      if (!line) return
      const raw = line.slice(5).trim()
      if (!raw || raw === '[DONE]') return
      let ev: any
      try {
        ev = JSON.parse(raw)
      } catch {
        return
      }
      handle(ev, ai)
    })
    decorate()
    scrollDown()
  }
}

  busy.value = true
  startTick()
  const t0 = Date.now()
  abortCtl = new AbortController()

  const postChat = (prev: string) =>
    api('chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ input: content, previous_response_id: prev }),
      signal: abortCtl!.signal,
    })

  const usedPrev = !!prevId.value
  let healed = false
  /** 网关把上游 400 当成正文吐回来，只能从文字上认 */
  const badCtx = () => /Invalid base64 data|rejected this request as malformed/i.test(ai.text || '')

  postChat(prevId.value || '')
    .then(async (resp) => {
      if (resp.ok) {
        await consume(resp, ai)
        // 上下文里有一条损坏的图片数据：整条 previous_response_id 链都会失败。
        // 丢掉上下文自动重发一次，用户不用自己 /new。
        if (badCtx() && usedPrev && !healed) {
          healed = true
          ai.text = ''
          ai.think = ''
          ai.steps = []
          ai.wait = true
          ai.status = 'running'
          prevId.value = ''
          ctxReset = true
          save()
          sysMsg('上一段上下文里有损坏的图片数据，已自动换一段新上下文重发（历史消息还在）。')
          decorate()
          await consume(await postChat(''), ai)
        }
        return
      }
      // 400 + 坏 base64：网关那侧的会话历史里有损坏的图片数据，
      // 整条 previous_response_id 链都会 400。别让用户自己 /new：
      // 丢掉上下文重发一次（历史气泡都还在，只是不再当上下文）。
      const detail = await resp.text().catch(() => '')
      if (resp.status === 400 && /base64|messages\[/i.test(detail) && prevId.value) {
        prevId.value = ''
        ctxReset = true
        save()
        sysMsg('上一段上下文里有损坏的图片数据，已自动换一段新上下文重发（历史消息还在）。')
        const r2 = await postChat('')
        return consume(r2, ai)
      }
      throw new Error('HTTP ' + resp.status + (detail ? ' ' + detail.slice(0, 200) : ''))
    })
    .catch(async (e: any) => {
      if (e?.name === 'AbortError') {
        if (killed === ai) {
          // 这条是「发新消息打断的」：状态已经在 interrupt() 里标好，别覆盖
          killed = null
          decorate()
          return
        }
        ai.status = 'interrupted'
        ai.wait = false
        if (!ai.text) ai.text = '（已中断）'
        save()
        decorate()
        return
      }
      const rid = live?.id
      if (!rid) {
        ai.text += (ai.text ? '\n' : '') + '⚠️ ' + errText(e)
        decorate()
        return
      }
      ai.text += (ai.text ? '\n' : '') + '⚠️ 连接断了，正在补齐这一轮…'
      decorate()
      try {
        const ok = await pollRun(ai, rid, 60)
        ai.text = ai.text.replace(/\n?⚠️ 连接断了[^\n]*/, '')
        decorate()
        if (!ok) {
          ai.text += '\n（这一轮还没跑完，稍等刷新页面会自动补上）'
          decorate()
        }
      } catch {
        ai.text += '\n（刷新页面会自动补上这一轮）'
        decorate()
      }
    })
    .then(() => {
      // 被打断的旧一轮也会走到这里：别把新一轮的忙碌状态/句柄清掉
      if (curAi !== ai) {
        ai.wait = false
        return
      }
      busy.value = false
      abortCtl = null
      stopTick()
      curAi = null
      ai.status = 'done'
      ai.wait = false
      ;(ai.steps || []).forEach((s) => (s.run = false))
      ai.elapsed = Math.max(1, Math.round((Date.now() - t0) / 1000))
      save()
      decorate()
      notifyDone(ai)
    })
}

/* ---------- 长按消息 ---------- */
let lpTimer: number | undefined
let lpStart = { x: 0, y: 0 }
let lpMoved = false

function msgDown(e: PointerEvent, idx: number) {
  const el = e.target as HTMLElement
  if (el.closest('a,button')) return
  lpMoved = false
  lpStart = { x: e.clientX, y: e.clientY }
  clearTimeout(lpTimer)
  lpTimer = window.setTimeout(() => {
    if (!lpMoved) openSheet(idx)
  }, 480)
}

function onLogPointerDown(e: PointerEvent) {
  const el = (e.target as HTMLElement).closest('.cx-msg') as HTMLElement | null
  if (!el || !logEl.value) return
  const all = Array.from(logEl.value.querySelectorAll('.cx-msg'))
  msgDown(e, all.indexOf(el))
}

function msgMove(e: PointerEvent) {
  if (Math.abs(e.clientX - lpStart.x) > 8 || Math.abs(e.clientY - lpStart.y) > 8) {
    lpMoved = true
    clearTimeout(lpTimer)
  }
}

function msgUp() {
  clearTimeout(lpTimer)
}

function openSheet(idx: number) {
  sheetIdx.value = idx
  sheetOpen.value = true
}

function sheetActions(m: Msg) {
  const acts: { k: string; t: string; cls?: string }[] = [{ k: 'copy', t: '复制文字' }]
  if (m.role === 'user' && m.text) acts.push({ k: 'resend', t: '重新发送' })
  acts.push({ k: 'del', t: '删除这条', cls: 'danger' })
  return acts
}

function sheetDo(k: string) {
  const m = messages.value[sheetIdx.value]
  sheetOpen.value = false
  if (!m) return
  if (k === 'copy') copyText(m.text || '')
  else if (k === 'resend') {
    draft.value = m.text || ''
    send()
  } else if (k === 'del') {
    const gone = messages.value[sheetIdx.value]
    messages.value.splice(sheetIdx.value, 1)
    save()
    decorate()
    // 只删本地没用：服务端账本里还在，2.5 秒后一同步就又回来了
    if (gone?.id) {
      api('log/del', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: [gone.id] }),
      }).catch(() => {})
    }
  }
}

/* ---------- 输入框 ---------- */
function autoGrow() {
  const el = inputEl.value
  if (!el) return
  el.style.height = 'auto'
  el.style.height = Math.min(el.scrollHeight, 104) + 'px'
}

function onKey(e: KeyboardEvent) {
  if (e.key === 'Enter' && !e.shiftKey && !(e as any).isComposing) {
    e.preventDefault()
    // 这里以前有 `if (busy.value) return`：上一轮在跑时回车直接没反应，
    // 用户看到的就是「不能继续发送」。现在照 TG 的做法，回车就把上一轮打断再发。
    send()
  }
}

/* 点日志区：下载链接 / 图片放大 / 审批按钮 */
function onLogClick(e: MouseEvent) {
  const t = e.target as HTMLElement
  const dl = t.closest('a.cx-dl, a.cx-file.dl') as HTMLAnchorElement | null
  if (dl) {
    e.preventDefault()
    saveViaAuth(dl.getAttribute('href') || '')
    return
  }
  const img = t.closest('.cx-imgs img, img.cx-mi') as HTMLImageElement | null
  if (img) {
    e.preventDefault()
    openViewerAt(img)
    return
  }
  const al = t.closest('a.cx-a') as HTMLAnchorElement | null
  if (al) {
    const href = al.getAttribute('href') || ''
    if (/\.(zip|rar|7z|pdf|docx?|xlsx?|pptx?|txt|csv|json|apk|epub|srt|ass|mp4|mkv|mp3|flac|png|jpe?g|webp|gif)$/i.test(href.split('?')[0])) {
      e.preventDefault()
      saveViaAuth(href, false)
      return
    }
  }
  const ap = t.closest('[data-ap]') as HTMLElement | null
  if (ap) answerApproval(ap.getAttribute('data-ap') || '')
}

/* ---------- 看图：直接用文件页那套 ImageViewer ---------- */
const vwOpen = ref(false)
const vwKey = ref(0)
const vwIdx = ref(0)
const vwEntries = ref<any[]>([])
const vwSrcs = ref<string[]>([])

async function openViewerAt(el: HTMLImageElement) {
  const box: ParentNode = el.closest('.cx-msg') || document
  const imgs = [...box.querySelectorAll<HTMLImageElement>('img.cx-mi, .cx-imgs img')]
  const raw = imgs
    .map((i) => ({
      full: i.getAttribute('data-full') || '',
      thumb: i.getAttribute('src') || '',
      name: i.getAttribute('alt') || i.getAttribute('title') || '图片',
    }))
    .filter((x) => x.full || x.thumb)
  if (!raw.length) return
  const k = Math.max(0, imgs.indexOf(el))
  vwEntries.value = raw.map((x) => ({
    name: x.name,
    path: x.name,
    is_dir: false,
    size: 0,
    mtime: 0,
    kind: 'image',
    ext: (x.name.split('.').pop() || '').toLowerCase(),
  }))
  // 先用缩略图顶上，原图在后台换成 blob（<img> 带不了 Basic 头）
  vwSrcs.value = raw.map((x) => x.thumb)
  vwIdx.value = Math.min(k, raw.length - 1)
  vwOpen.value = true

  const fullAt = async (j: number) => {
    const u = await fullBlob(raw[j].full)
    if (!u) return false
    const arr = [...vwSrcs.value]
    arr[j] = u
    vwSrcs.value = arr
    return true
  }
  if (await fullAt(k)) vwKey.value++
  for (let j = 0; j < raw.length; j++) {
    if (j === k) continue
    void fullAt(j)
  }
}

/** 原图要口令，先取 blob；同一张只取一次 */
const fullCache = new Map<string, string>()

async function fullBlob(url: string) {
  if (!url) return ''
  if (!url.includes('/hermes/api/')) return url
  const hit = fullCache.get(url)
  if (hit) return hit
  const auth = authB64()
  try {
    const r = await fetch(url, { headers: auth ? { Authorization: 'Basic ' + auth } : {} })
    if (!r.ok) return ''
    const u = URL.createObjectURL(await r.blob())
    fullCache.set(url, u)
    return u
  } catch {
    return ''
  }
}

/* 直接点 <a href="/hermes/api/dl"> 不会带 Basic 头 → 401，所以带鉴权取 blob 再存 */
async function saveViaAuth(href: string, withAuth = true) {
  const auth = withAuth ? authB64() : ''
  const m = /[?&]path=([^&]*)/.exec(href || '')
  let name = m ? decodeURIComponent(m[1]).split('/').pop() || 'download' : 'download'
  const sys: Msg = { role: 'system', text: '开始下载 ' + name + '…' }
  messages.value.push(sys)
  decorate()
  try {
    const r = await fetch(href, {
      headers: auth ? { Authorization: 'Basic ' + auth } : {},
      cache: 'no-store',
    })
    if (!r.ok) throw new Error(r.status === 401 ? '口令过期了，请重新解锁' : 'HTTP ' + r.status)
    const cd = r.headers.get('content-disposition') || ''
    const mm = /filename\*=UTF-8''([^;]+)/.exec(cd)
    if (mm) {
      try {
        name = decodeURIComponent(mm[1])
      } catch {}
    }
    const b = await r.blob()
    const u = URL.createObjectURL(b)
    const a = document.createElement('a')
    a.href = u
    a.download = name
    a.rel = 'noopener'
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(u), 8000)
    sys.text = `已开始保存 ${name}（${humanSize(b.size)}）`
  } catch (err: any) {
    sys.text = '下载失败：' + (err?.message || err)
  }
  save()
  decorate()
}

/* ---------- 版式：贴在导航与屏幕之间（照旧前端的 layout()） ---------- */
function layout() {
  const rail = document.querySelector('.rail') as HTMLElement | null
  const vh = window.innerHeight
  const vv = (window as any).visualViewport
  const kb = vv ? Math.max(0, Math.round(vh - vv.height - (vv.offsetTop || 0))) : 0
  let left = 0
  let bottom = kb
  let width = window.innerWidth
  if (rail) {
    const r = rail.getBoundingClientRect()
    if (r.top > vh * 0.5) bottom = Math.max(kb, Math.round(vh - r.top))
    else {
      left = Math.round(r.right)
      width = Math.max(0, Math.round(window.innerWidth - left))
    }
  }
  boxes.value = { left, width, bottom }
}

// 只给 left/right，宽度让浏览器自己算：任何一个 resize 事件漏掉都不会留下旧宽度
const boxStyle = computed(() => ({
  left: boxes.value.left + 'px',
  right: '0px',
  top: '0px',
  bottom: boxes.value.bottom + 'px',
}))

function onVis() {
  void pullLog()
  if (!document.hidden && authB64()) syncRuns()
}

/* ---------- 生命周期 ---------- */
onMounted(() => {
  load()
  void bootLog()
  logTimer = window.setInterval(() => {
    if (document.visibilityState === 'visible') void pullLog()
  }, 3000)
  layout()
  decorate().then(() => scrollDown(true))
  setTimeout(layout, 200)
  setTimeout(layout, 600)
  window.addEventListener('resize', layout)
  ;(window as any).visualViewport?.addEventListener('resize', layout)
  document.addEventListener('visibilitychange', onVis)
  setTimeout(() => {
    if (authB64()) syncRuns()
  }, 700)
  /* 没有口令也能看记录，发送时才提示去设置填 */
})

onUnmounted(() => {
  window.removeEventListener('resize', layout)
  ;(window as any).visualViewport?.removeEventListener('resize', layout)
  document.removeEventListener('visibilitychange', onVis)
  clearInterval(ticker)
  clearTimeout(syncTimer)
  clearInterval(logTimer)
  clearTimeout(pushTimer)
})
</script>

<template>
  <div class="cx" :style="boxStyle">
    <div
      ref="logEl"
      class="cx-log"
      @scroll.passive="onLogScroll"
      @click="onLogClick"
      @pointerdown="onLogPointerDown"
      @pointermove="msgMove"
      @pointerup="msgUp"
      @pointercancel="msgUp"
      @contextmenu.prevent
    >
      <div v-if="!messages.length" class="cx-intro">
        <b>在云匣里直接说话</b>
        发文字、照片、文件都行<br />命令和文件操作都在这台机器上真跑<br />
        <span style="opacity: 0.75">照片我会直接看，文件会存到服务器</span>
      </div>

      <template v-for="(m, i) in messages" :key="i">
        <div
          v-if="dayLabel(m.ts) && (i === 0 || dayLabel(m.ts) !== dayLabel(messages[i - 1]?.ts))"
          class="cx-day"
        >
          {{ dayLabel(m.ts) }}
        </div>

        <div
          class="cx-msg"
          :class="[m.role === 'system' ? 'sys' : m.role === 'user' ? 'user' : 'ai', grp(i)]"
        >
          <template v-if="m.role === 'system'">
            <div class="cx-sys">{{ m.text }}</div>
          </template>

          <template v-else>
            <!-- 对方：思考 / 终端过程 / 正文 / 图片 / 文件，全部装进同一个气泡 -->
            <div class="cx-b">
              <div v-if="m.steps && m.steps.length" class="cx-steps">
                <div class="cx-sh" @click="foldSteps[i] = !foldSteps[i]">
                  <Ico name="type-code" :size="12" class="cx-sh-i" />
                  <b>
                    终端过程 · {{ m.steps.length }} 步<template v-if="runCount(m)"> · 运行中 {{ runCount(m) }}</template>
                  </b>
                  <em>{{ foldSteps[i] ? '展开' : '收起' }}</em>
                </div>
                <template v-if="!foldSteps[i]">
                  <div
                    v-for="(s, si) in m.steps"
                    :key="si"
                    class="cx-step"
                    :class="{ run: s.run, bad: s.bad, open: openSteps[i + '-' + si] }"
                    @click="openSteps[i + '-' + si] = !openSteps[i + '-' + si]"
                  >
                    <div class="cx-sd">
                      <span v-if="s.run" class="cx-spin"></span>
                      <span v-else class="cx-ok">{{ s.bad ? '✕' : '✓' }}</span>
                      <span class="cx-sn">{{ s.name || 'tool' }}</span>
                      <span class="cx-sa">{{ s.arg }}</span>
                      <span class="cx-st">{{ stepRunText(s) }}</span>
                    </div>
                    <div v-if="s.out" class="cx-so">{{ s.out }}</div>
                  </div>
                </template>
              </div>

              <div v-if="m.think" class="cx-think" :class="{ open: openThinks[i] }">
                <div class="cx-th" @click="openThinks[i] = !openThinks[i]">
                  <Ico name="info" :size="12" class="cx-th-i" />
                  <b>{{ m.wait && !m.text ? '思考中…' : '思考过程' }}</b>
                  <em>{{ openThinks[i] ? '收起' : '展开' }}</em>
                </div>
                <div class="cx-tk">{{ m.think }}</div>
              </div>

              <div v-if="m.approval" class="cx-ap">
                <div class="cx-ap-h">
                  ⚠️ 这一步要你点头才能跑{{ m.approval.description ? '：' + m.approval.description : '' }}
                </div>
                <pre v-if="m.approval.command" class="cx-ap-c">{{ m.approval.command }}</pre>
                <div v-if="m.approval.choice" class="cx-ap-d">
                  {{ m.approval.choice === 'deny' ? '你拒绝了这一步' : `已允许（${AP_LABEL[m.approval.choice] || m.approval.choice}）` }}
                </div>
                <template v-else-if="m.approval.error">
                  <div class="cx-ap-d err">提交失败：{{ m.approval.error }}</div>
                  <div class="cx-ap-b">
                    <button
                      v-for="c in apButtons(m.approval)"
                      :key="c"
                      :data-ap="c"
                      :class="c === 'deny' ? 'no' : c === 'once' ? 'ok' : ''"
                    >
                      {{ AP_LABEL[c] || c }}
                    </button>
                  </div>
                </template>
                <div v-else class="cx-ap-b">
                  <button
                    v-for="c in apButtons(m.approval)"
                    :key="c"
                    :data-ap="c"
                    :class="c === 'deny' ? 'no' : c === 'once' ? 'ok' : ''"
                  >
                    {{ AP_LABEL[c] || c }}
                  </button>
                </div>
              </div>

              <div
                v-if="m.wait && !m.text && !(m.steps && m.steps.length) && !m.think"
                class="cx-dots"
              >
                <i></i><i></i><i></i>
              </div>

              <div v-if="m.imgs && m.imgs.length" class="cx-imgs">
                <img v-for="(u, k) in m.imgs" :key="k" :src="u" loading="lazy" alt="" />
              </div>

              <div v-if="bodyHtml(m)" class="cx-bt" v-html="bodyHtml(m)"></div>

              <div v-if="thumbsOf(m).length" class="cx-imgs">
                <img v-for="(t, k) in thumbsOf(m)" :key="k" :data-hx="t.href" :data-full="t.full" :title="t.name" alt="" />
              </div>

              <div v-if="mediaFilesOf(m).length" class="cx-mfiles">
                <a
                  v-for="(f, k) in mediaFilesOf(m)"
                  :key="k"
                  class="cx-dl"
                  :href="f.href"
                  download
                >📎 {{ f.name }}</a>
              </div>

              <a
                v-for="(f, k) in m.files || []"
                :key="k"
                class="cx-file dl"
                :href="dlHref(f.path || f.name)"
                download
              >
                📄 {{ f.name }} · {{ f.size }} · <b>下载</b>
              </a>

              <div class="cx-ft">
                <span v-if="m.status === 'running'" class="cx-run">
                  <i></i>更新中
                </span>
                <span v-else-if="m.status === 'interrupted'" class="cx-run bad">
                  已中断
                </span>
                <span v-else-if="statusText(m)">{{ statusText(m) }}</span>
                <span v-else class="cx-hh">{{ hhmm(m.ts) }}</span>
              </div>
            </div>


          </template>
        </div>
      </template>
    </div>

    <div class="cx-strip">
      <div v-for="a in atts" :key="a.id" class="cx-chip" :class="{ bad: a.error }">
        <img v-if="a.preview" :src="a.preview" alt="" />
        <span v-else>📄</span>
        <span>{{ a.name }}{{ attState(a) }}</span>
        <button @click="removeAtt(a.id)">✕</button>
      </div>
    </div>

    <ImageViewer
      v-if="vwOpen && vwEntries.length"
      :entry="vwEntries[vwIdx]"
      :gallery="vwEntries"
      :index="vwIdx"
      :key="vwKey"
      :direct="vwSrcs"
      @close="vwOpen = false"
    />

    <div class="cx-bar">
      <button class="cx-btn" aria-label="发照片或文件" @click="pickFile">
        <Ico name="attach" :size="21" />
      </button>
      <textarea
        ref="inputEl"
        v-model="draft"
        class="cx-in"
        rows="1"
        :placeholder="busy ? '回答中，发新消息会打断上一轮' : '发消息…'"
        @input="autoGrow"
        @keydown="onKey"
        @paste="onPaste"
      ></textarea>
      <button class="cx-btn go" aria-label="发送" @click="send()">
        <Ico name="send" :size="18" />
      </button>
    </div>

    <input ref="fileEl" type="file" multiple hidden @change="onFilePick" />

    <div class="cx-mask" :class="{ on: sheetOpen }" @click="sheetOpen = false"></div>
    <div class="cx-sheet" :class="{ on: sheetOpen }">
      <template v-if="sheetOpen">
        <button
          v-for="a in sheetActions(messages[sheetIdx] || { role: 'system', text: '' })"
          :key="a.k"
          :class="a.cls || ''"
          @click="sheetDo(a.k)"
        >
          {{ a.t }}
        </button>
        <button class="cancel" @click="sheetOpen = false">取消</button>
      </template>
    </div>

    <button v-show="!nearBottom" class="cx-top" aria-label="回到最新" @click="backToLatest">
      <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 5v14" />
        <path d="M6 13l6 6 6-6" />
      </svg>
    </button>
  </div>
</template>

<style scoped>
.cx {
  position: fixed;
  left: 0;
  right: 0;
  display: flex;
  flex-direction: column;
  z-index: 8;
  background: var(--bg2, #f5f6f8);
  overflow: hidden;
}

.cx-lock {
  flex: 0 0 auto;
  display: none;
  gap: 8px;
  align-items: center;
  padding: 10px 14px;
  background: #fff8e8;
  border-bottom: 1px solid #f3e4c6;
  font-size: 12px;
  color: #8a6a2f;
}

.cx-lock.on {
  display: flex;
}

.cx-lock input {
  flex: 1 1 auto;
  min-width: 0;
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 6px 9px;
  font-size: 13px;
  background: var(--surface);
  color: var(--ink);
  outline: none;
}

.cx-lock button {
  border: 0;
  background: var(--ac, var(--ac));
  color: #fff;
  border-radius: 9px;
  padding: 6px 12px;
  font-size: 12px;
  font-weight: 600;
}

.cx-log {
  flex: 1 1 auto;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
  overscroll-behavior: contain;
  padding: 12px 14px 18px;
  width: 100%;
  max-width: none;
  margin: 0;
  scrollbar-width: none;
}

/* 宽屏（平板/桌面）铺满，只把气泡本身放宽一点，别让人一行读一米 */
/* 平板/桌面：铺满容器，只留一点内边距 */
@media (min-width: 761px) {
  .cx-log {
    padding-left: 22px;
    padding-right: 22px;
  }

  /* 输入条跟着消息区的内边距走，两边对齐 */
  .cx-bar {
    padding-left: 22px;
    padding-right: 22px;
  }
}

.cx-log::-webkit-scrollbar {
  width: 0;
  height: 0;
  display: none;
}

.cx-intro {
  margin: 9vh auto 0;
  max-width: 320px;
  background: var(--surface, #fff);
  border: 1px solid var(--line, #eceff3);
  border-radius: 20px;
  padding: 22px 20px;
  color: var(--ink3, #9aa8ba);
  text-align: center;
  font-size: 13px;
  line-height: 2.1;
}

.cx-intro b {
  display: block;
  color: var(--ink, #26364a);
  font-size: 15.5px;
  font-weight: 700;
  margin-bottom: 8px;
  letter-spacing: 0.2px;
}

.cx-msg {
  display: flex;
  flex-direction: column;
  margin-bottom: 10px;
  max-width: 100%;
}

.cx-msg.first {
  margin-top: 6px;
}

.cx-msg:not(.first) {
  margin-top: 0;
  margin-bottom: 3px;
}

.cx-msg.user {
  align-items: flex-end;
}

.cx-msg.sys {
  align-items: center;
}

.cx-b {
  display: flex;
  flex-direction: column;
  max-width: min(80%, 900px);
  padding: 9px 13px 6px;
  border-radius: 20px;
  font-size: 15px;
  line-height: 1.45;
  letter-spacing: 0.1px;
  word-break: break-word;
}

.cx-bt {
  white-space: pre-wrap;
  word-break: break-word;
}

.cx-msg.user.last .cx-b {
  border-bottom-right-radius: 7px;
}

.cx-msg.ai.last .cx-b {
  border-bottom-left-radius: 7px;
}

/* 泡内右下：状态 / 时间 / 双勾 */
.cx-run {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  color: var(--ac, var(--ac));
}

.cx-run i {
  width: 5px;
  height: 5px;
  border-radius: 99px;
  background: currentColor;
  animation: cxPulse 1.1s ease-in-out infinite;
}

.cx-run.bad {
  color: #e0515f;
}

@keyframes cxPulse {
  0%,
  100% {
    opacity: 0.25;
  }
  50% {
    opacity: 1;
  }
}

.cx-ft {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  margin-top: 3px;
  font-size: 10px;
  line-height: 1.2;
  letter-spacing: 0.2px;
  color: var(--ink3, #9aa8ba);
  opacity: 0.9;
}

.cx-msg.user .cx-ft {
  color: rgba(255, 255, 255, 0.75);
}

.cx-ticks {
  letter-spacing: -2px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.92);
}

/* markdown 排版 */
.cx-bt :deep(b), .cx-bt b { font-weight: 650; }
.cx-bt :deep(ul), .cx-bt ul,
.cx-bt :deep(ol), .cx-bt ol {
  margin: 3px 0 3px 17px;
  padding: 0;
  white-space: normal;
}
.cx-bt :deep(li), .cx-bt li {
  margin: 1px 0;
  white-space: normal;
}
.cx-bt :deep(h3), .cx-bt h3 { font-size: 16px; margin: 8px 0 4px; }
.cx-bt :deep(h4), .cx-bt h4 { font-size: 15px; margin: 7px 0 3px; }
.cx-bt :deep(h5), .cx-bt h5,
.cx-bt :deep(h6), .cx-bt h6 { font-size: 14px; margin: 6px 0 3px; }
.cx-bt :deep(blockquote), .cx-bt blockquote {
  margin: 5px 0;
  padding: 2px 0 2px 9px;
  border-left: 2px solid var(--line, #e6ebf2);
  color: var(--ink2, #6e7683);
}
.cx-bt :deep(hr), .cx-bt hr {
  border: 0;
  border-top: 1px solid var(--line, #e8edf4);
  margin: 8px 0;
}

.cx-msg.user .cx-b {
  align-self: flex-end;
  border-bottom-right-radius: 20px;
  background: var(--ac, #0a84ff);
  color: #fff;
  border-bottom-right-radius: 7px;
  box-shadow: 0 1px 2px rgba(10, 132, 255, 0.2);
}

.cx-msg.ai .cx-b {
  align-self: flex-start;
  border-bottom-left-radius: 20px;
  background: var(--surface, #fff);
  color: var(--ink, #26364a);
  border: 1px solid var(--line, #eceff3);
  border-bottom-left-radius: 7px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
}

.cx-b :deep(code) {
  font-family: ui-monospace, Menlo, Consolas, monospace;
  font-size: 13px;
  background: var(--bg2, #f1f3f7);
  border-radius: 5px;
  padding: 1px 5px;
}

.cx-b :deep(pre) {
  position: relative;
  background: #1d2b3d;
  color: #dfe9f6;
  padding: 11px 13px;
  border-radius: 12px;
  overflow-x: auto;
  margin: 7px 0;
  font-size: 12.5px;
  line-height: 1.6;
  white-space: pre;
}

.cx-b :deep(pre[data-cp]) {
  padding-top: 27px;
}

.cx-b :deep(pre code) {
  background: none;
  color: inherit;
  padding: 0;
}

.cx-b :deep(.cx-cp) {
  position: absolute;
  top: 6px;
  right: 6px;
  border: 0;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.14);
  color: #cfd9e6;
  font-size: 10.5px;
  line-height: 1;
  padding: 4px 7px;
  cursor: pointer;
}

.cx-b :deep(.cx-a) {
  color: var(--ac);
  text-decoration: none;
  word-break: break-all;
}

.cx-msg.user .cx-b :deep(.cx-a) {
  color: #fff;
  text-decoration: underline;
}

.cx-b :deep(.cx-dl) {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border: 1px solid var(--line2, #e9eef6);
  background: var(--bg2, #f5f8fc);
  border-radius: 10px;
  padding: 6px 10px;
  font-size: 12px;
  font-weight: 500;
  color: var(--ac, var(--ac));
  text-decoration: none;
  margin: 2px 0;
  cursor: pointer;
}

.cx-b :deep(.cx-dl)::after {
  content: '下载';
  font-size: 11px;
  font-weight: 400;
  color: var(--ink3, #9aa8ba);
  margin-left: 2px;
}

.cx-think {
  display: block;
  width: 100%;
  margin: 0 0 6px;
  padding: 8px 11px;
  background: var(--bg2, #f5f8fc);
  border: 1px solid var(--line2, #e9eef6);
  border-radius: 11px;
}

.cx-th {
  display: flex;
  align-items: center;
  gap: 5px;
  font-size: 11.5px;
  color: var(--ink3, #9aa8ba);
  cursor: pointer;
  user-select: none;
}

.cx-th b {
  flex: 1;
  font-weight: 600;
  font-size: 11.5px;
  color: var(--ink3, #9aa8ba);
}

.cx-th em {
  font-style: normal;
  font-size: 11px;
}

.cx-tk {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  margin-top: 5px;
  font-size: 11.5px;
  line-height: 1.5;
  color: var(--ink2, #6e7683);
  white-space: pre-wrap;
  word-break: break-word;
}

.cx-think.open .cx-tk {
  display: block;
  -webkit-line-clamp: unset;
}

.cx-think-more {
  align-self: flex-start;
  border: 0;
  background: none;
  padding: 0;
  font-size: 11px;
  color: var(--ink3, #9aa5b5);
  margin: -3px 0 9px 13px;
  font-weight: 500;
  cursor: pointer;
}

.cx-steps {
  width: 100%;
  margin-bottom: 6px;
  box-sizing: border-box;
  padding: 7px 9px;
  background: var(--bg2, #f5f8fc);
  border: 1px solid var(--line2, #e9eef6);
  border-radius: 11px;
}

.cx-sh {
  display: flex;
  align-items: center;
  gap: 5px;
  font-size: 11px;
  color: var(--ink3, #9aa8ba);
  cursor: pointer;
  user-select: none;
}

.cx-sh b {
  flex: 1;
  font-weight: 600;
  font-size: 11px;
  color: var(--ink3, #9aa8ba);
}

.cx-sh em {
  font-style: normal;
  font-size: 10.5px;
}

.cx-sh-i,
.cx-th-i {
  color: var(--ink3, #9aa8ba);
  flex: none;
  display: inline-flex;
}

.cx-step {
  border: 0;
  background: transparent;
  padding: 4px 0 0;
  font-size: 11.5px;
  line-height: 1.5;
  color: #4a5f7a;
  cursor: pointer;
}

.cx-spin {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  border: 1.3px solid var(--ac, #0a84ff);
  border-top-color: transparent;
  animation: cxspin 0.8s linear infinite;
  flex: none;
}

@keyframes cxspin {
  to {
    transform: rotate(360deg);
  }
}

.cx-step.run {
  background: var(--acw, #edf5ff);
}

.cx-step.bad {
  background: #fff5f5;
}

.cx-sd {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.cx-sn {
  font-size: 11px;
  color: var(--ink, #26364a);
  flex: 0 0 auto;
  font-weight: 700;
  color: #26364a;
  font-family: ui-monospace, Menlo, Consolas, monospace;
  font-size: 11.5px;
}

.cx-sa {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #5d7391;
  font-family: ui-monospace, Menlo, Consolas, monospace;
}

.cx-st {
  flex: 0 0 auto;
  color: #9aa8ba;
  font-size: 10.5px;
  font-variant-numeric: tabular-nums;
}

.cx-dot {
  flex: 0 0 auto;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--ac);
  animation: cxp 0.9s ease-in-out infinite;
}

@keyframes cxp {
  0%,
  100% {
    opacity: 0.25;
    transform: scale(0.75);
  }
  50% {
    opacity: 1;
    transform: scale(1);
  }
}

.cx-ok {
  flex: 0 0 auto;
  color: #2f9e58;
  font-size: 11px;
  font-weight: 700;
}

.cx-step.bad .cx-ok {
  color: #e5484d;
}

.cx-so {
  margin: 2px 0 0 15px;
  font-size: 10.5px;
  line-height: 1.45;
  color: var(--ink2, #6e7683);
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 3.1em;
  overflow: hidden;
}

.cx-step.open .cx-so {
  max-height: none;
}

.cx-ap {
  width: 100%;
  box-sizing: border-box;
  max-width: none;
  background: #fffdf5;
  border: 1px solid #f0d9a8;
  border-radius: 12px;
  padding: 8px 10px;
  margin: 2px 0 6px;
}

.cx-ap-h {
  font-size: 12px;
  color: #8a6a2f;
  font-weight: 650;
  margin-bottom: 5px;
  line-height: 1.5;
}

.cx-ap-c {
  margin: 0 0 7px;
  background: #1d2b3d;
  color: #dfe9f6;
  padding: 7px 9px;
  border-radius: 8px;
  font-family: ui-monospace, Menlo, Consolas, monospace;
  font-size: 11.5px;
  overflow-x: auto;
  white-space: pre;
}

.cx-ap-b {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.cx-ap-b button {
  border: 1px solid var(--line);
  background: var(--surface);
  color: var(--ink2);
  border-radius: 8px;
  padding: 5px 10px;
  font-size: 11.5px;
  font-weight: 600;
}

.cx-ap-b button.ok {
  background: #2f9e58;
  border-color: #2f9e58;
  color: #fff;
}

.cx-ap-b button.no {
  background: #e5484d;
  border-color: #e5484d;
  color: #fff;
}

.cx-ap-d {
  font-size: 11.5px;
  color: #7a5c1f;
}

.cx-ap-d.err {
  color: #c0392b;
}

.cx-sys {
  align-self: center;
  max-width: 88%;
  background: var(--bg2, #eef1f5);
  color: var(--ink2, #6e6e73);
  border-radius: 20px;
  padding: 6px 12px;
  font-size: 11.5px;
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
  text-align: center;
}

.cx-mfiles {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 6px;
  margin-top: 8px;
}

.cx-imgs {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
  margin-bottom: 6px;
}

.cx-imgs img {
  width: 96px;
  height: 96px;
  object-fit: cover;
  border-radius: 8px;
  background: var(--bg2, #f4f6fa);
  cursor: zoom-in;
}

.cx-file {
  font-size: 11.5px;
  color: var(--ink2, #5d7391);
  background: var(--surface, #fff);
  border: 1px solid var(--line, #eceff3);
  border-radius: 20px;
  padding: 6px 11px;
  margin: 1px 0;
  text-decoration: none;
  display: inline-block;
}

a.cx-file.dl {
  background: var(--acw, #ebf3ff);
  border: 0;
  color: var(--ac, var(--ac));
}

.cx-file b {
  font-weight: 600;
}

.cx-meta {
  font-size: 10.5px;
  color: var(--ink3, #78828f);
  margin: 5px 3px 0;
  letter-spacing: 0.2px;
}

.cx-typing {
  padding: 12px 15px;
}

.cx-dots {
  display: inline-flex;
  gap: 6px;
  align-items: center;
  height: 11px;
}

.cx-dots i {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #c2cfdf;
  animation: cxb 1.2s infinite ease-in-out;
}

.cx-dots i:nth-child(2) {
  animation-delay: 0.16s;
}

.cx-dots i:nth-child(3) {
  animation-delay: 0.32s;
}

@keyframes cxb {
  0%,
  80%,
  100% {
    opacity: 0.3;
    transform: translateY(0);
  }
  40% {
    opacity: 1;
    transform: translateY(-3px);
  }
}

.cx-day {
  display: flex;
  align-items: center;
  gap: 9px;
  color: #a6aebc;
  font-size: 10.5px;
  letter-spacing: 0.5px;
  margin: 12px 2px 14px;
}

.cx-day::before,
.cx-day::after {
  content: '';
  flex: 1 1 auto;
  height: 1px;
  background: var(--line, #eceff3);
}

/* 正文里的图片缩略图 */
.cx-bt :deep(img.cx-mi), .cx-bt img.cx-mi {
  display: inline-block;
  width: 96px;
  height: 96px;
  object-fit: cover;
  border-radius: 8px;
  margin: 4px 6px 2px 0;
  background: var(--bg2, #f4f6fa);
  cursor: zoom-in;
  vertical-align: top;
}

/* 缩略图和原图都拉不到时的占位（文件被清掉了） */
.cx-bt :deep(img.cx-mi.cx-mi-bad), .cx-bt img.cx-mi.cx-mi-bad,
.cx-imgs img.cx-mi-bad {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0 8px;
  box-sizing: border-box;
  color: var(--ink3, #9aa3ad);
  font-size: 11px;
  line-height: 1.3;
  text-align: center;
  background: var(--bg2, #f4f6fa);
  border: 1px dashed var(--line, #dfe4ea);
  cursor: default;
}

.cx-strip {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
  padding: 0 max(12px, calc((100% - 760px) / 2 + 12px)) 4px;
  background: transparent;
  flex: 0 0 auto;
}

.cx-strip:empty {
  display: none;
}

.cx-chip {
  display: flex;
  align-items: center;
  gap: 5px;
  border-radius: 20px;
  padding: 4px 9px;
  font-size: 11.5px;
  color: var(--ink2, #5d7391);
  background: var(--bg2, #eef1f5);
}

.cx-chip.bad {
  background: #fff0f0;
  color: #c0392b;
}

.cx-chip img {
  width: 28px;
  height: 28px;
  border-radius: 5px;
  object-fit: cover;
}

.cx-chip span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 180px;
}

.cx-chip button {
  border: 0;
  background: transparent;
  color: #93a3b8;
  font-size: 14px;
  padding: 0 1px;
  cursor: pointer;
}

.cx-bar {
  flex: 0 0 auto;
  display: flex;
  align-items: flex-end;
  gap: 7px;
  /* 和消息区同宽（.cx-log 是 14px 内边距铺满），不要再把输入条缩成居中 760px */
  padding: 8px 14px 10px;
  background: var(--surface, #fff);
  border-top: 1px solid var(--line, #eff1f5);
}

.cx-btn {
  flex: 0 0 auto;
  width: 42px;
  height: 42px;
  border: 0;
  background: transparent;
  color: var(--ink2, #6e6e73);
  border-radius: 21px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  transition: transform 0.12s, background 0.16s;
}

.cx-btn:active {
  transform: scale(0.93);
}

.cx-btn.go {
  background: var(--ac, #0a84ff);
  color: #fff;
  box-shadow: 0 2px 8px rgba(10, 132, 255, 0.32);
}

.cx-btn.stop {
  background: #e5484d;
  box-shadow: 0 2px 6px rgba(229, 72, 77, 0.3);
}

.cx-stop-sq {
  width: 11px;
  height: 11px;
  border-radius: 3px;
  background: #fff;
}

.cx-in {
  flex: 1 1 auto;
  border: 0;
  background: var(--bg2, #f2f4f7);
  border-radius: 21px;
  padding: 10px 15px;
  line-height: 22px;
  min-height: 42px;
  box-sizing: border-box;
  font: inherit;
  font-size: 16px;
  color: var(--ink, #26364a);
  resize: none;
  outline: none;
  transition: background 0.16s, box-shadow 0.16s;
}

.cx-in:focus {
  background: var(--surface, #fff);
  box-shadow: 0 0 0 2px rgba(10, 132, 255, 0.16);
}

.cx-in::placeholder {
  color: var(--ink3, #a6aebc);
}

.cx-mask {
  position: absolute;
  inset: 0;
  background: rgba(16, 24, 40, 0.26);
  z-index: 12;
  display: none;
}

.cx-mask.on {
  display: block;
}

.cx-sheet {
  position: absolute;
  left: 12px;
  right: 12px;
  bottom: 14px;
  z-index: 13;
  display: none;
  flex-direction: column;
  gap: 7px;
}

.cx-sheet.on {
  display: flex;
}

.cx-sheet button {
  border: 0;
  border-radius: 15px;
  background: var(--surface, #fff);
  color: var(--ink, #1d1d1f);
  font-size: 16px;
  font-weight: 500;
  padding: 15px 10px;
  box-shadow: 0 4px 18px rgba(16, 24, 40, 0.16);
  cursor: pointer;
}

.cx-sheet button.danger {
  color: #e5484d;
}

.cx-sheet button.cancel {
  color: var(--ac, #0a84ff);
  font-weight: 600;
}

.cx-top {
  position: absolute;
  right: 15px;
  bottom: 84px;
  width: 34px;
  height: 34px;
  border-radius: 50%;
  background: var(--surface, #fff);
  border: 1px solid var(--line, #e7eaef);
  color: var(--ink2, #5b6675);
  box-shadow: 0 3px 10px rgba(16, 24, 40, 0.12);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  z-index: 9;
}
</style>
