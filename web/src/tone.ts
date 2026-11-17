/* 文件类型 → 图标槽位 + 配色：App `browse_page.dart` 的 `_FileRow._kindTone()` 原值 */
export type Tone = { icon: string; bg: string; fg: string }

const TONES: Record<string, Tone> = {
  dir: { icon: 'folder', bg: '#EAF2FF', fg: '#1677F8' },
  image: { icon: 'type-image', bg: '#E5F8EF', fg: '#0E9D78' },
  video: { icon: 'type-video', bg: '#EFEAFF', fg: '#7C5CF0' },
  audio: { icon: 'type-audio', bg: '#F0EAFF', fg: '#8859DC' },
  pdf: { icon: 'type-pdf', bg: '#FFF0EE', fg: '#E45E53' },
  archive: { icon: 'type-zip', bg: '#FFF3DF', fg: '#C78218' },
  code: { icon: 'type-code', bg: '#E8F5F4', fg: '#0E8F80' },
  doc: { icon: 'type-doc', bg: '#E9F2FF', fg: '#287BE8' },
  other: { icon: 'type-file', bg: '#F0F3F8', fg: '#5B6B82' },
}

export function kindOf(name: string, isDir: boolean): string {
  if (isDir) return 'dir'
  const n = (name || '').toLowerCase()
  const ext = n.slice(n.lastIndexOf('.') + 1)
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic'].includes(ext)) return 'image'
  if (['mp4', 'mkv', 'mov', 'avi', 'webm', 'ts', 'm2ts', 'flv', 'wmv', 'rmvb'].includes(ext)) return 'video'
  if (['mp3', 'flac', 'm4a', 'wav', 'aac', 'ogg', 'ape', 'amr'].includes(ext)) return 'audio'
  if (ext === 'pdf') return 'pdf'
  if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'].includes(ext)) return 'archive'
  if (['html', 'htm', 'js', 'ts', 'json', 'css', 'py', 'sh', 'java', 'kt', 'c', 'cpp', 'go', 'rs', 'xml', 'yaml', 'yml'].includes(ext))
    return 'code'
  if (['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv', 'srt', 'ass', 'vtt'].includes(ext)) return 'doc'
  return 'other'
}

export function toneOf(name: string, isDir: boolean): Tone {
  return TONES[kindOf(name, isDir)] || TONES.other
}

export function kindLabel(kind: string): string {
  const m: Record<string, string> = {
    dir: '文件夹',
    image: '图片',
    video: '视频',
    audio: '音频',
    pdf: 'PDF',
    archive: '压缩包',
    code: '代码',
    doc: '文件',
    other: '文件',
  }
  return m[kind] || '文件'
}
