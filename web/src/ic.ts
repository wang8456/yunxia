/** 旧代码里用的是 Apple emoji 当图标，这里把每个 emoji 映射到 App 的同义线性图标名
 *  （ICONS 见 src/icons.ts，同源于 App 的 ui_icons_data.dart）。
 *  页面只改渲染方式：数据里仍留着 emoji 字符，渲染时走 icoName()。 */
const MAP: Record<string, string> = {
  '☁': 'src-cloud',
  '💬': 'chat',
  '🏠': 'home',
  '📁': 'type-folder',
  '📂': 'type-folder',
  '🔍': 'search',
  '👤': 'user',
  '🖼': 'type-image',
  '🎬': 'type-video',
  '🎵': 'type-audio',
  '📕': 'type-pdf',
  '📄': 'type-doc',
  '🗜': 'type-zip',
  '⌨': 'type-code',
  '📦': 'type-file',
  '🔒': 'lock',
  '🔓': 'unlock',
  '⤓': 'download',
  '💾': 'src-disk',
  '🗄': 'src-nas',
  '🔗': 'link',
  '⚙': 'setting',
  '↻': 'refresh',
  '✕': 'close',
  '▶': 'play',
  '⏸': 'pause',
  '⭐': 'star',
  '🗑': 'trash',
  '✎': 'edit',
  '＋': 'add',
}

export function icoName(ch: string): string {
  return MAP[ch] || 'type-file'
}
