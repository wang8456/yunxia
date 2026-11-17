// 给 dist 里的静态文件生成 .br / .gz 预压缩版本
// 为什么不靠服务器实时压缩：NAS 只有 4 核 1.9G，还要跑听译和转码，
// 预压缩一次、之后都是零开销。
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { brotliCompressSync, gzipSync, constants } from 'node:zlib'

const ROOT = 'dist'
const EXTS = ['.js', '.css', '.html', '.svg', '.json', '.woff2', '.map']
const MIN = 1024 // 1KB 以下压了反而更大

function walk(dir) {
  const out = []
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    const st = statSync(p)
    if (st.isDirectory()) out.push(...walk(p))
    else if (EXTS.some((e) => name.endsWith(e)) && !name.endsWith('.br') && !name.endsWith('.gz')) {
      if (st.size >= MIN) out.push(p)
    }
  }
  return out
}

let raw = 0
let br = 0
let gz = 0
for (const f of walk(ROOT)) {
  const buf = readFileSync(f)
  const b = brotliCompressSync(buf, {
    params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: buf.length },
  })
  const g = gzipSync(buf, { level: 9 })
  writeFileSync(f + '.br', b)
  writeFileSync(f + '.gz', g)
  raw += buf.length
  br += b.length
  gz += g.length
}
const kb = (n) => (n / 1024).toFixed(0) + 'KB'
console.log(`预压缩完成：原始 ${kb(raw)} → br ${kb(br)} / gzip ${kb(gz)}`)
