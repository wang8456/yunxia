/* 翻译源（网页端自带，和 App 同一套口径）
   听（转写）在 NAS 上跑，译在客户端跑：填自己的 API 密钥，直连 OpenAI 兼容的
   /chat/completions。DeepSeek 是预设，也能填硅基流动 / 月之暗面 / one-api。 */

export type TrCfg = {
  provider: 'deepseek' | 'custom'
  base: string
  model: string
  key: string
}

const LS_KEY = 'yunxia.tr'
export const TR_PRESET = 'https://api.deepseek.com'
export const TR_MODEL = 'deepseek-flash'

const DEF: TrCfg = { provider: 'deepseek', base: '', model: TR_MODEL, key: '' }

export function trLoad(): TrCfg {
  try {
    const j = JSON.parse(localStorage.getItem(LS_KEY) || '{}')
    return {
      provider: j.provider === 'custom' ? 'custom' : 'deepseek',
      base: String(j.base || ''),
      model: String(j.model || ''),
      key: String(j.key || ''),
    }
  } catch {
    return { ...DEF }
  }
}

export function trSave(c: TrCfg) {
  localStorage.setItem(LS_KEY, JSON.stringify(c))
}

export function trEndpoint(c = trLoad()): string {
  let b = (c.provider === 'custom' ? c.base.trim() : TR_PRESET).trim()
  if (!b) b = TR_PRESET
  if (!/^https?:\/\//i.test(b)) b = 'https://' + b
  if (b.endsWith('/chat/completions')) return b
  b = b.replace(/\/+$/, '')
  const path = (() => {
    try {
      return new URL(b).pathname
    } catch {
      return ''
    }
  })()
  return path && path !== '/' ? `${b}/chat/completions` : `${b}/v1/chat/completions`
}

/** 本机没填过密钥时，从 NAS 取一次默认配置（省得每台设备手填） */
let ensured = false
export async function trEnsureKey(): Promise<boolean> {
  const cur = trLoad()
  if (cur.key.trim()) return true
  if (ensured) return false
  ensured = true
  try {
    const r = await fetch('/api/v1/subs/trcfg', {
      headers: { Authorization: 'Bearer ' + (localStorage.getItem('yunxia.token') || '') },
    })
    if (!r.ok) return false
    const j = await r.json()
    if (!j?.key) return false
    trSave({
      provider: j.provider === 'custom' ? 'custom' : 'deepseek',
      base: String(j.base || ''),
      model: String(j.model || TR_MODEL),
      key: String(j.key),
    })
    return true
  } catch {
    return false
  }
}

export function trReady(c = trLoad()): boolean {
  return !!c.key.trim()
}

export function trShownModel(c = trLoad()): string {
  return c.model.trim() || TR_MODEL
}

const cache = new Map<string, string>()
const CACHE_MAX = 3000

function sysPrompt(to: string): string {
  return (
    `你是字幕翻译。把输入的每一条英文（或其他语言）字幕翻成${to === 'en' ? '英文' : '简体中文'}。` +
    '要求：口语化、简洁、符合字幕长度；不添加解释、不合并也不拆分句子；专有名词保留原文。' +
    '专有名词保留原文。只输出 JSON：{"zh":["第1行译文","第2行译文", ...]}，数组长度必须与输入行数相同。'
  )
}

async function post(cfg: TrCfg, lines: string[], to: string): Promise<string[]> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), 60000)
  try {
    const r = await fetch(trEndpoint(cfg), {
      method: 'POST',
      signal: ctl.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + cfg.key.trim(),
      },
      body: JSON.stringify({
        model: trShownModel(cfg),
        temperature: 0,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: sysPrompt(to) },
          { role: 'user', content: JSON.stringify({ lines }) },
        ],
      }),
    })
    const txt = await r.text()
    if (!r.ok) {
      // 把服务端的原话挑出来，用户能看懂是没钱了还是密钥不对
      let msg = txt.slice(0, 160)
      try {
        const j = JSON.parse(txt)
        msg = j?.error?.message || msg
      } catch {
        /* 保持原文 */
      }
      throw new Error(`${r.status} ${msg}`)
    }
    const data = JSON.parse(txt)
    const content = data?.choices?.[0]?.message?.content || ''
    const obj = JSON.parse(content)
    const zh = obj?.zh || obj?.translations || []
    if (!Array.isArray(zh) || zh.length !== lines.length) {
      throw new Error(`译文条数不对：${Array.isArray(zh) ? zh.length : 0} / ${lines.length}`)
    }
    return zh.map((x: unknown) => String(x ?? '').trim())
  } finally {
    clearTimeout(timer)
  }
}

/** 翻译一组字幕：一行进一行出，失败重试一次，仍失败抛错（调用方决定退不退回原文） */
export async function trTranslate(lines: string[], to = 'zh'): Promise<string[]> {
  const cfg = trLoad()
  const out = lines.map(() => '')
  if (!lines.length) return out
  if (!trReady(cfg)) throw new Error('还没配置翻译源（设置 → 听设置 → 翻译源 · 填密钥）')

  const todo: number[] = []
  for (let i = 0; i < lines.length; i++) {
    const t = (lines[i] || '').trim()
    if (!t) continue
    const hit = cache.get(`${trShownModel(cfg)}|${to}|${t}`)
    if (hit !== undefined) {
      out[i] = hit
      continue
    }
    todo.push(i)
  }
  if (!todo.length) return out

  const batch = todo.slice(0, 16)
  const texts = batch.map((i) => (lines[i] || '').trim())
  let res: string[] | null = null
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      res = await post(cfg, texts, to)
      break
    } catch (e) {
      if (attempt === 1) throw e
    }
  }
  if (!res) throw new Error('翻译失败')
  for (let k = 0; k < batch.length; k++) {
    const i = batch[k]
    out[i] = res[k] || ''
    if (out[i]) cache.set(`${trShownModel(cfg)}|${to}|${texts[k]}`, out[i])
  }
  if (cache.size > CACHE_MAX) cache.clear()
  return out
}
