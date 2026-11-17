<script setup lang="ts">
/* 设置页 —— 样式与分组完全照 App（lib/ui/settings_page.dart），
   顺序：品牌栏 → 副标题 → 标题 → 来源快照 + 三个统计 →
   账号（文件源 / 写入口令）→ 外观（显示方式 / 主题）→ 听·译 → 更多 → 退出登录。
   网页端没有本地下载队列（浏览器自己接管），所以「下载」那一组整块不出现。 */
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
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
const curId = ref(localStorage.getItem('yunxia.source') || 'nas')
const counts = reactive({ dirs: 0, files: 0, favs: 0 })
const authed = ref(!!api.token || !!localStorage.getItem('yunxia.chatkey'))

/* 一眼看清三件事到底通不通：以前要发条消息才知道口令错没错、
   要等字幕转不出来才发现听译没起、翻译源有没有配也得试过才懂。 */
type HState = 'idle' | 'ok' | 'warn' | 'bad'
const health = reactive({
  chat: 'idle' as HState,
  chatMsg: '',
  subs: 'idle' as HState,
  subsMsg: '',
  tr: 'idle' as HState,
  trMsg: '',
  busy: false,
})

async function checkup() {
  health.busy = true
  // 对话：有口令 + 网关回包才算通
  // 和 ChatView.authB64() 同一套取法：直接用云匣登录口令也算有
  const a =
    localStorage.getItem('mfm.chat.auth') ||
    (localStorage.getItem('yunxia.chatkey') || '').replace(/^Basic\s+/i, '')
  if (!a) {
    health.chat = 'warn'
    health.chatMsg = '还没填对话口令'
  } else {
    try {
      const r = await fetch('/hermes/api/log?since=999999999', {
        headers: { Authorization: 'Basic ' + a },
      })
      health.chat = r.ok ? 'ok' : 'bad'
      health.chatMsg = r.ok ? '网关正常' : `网关返回 ${r.status}`
      if (r.status === 401) health.chatMsg = '口令不对'
    } catch {
      health.chat = 'bad'
      health.chatMsg = '连不上网关'
    }
  }
  // 听译：hub 在不在、手上有没有活
  try {
    const r: any = await api.subs()
    if (r?.online) {
      const live = (r.jobs || []).filter((j: any) => j.state === 'running' || j.live).length
      health.subs = 'ok'
      health.subsMsg = live ? `在线 · ${live} 个在跑` : '在线'
    } else {
      health.subs = 'bad'
      health.subsMsg = r?.error ? String(r.error).slice(0, 40) : '中枢没起来'
    }
  } catch {
    health.subs = 'bad'
    health.subsMsg = '连不上听译中枢'
  }
  // 翻译源：密钥在 NAS，客户端只拿一次
  const cached = localStorage.getItem('yunxia.trcfg')
  try {
    const c: any = await api.trCfg()
    if (c?.key) {
      health.tr = 'ok'
      health.trMsg = `${c.model || c.provider || '已配置'}`
      localStorage.setItem('yunxia.trcfg', JSON.stringify({ model: c.model, provider: c.provider }))
    } else {
      health.tr = 'warn'
      health.trMsg = '没配密钥（译文要靠它）'
    }
  } catch {
    if (cached) {
      const c = JSON.parse(cached)
      health.tr = 'warn'
      health.trMsg = `${c.model || '已缓存'} · 暂时读不到`
    } else {
      health.tr = 'bad'
      health.trMsg = '取不到翻译配置'
    }
  }
  health.busy = false
}

const hDot = (st: HState) =>
  st === 'ok' ? '#16a34a' : st === 'warn' ? '#b3720f' : st === 'bad' ? '#e45e53' : 'var(--ink3)'
const srcOpen = ref(false)

/* ---------- CloudDrive2：设置页只负责「填令牌」，云下载入口在文件页 ---------- */
const cd2 = ref<any>({ ok: false, ready: false, login: false, user: '', token_set: false })
const cd2Open = ref(false)
const cd2Tok = ref('')
const cd2Busy = ref(false)
const cd2Msg = ref('')

async function cd2Load() {
  try {
    cd2.value = await api.cd2Status()
  } catch {
    cd2.value = { ok: false }
  }
}

async function cd2Save() {
  if (!cd2Tok.value.trim() || cd2Busy.value) return
  cd2Busy.value = true
  cd2Msg.value = ''
  try {
    const r = await api.cd2Token(cd2Tok.value.trim())
    cd2Tok.value = ''
    cd2Msg.value = `令牌可用 · 目录里 ${r.items} 个条目`
    await cd2Load()
  } catch (e: any) {
    cd2Msg.value = e?.message || '令牌验证失败'
  } finally {
    cd2Busy.value = false
  }
}

/* 体检默认收起成一行：只有出问题才值得占屏 */
const diagOpen = ref(false)
const diagBad = computed(() =>
  [health.chat, health.subs, health.tr].filter((x) => x === 'warn' || x === 'bad').length,
)
const diagSummary = computed(() => {
  if (health.busy) return '检查中…'
  if (!health.chat && !health.subs && !health.tr) return '服务、听译、翻译'
  return diagBad.value ? `${diagBad.value} 项要注意` : '全部正常'
})

onMounted(() => {
  void cd2Load()
})


/* 主题列表照 5020 旧前端：浅色 / 深色 / 蓝色 / 绿色 / 护眼，bg+ac 用来画双色板 */
const THEMES: { id: string; name: string; bg: string; ac: string }[] = [
  { id: 'light', name: '浅色', bg: '#f2f3f5', ac: '#3a3a3c' },
  { id: 'dark', name: '深色', bg: '#121417', ac: '#4c9aff' },
  { id: 'blue', name: '蓝色', bg: '#f4f7fc', ac: '#1677f8' },
  { id: 'green', name: '绿色', bg: '#f2f9f4', ac: '#16a34a' },
  { id: 'sepia', name: '护眼', bg: '#f4efe3', ac: '#b07d3a' },
]

/* 来源副标题：服务端给了就用，没有按 kind 兜底（同 App 的 _sourceSub） */
function subOf(s: Src | undefined) {
  if (!s) return ''
  if (s.sub) return s.sub
  switch (s.kind) {
    case 'dufs':
      return 'files · 192.168.1.10:5007'
    case 'relay115':
    case 'webdav':
      return 'CloudDrive 网盘 · 只读'
    case 'pcdufs':
      return '经 NAS 中转'
    default:
      return ''
  }
}

const cur = computed(() => srcs.value.find((s) => s.id === curId.value))
const curName = computed(() => cur.value?.name || 'NAS')

const icoOf = (s?: Src) => {
  const k = s?.kind || ''
  if (k === 'relay115' || k === 'webdav') return { i: 'src-nas', bg: '#E8F2FF', fg: 'var(--ac)' }
  if (k === 'pcdufs') return { i: 'src-nas', bg: 'color-mix(in srgb, #E08A16 14%, var(--surface))', fg: '#E08A16' }
  return { i: 'src-nas', bg: 'var(--icobg)', fg: 'var(--ac)' }
}
const curIco = computed(() => icoOf(cur.value))

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

const themeName = computed(() => THEMES.find((t) => t.id === props.theme)?.name || '默认')

/* ── 下载监控 ────────────────────────────────────────────────
   云下载（CloudDrive 离线）+ 磁力（aria2）+ ed2k（aMule）。
   只在设置页开着的时候每 5 秒拉一次，页面不可见就停。 */
type DlItem = { name: string; pct: number; state: string; speed: number }

const dl = reactive({
  cd2: { ok: false, active: 0, total: 0, items: [] as DlItem[] },
  magnet: { ok: false, active: 0, speed: 0, items: [] as DlItem[] },
  ed2k: { ok: false, active: 0, speed: 0, items: [] as DlItem[] },
  at: '',
  busy: false,
})
let dlTimer: number | undefined

const CLOUD: Record<number, { label: string; done: boolean }> = {
  0: { label: '排队中', done: false },
  1: { label: '下载中', done: false },
  2: { label: '已完成', done: true },
  3: { label: '出错', done: false },
  4: { label: '已暂停', done: false },
}

function fmtSpeed(n: number) {
  const v = Math.max(0, Math.round(n))
  if (v < 1024) return `${v} B/s`
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(0)} KB/s`
  return `${(v / 1024 / 1024).toFixed(1)} MB/s`
}

function loadDl(force = false) {
  // 后台标签页只靠定时器停手；首次进页面和点「刷新」要强制取一次
  if (!force && document.hidden) return
  dl.busy = true
  void Promise.allSettled([api.cd2OfflineAll(), api.tasks()]).then(([cr, tr]) => {
    dl.busy = false
    dl.at = new Date().toTimeString().slice(0, 5)

    const c: any = cr.status === 'fulfilled' ? cr.value : null
    if (c && Array.isArray(c.items)) {
      dl.cd2.ok = true
      const live = c.items
        .filter((x: any) => (CLOUD[x.status] ? !CLOUD[x.status].done : true))
        .map((x: any) => ({
          name: String(x.name || '未命名'),
          pct: Math.max(0, Math.min(100, Number(x.percent) || 0)),
          state: (CLOUD[x.status] || { label: '未知' }).label,
          speed: 0,
        }))
      dl.cd2.total = c.items.length
      // 只有「下载中」算在下，排队另算（以前把排队也算成在了）
      dl.cd2.active = live.filter((t: any) => t.state === '下载中').length
      dl.cd2.items = live.slice(0, 8)
    } else {
      dl.cd2.ok = false
      dl.cd2.active = 0
      dl.cd2.items = []
    }

    const t: any = tr.status === 'fulfilled' ? tr.value : null
    for (const k of ['magnet', 'ed2k'] as const) {
      const hub = t?.hubs?.[k]
      // aMule 回的是 "Waiting"（大写），aria2 是小写，统一小写比较
      const st = (x: any) => String(x.state || '').toLowerCase()
      const rows: any[] = (t?.tasks || []).filter((x: any) => x.kind === k && st(x) !== 'done')
      dl[k].ok = !!hub?.online
      dl[k].active = rows.filter((x) => st(x) === 'active' || st(x) === 'waiting').length
      dl[k].speed = rows
        .filter((x) => st(x) === 'active')
        .reduce((a, x) => a + (Number(x.speed) || 0), 0)
      dl[k].items = rows
        .slice(0, 8)
        .map((x) => ({
          name: String(x.name || x.id || '未命名'),
          pct: Math.max(0, Math.min(100, Number(x.pct) || 0)),
          state:
            ({ active: '下载中', waiting: '排队中', paused: '已暂停', error: '出错' } as Record<string, string>)[
              st(x)
            ] || String(x.state || ''),
          speed: Number(x.speed) || 0,
        }))
    }
  })
}

// 设置页只留一句合并摘要，明细都在下载队列页
const dlSummary = computed(() => {
  if (!dl.cd2.ok && !dl.magnet.ok && !dl.ed2k.ok) {
    return dl.magnet.ok || dl.cd2.ok ? '正在取状态…' : '云下载 / 磁力 / ed2k · 连不上 NAS'
  }
  const running = dl.cd2.active + dl.magnet.active + dl.ed2k.active
  const waiting =
    dl.cd2.items.filter((t) => t.state === '排队中').length +
    dl.magnet.items.filter((t) => t.state === '排队中').length +
    dl.ed2k.items.filter((t) => t.state === '排队中').length
  // 已完成的不算「任务」，但也别写成「现在没有任务」——队列里可能躺着一堆已完成的
  if (running === 0 && waiting === 0) return '云下载 / 磁力 / ed2k · 没有在下的'
  const sp = dl.magnet.speed + dl.ed2k.speed
  return [
    `${running} 个在下`,
    sp > 0 ? fmtSpeed(sp) : '',
    waiting > 0 ? `${waiting} 个排队` : '',
  ]
    .filter(Boolean)
    .join(' · ')
})




onMounted(load)
onMounted(() => {
  void checkup()
})
onMounted(() => {
  loadDl(true)
  dlTimer = window.setInterval(() => loadDl(), 5000)
})
onBeforeUnmount(() => window.clearInterval(dlTimer))
</script>

<template>
  <div class="set">
    <header class="brandbar">
      <div class="brand-name">云匣</div>
      <button class="avatar" @click="emit('go', 'me')">我</button>
    </header>

    <p class="set-sub">改动立刻生效 · 只存在这台设备</p>
    <h1 class="page-title">设置</h1>

    <!-- 来源快照 + 三个统计 -->
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

    <!-- 体检：默认一行，点开才展开三项 -->
    <div class="diag">
      <button class="diag-head" @click="diagOpen = !diagOpen">
        <b>体检</b>
        <span class="diag-sum" :class="{ warn: diagBad > 0 }">{{ diagSummary }}</span>
        <Ico class="diag-chev" :class="{ rot: diagOpen }" name="chevron-right" :size="15" />
      </button>
      <template v-if="diagOpen">
        <div class="diag-row" @click="emit('pwd')">
          <span class="diag-dot" :style="{ background: hDot(health.chat) }" />
          <span class="diag-tx"><b>对话</b><i>{{ health.chatMsg || '还没检查' }}</i></span>
          <span class="diag-act">{{ health.chat === 'ok' ? '正常' : '去填口令' }}</span>
        </div>
        <div class="diag-row" @click="emit('go', 'subs')">
          <span class="diag-dot" :style="{ background: hDot(health.subs) }" />
          <span class="diag-tx"><b>听译</b><i>{{ health.subsMsg || '还没检查' }}</i></span>
          <span class="diag-act">去听监控</span>
        </div>
        <div class="diag-row" @click="emit('go', 'subcfg')">
          <span class="diag-dot" :style="{ background: hDot(health.tr) }" />
          <span class="diag-tx"><b>翻译</b><i>{{ health.trMsg || '还没检查' }}</i></span>
          <span class="diag-act">去设置</span>
        </div>
        <div class="diag-foot">
          <button class="diag-re" :disabled="health.busy" @click="checkup">
            {{ health.busy ? '检查中…' : '重新检查' }}
          </button>
        </div>
      </template>
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
          <i>{{ authed ? '已填 · 能改文件，对话也能用' : '未填 · 现在只能看，改文件和对话要填一次' }}</i>
        </span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
      <div class="hline" />
      <button class="grow" @click="cd2Open = !cd2Open">
        <span
          class="gico"
          :style="{
            background: cd2.ok
              ? 'color-mix(in srgb, #16a34a 14%, var(--surface))'
              : 'color-mix(in srgb, #e45e53 14%, var(--surface))',
            color: cd2.ok ? '#16a34a' : '#e45e53',
          }"
        >
          <Ico name="src-cloud" :size="18" />
        </span>
        <span class="gtx">
          <b>CloudDrive2 令牌</b>
          <i>{{
            cd2.ok
              ? cd2.token_set
                ? '已配置 · 115 网盘可读写、可云下载'
                : '在线 · 还差一个令牌'
              : '连不上，检查 NAS 上的 CloudDrive 容器'
          }}</i>
        </span>
        <span class="pill" :class="{ on: cd2.token_set }">{{ cd2.token_set ? '正常' : '待配置' }}</span>
      </button>
      <template v-if="cd2Open">
        <div class="hline" />
        <div class="y115-box">
          <input v-model="cd2Tok" class="y115-ta" placeholder="API 令牌" />
          <div class="y115-row">
            <span class="y115-tip">{{ cd2Msg || 'CloudDrive 后台 → 设置 → API 令牌' }}</span>
            <button class="y115-btn" :disabled="cd2Busy" @click="cd2Save()">
              {{ cd2Busy ? '验证中…' : '保存' }}
            </button>
          </div>
        </div>
      </template>
    </div>

    <div class="sec">下载</div>
    <div class="gcard">
      <button class="grow" @click="emit('go', 'dl')">
        <span class="gico" style="background: color-mix(in srgb, #1677f8 14%, var(--surface)); color: #1677f8">
          <Ico name="download" :size="18" />
        </span>
        <span class="gtx">
          <b>下载队列</b>
          <i>{{ dlSummary }}</i>
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

    <div class="sec">听 · 译</div>
    <div class="gcard">
      <button class="grow" @click="emit('go', 'subs')">
        <span class="gico" style="background: color-mix(in srgb, #0d9c7a 14%, var(--surface)); color: #0d9c7a">
          <Ico name="monitor" :size="18" />
        </span>
        <span class="gtx">
          <b>听译监控</b>
          <i>所有任务的进度 · 导出 · 重听 · 停止</i>
        </span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
      <div class="hline" />
      <button class="grow" @click="emit('go', 'subcfg')">
        <span class="gico" style="background: color-mix(in srgb, #7c5cf0 14%, var(--surface)); color: #7c5cf0">
          <Ico name="speed" :size="18" />
        </span>
        <span class="gtx">
          <b>听设置</b>
          <i>实时开关 · 识别精度 · 服务地址</i>
        </span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
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
        <span class="gtx"><b>更多</b><i>连接检测 · 清理缓存 · 权限</i></span>
        <Ico class="gchev" name="chevron-right" :size="17" />
      </button>
    </div>

    <button class="logout" @click="doLogout">退出登录</button>

    <!-- 文件源：底部弹窗（同 App 的 _showSources） -->
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
