<script setup lang="ts">
/* 首页：照 App 的 home_page.dart 还原
   品牌栏（云匣 + 我）→ 大标题「我的储存」→ 储存来源卡 → 收藏
   App 首页没有存储进度条、分类四宫格、继续观看、最近文件 —— 那些都去掉了。 */
import Ico from '../components/Ico.vue'
import { onMounted, onUnmounted, ref } from 'vue'
import { api } from '../api'

const emit = defineEmits<{ open: [string]; search: []; play: [string] }>()

type Src = { id: string; name: string; sub?: string; kind?: string; writable: boolean; root: string }
const sources = ref<Src[]>([])
const curSrc = ref(localStorage.getItem('yunxia.source') || '')
const loading = ref(true)

type Fav = { source: string; path: string; name: string }
const favs = ref<Fav[]>([])
function loadFavs() {
  try {
    favs.value = JSON.parse(localStorage.getItem('yunxia.favs') || '[]')
  } catch {
    favs.value = []
  }
}

/* 来源图标与配色：照 App home_page.dart 的 _iconOf()，底色/线色逐字抄 */
function srcTone(kind: string): { icon: string; bg: string; fg: string } {
  // 图标区分来源，颜色一律跟主题（照 5020 的 .src-ico{background:--t-acw;color:--t-ac}）
  const bg = 'var(--acw)'
  const fg = 'var(--ac)'
  if (kind === 'dufs') return { icon: 'src-pc', bg, fg }
  if (kind === 'webdav') return { icon: 'src-cloud', bg, fg }
  return { icon: 'src-nas', bg, fg }
}

/* 副标题照 App 的写法：说人话，不把服务器路径直接怼给用户 */
function srcSub(s: Src) {
  if (s.sub) return s.sub
  if (s.kind === 'dufs') return '电脑上的共享'
  if (s.kind === 'webdav') return 'WebDAV 网盘'
  return s.writable ? '服务器本地' : '只读目录'
}

/* 储存占用 + 文件分析：当前选中来源的磁盘容量与按类型统计 */
type AnaKind = { kind: string; count: number; bytes: number }
type Analysis = {
  source: string
  name: string
  local: boolean
  disk: { total: number; used: number; free: number; root: string } | null
  scan: {
    files: number
    dirs: number
    bytes: number
    by_kind: AnaKind[]
    top_dirs: { name: string; bytes: number }[]
    scanned_at: number
    elapsed: number
  } | null
  scanning: boolean
  stale: boolean
  note: string
}
const ana = ref<Analysis | null>(null)
const anaErr = ref('')
let anaTimer: number | undefined

const KIND_NAME: Record<string, string> = {
  video: '视频',
  image: '图片',
  audio: '音频',
  doc: '文档',
  archive: '压缩包',
  code: '代码',
  other: '其他',
}
const KIND_TONE: Record<string, string> = {
  video: '#7C5CF0',
  image: '#0E9D78',
  audio: '#8859DC',
  doc: '#287BE8',
  archive: '#C78218',
  code: '#0E8F80',
  other: '#5B6B82',
}

function fmtBytes(n: number): string {
  if (!n || n < 0) return '0 B'
  const u = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  let v = n
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024
    i++
  }
  return (v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)) + ' ' + u[i]
}

const usedPct = () => {
  const d = ana.value?.disk
  if (!d || !d.total) return 0
  return Math.min(100, Math.round((d.used / d.total) * 100))
}

/** 只画有内容的类型；全空时给一个「还没有文件」 */
const kindRows = () => (ana.value?.scan?.by_kind || []).filter((k) => k.count > 0)

/** 文件类型占比条：按字节切成几段 */
/** 环形右边那几行：体积最大的三类，剩下的合成一行 */
const kpiRows = () => {
  const rows = kindRows().slice().sort((a, b) => b.bytes - a.bytes)
  if (!rows.length) return []
  const head = rows.slice(0, 3).map((k) => ({
    kind: k.kind,
    bytes: k.bytes,
    label: `${KIND_NAME[k.kind] || k.kind} ${k.count}`,
    color: KIND_TONE[k.kind] || '#5B6B82',
  }))
  const tail = rows.slice(3)
  if (tail.length) {
    head.push({
      kind: 'rest',
      bytes: tail.reduce((n, k) => n + k.bytes, 0),
      label: `其他 ${tail.reduce((n, k) => n + k.count, 0)}`,
      color: '#5B6B82',
    })
  }
  return head
}

/** 盘上「不是这些文件」的那部分：系统、容器、快照 */
const restBytes = () => {
  const d = ana.value?.disk
  if (!d) return 0
  const files = ana.value?.scan?.bytes ?? 0
  return Math.max(0, d.used - files)
}

async function loadAna() {
  if (anaTimer) {
    clearTimeout(anaTimer)
    anaTimer = undefined
  }
  try {
    const r = await api.storageAnalysis(curSrc.value)
    ana.value = r
    anaErr.value = ''
    if (r.scanning) anaTimer = window.setTimeout(loadAna, 1200)
  } catch {
    anaErr.value = '读不到储存信息'
  }
}

function pick(s: Src) {
  curSrc.value = s.id
  localStorage.setItem('yunxia.source', s.id)
  ana.value = null
  loadAna()
  emit('open', '/')
}

function openFav(f: Fav) {
  curSrc.value = f.source
  localStorage.setItem('yunxia.source', f.source)
  emit('open', f.path)
}

onMounted(async () => {
  loadFavs()
  try {
    const r = await api.sources()
    sources.value = r.sources
    if (!r.sources.some((s) => s.id === curSrc.value)) {
      curSrc.value = r.default || r.sources[0]?.id || ''
    }
  } catch {
    sources.value = []
  }
  loading.value = false
  loadAna()
})
onUnmounted(() => {
  if (anaTimer) clearTimeout(anaTimer)
})
</script>

<template>
  <div class="home">
    <header class="brandbar">
      <div class="brand-name">云匣</div>

    </header>

    <!-- 我的储存：环形占比 + 类型体积 + 容量条 -->
    <div class="stg">
      <div class="stg-hd">
        <div class="stg-t">
          <b>我的储存</b>
          <i>{{ ana?.name || '正在读取…' }}</i>
        </div>
        <button class="stg-rf" :class="{ spin: !!ana?.scanning }" @click="loadAna">
          <Ico name="refresh" :size="15" />
        </button>
      </div>

      <template v-if="ana?.disk">
        <div class="stg-dash">
          <div class="stg-ring">
            <svg viewBox="0 0 124 124">
              <circle cx="62" cy="62" r="52" fill="none" stroke="var(--line)" stroke-width="13" />
              <circle
                cx="62"
                cy="62"
                r="52"
                fill="none"
                stroke="var(--ac)"
                stroke-width="13"
                stroke-linecap="round"
                stroke-dasharray="327"
                :stroke-dashoffset="327 - (327 * usedPct()) / 100"
              />
            </svg>
            <div class="stg-ring-c">
              <b>{{ usedPct() }}%</b>
              <i>已用</i>
            </div>
          </div>

          <div class="stg-kpis">
            <div v-for="k in kpiRows()" :key="k.kind" class="stg-kpi">
              <s :style="{ background: k.color }"></s>
              <b>{{ fmtBytes(k.bytes) }}</b>
              <i>{{ k.label }}</i>
            </div>
            <div v-if="!kpiRows().length" class="stg-tip">这个来源里还没有文件</div>
          </div>

          <div v-if="ana.scan?.top_dirs?.length" class="stg-dirs">
            <div class="stg-dirs-h">占空间最多</div>
            <div v-for="d in ana.scan.top_dirs.slice(0, 3)" :key="d.name" class="stg-dir">
              <b>{{ d.name }}</b>
              <i>{{ fmtBytes(d.bytes) }}</i>
            </div>
          </div>
        </div>

        <div class="stg-chips">
          <span class="stg-chip"><s style="background: var(--ac)"></s>已用 <b>{{ fmtBytes(ana.disk.used) }}</b></span>
          <span class="stg-chip"><s style="background: #C9D3E0"></s>可用 <b>{{ fmtBytes(ana.disk.free) }}</b></span>
          <span class="stg-chip">总容量 <b>{{ fmtBytes(ana.disk.total) }}</b></span>
          <span class="stg-chip">文件 <b>{{ ana.scan?.files ?? 0 }}</b></span>
        </div>

        <div v-if="restBytes() > 0" class="stg-tip">
          其余 {{ fmtBytes(restBytes()) }} 为系统与容器占用{{ ana.scanning ? ' · 正在统计…' : '' }}
        </div>
      </template>

      <div v-else-if="ana" class="stg-note">{{ ana.note || '这个来源不统计磁盘占用' }}</div>
      <div v-else-if="anaErr" class="stg-note">{{ anaErr }}</div>
      <div v-else class="stg-tip">正在读取…</div>
    </div>

    <div class="home-cols">
      <div class="home-col">
        <div class="group">
      <button
        v-for="s in sources"
        :key="s.id"
        class="src"
        :class="{ on: s.id === curSrc }"
        @click="pick(s)"
      >
        <span class="src-ico" :style="{ background: srcTone(s.kind || '').bg, color: srcTone(s.kind || '').fg }">
          <Ico :name="srcTone(s.kind || '').icon" :size="21" />
        </span>
        <span class="src-txt">
          <b :style="s.id === curSrc ? { color: 'var(--ac)' } : {}">{{ s.name }}</b>
          <i>{{ s.sub || srcSub(s) }}</i>
        </span>
        <span class="dot" :class="{ ro: !s.writable }"></span>
        <Ico class="chev" name="chevron-right" :size="18" />
      </button>
      <div v-if="!loading && !sources.length" class="src-empty">还没有文件源</div>
        </div>
      </div>

      <div class="home-col">
        <div class="sec-head">收藏</div>
        <div v-if="favs.length" class="group">
          <button v-for="(f, i) in favs" :key="i" class="src" @click="openFav(f)">
            <span class="src-ico fav"><Ico name="star" :size="20" /></span>
            <span class="src-txt"><b>{{ f.name }}</b><i>{{ f.path }}</i></span>
            <Ico class="chev" name="chevron-right" :size="18" />
          </button>
        </div>
        <div v-else class="fav-empty">
          <span class="fav-ico"><Ico name="star" :size="18" /></span>
          <span class="fav-txt">
            <b>还没有收藏</b>
            <i>在「文件」里点文件夹的 ⋯ → 收藏到首页</i>
          </span>
        </div>
      </div>
    </div>

  </div>
</template>

<style scoped>
.home {
  padding: 18px 16px 24px;
}

/* ---------- 平板 / 电脑：来源卡两列排，别拉成一整条 ---------- */
@media (min-width: 761px) {
  .home {
    padding: 0;
  }

  .brandbar .brand-name {
    display: none;          /* 侧栏已经有「云匣」 */
  }

  .home .brandbar {
    justify-content: flex-end;
    margin-bottom: 8px;
  }

  /* 来源/收藏一律竖着一列（同 App 的 SrcGroup）：一张白卡里每行一个来源，
     行间 1px 分隔线；不要再摊成 2 列卡片 */
  .group {
    display: block;
  }

  /* 宽屏才把「来源 | 收藏」并成左右两栏（同 App 的 wide 布局）；
     选择器带上 .home，否则会被下面基础的 .home-col + .home-col 压掉 */
  .home .home-cols {
    display: grid;
    grid-template-columns: minmax(0, 1.22fr) minmax(0, 1fr);
    gap: 0 18px;
    align-items: start;
  }

  .home .home-col + .home-col {
    margin-top: 0;
  }

  .home .home-col + .home-col .sec-head {
    margin-top: 0;
    padding-top: 2px;
  }

  .fav-empty {
    background: var(--surface, #fff);
    border: 1px solid var(--line);
    border-radius: 16px;
  }

  /* 宽屏：环放大一点，KPI 排成 2×2 统计格，容量块四等分，别留大空白 */
  .home .stg {
    padding: 20px 22px 18px;
  }

  .home .stg-dash {
    display: grid;
    grid-template-columns: 148px minmax(0, 1fr) minmax(220px, 0.8fr);
    gap: 24px;
    align-items: center;
    margin-top: 18px;
  }

  .home .stg-dirs {
    display: block;
    border-left: 1px solid #f1f4f9;
    padding-left: 22px;
  }

  .home .stg-dirs-h {
    font-size: 11.5px;
    color: #9aa8ba;
    letter-spacing: 0.2px;
    margin-bottom: 9px;
  }

  .home .stg-dir {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 10px;
    padding: 5px 0;
  }

  .home .stg-dir b {
    font-size: 12.5px;
    font-weight: 500;
    color: #3a4757;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .home .stg-dir i {
    font-style: normal;
    font-size: 12px;
    color: #9aa8ba;
    font-variant-numeric: tabular-nums;
    flex: none;
  }

  .home .stg-ring,
  .home .stg-ring svg {
    width: 148px;
    height: 148px;
  }

  .home .stg-ring-c b {
    font-size: 26px;
  }

  .home .stg-kpis {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px 26px;
    align-content: center;
    max-width: none;
  }

  .home .stg-kpi {
    display: grid;
    grid-template-columns: 6px 1fr;
    column-gap: 8px;
    row-gap: 3px;
    align-items: center;
  }

  .home .stg-kpi s {
    grid-area: 1 / 1;
  }

  .home .stg-kpi i {
    grid-area: 1 / 2;
    margin: 0;
    padding: 0;
    text-align: left;
  }

  .home .stg-kpi b {
    grid-area: 2 / 2;
    font-size: 16px;
  }

  .home .stg-chips {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 8px;
  }

  .home .stg-chip {
    justify-content: center;
  }
}

.brandbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 19px;
}

.brand-name {
  font-size: 20px;
  font-weight: 700;
  letter-spacing: -0.5px;
  color: var(--ink);
}

.avatar {
  width: 36px;
  height: 36px;
  border-radius: 99px;
  border: 1px solid var(--line);
  background: var(--surface, #fff);
  color: var(--ac, var(--ac));
  font-size: 14px;
  font-weight: 700;
}

.page-title {
  font-size: 26px;
  font-weight: 700;
  letter-spacing: -0.6px;
  margin: 0 0 15px;
}

.group {
  background: var(--surface, #fff);
  border: 1px solid var(--line);
  border-radius: 17px;
  box-shadow: 0 2px 10px rgba(53, 99, 156, 0.06);
  overflow: hidden;
}

.src {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 13px;
  min-height: 64px;
  padding: 11px 14px;
  border: 0;
  background: transparent;
  text-align: left;
}

.src + .src {
  border-top: 1px solid var(--line2);
}

/* 当前正在用的来源：淡蓝底 + 蓝字（同 App 的 SrcCard.on） */
.src.on {
  background: var(--acw);
}

.src.on:hover {
  background: color-mix(in srgb, var(--acw) 70%, var(--surface));
}

.src-ico {
  width: 40px;
  height: 40px;
  border-radius: 12px;
  display: grid;
  place-items: center;
  flex: none;
}

.src-ico.fav {
  background: color-mix(in srgb, #d99a1e 16%, var(--surface));
  color: #d99a1e;
}

.src-txt {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  flex: 1;
}

.src-txt b {
  font-size: 15.5px;
  font-weight: 600;
  letter-spacing: -0.15px;
  color: var(--ink);
}

.src-txt i {
  font-size: 12px;
  font-style: normal;
  color: #94a1b3;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.dot {
  width: 7px;
  height: 7px;
  border-radius: 99px;
  background: #2ec27e;
  box-shadow: 0 0 0 3px rgba(46, 194, 126, 0.14);
  flex: none;
}

.dot.ro {
  background: #b9c3d2;
  box-shadow: 0 0 0 3px rgba(185, 195, 210, 0.16);
}

.chev {
  color: #c9d1dd;
  flex: none;
}

.chev.small {
  color: #c2cddb;
}

@media (max-width: 899px) {
  .home-col + .home-col {
    margin-top: 4px;
  }
}

.sec-head {
  font-size: 11.5px;
  font-weight: 600;
  letter-spacing: 0.3px;
  color: #8795a8;
  margin: 18px 2px 6px;
}

.fav-empty {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 4px 2px;
}

.fav-ico {
  width: 36px;
  height: 36px;
  border-radius: 12px;
  background: #f1f5fb;
  color: #b3bfcd;
  display: grid;
  place-items: center;
  flex: none;
}

.fav-txt {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.fav-txt b {
  font-size: 13px;
  font-weight: 600;
  color: #8b95a3;
}

.fav-txt i {
  font-size: 11.5px;
  font-style: normal;
  color: #a8b3c2;
}

/* ---------- 储存占用 + 文件分析 ---------- */
.stg {
  margin: 0 0 20px;
  padding: 18px 18px 16px;
  background: var(--surface, #fff);
  border-radius: 20px;
  box-shadow:
    0 8px 24px -18px rgba(17, 24, 39, 0.55),
    0 1px 0 rgba(17, 24, 39, 0.03);
}

.stg-hd {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 10px;
}

.stg-t {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.stg-t b {
  font-size: 15.5px;
  font-weight: 600;
  letter-spacing: -0.15px;
  color: var(--ink);
}

.stg-t i {
  font-size: 12px;
  font-style: normal;
  color: #9aa8ba;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.stg-rf {
  width: 28px;
  height: 28px;
  border-radius: 9px;
  border: 1px solid var(--line, #eef2f7);
  background: #f8fafc;
  color: #7d8b9c;
  display: grid;
  place-items: center;
  flex: none;
}

.stg-rf.spin svg {
  animation: stgspin 1s linear infinite;
}

@keyframes stgspin {
  to {
    transform: rotate(360deg);
  }
}

.stg-dash {
  display: flex;
  align-items: center;
  gap: 18px;
  margin-top: 16px;
}

.stg-ring {
  position: relative;
  width: 124px;
  height: 124px;
  flex: none;
}

.stg-ring svg {
  width: 124px;
  height: 124px;
  transform: rotate(-90deg);
  display: block;
}

.stg-ring-c {
  position: absolute;
  inset: 0;
  display: grid;
  place-content: center;
  text-align: center;
}

.stg-ring-c b {
  display: block;
  font-size: 22px;
  font-weight: 700;
  letter-spacing: -0.8px;
  color: var(--ink);
  font-variant-numeric: tabular-nums;
}

.stg-ring-c i {
  display: block;
  margin-top: 1px;
  font-size: 11px;
  font-style: normal;
  color: #9aa8ba;
}

.stg-kpis {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 11px;
}

.stg-kpi {
  display: flex;
  align-items: baseline;
  gap: 6px;
  min-width: 0;
}

.stg-kpi s {
  width: 6px;
  height: 6px;
  border-radius: 2px;
  flex: none;
  align-self: center;
}

.stg-kpi b {
  font-size: 14.5px;
  font-weight: 600;
  letter-spacing: -0.2px;
  color: var(--ink);
  font-variant-numeric: tabular-nums;
}

.stg-kpi i {
  margin-left: auto;
  padding-left: 8px;
  font-size: 11.5px;
  font-style: normal;
  color: #9aa8ba;
  white-space: nowrap;
}

.stg-dirs {
  display: none;
}

.stg-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
  margin-top: 16px;
  padding-top: 14px;
  border-top: 1px solid #f1f4f9;
}

.stg-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px;
  border-radius: 9px;
  background: var(--surface2);
  font-size: 12px;
  color: var(--ink3);
}

.stg-chip s {
  width: 6px;
  height: 6px;
  border-radius: 2px;
  flex: none;
}

.stg-chip b {
  font-weight: 600;
  color: #3a4757;
  font-variant-numeric: tabular-nums;
}

.stg-tip {
  margin-top: 12px;
  font-size: 11.5px;
  color: #9aa8ba;
}

.stg-note {
  margin-top: 10px;
  font-size: 12.5px;
  color: #94a1b3;
  padding: 10px 0 4px;
  line-height: 1.6;
}

.src-empty {
  padding: 16px 14px;
  font-size: 12.5px;
  color: #94a1b3;
}

.mask {
  position: fixed;
  inset: 0;
  background: rgba(20, 30, 45, 0.42);
  display: grid;
  place-items: center;
  z-index: 60;
  padding: 24px;
}

.dlg {
  width: 100%;
  max-width: 340px;
  background: var(--surface, #fff);
  border-radius: 18px;
  padding: 18px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.dlg b {
  font-size: 16px;
  font-weight: 700;
}

.dlg p {
  margin: 0;
  font-size: 12px;
  color: var(--ink3);
}

.dlg input {
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 11px 12px;
  font-size: 13px;
  background: transparent;
  color: var(--ink);
}

.dlg-btns {
  display: flex;
  gap: 8px;
  margin-top: 4px;
}

.dlg-btns button {
  flex: 1;
  border: 0;
  border-radius: 12px;
  padding: 11px;
  font-size: 14px;
  font-weight: 600;
}

.ghost {
  background: var(--line2);
  color: var(--ink2, #44526a);
}

.primary {
  background: var(--ac);
  color: var(--onac);
}
</style>
