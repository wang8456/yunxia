<script setup lang="ts">
import Ico from '../components/Ico.vue'
import { icoName } from '../ic'
import { computed, ref, watch } from 'vue'
import { api, ApiError, humanSize, type Entry } from '../api'
import { ask, confirmBox } from '../ask'
import Preview from './Preview.vue'
import CloudDl from '../components/CloudDl.vue'
import ImageViewer from './ImageViewer.vue'

const props = defineProps<{ path: string; toast: (t: string) => void; play?: string }>()
const emit = defineEmits<{ 'update:path': [string]; played: []; search: [] }>()

const entries = ref<Entry[]>([])
const loading = ref(false)
const sort = ref(localStorage.getItem('yunxia.sort') || 'name')
const order = ref(localStorage.getItem('yunxia.order') || 'asc')

const selecting = ref(false)
const picked = ref<Set<string>>(new Set())
const view = ref<'list' | 'grid'>((localStorage.getItem('yunxia.view') as 'list' | 'grid') || 'list')
function setView(v: 'list' | 'grid') {
  view.value = v
  localStorage.setItem('yunxia.view', v)
}
const dragging = ref(false)
const uploading = ref<{ name: string; pct: number }[]>([])
const preview = ref<Entry | null>(null)
const gal = ref<Entry[]>([])   // 看图时同目录的图，支持左右翻
const galIdx = ref(0)
const sortOpen = ref(false)

// 磁力 / ed2k：没有云下载的源走这条（115 有云下载，用不上）
const magOpen = ref(false)
const magText = ref('')
const magBusy = ref(false)
const magTasks = ref<any[]>([])
let magTimer: number | undefined

async function loadMagTasks() {
  try {
    const r = await api.tasks()
    magTasks.value = (r.tasks || []).slice(0, 12)
  } catch {
    magTasks.value = []
  }
}

watch(magOpen, (on) => {
  window.clearInterval(magTimer)
  if (!on) return
  loadMagTasks()
  magTimer = window.setInterval(() => {
    if (!document.hidden) loadMagTasks()
  }, 4000)
})

function magName(t: any) {
  return t.name || t.id || '任务'
}
function magPct(t: any) {
  const n = Number(t.pct)
  return Number.isFinite(n) ? Math.max(0, Math.min(100, Math.round(n))) : 0
}

async function startMagnet() {
  const links = magText.value
    .split(/\s+/)
    .map((x) => x.trim())
    .filter((x) => /^(magnet:\?|ed2k:\/\/)/i.test(x))
  if (!links.length) {
    props.toast('贴上 magnet: 或 ed2k:// 链接')
    return
  }
  const dir = props.path.replace(/^\/+/, '')
  const groups: Record<string, string[]> = {}
  for (const l of links) {
    const kind = l.toLowerCase().startsWith('ed2k') ? 'ed2k' : 'magnet'
    ;(groups[kind] ||= []).push(l)
  }
  magBusy.value = true
  let ok = 0
  try {
    for (const [kind, urls] of Object.entries(groups)) {
      await api.addTask(kind, urls, dir)
      ok += urls.length
    }
    props.toast(`已交给下载器：${ok} 个任务`)
    magText.value = ''
    magOpen.value = false
  } catch (err) {
    props.toast(`添加失败：${err}`)
  } finally {
    magBusy.value = false
  }
}
const menuFor = ref<Entry | null>(null)
const cdlOpen = ref(false)   // 云下载面板（只有 CloudDrive 源才给入口）
const fabOpen = ref(false)   // 悬浮球的二选一菜单：上传文件 / 云下载
const cloudSrc = computed(
  () => (srcList.value.find((x: any) => x.id === source.value)?.kind === 'cd2'),
)

function favPicked() {
  let list: any[] = []
  try { list = JSON.parse(localStorage.getItem('yunxia.favs') || '[]') } catch { list = [] }
  let add = 0
  for (const p of picked.value) {
    const e = entries.value.find((x) => x.path === p)
    if (!e) continue
    if (!list.some((f) => f.source === source.value && f.path === e.path)) {
      list.push({ source: source.value, path: e.path, name: e.name })
      add++
    }
  }
  localStorage.setItem('yunxia.favs', JSON.stringify(list))
  props.toast(add ? `已收藏 ${add} 项到首页` : '这些已经在收藏里了')
  selecting.value = false
  picked.value.clear()
}

function addFav(e: Entry) {
  let list: any[] = []
  try { list = JSON.parse(localStorage.getItem('yunxia.favs') || '[]') } catch { list = [] }
  if (!list.some((f) => f.source === source.value && f.path === e.path)) {
    list.push({ source: source.value, path: e.path, name: e.name })
    localStorage.setItem('yunxia.favs', JSON.stringify(list))
    props.toast('已收藏到首页')
  } else {
    props.toast('这个已经在收藏里了')
  }
}
function searchHint() { emit('search') }
const srcList = ref<{ id: string; name: string; writable: boolean; kind?: string }[]>([])
const source = ref(localStorage.getItem('yunxia.source') || 'nas')
/* 预览时把当前来源一并传下去：pc / 115 的文件签名必须带自己的 source */
const previewSource = computed(() => source.value)
const writable = computed(() => srcList.value.find((s) => s.id === source.value)?.writable ?? true)
const fileInput = ref<HTMLInputElement | null>(null)

const crumbs = computed(() => props.path.split('/').filter(Boolean))

/* App 行里的时间写法：MM/DD HH:mm（不用「今天/昨天」） */
function stamp(sec: number) {
  if (!sec) return '—'
  const d = new Date(sec * 1000)
  const p2 = (n: number) => String(n).padStart(2, '0')
  return `${p2(d.getMonth() + 1)}/${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`
}

function kindLabel(kind: string) {
  switch (kind) {
    case 'dir': return '文件夹'
    case 'video': return '视频'
    case 'image': return '图片'
    case 'audio': return '音频'
    case 'pdf': return 'PDF'
    case 'archive': return '压缩包'
    case 'code': return '代码'
    case 'doc': return '文档'
    default: return '文件'
  }
}

function iconOf(kind: string) {
  /* 配色照 5020 旧前端 theme.css 的 --k-* 变量：八种类型各自一套色相，
     五套主题各自给一套明度（浅色降饱和 / 深色提亮 / 护眼加暖） */
  switch (kind) {
    case 'dir':
      return { icon: '📁', bg: 'var(--k-folder-bg)', fg: 'var(--k-folder)' }
    case 'image':
      return { icon: '🖼', bg: 'var(--k-img-bg)', fg: 'var(--k-img)' }
    case 'video':
      return { icon: '🎬', bg: 'var(--k-vid-bg)', fg: 'var(--k-vid)' }
    case 'audio':
      return { icon: '🎵', bg: 'var(--k-aud-bg)', fg: 'var(--k-aud)' }
    case 'pdf':
      return { icon: '📕', bg: 'var(--k-pdf-bg)', fg: 'var(--k-pdf)' }
    case 'archive':
      return { icon: '🗜', bg: 'var(--k-zip-bg)', fg: 'var(--k-zip)' }
    case 'code':
      return { icon: '⌨', bg: 'var(--k-code-bg)', fg: 'var(--k-code)' }
    case 'doc':
      return { icon: '📄', bg: 'var(--k-doc-bg)', fg: 'var(--k-doc)' }
    default:
      return { icon: '📄', bg: 'var(--k-doc-bg)', fg: 'var(--k-doc)' }
  }
}

function maybePlay() {
  const want = props.play
  if (!want) return
  const e = entries.value.find((x) => x.path === want && !x.is_dir)
  if (e) {
    if (e.kind === 'image' || e.kind === 'video') {
    // 图片左右翻、视频播放列表，都用同一组同类型条目
    gal.value = entries.value.filter((x) => x.kind === e.kind)
    galIdx.value = Math.max(0, gal.value.findIndex((x) => x.path === e.path))
  } else {
    gal.value = []
    galIdx.value = 0
  }
  preview.value = e
    emit('played')
  }
}

async function load() {
  loading.value = true
  try {
    const r = await api.list(source.value, props.path, sort.value, order.value)
    entries.value = r.entries
  } catch (e) {
    // 照 App 的说法：路径没了就说「路径不存在」，别丢一堆 Error: xxx
    const msg = e instanceof ApiError ? e.message : String(e)
    props.toast(e instanceof ApiError && e.status === 404 ? '这个路径不存在了' : `打开失败：${msg}`)
    entries.value = []
  } finally {
    loading.value = false
  }
  picked.value = new Set()
  maybePlay()
}

async function loadSources() {
  try {
    const r = await api.sources()
    srcList.value = r.sources
    if (!r.sources.some((s) => s.id === source.value)) source.value = r.default
  } catch {
    srcList.value = [{ id: 'nas', name: 'NAS 共享盘', writable: true, kind: 'dufs' }]
  }
}

loadSources()
watch(() => props.path, load, { immediate: true })
watch([sort, order], () => {
  localStorage.setItem('yunxia.sort', sort.value)
  localStorage.setItem('yunxia.order', order.value)
  load()
})

function open(e: Entry) {
  if (pressFired) {
    pressFired = false
    return
  }
  if (selecting.value) {
    toggle(e)
    return
  }
  if (e.is_dir) {
    emit('update:path', e.path)
    return
  }
  if (e.kind === 'video' || e.kind === 'image') {
    if (e.kind === 'image' || e.kind === 'video') {
    // 图片左右翻、视频播放列表，都用同一组同类型条目
    gal.value = entries.value.filter((x) => x.kind === e.kind)
    galIdx.value = Math.max(0, gal.value.findIndex((x) => x.path === e.path))
  } else {
    gal.value = []
    galIdx.value = 0
  }
  preview.value = e
    return
  }
  download(e)
}

async function download(e: Entry) {
  try {
    const r = await api.link(source.value, e.path)
    const a = document.createElement('a')
    a.href = api.absolute(r.url)
    a.download = e.name
    a.rel = 'noopener'
    // 必须挂进文档再点：游离的 <a>.click() 在 Chrome/Safari 上常常被忽略，
    // 表现就是「点了下载什么也没发生」。
    document.body.appendChild(a)
    a.click()
    a.remove()
    props.toast(`开始下载 ${e.name}`)
  } catch (err) {
    props.toast(`下载失败：${err}`)
  }
}

/* 长按进多选：模板上的 @pointerdown/@pointerup 一直指向不存在的函数，
   长按多选在网页端从来没生效过（控制台每次按下去都报 startPress is not defined）。*/
let pressTimer: number | undefined
let pressFired = false
let pressX = 0
let pressY = 0

function startPress(e: Entry, ev?: PointerEvent) {
  pressFired = false
  pressX = ev?.clientX ?? 0
  pressY = ev?.clientY ?? 0
  window.clearTimeout(pressTimer)
  pressTimer = window.setTimeout(() => {
    pressFired = true
    selecting.value = true
    const s = new Set(picked.value)
    s.add(e.path)
    picked.value = s
    try {
      navigator.vibrate?.(12)
    } catch {}
  }, 420)
}

function endPress() {
  window.clearTimeout(pressTimer)
}

/// 手指一滑就是滚动列表，别把滑动当成"长按"
function movePress(ev: PointerEvent) {
  if (!pressTimer) return
  if (Math.abs(ev.clientX - pressX) > 10 || Math.abs(ev.clientY - pressY) > 10) endPress()
}

function toggle(e: Entry) {
  const s = new Set(picked.value)
  if (s.has(e.path)) s.delete(e.path)
  else s.add(e.path)
  picked.value = s
}

function toggleAll() {
  picked.value =
    picked.value.size === entries.value.length
      ? new Set()
      : new Set(entries.value.map((e) => e.path))
}

async function newFolder() {
  const name = await ask({ title: '新建文件夹', placeholder: '文件夹名称', okText: '新建' })
  if (!name) return
  try {
    await api.mkdir(source.value, props.path, name)
    props.toast(`已创建 ${name}`)
    load()
  } catch (e) {
    props.toast(`创建失败：${e}`)
  }
}

/* ---------- 移动到其他文件夹 ---------- */
const moveFor = ref<Entry | null>(null)
const movePath = ref('/')
const moveDirs = ref<Entry[]>([])
const moveLoading = ref(false)
const moveBusy = ref(false)

const moveCrumbs = computed(() => {
  const p = movePath.value
  if (p === '/' || !p) return [] as { name: string; path: string }[]
  const parts = p.split('/').filter(Boolean)
  const out: { name: string; path: string }[] = []
  let acc = ''
  for (const part of parts) {
    acc += '/' + part
    out.push({ name: part, path: acc })
  }
  return out
})

const moveHereName = computed(() => moveCrumbs.value.length ? moveCrumbs.value[moveCrumbs.value.length - 1].name : '云匣')

/// 不能移到自己的子目录里（服务端也会拒，但界面上先别让他点）
const canMoveHere = computed(() => {
  const e = moveFor.value
  if (!e) return false
  const to = movePath.value
  if (!e.is_dir) return true
  return to !== e.path && !to.startsWith(e.path + '/')
})

function openMove(e: Entry) {
  menuFor.value = null
  moveFor.value = e
  movePath.value = props.path || '/'
  loadMoveDirs(movePath.value)
}

function closeMove() {
  moveFor.value = null
  moveDirs.value = []
  moveLoading.value = false
}

async function loadMoveDirs(p: string) {
  moveLoading.value = true
  moveDirs.value = []
  try {
    const r = await api.list(source.value, p)
    const self = moveFor.value
    moveDirs.value = (r.entries || []).filter(
      (e) => e.is_dir && !(self && e.path === self.path),
    )
  } catch (e) {
    props.toast(`读目录失败：${e}`)
  } finally {
    moveLoading.value = false
  }
}

function moveTo(p: string) {
  movePath.value = p
  loadMoveDirs(p)
}

function moveUp() {
  const p = movePath.value.replace(/\/+$/, '')
  const i = p.lastIndexOf('/')
  moveTo(i <= 0 ? '/' : p.slice(0, i))
}

async function doMove() {
  const e = moveFor.value
  if (!e || !canMoveHere.value) return
  const dest = (movePath.value === '/' ? '' : movePath.value) + '/' + e.name
  if (dest === e.path) {
    props.toast('已经在这个文件夹里了')
    return
  }
  moveBusy.value = true
  try {
    await api.move(source.value, e.path, dest)
    props.toast(`已移到「${moveHereName.value}」`)
    closeMove()
    load()
  } catch (err) {
    props.toast(`移动失败：${err}`)
  } finally {
    moveBusy.value = false
  }
}

async function makeSubs(e: Entry) {
  try {
    const r: any = await api.subsAdd(e.path, e.name)
    props.toast(r.ok ? `已排队听译：${e.name}` : `失败：${r.error ?? ''}`)
  } catch (err) {
    props.toast(`听译失败：${err}`)
  }
}

async function rename(e: Entry) {
  const name = await ask({ title: '重命名', value: e.name, okText: '保存' })
  if (!name || name === e.name) return
  const base = props.path === '/' ? '' : props.path
  try {
    await api.move(source.value, e.path, `${base}/${name}`)
    props.toast('已改名')
    load()
  } catch (err) {
    props.toast(`改名失败：${err}`)
  }
}

async function removePaths(paths: string[], label: string) {
  if (!paths.length) return
  if (!(await confirmBox(`删除 ${label}？`, '删掉就找不回来了', '删除'))) return
  try {
    await api.remove(source.value, paths)
    props.toast('已删除')
    selecting.value = false
    load()
  } catch (err) {
    props.toast(`删除失败：${err}`)
  }
}

// ---------- 上传（选文件 + 拖拽） ----------

async function uploadFiles(list: FileList | File[]) {
  const files = Array.from(list)
  if (!files.length) return
  for (const f of files) {
    uploading.value.push({ name: f.name, pct: 0 })
    const slot = uploading.value[uploading.value.length - 1]
    try {
      await api.upload(source.value, props.path, f, (sent, total) => {
        slot.pct = total ? Math.round((sent / total) * 100) : 0
      })
      slot.pct = 100
    } catch (e) {
      slot.pct = -1
      props.toast(`${f.name} 上传失败：${e}`)
    }
  }
  props.toast(`上传结束：${files.length} 个文件`)
  setTimeout(() => (uploading.value = []), 1200)
  load()
}

function onPick(e: Event) {
  const input = e.target as HTMLInputElement
  if (input.files) uploadFiles(input.files)
  input.value = ''
}

function onDrop(e: DragEvent) {
  dragging.value = false
  if (e.dataTransfer?.files?.length) uploadFiles(e.dataTransfer.files)
}

function goto(depth: number) {
  emit('update:path', depth === 0 ? '/' : `/${crumbs.value.slice(0, depth).join('/')}`)
}

function toggleSort(key: string) {
  if (sort.value === key) order.value = order.value === 'asc' ? 'desc' : 'asc'
  else {
    sort.value = key
    order.value = 'asc'
  }
}
</script>

<template>
  <div
    class="wrap"
    :class="{ dragging }"
    @dragover.prevent="dragging = true"
    @dragleave.prevent="dragging = false"
    @drop.prevent="onDrop"
  >
    <header class="brandbar">
      <div class="brand-name">云匣</div>
    </header>

    <div class="head">
      <!-- 根目录不显示面包屑：上面已经有「云匣」，下面 H1 就是这一屏的名字，
           三条一模一样的标题只会让人以为页面没做完。
           进到子目录（哪怕只有一层）就必须给一条回得去的路，
           否则手机上进了文件夹就没有退出的按钮，只能刷新。 -->
      <nav v-if="crumbs.length" class="crumbs">
        <button @click="goto(0)">云匣</button>
        <template v-for="(c, i) in crumbs.slice(0, -1)" :key="i">
          <span class="sep">/</span>
          <button @click="goto(i + 1)">{{ c }}</button>
        </template>
      </nav>
      <div class="title-row">
        <h1 class="page-title">{{ selecting ? `已选 ${picked.size}` : (crumbs.length ? crumbs[crumbs.length - 1] : '文件') }}</h1>
        <div class="title-acts">
          <template v-if="selecting">
            <button class="text-btn" @click="toggleAll">{{ picked.size === entries.length ? '全不选' : '全选' }}</button>
            <button class="text-btn" @click="selecting = false; picked.clear()">取消</button>
          </template>
          <template v-else>
            <button class="text-btn" @click="sortOpen = true">排序 <Ico name="sort" :size="14" /></button>
            <button class="icon-btn" :title="view === 'grid' ? '列表' : '宫格'" @click="setView(view === 'grid' ? 'list' : 'grid')">
              <Ico :name="view === 'grid' ? 'list' : 'grid'" :size="17" />
            </button>
          </template>
        </div>
      </div>
      <div v-if="sortOpen" class="sheet-mask" @click.self="sortOpen = false">
        <div class="sheet">
          <div class="sheet-title">排序</div>
          <button v-for="o in [['name','名称'],['mtime','修改时间'],['size','大小']]" :key="o[0]"
                  class="sheet-row" :class="{ on: sort === o[0] }" @click="toggleSort(o[0] as any); sortOpen = false">
            <Ico name="sort" :size="18" /> {{ o[1] }}
            <span class="sort-arrow" v-if="sort === o[0]">{{ order === 'asc' ? '正序 ↑' : '倒序 ↓' }}</span>
          </button>
        </div>
      </div>
    </div>

    <input ref="fileInput" type="file" multiple hidden @change="onPick" />



    <div v-if="uploading.length" class="uploads card">
      <div v-for="(u, i) in uploading" :key="i" class="up-item">
        <span class="up-name">{{ u.name }}</span>
        <div class="up-bar">
          <span :style="{ width: `${u.pct < 0 ? 100 : u.pct}%` }" :class="{ bad: u.pct < 0 }"></span>
        </div>
        <span class="up-pct">{{ u.pct < 0 ? '失败' : `${u.pct}%` }}</span>
      </div>
    </div>


    <p v-if="loading" class="muted">加载中…</p>
    <div v-else-if="!entries.length" class="empty card">这个文件夹是空的 · 拖文件进来就能上传</div>

    <div v-else-if="view === 'grid'" class="grid">
      <div
        class="tile"
        v-for="e in entries"
        :key="e.path"
        :class="{ picked: picked.has(e.path) }"
        @click="open(e)"
        @pointerdown="startPress(e, $event)"
        @pointerup="endPress"
        @pointerleave="endPress"
        @pointercancel="endPress"
        @pointermove="movePress"
        @contextmenu.prevent"
      >
        <div class="tile-thumb" :style="{ background: iconOf(e.kind).bg, color: iconOf(e.kind).fg }">
          <Ico :name="icoName(iconOf(e.kind).icon)" :size="30" />
          <span v-if="selecting" class="check over" :class="{ on: picked.has(e.path) }">
            {{ picked.has(e.path) ? '✓' : '' }}
          </span>
        </div>
        <div class="tile-body">
          <div class="tile-name">{{ e.name }}</div>
          <div class="tile-meta">{{ e.is_dir ? '文件夹' : kindLabel(e.kind) }}</div>
        </div>
      </div>
    </div>

    <div v-else class="rows">
      <div
        class="row"
        v-for="e in entries"
        :key="e.path"
        :class="{ picked: picked.has(e.path) }"
        @click="open(e)"
        @pointerdown="startPress(e, $event)"
        @pointerup="endPress"
        @pointerleave="endPress"
        @pointercancel="endPress"
        @pointermove="movePress"
        @contextmenu.prevent"
      >
        <span class="icon" :style="{ background: iconOf(e.kind).bg, color: iconOf(e.kind).fg }">
          <Ico class="emoji" :name="icoName(iconOf(e.kind).icon)" />
        </span>
        <div style="flex: 1; min-width: 0">
          <div class="name">{{ e.name }}</div>
          <div class="meta">{{ stamp(e.mtime) }}</div>
        </div>
        <span v-if="!e.is_dir" class="size">{{ humanSize(e.size) }}</span>
        <span v-if="selecting" class="check" :class="{ on: picked.has(e.path) }">
          <Ico v-if="picked.has(e.path)" name="check" :size="13" />
        </span>
        <button v-if="!selecting" class="dots" title="更多操作" @click.stop="menuFor = e">
          <Ico name="more" :size="18" />
        </button>
      </div>
    </div>

    <div v-if="dragging" class="dropmask">松手就上传到这个文件夹</div>

    <div v-if="selecting" class="selbottom">
      <span class="sel-txt">已选 {{ picked.size }} 项 · 还能再多点几个</span>
      <button class="sel-act" :disabled="!picked.size" @click="favPicked">收藏 <Ico name="star" :size="16" /></button>
      <button v-if="writable" class="sel-act danger" :disabled="!picked.size" @click="removePaths([...picked], `${picked.size} 项`)">
        删除 <Ico name="trash" :size="16" />
      </button>
    </div>

    <div v-if="!selecting" class="fabs">
      <button
        class="fab grad"
        :title="cloudSrc ? '上传 / 云下载' : '上传'"
        @click="fabOpen = true"
      >
        <Ico name="add" :size="22" />
      </button>
      <button class="fab round" title="搜索" @click="searchHint"><Ico name="search" :size="20" /></button>
    </div>

    <div v-if="fabOpen" class="sheet-mask" @click.self="fabOpen = false">
      <div class="sheet">
        <div class="sheet-title">{{ props.path && props.path !== '/' ? props.path : '当前目录（根）' }}</div>
        <button v-if="cloudSrc" class="sheet-row" @click="fabOpen = false; cdlOpen = true">
          <Ico name="download" :size="18" /> 云下载
        </button>
        <button v-else class="sheet-row" @click="fabOpen = false; magOpen = true">
          <Ico name="link" :size="18" /> 磁力 / ed2k
        </button>
        <button v-if="writable" class="sheet-row" @click="fabOpen = false; fileInput?.click()">
          <Ico name="upload" :size="18" /> 上传文件
        </button>
        <button v-if="writable" class="sheet-row" @click="fabOpen = false; newFolder()">
          <Ico name="folder" :size="18" /> 新建文件夹
        </button>
        <button v-if="!writable" class="sheet-row" disabled>
          <Ico name="login" :size="18" /> 这个来源不能写入
        </button>
      </div>
    </div>

    <div v-if="magOpen" class="sheet-mask" @click.self="magOpen = false">
      <div class="sheet">
        <div class="sheet-title">磁力 / ed2k · 下到 {{ props.path === '/' ? '根目录' : props.path }}</div>
        <textarea
          class="mag-ta"
          v-model="magText"
          rows="4"
          placeholder="一行一条：magnet:?xt=… 或 ed2k://|file|…"
        ></textarea>
        <div class="mag-tip">下载器在 NAS 上跑，下面的进度每 4 秒刷一次</div>
        <div class="mag-acts">
          <button class="text-btn" @click="magOpen = false">取消</button>
          <button class="mag-go" :disabled="magBusy" @click="startMagnet">
            {{ magBusy ? '提交中…' : '开始下载' }}
          </button>
        </div>
        <div v-if="magTasks.length" class="mag-list">
          <div v-for="(t, i) in magTasks" :key="t.id || i" class="mag-item">
            <div class="mag-name">{{ magName(t) }}</div>
            <div class="mag-bar"><span :style="{ width: magPct(t) + '%' }"></span></div>
            <div class="mag-meta">
              <span>{{ magPct(t) }}%</span>
              <span>{{ t.kind === 'ed2k' ? 'ed2k' : '磁力' }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div v-if="menuFor" class="sheet-mask" @click.self="menuFor = null">
      <div class="sheet">
        <div class="sheet-title">{{ menuFor.name }}</div>
        <button class="sheet-row" @click="open(menuFor); menuFor = null">
          <Ico :name="menuFor.is_dir ? 'folder' : 'open-new'" :size="18" />
          {{ menuFor.is_dir ? '打开' : '打开 / 预览' }}
        </button>
        <button v-if="!menuFor.is_dir" class="sheet-row" @click="download(menuFor); menuFor = null"><Ico name="download" :size="18" /> 下载到本机</button>
        <button v-if="menuFor.kind === 'video'" class="sheet-row" @click="makeSubs(menuFor); menuFor = null"><Ico name="translate" :size="18" /> 生成字幕</button>
        <button v-if="menuFor.is_dir" class="sheet-row" @click="addFav(menuFor); menuFor = null"><Ico name="star" :size="18" /> 收藏到首页</button>
        <button v-if="writable" class="sheet-row" @click="rename(menuFor); menuFor = null"><Ico name="edit" :size="18" /> 改名</button>
        <button v-if="writable" class="sheet-row" @click="openMove(menuFor)"><Ico name="move" :size="18" /> 移动到…</button>
        <button v-if="writable" class="sheet-row danger" @click="removePaths([menuFor.path], menuFor.name); menuFor = null"><Ico name="trash" :size="18" /> 删除</button>
        <button class="sheet-row cancel" @click="menuFor = null">取消</button>
      </div>
    </div>

    <!-- 移动到哪个文件夹（照 App 的目录选择器） -->
    <div v-if="moveFor" class="sheet-mask" @click.self="closeMove">
      <div class="sheet mv">
        <div class="sheet-title">把「{{ moveFor.name }}」移到</div>
        <div class="mv-crumbs">
          <button class="mv-crumb" @click="moveTo('/')">云匣</button>
          <template v-for="c in moveCrumbs" :key="c.path">
            <span class="mv-sep">/</span>
            <button class="mv-crumb" @click="moveTo(c.path)">{{ c.name }}</button>
          </template>
        </div>
        <div class="mv-list">
          <button v-if="movePath !== '/'" class="mv-row up" @click="moveUp">
            <Ico name="arrow-left" :size="16" /> 上一级
          </button>
          <button v-for="d in moveDirs" :key="d.path" class="mv-row" @click="moveTo(d.path)">
            <Ico name="folder" :size="18" class="mv-ico" /> <span class="mv-name">{{ d.name }}</span>
          </button>
          <div v-if="!moveDirs.length && !moveLoading" class="mv-empty">这里没有子文件夹</div>
          <div v-if="moveLoading" class="mv-empty">读取中…</div>
        </div>
        <button class="sheet-row ok" :disabled="!canMoveHere || moveBusy" @click="doMove">
          {{ moveBusy ? '正在移动…' : `移到「${moveHereName}」` }}
        </button>
        <button class="sheet-row cancel" @click="closeMove">取消</button>
      </div>
    </div>
  </div>

  <ImageViewer
    v-if="preview && preview.kind === 'image'"
    :entry="preview"
    :source="previewSource"
    :gallery="gal"
    :index="galIdx"
    @close="preview = null"
  />
  <Preview
    v-else-if="preview"
    :entry="preview"
    :source="previewSource"
    :gallery="gal"
    :index="galIdx"
    @close="preview = null"
  />
    <CloudDl
      v-if="cdlOpen"
      :source="source"
      :dir="props.path || '/'"
      :toast="props.toast"
      @close="cdlOpen = false"
    />
</template>

<style scoped>
.title-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin: 2px 0 12px;
}

.title-row .page-title {
  margin: 0;
}

.mag-ta {
  width: 100%;
  box-sizing: border-box;
  margin: 4px 0 0;
  padding: 11px 12px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface2);
  color: var(--ink);
  font-size: 13px;
  line-height: 1.5;
  resize: none;
  outline: none;
}

.mag-ta:focus {
  border-color: var(--ac);
}

.mag-tip {
  margin: 8px 2px 0;
  font-size: 11.5px;
  color: var(--ink3);
}

.mag-list {
  margin-top: 14px;
  max-height: 220px;
  overflow: auto;
}

.mag-item {
  padding: 9px 0;
  border-top: 1px solid var(--line);
}

.mag-name {
  font-size: 12.5px;
  color: var(--ink);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.mag-bar {
  margin: 6px 0 4px;
  height: 4px;
  border-radius: 99px;
  background: var(--line);
  overflow: hidden;
}

.mag-bar span {
  display: block;
  height: 100%;
  background: var(--ac);
  border-radius: 99px;
}

.mag-meta {
  display: flex;
  justify-content: space-between;
  font-size: 11px;
  color: var(--ink3);
}

.mag-acts {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  margin-top: 12px;
}

.mag-go {
  padding: 9px 18px;
  border: 0;
  border-radius: 999px;
  background: var(--ac);
  color: #fff;
  font-size: 13.5px;
  font-weight: 600;
}

.mag-go:disabled {
  opacity: .6;
}

.sort-arrow {
  margin-left: auto;
  font-size: 12px;
  color: var(--ink3);
}

.title-acts {
  display: flex;
  align-items: center;
  gap: 10px;
}

.text-btn {
  border: 0;
  background: transparent;
  color: var(--ac, var(--ac));
  font-size: 12.5px;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px 2px;
}

.crumbs.empty {
  min-height: 21px;
}

.icon-btn {
  border: 0;
  background: transparent;
  /* 视觉还是小图标，热区补到 40（手机上 44），不然点不中 */
  min-width: 40px;
  min-height: 40px;
  padding: 6px;
  border-radius: 99px;
  color: var(--ink2, #6b7a90);
  display: grid;
  place-items: center;
}

.sort-sheet {
  display: flex;
  flex-direction: column;
  padding: 6px;
  margin-bottom: 10px;
}

.sort-item {
  border: 0;
  background: transparent;
  text-align: left;
  padding: 11px 12px;
  border-radius: 10px;
  font-size: 13px;
  color: var(--ink);
}

.sort-item.on {
  color: var(--ac, var(--ac));
  font-weight: 700;
  background: var(--acw, #eef4ff);
}

.dots {
  border: 0;
  background: transparent;
  width: 36px;
  height: 36px;
  display: grid;
  place-items: center;
  color: #9aa7b8;
  border-radius: 10px;
  flex: none;
}

@media (min-width: 761px) {
  .brandbar .brand-name {
    display: none;          /* 侧栏已经有「云匣」 */
  }

  .wrap .brandbar {
    justify-content: flex-end;
    margin-bottom: 8px;
  }
}

/* 平板 / 电脑：悬浮球照 App 一样留着（顶栏只剩排序 + 视图） */
.wide-only {
  display: none;
}

@media (min-width: 761px) {
  .wide-only {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }

}

.act-primary {
  border: 0;
  background: linear-gradient(145deg, var(--ac), color-mix(in srgb, var(--ac) 60%, #fff));
  color: #fff;
  border-radius: 10px;
  padding: 8px 14px;
  font-size: 12.5px;
  font-weight: 650;
  font-family: inherit;
  box-shadow: 0 6px 14px -6px rgba(22, 129, 248, 0.6);
}

.act-primary:active {
  transform: translateY(1px);
}

.fabs {
  position: fixed;
  right: 18px;
  bottom: 84px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  z-index: 20;
}

.fab {
  border: 0;
  display: grid;
  place-items: center;
  transition: transform 0.12s ease;
}

.fab:active {
  transform: scale(0.95);
}

/* App 的 GradFab：55 见方、圆角 19（不是正圆） */
.fab.grad {
  width: 55px;
  height: 55px;
  border-radius: 19px;
  color: #fff;
  background: linear-gradient(145deg, var(--ac), var(--ac2));
  box-shadow: 0 9px 24px color-mix(in srgb, var(--ac) 30%, transparent);
}

/* App 的 RoundFab：50 正圆白底 */
.fab.round {
  width: 50px;
  height: 50px;
  border-radius: 99px;
  background: var(--surface, #fff);
  color: var(--ink2, #6b7a90);
  box-shadow: 0 8px 20px rgba(44, 93, 146, 0.15);
}



.sheet-mask {
  position: fixed;
  inset: 0;
  background: rgba(15, 23, 40, 0.32);
  display: flex;
  align-items: flex-end;
  z-index: 40;
}

.sheet {
  width: 100%;
  background: var(--surface, #fff);
  border-radius: 18px 18px 0 0;
  padding: 8px 10px calc(10px + env(safe-area-inset-bottom));
}

.sheet-title {
  font-size: 12px;
  color: var(--ink3);
  padding: 10px 12px 6px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sheet-row {
  width: 100%;
  border: 0;
  background: transparent;
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 13px 12px;
  font-size: 14px;
  color: var(--ink);
  border-radius: 12px;
}

.sheet-row.danger {
  color: #e0515f;
}

/* 移动选择器 */
.mv {
  max-height: 78vh;
  display: flex;
  flex-direction: column;
}
.mv-crumbs {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-wrap: wrap;
  padding: 2px 8px 8px;
  font-size: 12.5px;
  color: var(--ink3, #9aa8ba);
}
.mv-crumb {
  border: 0;
  background: transparent;
  padding: 3px 5px;
  border-radius: 7px;
  color: var(--ac, #1677f8);
  font-size: 12.5px;
}
.mv-crumb:hover {
  background: var(--acw, #e7f1ff);
}
.mv-sep {
  color: var(--ink3, #9aa8ba);
}
.mv-list {
  flex: 1;
  min-height: 96px;
  max-height: 46vh;
  overflow: auto;
  border-top: 1px solid var(--line2, #f2f5f9);
}
.mv-row {
  width: 100%;
  border: 0;
  background: transparent;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 10px;
  min-height: 46px;
  border-radius: 11px;
  font-size: 14px;
  color: var(--ink, #26364a);
  text-align: left;
}
.mv-row:hover {
  background: var(--surface2, #f7fafe);
}
.mv-row .mv-ico {
  color: var(--ac, #1677f8);
  flex: none;
}
.mv-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.mv-row.up {
  color: var(--ink2, #5d7391);
}
.mv-empty {
  padding: 18px 10px;
  font-size: 13px;
  color: var(--ink3, #9aa8ba);
  text-align: center;
}
.sheet-row.ok {
  justify-content: center;
  color: var(--onac, #fff);
  background: var(--ac, #1677f8);
  border-radius: 12px;
  margin-top: 8px;
  font-weight: 600;
}
.sheet-row.ok:disabled {
  opacity: 0.45;
}

.sheet-row.cancel {
  justify-content: center;
  color: var(--ink3);
}

.wrap {
  position: relative;
  min-height: 60vh;
}

.head {
  display: block;          /* 照 App：面包屑在上，标题行在下一行 */
  margin-bottom: 10px;
}

.head .crumbs {
  margin-bottom: 8px;
}

.tools {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.chip.danger {
  color: #e0515f;
  border-color: color-mix(in srgb, #e0515f 30%, var(--line));
}

.chip:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.srcbar {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 12px;
}

.ro {
  margin-left: 5px;
  font-size: 9.5px;
  opacity: 0.7;
}

.crumbs {
  display: flex;
  align-items: center;
  gap: 2px;
  font-size: 12px;
  color: var(--ink3);
  margin-bottom: 14px;
  flex-wrap: wrap;
}

.crumbs button {
  color: var(--ac);
  padding: 3px 6px;
  border-radius: 8px;
  font-size: 12px;
}

.crumbs button.now {
  color: var(--ink3);
}

.sep {
  color: var(--line);
}

.uploads {
  padding: 10px 14px;
  margin-bottom: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.up-item {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 11.5px;
}

.up-name {
  width: 40%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.up-bar {
  flex: 1;
  height: 4px;
  border-radius: 9px;
  background: var(--line2);
  overflow: hidden;
}

.up-bar span {
  display: block;
  height: 100%;
  background: var(--ac);
  transition: width 0.2s ease;
}

.up-bar span.bad {
  background: #e0515f;
}

.up-pct {
  width: 38px;
  text-align: right;
  color: var(--ink3);
}

.selbar {
  padding: 9px 12px;
  margin-bottom: 12px;
  display: flex;
  align-items: center;
  gap: 10px;
}

.empty {
  padding: 48px;
  text-align: center;
  color: var(--ink3);
  font-size: 13px;
}

.row.picked {
  background: var(--acw);
}

.check {
  width: 20px;
  height: 20px;
  border-radius: 7px;
  border: 1.5px solid var(--line);
  display: grid;
  place-items: center;
  font-size: 12px;
  color: #fff;
  flex: 0 0 auto;
}

.check.on {
  background: var(--ac);
  border-color: var(--ac);
}

.size {
  font-size: 11px;
  color: var(--ink3);
  white-space: nowrap;
}

.ops {
  display: flex;
  gap: 2px;
  opacity: 0;
  transition: opacity var(--fast) var(--ease);
}

.row:hover .ops {
  opacity: 1;
}

.op {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  color: var(--ink3);
  font-size: 13px;
}

.op:hover {
  background: var(--surface2);
  color: var(--ac);
}

.op.danger:hover {
  color: #e0515f;
}

.muted {
  color: var(--ink3);
  font-size: 11.5px;
}

.dragging {
  outline: 2px dashed var(--ac);
  outline-offset: 6px;
  border-radius: var(--r16);
}

.dropmask {
  position: fixed;
  inset: 0;
  background: color-mix(in srgb, var(--ac) 12%, transparent);
  color: var(--ac);
  font-weight: 700;
  font-size: 15px;
  display: grid;
  place-items: center;
  pointer-events: none;
  z-index: 60;
}

@media (max-width: 760px) {
  .ops {
    opacity: 1;
  }
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 14px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(134px, 1fr));
  gap: 10px;
  padding-bottom: 96px;
}

.tile {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 16px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  cursor: default;
}

.tile.picked {
  outline: 2px solid var(--ac);
  outline-offset: -2px;
}

.tile-thumb {
  position: relative;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
}

.tile-body {
  padding: 8px 9px;
}

.tile-name {
  font-size: 11.5px;
  line-height: 1.35;
  font-weight: 600;
  color: var(--ink);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.tile-meta {
  margin-top: 3px;
  font-size: 10.5px;
  color: var(--ink3);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tile-ico .emoji,
.tile-ico img {
  width: 26px;
  height: 26px;
  object-fit: contain;
}

.tile-name {
  padding: 8px 10px 0;
  font-size: 12.5px;
  font-weight: 500;
  color: var(--ink);
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  word-break: break-all;
}

.tile-meta {
  padding: 2px 10px 0;
  font-size: 11px;
  color: var(--ink3);
}

.check.over {
  position: absolute;
  top: 8px;
  left: 8px;
}

/* 行图标照 App _FileRow：43×43、圆角 13、字形 22 */
.row .icon {
  width: 43px;
  height: 43px;
  border-radius: 13px;
  display: grid;
  place-items: center;
  flex: none;
}

.row .icon .emoji,
.row .icon svg {
  width: 22px;
  height: 22px;
}

/* 品牌栏：云匣 20/700 + 我 36 圆（App BrandBar） */
.brandbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 16px;
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

/* 选择模式：圆形勾选框在右侧，选中蓝底白勾 */
.check {
  width: 22px;
  height: 22px;
  border-radius: 99px;
  border: 1.5px solid #d5dde8;
  display: grid;
  place-items: center;
  color: #fff;
  flex: none;
  margin-left: 10px;
}

.check.on {
  background: var(--ac, var(--ac));
  border-color: var(--ac, var(--ac));
}

/* 底部操作条 */
.selbottom {
  position: fixed;
  left: 12px;
  right: 12px;
  bottom: 84px;
  background: var(--surface, #fff);
  border-radius: 16px;
  box-shadow: 0 6px 22px rgba(45, 86, 135, 0.14);
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  z-index: 22;
}

.sel-txt {
  flex: 1;
  font-size: 12px;
  color: var(--ink3);
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sel-act {
  border: 0;
  background: transparent;
  color: var(--ac, var(--ac));
  font-size: 13px;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.sel-act.danger {
  color: #e0515f;
}

.sel-act:disabled {
  opacity: 0.4;
}

/* 手机上上/搜索两个悬浮球会压在列表最后一行上：给列表留出底部空档
   （宫格模式原本就有 padding-bottom:96px，列表模式漏了） */
@media (max-width: 760px) {
  .rows {
    padding-bottom: 132px;
  }
}

/* 宽屏：App 在 >=760px 时拆成左右两栏列表（browse_page.dart） */
@media (min-width: 900px) {
  .rows {
    column-count: 2;
    column-gap: 14px;
  }

  .row {
    break-inside: avoid;
  }
}
</style>
