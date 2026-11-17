<script setup lang="ts">
/* 下载队列 —— 1:1 照 App 的 lib/ui/downloads_page.dart。
   云下载（115 离线）+ 磁力 + ed2k 合成一个列表，按状态分组、按来源过滤。 */
import Ico from '../components/Ico.vue'
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api } from '../api'
import { confirmBox } from '../ask'

const props = defineProps<{ toast: (t: string) => void; close: () => void }>()

type Item = {
  kind: 'cloud' | 'magnet' | 'ed2k'
  id: string
  name: string
  pct: number // 0..1
  speed: number
  size: number
  state: 'active' | 'waiting' | 'paused' | 'error' | 'done'
  extra: string
}

const items = ref<Item[]>([])
const loading = ref(true)
const err = ref('')
const filter = ref<'all' | 'cloud' | 'magnet' | 'ed2k'>('all')
const busy = ref(false)
const showDone = ref(false)
// 没有在下的任务时，已完成自动展开（否则页面空着）
const doneOpen = computed(
  () => showDone.value || (!running.value.length && !waiting.value),
)
let timer: number | undefined
let inflight = false

const STYLE: Record<string, { label: string; fg: string; bg: string; icon: string }> = {
  cloud: { label: '云下载', fg: '#1677F8', bg: '#E8F2FF', icon: 'src-cloud' },
  magnet: { label: '磁力', fg: '#7C5CF0', bg: '#F0ECFF', icon: 'link' },
  ed2k: { label: 'ed2k', fg: '#16A34A', bg: '#E6F7EE', icon: 'download' },
}

const STATE_LABEL: Record<string, string> = {
  active: '下载中',
  waiting: '排队中',
  paused: '已暂停',
  error: '出错',
  done: '已完成',
}

function normState(raw: any): Item['state'] {
  const s = String(raw || '').toLowerCase()
  if (s.startsWith('active') || s === 'downloading' || s === 'seeding') return 'active'
  if (s.startsWith('wait') || s === 'queued') return 'waiting'
  if (s.includes('pause')) return 'paused'
  if (s.includes('error') || s.includes('fail')) return 'error'
  if (s.includes('complete') || s === 'done' || s === 'finished') return 'done'
  return 'waiting'
}

function fmtSpeed(n: number) {
  if (!n || n <= 0) return ''
  if (n < 1024) return `${Math.round(n)} B/s`
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB/s`
  return `${(n / 1024 / 1024).toFixed(1)} MB/s`
}

function fmtSize(n: number) {
  if (!n || n <= 0) return ''
  const u = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = n
  let i = 0
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024
    i++
  }
  return `${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${u[i]}`
}

function eta(it: Item) {
  if (!it.speed || it.speed <= 0 || !it.size || it.size <= it.size * it.pct) return ''
  const sec = Math.round((it.size * (1 - it.pct)) / it.speed)
  if (sec <= 0) return ''
  if (sec < 60) return `${sec} 秒`
  if (sec < 3600) return `${Math.floor(sec / 60)} 分钟`
  return `${(sec / 3600).toFixed(1)} 小时`
}

let pending = false

async function load(force = false) {
  if (!force && document.hidden) return
  if (inflight) {
    // 轮询正在跑：别把「刚点完按钮」的那次刷新丢掉，否则要等 4 秒才看到结果
    if (force) pending = true
    return
  }
  inflight = true
  loading.value = items.value.length === 0
  const out: Item[] = []
  let bad = 0
  try {
    const r: any = await api.tasks()
    for (const t of r.tasks || []) {
      const pct = Math.max(0, Math.min(100, Number(t.pct) || 0)) / 100
      out.push({
        kind: t.kind === 'ed2k' ? 'ed2k' : 'magnet',
        id: String(t.id || ''),
        name: t.name || t.id || '未命名',
        pct,
        speed: Number(t.speed) || 0,
        size: Number(t.size) || 0,
        state: pct >= 1 ? 'done' : normState(t.state),
        extra: t.error || '',
      })
    }
  } catch {
    bad++
  }
  try {
    const c: any = await api.cd2OfflineAll()
    for (const x of c.items || []) {
      const st = Number(x.status ?? 0)
      out.push({
        kind: 'cloud',
        id: String(x.hash || ''),
        name: x.name || '未命名',
        pct: Math.max(0, Math.min(100, Number(x.percent) || 0)) / 100,
        speed: 0,
        size: Number(x.size) || 0,
        state: (['waiting', 'active', 'done', 'error', 'paused'][st] || 'waiting') as Item['state'],
        extra: '',
      })
    }
  } catch {
    bad++
  }
  const rank: Record<string, number> = { active: 0, waiting: 1, paused: 2, error: 3, done: 4 }
  out.sort((a, b) => (rank[a.state] - rank[b.state]) || b.pct - a.pct)
  items.value = out
  err.value = bad === 2 ? '任务读不到 · 检查 NAS' : ''
  loading.value = false
  inflight = false
  if (pending) {
    pending = false
    void load(true)
  }
}

// 有任务在下时 4 秒一刷；全闲着就退到 12 秒，别让手机一直空转
function tick() {
  const busy = running.value.length > 0 || waiting.value > 0
  timer = window.setTimeout(async () => {
    await load()
    tick()
  }, busy ? 4000 : 12000)
}

onMounted(async () => {
  await load(true)
  tick()
})
onUnmounted(() => window.clearTimeout(timer))

const counts = computed(() => {
  const m: Record<string, number> = { all: items.value.length }
  for (const k of ['cloud', 'magnet', 'ed2k'] as const) {
    const n = items.value.filter((i) => i.kind === k).length
    if (n) m[k] = n
  }
  return m
})

const shown = computed(() =>
  filter.value === 'all' ? items.value : items.value.filter((i) => i.kind === filter.value),
)

const running = computed(() => items.value.filter((i) => i.state === 'active'))
const waiting = computed(() => items.value.filter((i) => i.state === 'waiting').length)
const speed = computed(() => running.value.reduce((a, i) => a + i.speed, 0))

const summary = computed(() => {
  if (err.value) return err.value
  if (!items.value.length) return '还没有任务'
  const parts: string[] = []
  if (running.value.length) parts.push(`${running.value.length} 个在下`)
  if (speed.value > 0) parts.push(fmtSpeed(speed.value))
  if (waiting.value) parts.push(`${waiting.value} 个排队`)
  if (!running.value.length && !waiting.value) {
    parts.push(`全部完成 · ${items.value.filter((i) => i.state === 'done').length} 个`)
  }
  return parts.join(' · ')
})

const GROUPS: Array<[Item['state'], string]> = [
  ['active', '进行中'],
  ['waiting', '排队中'],
  ['paused', '已暂停'],
  ['error', '出错'],
  ['done', '已完成'],
]

function groupRows(state: Item['state']) {
  return shown.value.filter((i) => i.state === state)
}

function metaOf(it: Item) {
  const s = STYLE[it.kind]
  const parts = [`${s.label} · ${STATE_LABEL[it.state]}`]
  if (it.size > 0) parts.push(fmtSize(it.size))
  if (it.state === 'active' && it.speed > 0) parts.push(fmtSpeed(it.speed))
  if (it.state === 'active' && eta(it)) parts.push(`剩 ${eta(it)}`)
  if (it.extra && (it.state === 'error' || it.state === 'done')) parts.push(it.extra)
  return parts.join(' · ')
}

function colorOf(it: Item) {
  if (it.state === 'done') return '#0E9D78'
  if (it.state === 'error') return '#E45E53'
  if (it.state === 'paused') return '#C78218'
  return STYLE[it.kind].fg
}

async function act(it: Item, what: 'pause' | 'resume' | 'remove') {
  if (busy.value) return
  busy.value = true
  try {
    if (it.kind === 'cloud') {
      if (what !== 'remove') return
      const ok = await confirmBox(
        '删除这个任务？',
        `「${it.name}」会从 115 离线列表移除，已经下到网盘上的文件不动。`,
        '删除',
      )
      if (!ok) return
      await api.cd2OfflineDel(it.id, { deleteFiles: false })
    } else {
      if (what === 'remove') {
        const ok = await confirmBox(
          '删除这个任务？',
          `「${it.name}」会从下载器里移除，NAS 上的文件不动。`,
          '删除',
        )
        if (!ok) return
      }
      await api.taskAct(it.kind, it.id, what)
    }
    props.toast(what === 'remove' ? '已删除' : what === 'pause' ? '已暂停' : '已继续')
    await load(true)
  } catch (e: any) {
    props.toast(`${what === 'remove' ? '删除' : what === 'pause' ? '暂停' : '继续'}失败：${e?.message || e}`)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="dq">
    <div class="dq-inner">
    <header class="dq-head">
      <button class="dq-back" aria-label="返回" @click="props.close()">
        <Ico name="arrow-left" :size="22" />
      </button>
      <b class="dq-title">下载队列</b>
      <button class="dq-refresh" aria-label="刷新" @click="load(true)">
        <Ico name="refresh" :size="19" />
      </button>
    </header>

    <p class="dq-sum">{{ summary }}</p>

    <div v-if="items.length" class="dq-chips">
      <button
        v-for="k in Object.keys(counts)"
        :key="k"
        class="chip"
        :class="{ on: filter === k }"
        @click="filter = k as any"
      >
        {{ k === 'all' ? '全部' : STYLE[k].label }} {{ counts[k] }}
      </button>
    </div>

    <p v-if="loading" class="dq-empty">加载中…</p>
    <template v-else-if="!items.length">
      <div class="dq-empty2">
        <Ico name="download" :size="44" />
        <b>还没有下载任务</b>
        <span>文件页「＋」里加云下载 / 磁力</span>
      </div>
    </template>
    <p v-else-if="!shown.length" class="dq-empty">这个来源没有任务</p>
    <template v-else>
      <template v-for="g in GROUPS" :key="g[0]">
        <!-- 已完成的默认收起，别把正在下的挤下去 -->
        <div v-if="g[0] === 'done' && groupRows('done').length" class="dq-secrow">
          <span class="dq-sec">{{ g[1] }} · {{ groupRows('done').length }}</span>
          <button v-if="running.length || waiting" class="dq-more" @click="showDone = !showDone">
            {{ showDone ? '收起' : '展开' }}
          </button>
        </div>
        <div v-else-if="groupRows(g[0]).length" class="dq-sec">
          {{ g[1] }} · {{ groupRows(g[0]).length }}
        </div>
        <template v-if="g[0] !== 'done' || doneOpen">
        <div v-for="it in groupRows(g[0])" :key="it.kind + it.id" class="dq-card">
          <div class="dq-r1">
            <span class="dq-ico" :style="{ background: STYLE[it.kind].bg, color: STYLE[it.kind].fg }">
              <Ico :name="STYLE[it.kind].icon" :size="18" />
            </span>
            <span class="dq-mid">
              <b class="dq-name">{{ it.name }}</b>
              <i class="dq-meta">{{ metaOf(it) }}</i>
            </span>
            <span class="dq-pct" :style="{ color: colorOf(it) }">
              {{ it.state === 'done' ? '完成' : Math.round(it.pct * 100) + '%' }}
            </span>
          </div>
          <div class="dq-bar">
            <span :style="{ width: (it.pct * 100).toFixed(1) + '%', background: colorOf(it) }" />
          </div>
          <div class="dq-btns">
            <button v-if="it.kind !== 'cloud' && (it.state === 'active' || it.state === 'waiting')" @click="act(it, 'pause')">
              暂停
            </button>
            <button v-if="it.kind !== 'cloud' && it.state === 'paused'" class="primary" @click="act(it, 'resume')">
              继续
            </button>
            <button class="danger" @click="act(it, 'remove')">删除</button>
          </div>
        </div>
        </template>
      </template>
    </template>
    </div>
  </div>
</template>

<style scoped>
.dq {
  display: flex;
  flex-direction: column;
  padding-bottom: 30px;
}

/* 宽屏不要横着一张卡拉到底 */
.dq-inner {
  width: 100%;
  max-width: 780px;
  margin: 0 auto;
}

.dq-head {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 2px 0;
}

.dq-back,
.dq-refresh {
  border: 0;
  background: transparent;
  color: var(--ink, #26364a);
  width: 34px;
  height: 34px;
  display: grid;
  place-items: center;
  padding: 0;
  border-radius: 10px;
}

.dq-refresh {
  color: var(--ink3, #93a3b8);
  margin-left: auto;
}

.dq-back:active,
.dq-refresh:active {
  background: var(--bg2, #eef1f5);
}

.dq-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--ink, #26364a);
  letter-spacing: -0.2px;
}

.dq-sum {
  margin: 2px 0 8px 40px;
  font-size: 12px;
  color: var(--ink3, #93a3b8);
}

.dq-chips {
  display: flex;
  gap: 8px;
  overflow-x: auto;
  padding: 2px 0 8px;
  scrollbar-width: none;
}

.dq-chips::-webkit-scrollbar {
  display: none;
}

.chip {
  flex: none;
  border: 0;
  padding: 6px 12px;
  border-radius: 99px;
  background: var(--surface2, #f2f3f5);
  color: var(--ink2, #5c6b80);
  font-size: 12px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
}

.chip.on {
  background: var(--ac, #1677f8);
  color: #fff;
}

.dq-secrow {
  display: flex;
  align-items: center;
  gap: 8px;
}

.dq-more {
  margin-left: auto;
  border: 0;
  background: none;
  padding: 0 4px;
  color: var(--ac, #1677f8);
  font-family: inherit;
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
}

.dq-sec {
  padding: 10px 4px 8px;
  font-size: 11.5px;
  font-weight: 600;
  color: var(--ink3, #93a3b8);
}

.dq-card {
  background: var(--surface, #fff);
  border-radius: 16px;
  padding: 11px 12px;
  margin-bottom: 8px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
}

.dq-r1 {
  display: flex;
  align-items: flex-start;
  gap: 10px;
}

.dq-ico {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  border-radius: 10px;
  display: grid;
  place-items: center;
}

.dq-mid {
  flex: 1;
  min-width: 0;
}

.dq-name {
  display: block;
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink, #26364a);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.dq-meta {
  display: block;
  margin-top: 3px;
  font-style: normal;
  font-size: 11.5px;
  line-height: 1.4;
  color: var(--ink3, #93a3b8);
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.dq-pct {
  flex: none;
  font-size: 12px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.dq-bar {
  margin: 9px 0 0;
  height: 5px;
  border-radius: 99px;
  background: var(--surface2, #f2f3f5);
  overflow: hidden;
}

.dq-bar span {
  display: block;
  height: 100%;
  border-radius: 99px;
  transition: width 0.3s linear;
}

.dq-btns {
  display: flex;
  gap: 8px;
  margin-top: 9px;
}

.dq-btns button {
  border: 0;
  padding: 6px 12px;
  border-radius: 9px;
  background: var(--surface2, #f2f3f5);
  color: var(--ink2, #5c6b80);
  font-size: 12px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
}

.dq-btns button.primary {
  background: var(--ac, #1677f8);
  color: #fff;
}

.dq-btns button.danger {
  margin-left: auto;
  background: rgba(228, 94, 83, 0.08);
  color: #e45e53;
}

.dq-empty {
  padding: 40px 0;
  text-align: center;
  font-size: 12.5px;
  color: var(--ink3, #93a3b8);
}

.dq-empty2 {
  padding: 70px 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  color: var(--ink3, #93a3b8);
}

.dq-empty2 b {
  font-size: 13px;
  font-weight: 600;
  color: var(--ink2, #5c6b80);
}

.dq-empty2 span {
  font-size: 11.5px;
}
</style>
