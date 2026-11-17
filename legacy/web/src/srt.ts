/** SRT → 播放器用的 cue 数组： [开始, 结束, 原文, 译文] */
export type Cue = [number, number, string, string]

function sec(h: string, m: string, s: string, ms: string): number {
  return Number(h) * 3600 + Number(m) * 60 + Number(s) + Number(ms) / 1000
}

export function parseSrt(text: string): Cue[] {
  const out: Cue[] = []
  if (!text) return out
  const blocks = text.replace(/\r/g, '').split(/\n{2,}/)
  for (const block of blocks) {
    const lines = block.split('\n').filter((l) => l.trim() !== '')
    if (!lines.length) continue
    let i = 0
    if (/^\d+$/.test(lines[0].trim())) i = 1
    const tm = (lines[i] || '').match(
      /(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)/,
    )
    if (!tm) continue
    const s = sec(tm[1], tm[2], tm[3], tm[4])
    const e = sec(tm[5], tm[6], tm[7], tm[8])
    const body = lines
      .slice(i + 1)
      .join('\n')
      .trim()
    // 简易去标签（<i>/<b>/{\an8} 这类在内封字幕里很常见）
    const clean = body
      .replace(/<[^>]+>/g, '')
      .replace(/\{[^}]*\}/g, '')
      .trim()
    if (clean) out.push([s, e, clean, ''])
  }
  return out
}
