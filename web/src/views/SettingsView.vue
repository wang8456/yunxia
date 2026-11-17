<script setup lang="ts">
/* 设置页 —— 状态卡（口令入口）→ 外观 → 播放器 → 更多 → 关于
   开源版只保留这些：听译 / 翻译 / 下载队列 / CloudDrive2 这些定制入口都拆掉了。 */
import { computed, onMounted, reactive, ref } from 'vue'
import Ico from '../components/Ico.vue'
import { api } from '../api'
import { confirmBox } from '../ask'

const props = defineProps<{ view: 'list' | 'grid'; theme: string }>()
const emit = defineEmits<{
  toast: [string]
  go: [string]
  pwd: []
  theme: [string]
  view: [string]
  refresh: []
  root: []
  logout: []
  source: [string]
}>()

type Src = { id: string; name: string; sub?: string; kind?: string; writable?: boolean }

const srcs = ref<Src[]>([])
const curId = ref(localStorage.getItem('yunxia.source') || '')
const counts = reactive({ dirs: 0, files: 0, favs: 0 })
const authed = ref(!!api.token || !!localStorage.getItem('yunxia.chatkey'))
const origin = location.origin

/* 来源副标题：服务端给了就用，没有按 kind 兜底 */
function subOf(s: Src | undefined) {
  if (!s) return ''
  if (s.sub) return s.sub
  switch (s.kind) {
    case 'local':
      return '服务器本地磁盘'
    case 'dufs':
      return '电脑上的 dufs 共享'
    case 'webdav':
      return 'WebDAV 网盘'
    default:
      return ''
  }
}

/* 来源图标按 kind 取：local / dufs / webdav */
function icoOf(s?: Src) {
  const k = s?.kind || ''
  if (k === 'dufs')
    return { i: 'src-pc', bg: 'color-mix(in srgb, #E08A16 14%, var(--surface))', fg: '#E08A16' }
  if (k === 'webdav')
    return { i: 'src-cloud', bg: 'color-mix(in srgb, var(--ac) 14%, var(--surface))', fg: 'var(--ac)' }
  return { i: 'src-nas', bg: 'var(--icobg)', fg: 'var(--ac)' }
}
const curIco = computed(() => icoOf(cur.value))
const cur = computed(() => srcs.value.find((s) => s.id === curId.value))
const curName = computed(() => cur.value?.name || 'NAS')

const srcOpen = ref(false)

/* 主题列表：浅色 / 深色 / 蓝色 / 绿色 / 护眼，bg+ac 用来画双色板 */
const THEMES: { id: string; name: string; bg: string; ac: string }[] = [
  { id: 'light', name: '浅色', bg: '#f2f3f5', ac: '#3a3a3c' },
  { id: 'dark', name: '深色', bg: '#121417', ac: '#4c9aff' },
  { id: 'blue', name: '蓝色', bg: '#f4f7fc', ac: '#1677f8' },
  { id: 'green', name: '绿色', bg: '#f2f9f4', ac: '#16a34a' },
  { id: 'sepia', name: '护眼', bg: '#f4efe3', ac: '#b07d3a' },
]
const themeName = computed(() => THEMES.find((t) => t.id === props.theme)?.name || '默认')

/* 播放器本地偏好：播放器里直接读这两个键 */
const lpRate = ref(Number(localStorage.getItem('mfm_lp_rate') || 3))
const swK = ref(Number(localStorage.getItem('mfm_sw_k') || 1))
function setLp(r: number) {
  lpRate.value = r
  localStorage.setItem('mfm_lp_rate', String(r))
  emit('toast', `长按倍速 ${r}×`)
}
function setSw(k: number) {
  swK.value = k
  localStorage.setItem('mfm_sw_k', String(k))
  emit('toast', `滑动灵敏度 ${k}`)
}

async function load() {
  try {
    // 设置页永远要最新的：这里看得见「能不能写」，缓存 30 秒会骗人
    const r = await api.sources({ fresh: true })
    srcs.value = (r.sources || []) as Src[]
    if (srcs.value.length && !srcs.value.some((s) => s.id === curId.value)) {
      curId.value = r.default || srcs.value[0].id
    }
  } catch {
    srcs.value = []
  }
  try {
    const l: any = await api.list(curId.value, '/')
    const es: any[] = l.entries || []
    // 服务端字段是 is_dir（snake_case），不是 isDir
    counts.dirs = es.filter((e) => e.is_dir === true).length
    counts.files = es.filter((e) => e.is_dir !== true).length
  } catch {
    /* 没网就留 0，不编数字 */
  }
  try {
    const raw = localStorage.getItem('yunxia.favs')
    counts.favs = raw ? (JSON.parse(raw) as string[]).length : 0
  } catch {
    counts.favs = 0
  }
}

function pickSrc(id: string) {
  srcOpen.value = false
  if (id === curId.value) return
  curId.value = id
  localStorage.setItem('yunxia.source', id)
  emit('source', id)
  emit('toast', '已切到 ' + (srcs.value.find((s) => s.id === id)?.name || id))
  load()
}

function setView(v: 'list' | 'grid') {
  emit('view', v)
  emit('toast', v === 'grid' ? '网格缩略图' : '紧凑列表')
}

function setTheme(id: string) {
  emit('theme', id)
  emit('toast', '主题：' + (THEMES.find((t) => t.id === id)?.name || id))
}

function clearPos() {
  localStorage.removeItem('yunxia.pos')
  localStorage.removeItem('mfm_pos')
  emit('toast', '播放记录已清空')
}

async function doLogout() {
  const ok = await confirmBox('退出登录？', '退出后要重新输入口令才能上传。', '退出')
  if (ok) emit('logout')
}

onMounted(load)
</script>

<template>
  <div class="set">
    <header class="brandbar">
      <div class="brand-name">云匣</div>
      <button class="avatar" @click="emit('go', 'me')">我</button>
    </header>

    <p class="set-sub">改动立刻生效 · 只存在这台设备</p>
    <h1 class="page-title">设置</h1>

    <!-- 状态卡：来源快照 + 三个统计 -->
    <div class="stat-card">
      <div class="stat-top">
        <span class="stat-ico" :style="{ background: curIco.bg, color: curIco.fg }">
          <Ico :name="curIco.i" :size="22" />
        </span>
        <span class="stat-name">
          <b>{{ curName }}</b>
          <i>{{ subOf(cur) || '共享目录' }}</i>
        </span>
        <span class="pill" :class="{ on: authed }">{{ authed ? '已连接' : '未登录' }}</span>
      </div>
      <div class="stat-line" />
      <div class="stat-row">
        <div class="stat"><b>{{ counts.dirs }}</b><i>文件夹</i></div>
        <div class="vline" />
        <div class="stat"><b>{{ counts.files }}</b><i>文件</i></div>
        <div class="vline" />
        <div class="stat"><b>{{ counts.favs }}</b><i>收藏</i></div>
      </div>
    </div>

    <div class="sec">账号</div>
    <div class="gcard">
      <button class="grow" @click="srcOpen = true">
        <span class="gico" style="background: color-mix(in srgb, var(--ac) 14%, var(--surface)); color: var(--ac)">
          <Ico name="src-nas" :size="18" />
        </span>
        <span class="gtx">
          <b>文件源</b>
          <i>{{ srcs.length ? `共 ${srcs.length} 个 · 当前 ${curName}` : '还没有文件源' }}</i>
        </span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
      <div class="hline" />
      <button class="grow" @click="emit('pwd')">
        <span class="gico" style="background: color-mix(in srgb, #e08a16 14%, var(--surface)); color: #e08a16">
          <Ico name="lock" :size="18" />
        </span>
        <span class="gtx">
          <b>写入口令</b>
          <i>{{ authed ? '已填 · 能改文件' : '未填 · 现在只能看，改文件要填一次' }}</i>
        </span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
    </div>

    <div class="sec">外观</div>
    <div class="gcard">
      <div class="grow static">
        <span class="gico plain"><Ico name="grid" :size="18" /></span>
        <span class="gtx"><b>显示方式</b></span>
        <span class="seg">
          <button :class="{ on: view === 'list' }" @click="setView('list')">紧凑列表</button>
          <button :class="{ on: view === 'grid' }" @click="setView('grid')">网格缩略图</button>
        </span>
      </div>
      <div class="hline" />
      <div class="grow col">
        <span class="rowline">
          <span class="gico plain"><Ico name="setting" :size="18" /></span>
          <b>主题</b>
          <i class="dim">当前：{{ themeName }}</i>
        </span>
        <span class="chips">
          <button
            v-for="t in THEMES"
            :key="t.id"
            class="chip"
            :class="{ on: theme === t.id }"
            @click="setTheme(t.id)"
          >
            <s class="tsw">
              <i :style="{ background: t.bg }"></i>
              <i class="ac" :style="{ background: t.ac }"></i>
            </s>
            {{ t.name }}
          </button>
        </span>
      </div>
    </div>

    <div class="sec">播放器</div>
    <div class="gcard">
      <div class="grow col">
        <span class="rowline">
          <span class="gico plain"><Ico name="speed" :size="18" /></span>
          <b>长按倍速</b>
          <i class="dim">按住画面时用这个速度</i>
        </span>
        <span class="chips">
          <button v-for="r in [1.5, 2, 3]" :key="r" class="chip" :class="{ on: lpRate === r }" @click="setLp(r)">
            {{ r }}×
          </button>
        </span>
      </div>
      <div class="hline" />
      <div class="grow col">
        <span class="rowline">
          <span class="gico plain"><Ico name="arrow-right" :size="18" /></span>
          <b>滑动灵敏度</b>
          <i class="dim">左右滑快进的倍率</i>
        </span>
        <span class="chips">
          <button v-for="k in [0.5, 1, 1.5, 2]" :key="k" class="chip" :class="{ on: swK === k }" @click="setSw(k)">
            {{ k }}
          </button>
        </span>
      </div>
    </div>

    <div class="sec">更多</div>
    <div class="gcard">
      <button class="grow" @click="emit('refresh')">
        <span class="gico" style="background: color-mix(in srgb, var(--ac) 14%, var(--surface)); color: var(--ac)">
          <Ico name="refresh" :size="18" />
        </span>
        <span class="gtx"><b>刷新列表</b><i>重新向服务端取这个目录</i></span>
      </button>
      <div class="hline" />
      <button class="grow" @click="emit('root')">
        <span class="gico" style="background: #e8f2ff; color: var(--ac)">
          <Ico name="home" :size="18" />
        </span>
        <span class="gtx"><b>回到共享根目录</b><i>直接跳到最外层</i></span>
      </button>
      <div class="hline" />
      <button class="grow" @click="clearPos">
        <span class="gico" style="background: color-mix(in srgb, #e45e53 14%, var(--surface)); color: #e45e53">
          <Ico name="trash" :size="18" />
        </span>
        <span class="gtx"><b>清空播放记录</b><i>忘掉每个文件看到哪儿</i></span>
      </button>
      <div class="hline" />
      <button class="grow" @click="emit('go', 'more')">
        <span class="gico" style="background: color-mix(in srgb, #5d7391 14%, var(--surface)); color: var(--ink2)">
          <Ico name="more" :size="18" />
        </span>
        <span class="gtx"><b>健康检查</b><i>连接检测 · 清理缓存</i></span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
    </div>

    <div class="sec">关于</div>
    <div class="gcard">
      <div class="grow static">
        <span class="gico plain"><Ico name="info" :size="18" /></span>
        <span class="gtx">
          <b>云匣 · 开源版</b>
          <i>{{ origin }}</i>
        </span>
      </div>
    </div>

    <button class="logout" @click="doLogout">退出登录</button>

    <!-- 文件源：底部弹窗 -->
    <div v-if="srcOpen" class="mask" @click.self="srcOpen = false">
      <div class="sheet">
        <div class="sheet-h">文件源</div>
        <div class="gcard flat">
          <template v-for="(s, i) in srcs" :key="s.id">
            <div v-if="i" class="hline" />
            <button class="grow" @click="pickSrc(s.id)">
              <span class="gico" :style="{ background: icoOf(s).bg, color: icoOf(s).fg }">
                <Ico :name="icoOf(s).i" :size="18" />
              </span>
              <span class="gtx">
                <b>{{ s.name || s.id }}</b>
                <i>
                  {{ s.id === curId ? '正在用这个源' : s.writable ? '可写 · 上传 / 改名 / 删除' : '只读 · 浏览和播放不用登录' }}
                </i>
              </span>
              <span class="pill" :class="{ on: s.id === curId }">
                {{ s.id === curId ? '当前' : s.writable ? '可写' : '只读' }}
              </span>
            </button>
          </template>
          <div v-if="!srcs.length" class="empty">还没有文件源</div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* 体检卡片 */
.diag {
  margin: 14px 0 4px;
  padding: 0 14px 4px;
  background: var(--surface);
  border-radius: 14px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
}
.diag-head {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 8px 0;
  border: 0;
  background: none;
  cursor: pointer;
  text-align: left;
}
.diag-sum {
  margin-left: auto;
  font-size: 12px;
  color: var(--ink3);
}
.diag-sum.warn {
  color: #e08b0a;
}
.diag-chev {
  color: var(--ink3);
  transition: transform 0.18s;
}
.diag-chev.rot {
  transform: rotate(90deg);
}
.diag-foot {
  border-top: 1px solid var(--line2);
  padding: 4px 0 2px;
  text-align: right;
}
.diag-head b {
  font-size: 13px;
  font-weight: 600;
  color: var(--ink);
}
.diag-re {
  border: 0;
  background: none;
  padding: 4px 2px;
  font-size: 12px;
  color: var(--ac);
  cursor: pointer;
}
.diag-re:disabled {
  color: var(--ink3);
  cursor: default;
}
.diag-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 0;
  cursor: pointer;
}
.diag-row + .diag-row {
  border-top: 1px solid var(--line2);
}
.diag-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex: none;
}
.diag-tx {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  flex: 1;
}
.diag-tx b {
  font-size: 13px;
  font-weight: 500;
  color: var(--ink);
}
.diag-tx i {
  font-size: 11.5px;
  font-style: normal;
  color: var(--ink3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.diag-act {
  font-size: 12px;
  color: var(--ac);
  flex: none;
}

.set {
  padding: 18px 19px 40px;
  max-width: 780px;
  margin: 0 auto;
}

.brandbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.brand-name {
  font-size: 13px;
  font-weight: 700;
  color: var(--ink3);
  letter-spacing: 0.5px;
}

.brandbar .avatar {
  width: 36px;
  height: 36px;
  border: 0;
  border-radius: 50%;
  background: #edf2f8;
  color: #41536b;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
}

.set-sub {
  font-size: 12px;
  color: var(--ink3);
  margin: 0 0 5px;
}

.page-title {
  font-size: 26px;
  font-weight: 750;
  letter-spacing: -0.6px;
  margin: 0 0 16px;
}

/* ---------- 来源快照卡 ---------- */
.stat-card {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 18px;
  box-shadow: 0 2px 10px var(--sh);
  overflow: hidden;
  margin-bottom: 16px;
}

.stat-top {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 14px;
}

.stat-ico {
  width: 40px;
  height: 40px;
  flex: 0 0 40px;
  border-radius: 12px;
  display: grid;
  place-items: center;
}

.stat-name {
  flex: 1;
  min-width: 0;
}

.stat-name b {
  display: block;
  font-size: 15.5px;
  font-weight: 600;
  color: var(--ink);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.stat-name i {
  display: block;
  font-style: normal;
  font-size: 12px;
  color: var(--ink2);
  margin-top: 2px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.stat-line {
  height: 1px;
  background: var(--line2);
}

.stat-row {
  display: flex;
  align-items: center;
}

.stat {
  flex: 1;
  text-align: center;
  padding: 11px 0;
}

.stat b {
  display: block;
  font-size: 17px;
  font-weight: 700;
  color: var(--ink);
}

.stat i {
  display: block;
  font-style: normal;
  font-size: 11.5px;
  color: var(--ink3);
  margin-top: 3px;
}

.vline {
  width: 1px;
  height: 34px;
  background: var(--line2);
}

/* ---------- 分组卡片 ---------- */
.sec {
  font-size: 11.5px;
  font-weight: 600;
  letter-spacing: 0.3px;
  color: #8795a8;
  padding: 0 14px;
  margin: 13px 0 6px;
}

.gcard {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 17px;
  box-shadow: 0 2px 10px var(--sh);
  overflow: hidden;
  margin-bottom: 12px;
}

.gcard.flat {
  box-shadow: none;
  margin-bottom: 0;
}

.grow {
  display: flex;
  align-items: center;
  gap: 11px;
  width: 100%;
  min-height: 52px;
  padding: 11px 14px;
  border: 0;
  background: none;
  text-align: left;
  cursor: pointer;
  font: inherit;
}

.grow.static {
  cursor: default;
}

.grow.col {
  flex-direction: column;
  align-items: stretch;
  gap: 10px;
  padding: 13px 14px;
}

.grow:not(.static):hover {
  background: var(--surface2);
}

.gico {
  width: 30px;
  height: 30px;
  flex: 0 0 30px;
  border-radius: 9px;
  display: grid;
  place-items: center;
}

.gico.plain {
  background: none;
  width: 20px;
  flex: 0 0 20px;
  color: var(--ink2);
}

.gtx {
  flex: 1;
  min-width: 0;
}

.rowline {
  display: flex;
  align-items: center;
  gap: 11px;
  width: 100%;
}

.gtx b {
  display: block;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.3;
  color: var(--ink);
}

.rowline b {
  font-size: 13px;
  font-weight: 600;
  color: var(--ink);
}

.gtx i {
  display: block;
  font-style: normal;
  font-size: 11.5px;
  line-height: 1.3;
  color: #8795a8;
  margin-top: 3px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.gtx i.dim,
.rowline i.dim {
  font-style: normal;
  font-size: 11.5px;
  color: #8795a8;
  margin-left: auto;
}

.gchev {
  color: var(--ink3);
  opacity: 0.55;
  flex: none;
}

.hline {
  height: 1px;
  background: var(--line2);
}

/* 分段控件（同 App 的 _Seg） */
.seg {
  display: flex;
  padding: 3px;
  gap: 2px;
  background: var(--surface2);
  border: 1px solid var(--line2);
  border-radius: 10px;
}

.seg button {
  border: 0;
  background: none;
  padding: 5px 9px;
  border-radius: 8px;
  font-size: 11.5px;
  font-weight: 600;
  color: var(--ink3);
  cursor: pointer;
}

.seg button.on {
  background: var(--surface);
  color: var(--ink);
  box-shadow: 0 1px 6px var(--sh);
}

/* 主题色块 */
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.chip {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 8px 13px;
  border-radius: 11px;
  border: 1px solid var(--line);
  background: var(--surface2);
  color: var(--ink2);
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
}

.chip.on {
  background: var(--ac);
  border-color: var(--ac);
  color: var(--onac);
}

.tsw {
  position: relative;
  display: block;
  flex: 0 0 auto;
  width: 26px;
  min-width: 26px;
  height: 22px;
}

.tsw i {
  position: absolute;
  display: block;
}

.tsw i:first-child {
  left: 0;
  top: 3px;
  width: 17px;
  height: 17px;
  border-radius: 6px;
  box-shadow: inset 0 0 0 1px rgba(128, 128, 128, 0.4);
}

.tsw i.ac {
  left: 12px;
  top: 8px;
  width: 11px;
  height: 11px;
  border-radius: 50%;
  box-shadow: 0 0 0 2px var(--surface);
}

/* 权限胶囊 */
.pill {
  flex: none;
  padding: 3px 9px;
  border-radius: 999px;
  background: var(--surface2);
  color: var(--ink3);
  font-size: 11px;
  font-weight: 600;
}

.pill.on {
  background: var(--acw);
  color: var(--ac);
}

.pill.warn {
  background: #fdecea;
  color: #e45e53;
}

/* 退出登录 */
.logout {
  width: 100%;
  height: 52px;
  margin-top: 6px;
  border: 1px solid var(--line);
  border-radius: 18px;
  background: var(--surface);
  color: #e45e53;
  font-size: 14.5px;
  font-weight: 600;
  cursor: pointer;
}

.logout:hover {
  background: #fef6f5;
}

/* 底部弹窗 */
.mask {
  position: fixed;
  inset: 0;
  background: var(--ov);
  display: flex;
  align-items: flex-end;
  justify-content: center;
  z-index: 40;
  padding: 10px;
}

.sheet {
  width: min(560px, 100%);
  background: var(--surface);
  border-radius: 22px;
  padding: 12px 14px 16px;
}

.sheet-h {
  font-size: 16px;
  font-weight: 700;
  color: var(--ink);
  padding: 2px 4px 10px;
}

.empty {
  padding: 18px 14px;
  font-size: 12px;
  color: var(--ink3);
  text-align: center;
}

@media (max-width: 760px) {
  .set {
    padding: 14px 16px 32px;
  }

  .page-title {
    font-size: 24px;
  }
}
/* ---------- 115 云盘 ---------- */
.y115-box {
  padding: 4px 16px 14px;
}
.y115-ta {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid var(--line);
  background: var(--bg2, #f6f7f9);
  border-radius: 12px;
  padding: 10px 12px;
  font: inherit;
  font-size: 14px;
  color: var(--ink);
  resize: vertical;
  line-height: 1.5;
}
.y115-ta:focus {
  outline: none;
  border-color: var(--ac);
}
.y115-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 10px;
}
.y115-tip {
  flex: 1 1 auto;
  font-size: 12px;
  color: var(--ink3);
  min-width: 0;
}
.y115-btn {
  flex: none;
  border: 0;
  border-radius: 10px;
  padding: 9px 16px;
  background: var(--ac);
  color: #fff;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
}
.y115-btn:disabled {
  opacity: 0.6;
}
.y115-mini {
  flex: none;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--ink2);
  border-radius: 9px;
  padding: 6px 12px;
  font-size: 12.5px;
  cursor: pointer;
}
.y115-tasks {
  border-top: 1px solid var(--line);
  padding: 10px 16px 14px;
  display: flex;
  flex-direction: column;
  gap: 9px;
}
.y115-task {
  display: grid;
  grid-template-columns: 1fr 56px;
  grid-template-areas: 'name meta' 'bar bar';
  gap: 5px 10px;
  align-items: center;
}
.y115-tname {
  grid-area: name;
  font-size: 12.5px;
  color: var(--ink);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.y115-tmeta {
  grid-area: meta;
  font-size: 12px;
  color: var(--ink3);
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.y115-tbar {
  grid-area: bar;
  height: 4px;
  border-radius: 99px;
  background: var(--line);
  overflow: hidden;
}
.y115-tbar > i {
  display: block;
  height: 100%;
  background: var(--ac);
  border-radius: 99px;
  transition: width 0.3s;
}
</style>
