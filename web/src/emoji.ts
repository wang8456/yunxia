/**
 * 图标：用 Apple 表情包（emoji-datasource-apple）的 PNG。
 *
 * 为什么不用字符：Windows 上很多 emoji 没有彩色字形，会被渲染成黑白线条，
 * 跟老网页版那套圆润彩色图标差得远。这里统一换成图片，尺寸和色块由 CSS 控制。
 *
 * 文件名的坑：文本默认呈现的字符（🖼 🗜 ⌨ ☁ ⤓）必须带 fe0f，否则 404。
 */
// 图片随前端一起打包，不走 CDN：jsDelivr 在不少国内网络里打不开，图标会全空
const BASE = '/emoji'

const CODE: Record<string, string> = {
  '🏠': '1f3e0',
  '📁': '1f4c1',
  '📂': '1f4c2',
  '🔍': '1f50d',
  '👤': '1f464',
  '🖼': '1f5bc-fe0f',
  '🎬': '1f3ac',
  '🎵': '1f3b5',
  '📕': '1f4d5',
  '📄': '1f4c4',
  '🗜': '1f5dc-fe0f',
  '⌨': '2328-fe0f',
  '☁': '2601-fe0f',
  '🔒': '1f512',
  '⤓': '2935-fe0f',
  '💾': '1f4be',
  '🗄': '1f5c4-fe0f',
  '📦': '1f4e6',
  '🔗': '1f517',
}

export function emoji(ch: string): string {
  const code = CODE[ch]
  return code ? `${BASE}/${code}.png` : ''
}

export const emojiList = CODE
