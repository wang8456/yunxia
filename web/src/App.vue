<script setup lang="ts">
import Ico from './components/Ico.vue'
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { api, ApiError } from './api'
import MoreView from './views/MoreView.vue'
import ChatView from './views/ChatView.vue'
import SettingsView from './views/SettingsView.vue'
import HomeView from './views/HomeView.vue'
import FilesView from './views/FilesView.vue'
import SearchView from './views/SearchView.vue'
import SubsView from './views/SubsView.vue'

/* 'subs' 是听译队列：不进主导航，只从「设置 → 听·译」和文件页 ⋯ →「查看字幕作业」跳进来 */
type Tab = 'home' | 'files' | 'chat' | 'me' | 'search' | 'more' | 'subs'
const tab = ref<Tab>('home')
const authed = ref(false)
const booting = ref(true)
const toast = ref('')
const theme = ref(normTheme(localStorage.getItem('yunxia.theme') || 'blue'))
const online = ref(true)
const dirCount = ref(0)
const fileCount = ref(0)
const favCount = ref(0)
const srcCount = ref(0)
const srcName = ref('')
const writable = ref(!!localStorage.getItem('yunxia.writable'))
const viewMode = ref(localStorage.getItem('yunxia.viewmode') || 'list')

/* 来源名照 App 的叫法：NAS / 115 网盘 / 电脑 */
/// 切换文件源：模板里不能直接写 localStorage（Vue 会编译成 _ctx.localStorage，
/// 运行期是 undefined，整个处理器抛 TypeError，后面的 fileEpoch++ 就不执行了）
function setSource(id: string) {
  try {
    localStorage.setItem('yunxia.source', id)
  } catch {}
  fileEpoch.value++
}

function setViewMode(v: string) {
  viewMode.value = v
  localStorage.setItem('yunxia.viewmode', v)
}

let toastTimer: number | undefined

/* 对话默认关闭：服务端 /meta/sources 里 chat.enabled=false 时整项都不出现 */
const chatOn = ref(false)

const nav = computed<{ id: Tab; label: string; icon: string }[]>(() => {
  const list: { id: Tab; label: string; icon: string }[] = [
    { id: 'home', label: '首页', icon: 'home' },
    { id: 'files', label: '文件', icon: 'folder' },
    { id: 'search', label: '搜索', icon: 'search' },
  ]
  if (chatOn.value) list.push({ id: 'chat', label: '对话', icon: 'chat' })
  list.push({ id: 'me', label: '设置', icon: 'setting' })
  return list
})

/* 侧栏收起：只改宽度，内容区 flex:1 自动让位；状态记本机 */
const sideDown = ref(localStorage.getItem('yunxia.side.collapsed') === '1')
function toggleSide() {
  sideDown.value = !sideDown.value
  localStorage.setItem('yunxia.side.collapsed', sideDown.value ? '1' : '0')
}

/* 侧栏底部储存占用（真数据，拿不到就不显示那一条） */
const stgPct = ref<number | null>(null)
async function loadStg() {
  try {
    const r = await api.storage()
    stgPct.value = r && r.total > 0 ? Math.min(100, Math.round((r.used / r.total) * 100)) : null
  } catch {
    stgPct.value = null
  }
}

const openPath = reactive({ path: '/' })
/* 设置页点「刷新列表」时换 key，强制 FilesView 重新挂载重取 */
const fileEpoch = ref(0)
function refreshFiles() {
  fileEpoch.value++
  showToast('已刷新')
}
const playTarget = ref('')   // 首页「继续观看」点进来要自动播的那条

function showToast(text: string) {
  toast.value = text
  window.clearTimeout(toastTimer)
  toastTimer = window.setTimeout(() => (toast.value = ''), 2200)
}

/** 老版本存的是 'beige'，5020 这套叫 'sepia'（界面上都显示「护眼」） */
function normTheme(t: string) {
  return t === 'beige' ? 'sepia' : t
}

function applyTheme(t: string) {
  t = normTheme(t)
  theme.value = t
  localStorage.setItem('yunxia.theme', t)
  document.documentElement.dataset.theme = t === 'blue' ? '' : t
}

async function probe() {
  try {
    await api.me()
    authed.value = true
  } catch {
    authed.value = false
  }
}

/* 写入口令：换一次、也能清掉（清掉就退回登录页） */
const pwdOpen = ref(false)
const pwdDraft = ref('')
const pwdBusy = ref(false)

async function savePwd() {
  const p = pwdDraft.value.trim()
  if (!p) return
  pwdBusy.value = true
  try {
    const r = await api.login(p)
    api.setToken(r.token)
    localStorage.setItem('yunxia.chatkey', 'Basic ' + btoa('hermes:' + p))
    localStorage.setItem('mfm.chat.auth', btoa('hermes:' + p))
    writable.value = true
    authed.value = true
    pwdOpen.value = false
    pwdDraft.value = ''
    showToast('口令已更新')
  } catch (e) {
    showToast(`口令不对：${e instanceof ApiError ? e.message : e}`)
  } finally {
    pwdBusy.value = false
  }
}

function clearPwd() {
  api.setToken(null)
  localStorage.removeItem('yunxia.chatkey')
  localStorage.removeItem('mfm.chat.auth')
  authed.value = false
  pwdOpen.value = false
  showToast('口令已清掉')
}

function logout() {
  api.setToken(null)
  localStorage.removeItem('yunxia.chatkey')
  localStorage.removeItem('mfm.chat.auth')
  authed.value = false
}

function go(target: Tab, path?: string) {
  if (path) openPath.path = path
  tab.value = target
}

function onNeedPwd() {
  if (!pwdOpen.value) {
    pwdDraft.value = ''
    pwdOpen.value = true
  }
}

onMounted(async () => {
  window.addEventListener('yunxia:pwd', onNeedPwd)
  applyTheme(theme.value)
  api
    .sources()
    .then((r) => {
      srcCount.value = r.sources.length
      // 没选过就用服务端给的默认来源（开源版不写死任何 id）
      const wanted = localStorage.getItem('yunxia.source') || ''
      const cur = r.sources.find((x) => x.id === wanted) || r.sources[0]
      srcName.value = cur ? cur.name : ''
      writable.value = !!cur?.writable
      if (cur && cur.id !== wanted) localStorage.setItem('yunxia.source', cur.id)
      chatOn.value = !!r.chat?.enabled
      if (!chatOn.value && tab.value === 'chat') tab.value = 'home'
      online.value = true
    })
    .catch(() => (online.value = false))
  api
    .searchStatus()
    .then((r) => { dirCount.value = r.dirs; fileCount.value = r.files })
    .catch(() => {})
  try { favCount.value = (JSON.parse(localStorage.getItem('yunxia.favs') || '[]') || []).length } catch { favCount.value = 0 }
  if (api.token) {
    await probe()
    loadStg()
  }
  booting.value = false
})

onUnmounted(() => window.removeEventListener('yunxia:pwd', onNeedPwd))
</script>

<template>
  <div v-if="booting" class="boot">云匣</div>

  <div v-else class="shell">
    <aside class="rail" :class="{ down: sideDown }">
      <button
        class="rail-tgl"
        :title="sideDown ? '展开侧栏' : '收起侧栏'"
        @click="toggleSide"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="4.5" width="18" height="15" rx="3.5" />
          <path d="M9.5 4.5v15" />
        </svg>
      </button>

      <div class="brand">
        <span class="brand-badge">匣</span>
        <span class="brand-txt">云匣<em>{{ srcName ? '私有云 · ' + srcName : '私有云' }}</em></span>
      </div>

      <div class="rail-sec">主导航</div>
      <button
        v-for="n in nav"
        :key="n.id"
        class="rail-item"
        :class="{ active: tab === n.id }"
        :title="n.label"
        @click="tab = n.id"
      >
        <span class="rail-ico"><Ico :name="n.icon" :size="20" /></span>
        <span class="rail-lb">{{ n.label }}</span>
      </button>

      <div class="rail-spacer"></div>

      <div class="rail-foot">
        <div v-if="stgPct !== null" class="rail-quota">
          <span>储存</span>
          <span class="qbar"><i :style="{ width: stgPct + '%' }"></i></span>
          <span>{{ stgPct }}%</span>
        </div>
        <button class="rail-me" title="设置" @click="tab = 'me'">
          <span class="me-av">我</span>
          <span class="me-tx"><b>我</b><em>{{ online ? ('已连接' + (srcName ? ' · ' + srcName : '')) : '连接中…' }}</em></span>
        </button>
      </div>
    </aside>

    <main class="main">
      <HomeView
        v-if="tab === 'home'"
        @play="(p: string) => { playTarget = p; go('files', p.replace(/\/[^/]+$/, '') || '/') }"
        @open="(p: string) => go('files', p)"
        @search="go('search')"
      />
      <FilesView
        v-else-if="tab === 'files'"
        :key="'files-' + fileEpoch"
        v-model:path="openPath.path"
        :toast="showToast"
        :play="playTarget"
        @played="playTarget = ''"
        @search="tab = 'search'"
        @subs="tab = 'subs'"
      />
      <SearchView
        v-else-if="tab === 'search'"
        @open="(p: string) => go('files', p.replace(/\/[^/]+$/, '') || '/')"
      />
      <SubsView v-else-if="tab === 'subs'" :toast="showToast" @back="tab = 'me'" />
      <ChatView v-else-if="tab === 'chat'" />

      <MoreView v-else-if="tab === 'more'" :toast="showToast" :close="() => (tab = 'me')" />
      <SettingsView
        v-else
        :view="viewMode === 'grid' ? 'grid' : 'list'"
        :theme="theme"
        @toast="showToast"
        @go="(t: string) => (tab = t as Tab)"
        @pwd="pwdDraft = ''; pwdOpen = true"
        @theme="applyTheme"
        @view="setViewMode"
        @source="setSource"
        @refresh="refreshFiles"
        @root="go('files', '/')"
        @logout="logout"
      />
    </main>

    <div v-if="pwdOpen" class="mask" @click.self="pwdOpen = false">
      <div class="dlg">
        <h3>口令</h3>
        <p class="dlg-sub">和登录同一个口令 · 只存在这台设备</p>
        <input
          v-model="pwdDraft"
          type="password"
          placeholder="云匣口令"
          autocomplete="current-password"
          @keyup.enter="savePwd"
        />
        <div class="dlg-btns">
          <button class="btn ghost" @click="pwdOpen = false">取消</button>
          <button class="btn" :disabled="pwdBusy" @click="savePwd">保存</button>
        </div>
        <button class="dlg-clear" @click="clearPwd">清掉口令，退回只读</button>
      </div>
    </div>

    <div v-if="toast" class="toast">{{ toast }}</div>
  </div>
</template>

<style scoped>
.boot {
  display: grid;
  place-items: center;
  min-height: 100vh;
  color: var(--ink3);
  font-size: 15px;
  letter-spacing: 3px;
}

.brand-emoji {
  display: flex;
}

.nav-emoji {
  display: flex;
}

.mask {
  position: fixed;
  inset: 0;
  background: rgba(16, 24, 40, 0.32);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 22px;
  z-index: 900;          /* 必须高于播放器（100），否则播放器里点写操作看不见口令框 */
  animation: fade 0.16s ease;
}

@keyframes fade {
  from {
    opacity: 0;
  }
}

.dlg {
  width: 100%;
  max-width: 330px;
  background: var(--surface, #fff);
  border-radius: 18px;
  padding: 20px 18px 14px;
  box-shadow: 0 24px 60px -18px rgba(16, 24, 40, 0.45);
}

.dlg h3 {
  margin: 0 0 5px;
  font-size: 16.5px;
  font-weight: 700;
  color: var(--ink);
}

.dlg-sub {
  margin: 0 0 14px;
  font-size: 12px;
  color: var(--ink3);
  line-height: 1.6;
}

.dlg input {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid var(--line);
  background: var(--bg2, #f6f8fb);
  border-radius: 11px;
  padding: 11px 13px;
  font-size: 16px;
  font-family: inherit;
  color: var(--ink);
  outline: none;
}

.dlg input:focus {
  border-color: var(--ac);
  background: #fff;
  box-shadow: 0 0 0 3px var(--acw);
}

.dlg-btns {
  display: flex;
  gap: 9px;
  margin-top: 13px;
}

.dlg-btns .btn {
  flex: 1;
  padding: 10px 0;
  font-size: 13.5px;
  font-weight: 600;
}

.dlg-clear {
  width: 100%;
  margin-top: 9px;
  border: 0;
  background: none;
  color: var(--ink3);
  font-size: 12px;
  padding: 6px 0;
  font-family: inherit;
}

.toast {
  position: fixed;
  left: 50%;
  bottom: 84px;
  transform: translateX(-50%);
  background: rgba(24, 34, 48, 0.92);
  color: #fff;
  font-size: 12.5px;
  font-weight: 500;
  padding: 9px 16px;
  border-radius: 999px;
  z-index: 950;
  max-width: 80vw;
  text-align: center;
  animation: toastIn 0.18s ease;
}

@keyframes toastIn {
  from {
    opacity: 0;
    transform: translate(-50%, 8px);
  }
}

@media (min-width: 761px) {
  .toast {
    bottom: 32px;
  }
}
</style>
