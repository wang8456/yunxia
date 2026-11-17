<script setup lang="ts">
/* 图片查看器 —— 1:1 照旧前端 5020（assets/app.js 的 Viewer + theme.css 的 #iv）。

   旧前端的手感要点（别再自己发明）：
   - 横向滑**不跟手**，也不做两图翻页；松手过 45px 直接换，换完就是新图（.iv-img 只在缩放时才有 transform 过渡）
   - 双击居中放大 2.5×（transform-origin: center，不是点哪儿放哪儿）
   - 放大后单指拖动是平移，边界按舞台尺寸 clamp
   - 单击延迟 270ms 切 chrome（双击时把这次单击取消掉）
   - 顶栏：关闭 / 名称 / 缩放百分比 / n/total / 旋转 / 新标签 / 下载
   - 底栏：n / total、大小 · 日期、一行提示、拖动条（input 只更新文字，change 才换图）
*/
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import Ico from '../components/Ico.vue'
import { api, humanSize, type Entry } from '../api'

const props = defineProps<{
  entry: Entry
  source?: string
  gallery?: Entry[]
  index?: number
  /** 直接给地址（对话里的图走这条，不经文件表签名） */
  direct?: string[]
}>()
const emit = defineEmits<{ close: [] }>()

const pics = computed(() => (props.gallery && props.gallery.length ? props.gallery : [props.entry]))
const idx = ref(props.index ?? 0)
const cur = computed(() => pics.value[idx.value] || props.entry)

const url = ref('')
const scale = ref(1)
const tx = ref(0)
const ty = ref(0)
const rot = ref(0)
const hint = ref('加载中…')
const failed = ref(false)
const chromeOn = ref(true)
const stageEl = ref<HTMLElement | null>(null)
const imgEl = ref<HTMLImageElement | null>(null)

/* 拖动条的即时文字：input 时只改这个，别一拖就疯狂换图 */
const posText = ref('')
const rangeVal = ref(0)

const zoomText = computed(() => Math.round(scale.value * 100) + '%')
const metaText = computed(() => {
  const e = cur.value
  const parts: string[] = []
  if (e.size && e.size > 0) parts.push(humanSize(e.size))
  if (e.mtime && e.mtime > 0) parts.push(dayOf(e.mtime))
  return parts.join(' · ')
})

function pad(x: number) {
  return x < 10 ? '0' + x : String(x)
}

function dayOf(ms?: number) {
  if (!ms) return '—'
  const d = new Date(ms)
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function clamp() {
  const s = stageEl.value
  if (!s) return
  const mx = Math.max(0, (s.clientWidth * scale.value - s.clientWidth) / 2)
  const my = Math.max(0, (s.clientHeight * scale.value - s.clientHeight) / 2)
  tx.value = Math.max(-mx, Math.min(mx, tx.value))
  ty.value = Math.max(-my, Math.min(my, ty.value))
}

async function show(k: number) {
  const list = pics.value
  if (!list.length) return
  k = Math.max(0, Math.min(list.length - 1, k))
  idx.value = k
  scale.value = 1
  tx.value = 0
  ty.value = 0
  rot.value = 0
  failed.value = false
  hint.value = '加载中…'
  const e = list[k]
  const direct = props.direct && props.direct[k]
  if (direct) {
    url.value = direct
    posText.value = `${k + 1} / ${list.length}`
    rangeVal.value = k
    return
  }
  try {
    const r = await api.link(props.source || '', e.path)
    if (idx.value !== k) return
    url.value = api.absolute(r.url)
  } catch (err) {
    url.value = ''
    hint.value = '图片加载失败'
    failed.value = true
    return
  }
  posText.value = `${k + 1} / ${list.length}`
  rangeVal.value = k
  // 预取前后两张，翻页秒开（旧前端就是 next / prev / next+2）
  for (const j of [k + 1, k - 1, k + 2]) {
    const n = list[j]
    if (!n) continue
    api
      .link(props.source || '', n.path)
      .then((rr) => {
        const im = new Image()
        im.src = api.absolute(rr.url)
      })
      .catch(() => {})
  }
}

function next() {
  if (idx.value < pics.value.length - 1) show(idx.value + 1)
}

function prev() {
  if (idx.value > 0) show(idx.value - 1)
}

function rotate() {
  rot.value = (rot.value + 90) % 360
  scale.value = 1
  tx.value = 0
  ty.value = 0
}

function openTab() {
  if (url.value) window.open(url.value, '_blank')
}

/* 旧前端：input 只动文字，change 才换图 */
function onRangeInput(ev: Event) {
  const v = Number((ev.target as HTMLInputElement).value)
  posText.value = `${v + 1} / ${pics.value.length}`
}

function onRangeChange(ev: Event) {
  show(Number((ev.target as HTMLInputElement).value))
}

/* ── 手势：照旧前端的 touchstart / touchmove / touchend ── */
const ptrs = new Map<number, { x: number; y: number }>()
let g: {
  pinch: boolean
  x: number
  y: number
  tx: number
  ty: number
  moved: boolean
  t: number
  d: number
  scale: number
} | null = null
let lastTap = 0
let tapTimer: number | undefined

function dist() {
  const a = [...ptrs.values()]
  if (a.length < 2) return 0
  return Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y)
}

function onDown(e: PointerEvent) {
  ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY })
  if (ptrs.size === 1) {
    g = {
      pinch: false,
      x: e.clientX,
      y: e.clientY,
      tx: tx.value,
      ty: ty.value,
      moved: false,
      t: Date.now(),
      d: 0,
      scale: scale.value,
    }
  } else if (ptrs.size === 2) {
    g = {
      pinch: true,
      x: e.clientX,
      y: e.clientY,
      tx: tx.value,
      ty: ty.value,
      moved: true,
      t: Date.now(),
      d: dist(),
      scale: scale.value,
    }
  }
}

function onMove(e: PointerEvent) {
  if (!ptrs.has(e.pointerId)) return
  ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY })
  if (!g) return

  if (g.pinch && ptrs.size === 2) {
    scale.value = Math.min(6, Math.max(1, (g.scale * dist()) / (g.d || 1)))
    return
  }
  if (ptrs.size !== 1) return

  const dx = e.clientX - g.x
  const dy = e.clientY - g.y
  if (Math.abs(dx) > 6 || Math.abs(dy) > 6) g.moved = true
  if (scale.value > 1) {
    tx.value = g.tx + dx
    ty.value = g.ty + dy
    clamp()
  }
}

function onUp(e: PointerEvent) {
  ptrs.delete(e.pointerId)
  if (!g) return
  const gg = g

  if (gg.pinch) {
    if (ptrs.size < 2) {
      g = null
      if (scale.value <= 1.03) {
        scale.value = 1
        tx.value = 0
        ty.value = 0
      }
      clamp()
    }
    return
  }
  if (ptrs.size > 0) return
  g = null

  const dx = e.clientX - gg.x
  const dy = e.clientY - gg.y
  // 快速轻点 = 单击（320ms 内且没位移）
  if (!gg.moved && Date.now() - gg.t < 320) {
    tap()
    return
  }
  if (scale.value > 1) {
    clamp()
    return
  }
  if (dy > 90 && Math.abs(dx) < 70) {
    emit('close')
    return
  }
  if (Math.abs(dx) > 45 && Math.abs(dy) < 70) {
    if (dx < 0) next()
    else prev()
  }
}

/* 双击 = 居中 2.5×；单击 = 270ms 后切 chrome（双击时取消这次单击） */
function tap() {
  const now = Date.now()
  if (now - lastTap < 300) {
    lastTap = 0
    window.clearTimeout(tapTimer)
    if (scale.value > 1) {
      scale.value = 1
      tx.value = 0
      ty.value = 0
    } else {
      scale.value = 2.5
    }
    clamp()
    return
  }
  lastTap = now
  tapTimer = window.setTimeout(() => (chromeOn.value = !chromeOn.value), 270)
}

function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape') emit('close')
  else if (e.key === 'ArrowRight') next()
  else if (e.key === 'ArrowLeft') prev()
  else if (e.key === '+' || e.key === '=') {
    scale.value = Math.min(6, scale.value + 0.5)
    clamp()
  } else if (e.key === '-' || e.key === '_') {
    scale.value = Math.max(1, scale.value - 0.5)
    clamp()
  }
}

function onLoaded() {
  hint.value = ''
  failed.value = false
}

function onError() {
  hint.value = '图片加载失败'
  failed.value = true
}

function retry() {
  const u = url.value
  failed.value = false
  hint.value = '加载中…'
  url.value = ''
  requestAnimationFrame(() => (url.value = u))
}

const imgStyle = computed(() => ({
  transform: `translate(${tx.value}px, ${ty.value}px) scale(${scale.value}) rotate(${rot.value}deg)`,
  transition: scale.value > 1 ? 'none' : undefined,
}))

watch(
  () => props.entry,
  () => show(props.index ?? 0),
  { immediate: false },
)

onMounted(() => {
  window.addEventListener('keydown', onKey)
  show(props.index ?? 0)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKey)
  window.clearTimeout(tapTimer)
})
</script>

<template>
  <div class="iv" :class="{ zoomed: scale > 1, 'chrome-hidden': !chromeOn }">
    <div class="iv-top">
      <button class="iv-btn sm" title="关闭" @click="emit('close')"><Ico name="close" :size="19" /></button>
      <div class="iv-name">{{ cur.name }}</div>
      <span v-show="scale > 1.02" class="iv-zoom">{{ zoomText }}</span>
      <span class="iv-count">{{ idx + 1 }}/{{ pics.length }}</span>
      <button class="iv-btn sm" title="旋转 90°" @click="rotate"><Ico name="rotate" :size="19" /></button>
      <button class="iv-btn sm" title="在新标签打开原图" @click="openTab"><Ico name="open-new" :size="19" /></button>
      <a class="iv-btn sm" :href="url" :download="cur.name" title="保存原图"><Ico name="download" :size="19" /></a>
    </div>

    <div
      ref="stageEl"
      class="iv-stage"
      @pointerdown="onDown"
      @pointermove="onMove"
      @pointerup="onUp"
      @pointercancel="onUp"
    >
      <button class="iv-btn iv-nav iv-prev" :disabled="idx === 0" title="上一张" @click.stop="prev">
        <Ico name="arrow-left" :size="26" />
      </button>
      <img
        v-if="url"
        ref="imgEl"
        class="iv-img"
        :src="url"
        :alt="cur.name"
        :style="imgStyle"
        @load="onLoaded"
        @error="onError"
      />
      <div v-if="hint" class="iv-hint">
        {{ hint }}
        <br v-if="failed" />
        <button v-if="failed" class="iv-retry" @click.stop="retry">重试</button>
      </div>
      <button
        class="iv-btn iv-nav iv-next"
        :disabled="idx === pics.length - 1"
        title="下一张"
        @click.stop="next"
      >
        <Ico name="arrow-right" :size="26" />
      </button>
    </div>

    <div class="iv-bottom">
      <div class="iv-row">
        <span class="iv-pos">{{ posText }}</span>
        <span class="iv-meta">{{ metaText }}</span>
      </div>
      <div class="iv-row iv-tips">
        <span>左右滑动切换 · 双击放大 · 双指缩放 · 下滑关闭</span>
      </div>
      <input
        class="iv-range"
        type="range"
        min="0"
        :max="pics.length - 1"
        step="1"
        :value="rangeVal"
        @input="onRangeInput"
        @change="onRangeChange"
      />
    </div>
  </div>
</template>

<style scoped>
.iv {
  position: fixed;
  inset: 0;
  z-index: 99999;
  background: #000;
  display: flex;
  flex-direction: column;
  overscroll-behavior: contain;
  touch-action: none;
  user-select: none;
}

.iv-top {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 4;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: calc(env(safe-area-inset-top, 0px) + 9px) 11px 14px;
  background: linear-gradient(rgba(0, 0, 0, 0.8), rgba(0, 0, 0, 0.42) 60%, rgba(0, 0, 0, 0));
  transition: opacity 0.22s ease;
}

.iv-name {
  flex: 1 1 auto;
  min-width: 0;
  text-align: center;
  color: #fff;
  font-size: 13.5px;
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.iv-count {
  flex: 0 0 auto;
  color: #e6e6ea;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
  background: rgba(255, 255, 255, 0.16);
  padding: 3px 10px;
  border-radius: 999px;
}

.iv-zoom {
  flex: 0 0 auto;
  color: #fff;
  font-size: 11.5px;
  font-variant-numeric: tabular-nums;
  background: rgba(255, 255, 255, 0.2);
  padding: 3px 8px;
  border-radius: 999px;
}

.iv-btn {
  flex: 0 0 auto;
  width: 42px;
  height: 42px;
  border: 0;
  border-radius: 13px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(255, 255, 255, 0.14);
  color: #fff;
  line-height: 1;
  cursor: pointer;
  text-decoration: none;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.15s;
}

.iv-btn:active {
  background: rgba(255, 255, 255, 0.3);
}

.iv-btn.sm {
  min-width: 34px;
  height: 34px;
  width: 34px;
  border-radius: 11px;
}

.iv-stage {
  position: relative;
  flex: 1 1 auto;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
}

.iv-img {
  max-width: 100%;
  max-height: 100%;
  display: block;
  margin: auto;
  transform-origin: center center;
  will-change: transform;
  transition: transform 0.18s cubic-bezier(0.22, 0.61, 0.36, 1);
  -webkit-user-drag: none;
}

.iv-hint {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  color: #8e8e93;
  font-size: 13px;
  text-align: center;
  line-height: 1.7;
}

.iv-nav {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  z-index: 3;
  width: 46px;
  height: 46px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.13);
  backdrop-filter: blur(6px);
}

.iv-prev {
  left: 10px;
}

.iv-next {
  right: 10px;
}

.iv-nav[disabled] {
  opacity: 0.22;
  pointer-events: none;
}

.iv-bottom {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 4;
  padding: 18px 16px calc(env(safe-area-inset-bottom, 0px) + 12px);
  background: linear-gradient(rgba(0, 0, 0, 0), rgba(0, 0, 0, 0.7));
  transition: opacity 0.22s ease;
}

.iv-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 9px;
  color: #cfcfd4;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}

.iv-meta {
  color: #b9b9c0;
  font-size: 11.5px;
  font-variant-numeric: tabular-nums;
}

.iv-tips {
  color: #8e8e93;
  font-size: 11.5px;
  margin-bottom: 2px;
}

.iv-range {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: 4px;
  margin: 0;
  border-radius: 99px;
  background: rgba(255, 255, 255, 0.28);
  outline: none;
}

.iv-range::-webkit-slider-thumb {
  -webkit-appearance: none;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 5px rgba(0, 0, 0, 0.55);
}

.iv-range::-moz-range-thumb {
  width: 22px;
  height: 22px;
  border: 0;
  border-radius: 50%;
  background: #fff;
}

.iv-retry {
  margin-top: 10px;
  border: 1px solid rgba(255, 255, 255, 0.27);
  background: transparent;
  color: #fff;
  border-radius: 11px;
  padding: 7px 18px;
  font-size: 13px;
}

.chrome-hidden .iv-top,
.chrome-hidden .iv-bottom,
.chrome-hidden .iv-nav {
  opacity: 0;
  pointer-events: none;
}

.chrome-hidden .iv-top *,
.chrome-hidden .iv-bottom *,
.chrome-hidden .iv-nav * {
  pointer-events: none;
}

@media (min-width: 769px) {
  .iv-nav {
    width: 54px;
    height: 54px;
  }
}
</style>
