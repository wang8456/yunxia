<script setup lang="ts">
/* 播放器：照 App 的 player_page.dart 重做
   · 顶部：返回 + 文件名 + 大小 + 下载 + 关闭
   · 底部一层：进度条 + 时间 +（-10s / 播放暂停 / +10s / 音轨 / 播放列表 / 倍速 / 全屏）
   · 点画面切换控件；长按画面 3× 快放 */
import Ico from '../components/Ico.vue'
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, humanSize, type Entry } from '../api'

const props = defineProps<{ entry: Entry; source?: string; direct?: string; gallery?: Entry[]; index?: number }>()
const emit = defineEmits<{ close: [] }>()

const url = ref('')
const loading = ref(true)
const error = ref('')
const zoom = ref(1)
const isVideo = computed(() => !!props.direct || props.entry.kind === 'video')
const pics = computed(() => (props.gallery && props.gallery.length ? props.gallery : [props.entry]))
const gi = ref(props.index ?? 0)
const curEntry = computed(() => pics.value[gi.value] || props.entry)
const multi = computed(() => !isVideo.value && pics.value.length > 1)
/* 同一目录的其它视频 = 播放列表（App 播放器底栏的「播放列表」） */
const plist = computed(() => (isVideo.value && props.gallery && props.gallery.length > 1 ? props.gallery : []))

async function stepPic(d: number) {
  const n = pics.value.length
  if (!n) return
  await goto((gi.value + d + n) % n)
}

const videoEl = ref<HTMLVideoElement | null>(null)

/* ---- 播放状态 ---- */
const playing = ref(false)
const cur = ref(0)
const dur = ref(0)
const ctrl = ref(true)
let hideTimer: number | undefined

const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
const speed = ref(Number(localStorage.getItem('mfm_rate') || localStorage.getItem('yunxia.speed') || 1))
const sheet = ref<'none' | 'speed' | 'audio' | 'list' | 'more'>('none')
const jumpHint = ref('')
const resumed = ref('')
const resumePos = ref(0)   // 点胶囊时要用

function applySpeed() {
  const v = videoEl.value
  if (v) v.playbackRate = speed.value
}
function setSpeed(r: number) {
  speed.value = r
  localStorage.setItem('yunxia.speed', String(r))
  applySpeed()
  sheet.value = 'none'
}

function togglePlay() {
  const v = videoEl.value
  if (!v) return
  if (v.paused) v.play().catch(() => {})
  else v.pause()
  showCtrl()
}

let hintTimer: number | undefined
function jump(sec: number) {
  const v = videoEl.value
  if (!v) return
  v.currentTime = Math.max(0, Math.min(v.duration || 0, v.currentTime + sec))
  jumpHint.value = sec > 0 ? `+${sec} 秒` : `${sec} 秒`
  window.clearTimeout(hintTimer)
  hintTimer = window.setTimeout(() => (jumpHint.value = ''), 700)
  showCtrl()
}

function showCtrl() {
  ctrl.value = true
  window.clearTimeout(hideTimer)
  hideTimer = window.setTimeout(() => {
    if (playing.value && sheet.value === 'none') ctrl.value = false
  }, 3200)
}

function seekTo(e: Event) {
  const v = videoEl.value
  const t = Number((e.target as HTMLInputElement).value)
  if (v && isFinite(t)) v.currentTime = t
}

/* ---- 长按 3× ---- */
let pressTimer: number | undefined
let boosted = false
function pressStart() {
  window.clearTimeout(pressTimer)
  pressTimer = window.setTimeout(() => {
    const v = videoEl.value
    if (v && !v.paused) {
      boosted = true
      v.playbackRate = 3
      jumpHint.value = '3× 快放'
    }
  }, 380)
}
function pressEnd() {
  window.clearTimeout(pressTimer)
  if (boosted) {
    boosted = false
    applySpeed()
    jumpHint.value = ''
  }
}

/* ---- 进度 / 字幕 / 续播 ---- */
let lastSave = 0
function savePos(force = false) {
  const v = videoEl.value
  if (!v || !isVideo.value || !v.duration) return
  const now = Date.now()
  if (!force && now - lastSave < 5000) return
  lastSave = now
  api.playSave(props.entry.path, v.currentTime, v.duration, props.entry.name).catch(() => {})
}

function onTime() {
  const v = videoEl.value
  if (!v) return
  cur.value = v.currentTime
  dur.value = v.duration || 0
  savePos()
}

async function resume() {
  if (!isVideo.value) return
  const v = videoEl.value
  if (!v) return
  try {
    const r = await api.playOne(props.entry.path)
    if (r.found && r.pos > 10 && (!r.dur || r.pos < r.dur - 30)) {
      v.currentTime = r.pos
      resumePos.value = r.pos
      const m = Math.floor(r.pos / 60)
      const s = Math.floor(r.pos % 60)
      resumed.value = `已从 ${m}:${String(s).padStart(2, '0')} 继续`
      setTimeout(() => (resumed.value = ''), 4200)
    }
  } catch {
    /* 没进度就正常播 */
  }
}

/** 点「已从 X 继续」胶囊：真的跳回去并继续播（浏览器偶尔会丢掉 currentTime 赋值） */
function jumpResume() {
  const v = videoEl.value
  if (!v || !resumePos.value) return
  v.currentTime = resumePos.value
  v.play().catch(() => {})
  resumed.value = ''
}


async function load() {
  if (props.direct) {
    url.value = props.direct
    loading.value = false
    return
  }
  // 图片已经在缓存里就别再要一次签名：翻页提交时必须一帧内换完
  if (curEntry.value.kind === 'image') {
    const hit = imgCache.get(curEntry.value.path)
    if (hit) {
      url.value = hit
      imgSrc.value = hit
      loadPct.value = null
      imgErr.value = false
      loading.value = false
      return
    }
  }
  try {
    const r = await api.link(props.source || '', curEntry.value.path)
    url.value = api.absolute(r.url)
    loading.value = false
    if (curEntry.value.kind === 'image') {
      zoom.value = 1
      panX.value = 0
      panY.value = 0
      origin.value = '50% 50%'
      loadImg(url.value).then(() => prefetch())
    }
  } catch (e) {
    error.value = `${e}`
    loading.value = false
  }
}

function mmss(t: number) {
  const x = Math.max(0, Math.floor(t || 0))
  const h = Math.floor(x / 3600)
  const m = Math.floor((x % 3600) / 60)
  const s = x % 60
  return `${h ? h + ':' : ''}${h ? String(m).padStart(2, '0') : m}:${String(s).padStart(2, '0')}`
}

/* ───────── 看图：照 App 的 image_viewer_page 全套 ─────────
   单击切 chrome、双击 2.5× 以点击处为中心、捏合 1~5×、
   单指：未放大时轴锁（横切图/竖关窗），放大后是平移。 */
const dragY = ref(0)
const dragDx = ref(0)
const noTrans = ref(false)
const chrome = ref(true)
const loadPct = ref<number | null>(null)
const imgErr = ref(false)
const imgSrc = ref('')
const panX = ref(0)
const panY = ref(0)
const origin = ref('50% 50%')

/* 翻页图层：拖的时候把邻居也画出来，松手是「滑过去」而不是先弹回再切换 */
const vw = ref(typeof window === 'undefined' ? 390 : window.innerWidth)
let commitTimer: number | undefined

function neighbor(d: number) {
  const i = gi.value + d
  return i >= 0 && i < pics.value.length ? pics.value[i] : null
}


const ptrs = new Map<number, { x: number; y: number }>()
let pinchFrom = 0
let pinchZoom = 1
let dragFromY = 0
let dragFromX = 0
let lastX = 0
let lastY = 0
let dragOn = false
let moved = false

function dist2() {
  const a = [...ptrs.values()]
  return Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y)
}

function onStageClick() {
  if (isVideo.value || moved) return
  chrome.value = !chrome.value
}

function onDbl(e: MouseEvent) {
  if (isVideo.value) {
    // App：双击屏幕 = 暂停/继续，不切横竖屏
    togglePlay()
    return
  }
  if (zoom.value > 1.05) {
    zoom.value = 1
    panX.value = 0
    panY.value = 0
    origin.value = '50% 50%'
  } else {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
    origin.value = `${(((e.clientX - r.left) / r.width) * 100).toFixed(1)}% ${(((e.clientY - r.top) / r.height) * 100).toFixed(1)}%`
    zoom.value = 2.5
  }
  chrome.value = true
}

/* 签名直链 + 已下载字节都缓存起来：App 里 _goto 命中缓存是瞬切，
   网页也要做到滑过去不转圈。 */
const imgCache = new Map<string, string>()
const urlCache = new Map<string, string>()
const inflight = new Set<string>()

async function blobOf(u: string, path: string, onPct?: (p: number) => void) {
  if (imgCache.has(path)) return imgCache.get(path)!
  const res = await fetch(u)
  if (!res.ok) throw new Error(String(res.status))
  const total = Number(res.headers.get('content-length') || 0)
  const reader = res.body?.getReader()
  if (!reader) {
    imgCache.set(path, u)
    return u
  }
  const chunks: BlobPart[] = []
  let got = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (value) {
      chunks.push(value as BlobPart)
      got += value.length
      if (total && onPct) onPct(Math.min(99, Math.round((got / total) * 100)))
    }
  }
  const obj = URL.createObjectURL(new Blob(chunks))
  imgCache.set(path, obj)
  return obj
}

/* 预取前后各两张：签名地址 + 图片字节都先备好，滑过去直接出图 */
async function prefetch() {
  if (isVideo.value) return
  const src = props.source || ''
  for (const d of [-1, 1, 2, -2]) {
    const i = gi.value + d
    if (i < 0 || i >= pics.value.length) continue
    const e = pics.value[i]
    if (imgCache.has(e.path) || inflight.has(e.path)) continue
    inflight.add(e.path)
    try {
      let u = urlCache.get(e.path)
      if (!u) {
        const r = await api.link(src, e.path)
        u = api.absolute(r.url)
        urlCache.set(e.path, u)
      }
      await blobOf(u, e.path)
    } catch {
      /* 预取失败不影响当前图 */
    } finally {
      inflight.delete(e.path)
    }
  }
}

/* App 里换图是：setState 换 src 同时把 _dragX 归零，
   AnimatedContainer 于是让**新图**从刚才的偏移滑回正中（Shape.base 220ms）。
   这里 1:1 复刻：先把新图按旧偏移摆好，下一帧归零。 */
async function slideTo(d: 1 | -1, from: number) {
  const target = gi.value + d
  zoom.value = 1
  panX.value = 0
  panY.value = 0
  origin.value = '50% 50%'
  gi.value = target
  noTrans.value = true
  dragDx.value = from
  await load()
  await new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r())))
  noTrans.value = false
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  dragDx.value = 0
  chrome.value = true
  prefetch()
}

/* 切到第 i 张：左右滑、两侧箭头、底部拖动条都走这里（App 的 _goto） */
async function goto(i: number) {
  if (isVideo.value) return
  if (i < 0 || i >= pics.value.length) return
  if (i === gi.value && imgSrc.value) return
  gi.value = i
  zoom.value = 1
  panX.value = 0
  panY.value = 0
  origin.value = '50% 50%'
  chrome.value = true
  await load()
  prefetch()
}

function onRange(ev: Event) {
  const v = Number((ev.target as HTMLInputElement).value)
  goto(v)
}

/* 图片按字节流加载：能报百分比，也能在失败时给出「图片加载失败」 */
async function loadImg(u: string) {
  const path = curEntry.value.path
  imgErr.value = false
  const hit = imgCache.get(path)
  if (hit) {
    imgSrc.value = hit
    loadPct.value = null
    return
  }
  imgSrc.value = ''
  loadPct.value = 0
  try {
    const obj = await blobOf(u, path, (p) => (loadPct.value = p))
    imgSrc.value = obj
  } catch {
    imgSrc.value = u
  } finally {
    loadPct.value = null
  }
}

/* ⋯ 菜单：App 播放器只有两项 —— 画中画 / 从头播放 */
async function togglePip() {
  const v = videoEl.value
  if (!v) return
  sheet.value = 'none'
  try {
    if ((document as any).pictureInPictureElement) await (document as any).exitPictureInPicture()
    else if ((v as any).requestPictureInPicture) await (v as any).requestPictureInPicture()
    else jumpHint.value = '这版浏览器不支持画中画'
  } catch {
    jumpHint.value = '画中画被拦了'
  }
  window.clearTimeout(hintTimer)
  hintTimer = window.setTimeout(() => (jumpHint.value = ''), 1600)
}

function fromStart() {
  const v = videoEl.value
  if (v) v.currentTime = 0
  sheet.value = 'none'
  jumpHint.value = '从头播放'
  window.clearTimeout(hintTimer)
  hintTimer = window.setTimeout(() => (jumpHint.value = ''), 900)
}

/* 视频手势：左右滑快进、右侧上下滑音量（App 的 player_page） */
let gx0 = 0
let gy0 = 0
let gOn = false
let gMode: '' | 'seek' | 'vol' = ''
let gVol = 1
let lpTimer: number | undefined
let lpFrom = 1
let lpFired = false
let gTime = 0

function pd(e: PointerEvent) {
  if (isVideo.value) {
    gOn = true
    gx0 = e.clientX
    gy0 = e.clientY
    gMode = ''
    gVol = videoEl.value?.volume ?? 1
    gTime = videoEl.value?.currentTime ?? 0
    lpFrom = videoEl.value?.playbackRate ?? 1
    lpFired = false
    window.clearTimeout(lpTimer)
    lpTimer = window.setTimeout(() => {
      const v = videoEl.value
      if (!v || !gOn) return
      lpFired = true
      const r = Number(localStorage.getItem('mfm_lp_rate') || 3)
      v.playbackRate = r
      jumpHint.value = `长按加速 ${r}×`
    }, 400)
    return
  }
  ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY })
  if (ptrs.size === 2) {
    pinchFrom = dist2()
    pinchZoom = zoom.value
    dragOn = false
    return
  }
  if (zoom.value > 1.05) {
    dragOn = true
    moved = false
    lastX = e.clientX
    lastY = e.clientY
    return
  }
  dragOn = true
  moved = false
  dragFromX = e.clientX
  dragFromY = e.clientY
}

function pm(e: PointerEvent) {
  if (isVideo.value) {
    if (!gOn) return
    const dx = e.clientX - gx0
    const dy = e.clientY - gy0
    if (Math.abs(dx) > 8 || Math.abs(dy) > 8) window.clearTimeout(lpTimer)
    if (!gMode && (Math.abs(dx) > 14 || Math.abs(dy) > 14)) {
      gMode = Math.abs(dx) > Math.abs(dy) ? 'seek' : 'vol'
    }
    if (gMode === 'seek') {
      const swk = Number(localStorage.getItem('mfm_sw_k') || 1)
      const sec = Math.round((dx / 8) * swk)
      jumpHint.value = `${sec > 0 ? '+' : ''}${sec} 秒`
    } else if (gMode === 'vol') {
      // App 的口径：只有右半边竖滑才调音量，左半边不动
      if (gx0 < window.innerWidth / 2) return
      const v = Math.min(1, Math.max(0, gVol - dy / 240))
      if (videoEl.value) videoEl.value.volume = v
      jumpHint.value = `音量 ${Math.round(v * 100)}%`
    }
    return
  }
  if (!ptrs.has(e.pointerId)) return
  ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY })

  if (ptrs.size === 2 && pinchFrom) {
    zoom.value = Math.min(5, Math.max(1, (pinchZoom * dist2()) / pinchFrom))
    if (zoom.value > 1.05) chrome.value = true
    return
  }
  if (!dragOn) return

  if (zoom.value > 1.05) {
    panX.value += e.clientX - lastX
    panY.value += e.clientY - lastY
    lastX = e.clientX
    lastY = e.clientY
    moved = true
    return
  }

  const dx = e.clientX - dragFromX
  const dy = e.clientY - dragFromY
  if (Math.abs(dx) > 6 || Math.abs(dy) > 6) moved = true
  // 轴锁：横的占两成以上就只横着拖，竖的相反（App 用 1.2 的比）
  if (Math.abs(dx) > Math.abs(dy) * 1.2) {
    dragDx.value = dx
    dragY.value = 0
  } else if (Math.abs(dy) > Math.abs(dx) * 1.2) {
    dragY.value = dy
    dragDx.value = 0
  }
}

function pu(e?: PointerEvent) {
  if (isVideo.value) {
    if (!gOn) return
    gOn = false
    window.clearTimeout(lpTimer)
    if (lpFired && videoEl.value) {
      videoEl.value.playbackRate = lpFrom
      lpFired = false
      jumpHint.value = ''
    }
    if (gMode === 'seek' && e) {
      const swk = Number(localStorage.getItem('mfm_sw_k') || 1)
      const sec = Math.round(((e.clientX - gx0) / 8) * swk)
      if (sec) {
        const v = videoEl.value
        if (v) v.currentTime = Math.max(0, Math.min(v.duration || 0, gTime + sec))
      }
    }
    gMode = ''
    window.clearTimeout(hintTimer)
    hintTimer = window.setTimeout(() => (jumpHint.value = ''), 700)
    return
  }
  if (e) ptrs.delete(e.pointerId)
  if (ptrs.size < 2) pinchFrom = 0
  if (!dragOn) return
  dragOn = false

  if (zoom.value <= 1.05) {
    const dx = dragDx.value
    const dy = dragY.value
    dragY.value = 0
    dragDx.value = 0
    // 手势收尾：竖向够长就关、横向够长就换图（阈值照 App：110 / 45）
    if (Math.abs(dy) > 110 && Math.abs(dx) < 80) {
      emit('close')
      return
    }
    if (Math.abs(dx) > 45 && Math.abs(dy) < 70 && multi.value) {
      const d: 1 | -1 = dx < 0 ? 1 : -1
      if (neighbor(d)) {
        slideTo(d, dx)
        return
      }
    }
  } else {
    // 放大后松手：稍微拉回视野，别把图拖出屏幕
    const lim = 240
    panX.value = Math.max(-lim, Math.min(lim, panX.value))
    panY.value = Math.max(-lim, Math.min(lim, panY.value))
  }
}

function onWheel(e: WheelEvent) {
  if (isVideo.value) return
  e.preventDefault()
  zoom.value = Math.min(5, Math.max(1, zoom.value - e.deltaY * 0.0015))
}

function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape') emit('close')
  if (e.key === ' ' && isVideo.value) {
    e.preventDefault()
    togglePlay()
  }
  if (e.key === 'ArrowLeft' && isVideo.value) jump(-10)
  if (e.key === 'ArrowRight' && isVideo.value) jump(10)
}

function save() {
  const a = document.createElement('a')
  a.href = url.value
  a.download = props.entry.name
  a.click()
}

function fullscreen() {
  const el = videoEl.value?.parentElement
  if (document.fullscreenElement) document.exitFullscreen()
  else el?.requestFullscreen?.()
}

onMounted(() => {
  load()
  window.addEventListener('keydown', onKey)
  document.body.style.overflow = 'hidden'
})
function onResize() {
  vw.value = window.innerWidth
}

onMounted(() => {
  window.addEventListener('resize', onResize)
})

onUnmounted(() => {
  window.clearTimeout(hintTimer)
  window.clearTimeout(hideTimer)
  window.clearTimeout(pressTimer)
  window.clearTimeout(lpTimer)
  window.removeEventListener('resize', onResize)
  window.clearTimeout(commitTimer)
  for (const u of imgCache.values()) {
    if (u.startsWith('blob:')) URL.revokeObjectURL(u)
  }
  imgCache.clear()
  urlCache.clear()
  savePos(true)
  window.removeEventListener('keydown', onKey)
  document.body.style.overflow = ''
})
</script>

<template>
  <div class="ov" :class="{ clean: !isVideo && !chrome }">
    <div class="bar">
      <button class="iv-btn" title="返回" @click="emit('close')"><Ico name="arrow-left" :size="19" /></button>
      <span class="title">{{ curEntry.name }}</span>
      <span v-if="plist.length > 1" class="ep-pill">{{ gi + 1 }}/{{ plist.length }}</span>
      <span v-if="multi" class="iv-pill">{{ gi + 1 }}/{{ pics.length }}</span>
      <button class="iv-btn" title="存到本机" @click="save"><Ico name="download" :size="19" /></button>
    </div>

    <div class="stage" @wheel="onWheel" @dblclick="onDbl" @click="onStageClick" @pointerdown="pd" @pointermove="pm" @pointerup="pu" @pointercancel="pu">
      <p v-if="loading" class="hint">加载中…</p>
      <p v-else-if="error" class="hint">{{ error }}</p>

      <div v-else-if="isVideo" class="vwrap" @click="ctrl = !ctrl; showCtrl()">
        <video
          ref="videoEl"
          :src="url"
          autoplay
          playsinline
          class="video"
          @timeupdate="onTime"
          @seeked="onTime"
          @loadedmetadata="(applySpeed(), resume(), onTime())"
          @play="playing = true; showCtrl()"
          @pause="playing = false; ctrl = true"
          @pointerdown="pressStart"
          @pointerup="pressEnd"
          @pointerleave="pressEnd"
        ></video>

        <div v-if="resumed" class="resume-pill" @click.stop="jumpResume">{{ resumed }}</div>
        <div v-if="jumpHint" class="jumphint">{{ jumpHint }}</div>

        <transition name="fade">
          <div v-if="ctrl" class="ctl" @click.stop>
            <div class="seek">
              <input class="range" type="range" min="0" :max="dur || 0" step="0.1" :value="cur" @input="seekTo" />
            </div>
            <div class="times">
              <span>{{ mmss(cur) }}</span>
              <span>{{ mmss(dur) }}</span>
            </div>
            <div class="btns">
              <button class="pbtn" title="后退 10 秒" @click="jump(-10)"><Ico name="back10" :size="22" /></button>
              <button class="pbtn big" @click="togglePlay">
                <Ico :name="playing ? 'pause' : 'play'" :size="26" />
              </button>
              <button class="pbtn" title="前进 10 秒" @click="jump(10)"><Ico name="fwd10" :size="22" /></button>
              <button class="pbtn" title="音轨" @click="sheet = 'audio'"><Ico name="volume" :size="22" /></button>
              <button v-if="plist.length" class="pbtn" title="播放列表" @click="sheet = 'list'">
                <Ico name="playlist" :size="22" />
              </button>
              <button class="pbtn text" title="倍速" @click="sheet = 'speed'">{{ speed }}×</button>
              <button class="pbtn" title="全屏" @click="fullscreen"><Ico name="fullscreen" :size="22" /></button>
              <button class="pbtn" title="更多" @click="sheet = 'more'"><Ico name="more" :size="22" /></button>
            </div>
          </div>
        </transition>

        <div v-if="sheet === 'more'" class="sheet" @click.stop>
          <div class="sh-head">
            <b>更多</b>
            <button class="sh-close" @click="sheet = 'none'"><Ico name="close" :size="16" /></button>
          </div>
          <button class="mact" @click="togglePip"><Ico name="pip" :size="19" /> 画中画</button>
          <button class="mact" @click="fromStart"><Ico name="rotate" :size="19" /> 从头播放</button>
        </div>

        <div v-if="sheet === 'list'" class="sheet" @click.stop>
          <div class="sh-head">
            <b>播放列表 · {{ plist.length }}</b>
            <button class="sh-close" @click="sheet = 'none'"><Ico name="close" :size="16" /></button>
          </div>
          <div class="plist">
            <button
              v-for="(p, i) in plist"
              :key="p.path"
              class="pitem"
              :class="{ on: i === gi }"
              @click="gi = i; load(); sheet = 'none'"
            >
              <span class="pi-i">{{ i + 1 }}</span>
              <span class="pi-n">{{ p.name }}</span>
              <Ico v-if="i === gi" name="check" :size="15" />
            </button>
          </div>
        </div>

        <div v-if="sheet === 'speed'" class="sheet" @click.stop>
          <div class="sh-head"><b>播放速度</b><button class="sh-close" @click="sheet = 'none'"><Ico name="close" :size="16" /></button></div>
          <div class="seg">
            <button v-for="r in speeds" :key="r" :class="{ on: r === speed }" @click="setSpeed(r)">{{ r }}×</button>
          </div>
        </div>

        <div v-if="sheet === 'audio'" class="sheet" @click.stop>
          <div class="sh-head"><b>音轨</b><button class="sh-close" @click="sheet = 'none'"><Ico name="close" :size="16" /></button></div>
          <div class="seg"><button class="on">默认音轨</button></div>
          <p class="sh-note">网页端只能用视频里的默认音轨，多音轨切换要等浏览器支持（App 里可切）</p>
        </div>
      </div>

      <template v-else>
        <img
          v-if="imgSrc"
          :src="imgSrc"
          class="img"
          :style="{
            transform: `translate(${panX + dragDx}px, ${panY + dragY}px) scale(${zoom})`,
            transformOrigin: origin,
            transition: dragOn || pinchFrom || noTrans ? 'none' : 'transform .22s cubic-bezier(0, 0, 0.58, 1)',
          }"
          alt=""
          @error="imgErr = true"
        />
        <div v-if="!imgSrc || loadPct !== null" class="ivload">
          <span class="ivspin"></span>
          <p>{{ loadPct === null ? '加载中' : `加载中 ${loadPct}%` }}</p>
        </div>
        <div v-else-if="imgErr" class="iverr">
          <Ico name="type-image" :size="42" />
          <p>图片加载失败</p>
        </div>
      </template>
      <button v-if="multi && zoom <= 1.05 && chrome" class="pic-nav left" @click.stop="stepPic(-1)">‹</button>
      <button v-if="multi && zoom <= 1.05 && chrome" class="pic-nav right" @click.stop="stepPic(1)">›</button>
    </div>

    <div v-if="!isVideo && !loading" class="ivbot" :class="{ hide: !chrome }">
      <div class="ivrow">
        <span class="ivsize">{{ humanSize(curEntry.size) }}</span>
        <span class="ivhint">{{
          zoom > 1.05
            ? `${Math.round(zoom * 100)}% · 双击还原 · 下滑关闭`
            : multi
              ? '左右滑动切图 · 双击放大'
              : '双击放大 · 下滑关闭'
        }}</span>
      </div>
      <input
        v-if="pics.length > 1"
        class="ivrange"
        type="range"
        min="0"
        :max="pics.length - 1"
        step="1"
        :value="gi"
        @input="onRange"
      />
      <div v-else class="ivgap"></div>
    </div>
  </div>
</template>

<style scoped>
.ov {
  position: fixed;
  inset: 0;
  background: #000;
  z-index: 100;
  display: flex;
  flex-direction: column;
}

.bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 9px 11px 14px;
  color: #fff;
  background: linear-gradient(
    to bottom,
    rgba(0, 0, 0, 0.8),
    rgba(0, 0, 0, 0.42) 60%,
    rgba(0, 0, 0, 0)
  );
}

/* App 的 _IvBtn：42×42、圆角 13、白色 14% 底 */
.iv-btn {
  width: 42px;
  height: 42px;
  flex: none;
  border: 0;
  border-radius: 13px;
  background: rgba(255, 255, 255, 0.14);
  color: #fff;
  display: grid;
  place-items: center;
  padding: 0;
}

/* App 的序号药丸：白 16% 底、12.5、圆角 999、右 8 */
.iv-pill {
  flex: none;
  margin-right: 8px;
  padding: 3px 10px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.16);
  color: #e6e6ea;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
}

.title {
  flex: 1;
  text-align: center;
  font-size: 13.5px;
  font-weight: 500;
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.size {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.55);
}

.icon-btn {
  color: #fff;
  background: transparent;
  border: 0;
  width: 32px;
  height: 32px;
  border-radius: 9px;
  display: grid;
  place-items: center;
}

.stage {
  flex: 1;
  display: grid;
  place-items: center;
  overflow: hidden;
  background: #000;
}

.vwrap {
  position: relative;
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}

.video {
  max-width: 100%;
  max-height: 100%;
  background: #000;
}

.img {
  max-width: 100%;
  max-height: 100%;
  transition: transform 0.08s linear;
  will-change: transform;
}

.stage {
  position: relative;
}

.seg.wrap {
  flex-wrap: wrap;
}

.ctl {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  padding: 10px 16px calc(14px + env(safe-area-inset-bottom));
  background: linear-gradient(180deg, transparent, rgba(0, 0, 0, 0.72));
}

.seek {
  padding: 6px 0 2px;
}

.range {
  width: 100%;
  height: 22px;
  appearance: none;
  background: transparent;
}

.range::-webkit-slider-runnable-track {
  height: 4px;
  border-radius: 99px;
  background: rgba(255, 255, 255, 0.28);
}

.range::-webkit-slider-thumb {
  appearance: none;
  width: 14px;
  height: 14px;
  margin-top: -5px;
  border-radius: 99px;
  background: #fff;
}

.times {
  display: flex;
  justify-content: space-between;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.72);
  font-variant-numeric: tabular-nums;
}

.btns {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 4px;
  margin-top: 6px;
}

.pbtn {
  border: 0;
  background: transparent;
  color: #fff;
  width: 42px;
  height: 42px;
  border-radius: 12px;
  display: grid;
  place-items: center;
  font-size: 13px;
  font-weight: 600;
}

.pbtn.big {
  width: 52px;
  height: 52px;
  background: rgba(255, 255, 255, 0.14);
  border-radius: 99px;
}

.pbtn.on {
  color: #6bb8ff;
}

.pbtn.text {
  font-variant-numeric: tabular-nums;
}

.sheet {
  position: absolute;
  z-index: 8;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(16, 18, 22, 0.99);
  color: #fff;
  border-radius: 18px 18px 0 0;
  padding: 12px 16px calc(18px + env(safe-area-inset-bottom));
  max-height: 62vh;
  overflow: auto;
}

.sh-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 14px;
  margin-bottom: 6px;
}

.sh-close {
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.6);
}

.sh-label {
  font-size: 11.5px;
  color: rgba(255, 255, 255, 0.5);
  margin: 12px 2px 6px;
}

.seg {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.seg button {
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.82);
  font-size: 12.5px;
  padding: 8px 14px;
  border-radius: 10px;
}

.seg button.on {
  border-color: transparent;
  background: var(--ac);
  color: #fff;
  font-weight: 700;
}

.seg button:disabled {
  opacity: 0.45;
}

.sh-note {
  font-size: 11.5px;
  color: rgba(255, 255, 255, 0.45);
  margin: 12px 2px 0;
  line-height: 1.5;
}

.jumphint,
.resume-pill {
  position: absolute;
  left: 50%;
  transform: translateX(-50%);
  padding: 7px 14px;
  border-radius: 99px;
  background: rgba(12, 18, 28, 0.72);
  color: #fff;
  font-size: 12.5px;
  pointer-events: none;
}

.jumphint {
  top: 46%;
}

.resume-pill {
  top: 14px;
  pointer-events: auto;
  cursor: pointer;
}

.hint {
  color: rgba(255, 255, 255, 0.6);
  font-size: 13px;
}

.tip {
  text-align: center;
  color: rgba(255, 255, 255, 0.4);
  font-size: 11px;
  padding: 12px 0 18px;
  margin: 0;
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.16s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

.pic-nav {
  position: fixed;
  top: 50%;
  transform: translateY(-50%);
  width: 44px;
  height: 44px;
  border-radius: 99px;
  border: 0;
  background: rgba(255, 255, 255, 0.16);
  color: #fff;
  font-size: 24px;
  line-height: 1;
  display: grid;
  place-items: center;
  backdrop-filter: blur(6px);
}

.pic-nav.left { left: 12px; }
.pic-nav.right { right: 12px; }

.monitor {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  margin-bottom: 10px;
  background: #f4f7fb;
  border-radius: 11px;
}

.mo-t {
  font-size: 11.5px;
  color: var(--ink2, #44526a);
  flex: none;
}

.mo-bar {
  flex: 1;
  height: 4px;
  border-radius: 99px;
  background: #e3e9f1;
  overflow: hidden;
}

.mo-bar i {
  display: block;
  height: 100%;
  background: var(--ac);
  border-radius: 99px;
  transition: width 0.4s;
}

.mo-p {
  font-size: 11px;
  color: var(--ink3);
  font-variant-numeric: tabular-nums;
}

.plist {
  max-height: 46vh;
  overflow-y: auto;
}

.pitem {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 4px;
  border: 0;
  background: transparent;
  text-align: left;
  border-top: 1px solid #f2f5f9;
}

.pitem.on {
  color: var(--ac, var(--ac));
  font-weight: 600;
}

.pi-i {
  width: 22px;
  font-size: 11.5px;
  color: var(--ink3);
  font-variant-numeric: tabular-nums;
  flex: none;
}

.pitem.on .pi-i {
  color: var(--ac, var(--ac));
}

.pi-n {
  flex: 1;
  min-width: 0;
  font-size: 13.5px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.ep-pill {
  font-size: 11px;
  color: #dfe7f2;
  background: rgba(255, 255, 255, 0.14);
  border-radius: 99px;
  padding: 3px 9px;
  flex: none;
  font-variant-numeric: tabular-nums;
}

.mact {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 13px 2px;
  border: 0;
  background: transparent;
  color: #fff;
  font-size: 14px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}

.ivload,
.iverr {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
  align-items: center;
  justify-content: center;
  color: rgba(255, 255, 255, 0.55);
  font-size: 12px;
  pointer-events: none;
}

.ivspin {
  width: 26px;
  height: 26px;
  border-radius: 50%;
  border: 2px solid rgba(255, 255, 255, 0.2);
  border-top-color: rgba(255, 255, 255, 0.75);
  animation: ivspin 0.9s linear infinite;
}

@keyframes ivspin {
  to {
    transform: rotate(360deg);
  }
}

.ivbot {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  padding: 18px 16px calc(12px + env(safe-area-inset-bottom));
  background: linear-gradient(to bottom, rgba(0, 0, 0, 0), rgba(0, 0, 0, 0.7));
  transition: opacity 0.22s, transform 0.22s;
}

.ivrow {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  pointer-events: none;
}

.ivgap {
  height: 8px;
}

/* 底部拖动条：控的是第几张，不是缩放（App 的 .iv-range） */
.ivrange {
  -webkit-appearance: none;
  appearance: none;
  display: block;
  width: 100%;
  height: 22px;
  margin: 4px 0 0;
  background: transparent;
  touch-action: none;
}

.ivrange::-webkit-slider-runnable-track {
  height: 4px;
  border-radius: 2px;
  background: rgba(255, 255, 255, 0.28);
}

.ivrange::-webkit-slider-thumb {
  -webkit-appearance: none;
  width: 22px;
  height: 22px;
  margin-top: -9px;
  border-radius: 50%;
  background: #fff;
  border: 0;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.35);
}

.ivrange::-moz-range-track {
  height: 4px;
  border-radius: 2px;
  background: rgba(255, 255, 255, 0.28);
}

.ivrange::-moz-range-thumb {
  width: 18px;
  height: 18px;
  border: 0;
  border-radius: 50%;
  background: #fff;
}

.ivbot.hide {
  opacity: 0;
  transform: translateY(140px);
}

.ivsize,
.ivhint {
  font-size: 12px;
  color: #cfcfd4;
  font-variant-numeric: tabular-nums;
}

.bar {
  transition: opacity 0.22s, transform 0.22s;
}

.clean .bar {
  opacity: 0;
  transform: translateY(-100%);
  pointer-events: none;
}
</style>
