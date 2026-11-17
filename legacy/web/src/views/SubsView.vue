<script setup lang="ts">
/* 听监控 —— 1:1 照 App 的 lib/ui/subs_page.dart。
   App 原话：听监控只显示「听」（转写）。译是播放时实时翻的，不进这个队列。

   布局（数值全部照 subs_page.dart）：
   - 顶栏 10/6/14/2：← 返回（22）、「听监控」20-700、右侧刷新（19，ink3）
   - 中枢状态：胶囊（正常 #0E9D78 / 离线 #E45E53，底 12% 同色，11.5-600）+ 「队列 N 在转 · N 排队 · 实时听不进队列」11.5
   - 同时转写：左标题 13-ink2，右侧 1 个 / 2 个 / 3 个 胶囊（激活主题色白字，未激活 surface2）
   - 三个分页：容器 3px padding、圆角 11、底 surface2；每格高 32、圆角 9、激活白底加粗
   - 任务卡：13.5 名 + 状态胶囊；第二行 folder 图标 + 文件夹名 11；绿条 5px（完成后 100%）
     「1:34:00 / 1:34:00 · 100% · 1025 段」11.5 等宽数字；按钮 Wrap gap 8：
     查看 / 翻译（只在 done 出现）/ 导出 .srt / 重新转写 / 删除（红）
*/
import Ico from '../components/Ico.vue'
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api } from '../api'
import { confirmBox } from '../ask'

const props = defineProps<{ toast: (t: string) => void; close: () => void }>()

const jobs = ref<any[]>([])
const online = ref(false)
const loading = ref(true)
const err = ref('')
const maxActive = ref(1)
const tab = ref(1) // 0 进行中 / 1 已转好 / 2 已停止
const detail = ref<{ id: string; name: string; lang: string; segs: any[] } | null>(null)
const showTr = ref(true)
const busy = ref(false)
let timer: number | undefined
let inflight = false

/* ---------- 任务模型（照 SubJob 的 getter） ---------- */
const isRunning = (j: any) => j.relocating === true || ['asr', 'translating', 'queued', 'probing'].includes(j.state)
const isDone = (j: any) => j.state === 'done'
const isFailed = (j: any) => ['error', 'cancelled', 'cancel'].includes(j.state)

const STATE_LABEL: Record<string, string> = {
  queued: '排队中',
  probing: '读取片长',
  asr: '转写中',
  translating: '转写中',
  done: '已转好',
  error: '出错',
  cancelled: '已停止',
  cancel: '已停止',
}

function labelOf(j: any) {
  if (j.relocating) return '换位置中'
  return STATE_LABEL[j.state] || j.state || '未知'
}

const running = computed(() => jobs.value.filter(isRunning).length)
const done = computed(() => jobs.value.filter(isDone).length)
const stopped = computed(() => jobs.value.filter(isFailed).length)
const queued = computed(() => jobs.value.filter((j) => j.state === 'queued' || j.state === 'probing').length)

const shown = computed(() =>
  tab.value === 0 ? jobs.value.filter(isRunning) : tab.value === 2 ? jobs.value.filter(isFailed) : jobs.value.filter(isDone),
)

const emptyText = computed(() =>
  tab.value === 0 ? '队列是空的 · 实时听不占队列' : tab.value === 2 ? '没有停掉的任务' : '还没有转好的字幕',
)

/* hub 给的 folder 是签名前缀（f/<ts>/<hash>/<source>/<真实目录>），
   照 App 那样只显示人能看的目录；path 为空时也能拼回真实路径给「重新转写」用 */
function cleanFolder(j: any) {
  const f = String(j.folder || '')
  const m = /^f\/\d+\/[0-9a-f]{32}\/[^/]+\/(.*)$/.exec(f)
  if (m) return m[1] ? '/' + m[1] : '/'
  return f
}

function pathOf(j: any) {
  const p = String(j.path || '')
  if (p) return p
  const f = cleanFolder(j)
  if (f && f.charAt(0) === '/') return (f.replace(/\/$/, '') || '') + '/' + String(j.name || '')
  return String(j.name || '')
}

function mmss(sec: number) {
  const s = Math.round(sec || 0)
  if (s <= 0) return '00:00'
  const m = Math.floor(s / 60)
  const r = s % 60
  if (m >= 60) return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}:${String(r).padStart(2, '0')}`
  return `${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}`
}

function pct(j: any) {
  if (isDone(j)) return 1
  const dur = Number(j.dur || 0)
  const at = Number(j.done_until || 0)
  return dur > 0 ? Math.min(1, Math.max(0, at / dur)) : 0
}

function barColor(j: any) {
  return isDone(j) ? '#0E9D78' : isFailed(j) ? '#E45E53' : 'var(--ac, var(--ac))'
}

function pillCls(j: any) {
  return isDone(j) ? 'ok' : isFailed(j) ? 'bad' : 'run'
}

function metaOf(j: any) {
  const dur = Number(j.dur || 0)
  const at = Number(j.done_until || 0)
  const p = pct(j)
  const parts: string[] = []
  if (isDone(j) && dur > 0) parts.push(`${mmss(dur)} / ${mmss(dur)}`)
  else if (dur > 0) parts.push(`${mmss(at)} / ${mmss(dur)}`)
  else if (at > 0) parts.push(`已转至 ${mmss(at)}`)
  else parts.push('转写中')
  if (j.state === 'probing') parts.push('读取片长…')
  else if (dur > 0) parts.push(`${Math.round(p * 100)}%`)
  parts.push(`${Number(j.segments || 0)} 段`)
  // 「已转好」只代表听完了；译文是客户端/整片翻译后补的，缺得多的时候得让人看见，
  // 否则卡片写着 100% 打开全是原文。
  const total = Number(j.segments || 0)
  const pend = Number(j.pending || 0)
  if (isDone(j) && total > 0 && pend > 0) {
    parts.push(`译文 ${total - pend}/${total}`)
  }
  if (Number(j.eta || 0) > 0 && isRunning(j)) {
    const e = Number(j.eta)
    parts.push(e >= 3600 ? `剩 ${(e / 3600).toFixed(1)} 小时` : `剩 ${Math.round(e / 60)} 分钟`)
  }
  return parts.join(' · ')
}

/* ---------- 数据 ---------- */
async function load(silent = false) {
  if (inflight) return
  inflight = true
  if (!silent) loading.value = true
  try {
    const [r, cfg] = await Promise.all([api.subs(), api.subsConfig().catch(() => null as any)])
    jobs.value = r.jobs || []
    online.value = !!r.online
    err.value = ''
    if (cfg && typeof cfg.max_active === 'number') maxActive.value = cfg.max_active
  } catch (e: any) {
    err.value = String(e?.message || e)
    if (!silent) online.value = false
  } finally {
    loading.value = false
    inflight = false
  }
}

async function setMax(n: number) {
  try {
    await api.setSubsConfig({ max_active: n })
    maxActive.value = n
    props.toast(`同时转写 ${n} 个`)
  } catch (e) {
    props.toast(`设置失败：${e}`)
  }
}

/* ---------- 卡片动作 ---------- */
async function open(j: any) {
  if (!Number(j.segments || 0)) {
    props.toast('这个任务还没有字幕')
    return
  }
  busy.value = true
  try {
    const r = await api.subsDetail(j.id)
    detail.value = {
      id: j.id,
      name: j.name || j.path || '字幕',
      lang: r.lang || j.lang || '',
      segs: r.segments_list || [],
    }
  } catch (e) {
    props.toast(`打开字幕稿失败：${e}`)
  } finally {
    busy.value = false
  }
}

async function exportSrt(j: any) {
  try {
    const tok = api.token || ''
    const r = await fetch(api.absolute(`/api/v1/subs/${encodeURIComponent(j.id)}/srt`), {
      headers: tok ? { Authorization: `Bearer ${tok}` } : {},
    })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    const b = await r.blob()
    const fname = String(j.name || 'subs').replace(/\.[^.]+$/, '') + '.srt'
    /* 手机上（尤其微信内置浏览器）a[download] 经常被直接忽略：
       点了没反应、也不报错。所以先试系统分享（iOS/安卓都能存到文件），
       没有分享能力才退回桌面那套下载，再不行就直接开链接让浏览器自己处理。 */
    const nav: any = navigator
    const file = new File([b], fname, { type: 'application/x-subrip' })
    if (nav.canShare && nav.canShare({ files: [file] })) {
      try {
        await nav.share({ files: [file], title: fname })
        props.toast('已打开分享，选「存储到文件」')
        return
      } catch (e: any) {
        if (String(e?.name) === 'AbortError') return   // 用户自己取消，不弹错误
      }
    }
    const u = URL.createObjectURL(b)
    const a = document.createElement('a')
    a.href = u
    a.download = fname
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(u), 5000)
    // 微信里 a.click() 什么都不做：补一条能点的链接，别让用户以为按钮坏了
    props.toast(`已导出 ${fname}`)
  } catch (e) {
    props.toast(`导出失败：${e}`)
  }
}

/* 网页端没有 App 那个本地翻译器：让中枢换语言，译文由它补回来 */
async function translate(j: any) {
  if (!Number(j.segments || 0)) {
    props.toast('这个任务还没有字幕')
    return
  }
  try {
    await api.subsLang(j.id, 'zh')
    props.toast('已交给 NAS 翻译（中文）')
    setTimeout(() => load(true), 1200)
  } catch (e) {
    props.toast(`翻译失败：${e}`)
  }
}

/* 重新转写：路径和源必须用任务里记的原始值（115 写成 nas 会 404） */
async function again(j: any) {
  if (!(await confirmBox(`重新转写《${j.name}》？`, '现有字幕会被覆盖', '重新转写'))) return
  try {
    // 第五个参数 again=true：hub 才会把旧字幕清空重排队
    await api.subsAdd(pathOf(j), j.name, j.source || 'nas', '', true)
    props.toast('已重新排入转写')
    setTimeout(() => load(true), 800)
  } catch (e: any) {
    const m = String(e?.message || e)
    // 409 busy：这条正在转，服务端拒绝重排（老 worker 还会往里写段落）
    props.toast(m.includes('busy') ? '这个任务正在转写，先停止再重写' : `提交失败：${m}`)
  }
}

async function del(j: any) {
  if (!(await confirmBox('删除这条听任务？', String(j.name || ''), '删除'))) return
  try {
    await api.subsDelete(j.id)
    jobs.value = jobs.value.filter((x) => x.id !== j.id)
    props.toast('已删除')
  } catch (e) {
    props.toast(`删除失败：${e}`)
  }
}

/* ---------- 字幕稿 ---------- */
function segText(seg: any) {
  if (Array.isArray(seg)) return { t: seg[2] || '', tr: seg[3] || '', start: seg[0] }
  return { t: seg.text || seg.t || '', tr: seg.tr || seg.trans || '', start: seg.start || 0 }
}

function plain() {
  if (!detail.value) return ''
  return detail.value.segs
    .map((s) => {
      const x = segText(s)
      return x.tr && showTr.value ? `${x.t}\n${x.tr}` : x.t
    })
    .join('\n')
}

async function copyAll() {
  try {
    await navigator.clipboard.writeText(plain())
    props.toast('全文已复制')
  } catch {
    props.toast('复制失败：浏览器不给剪贴板权限')
  }
}

function stamp(sec: number) {
  const s = Math.max(0, Math.floor(sec || 0))
  const p2 = (n: number) => String(n).padStart(2, '0')
  return `${p2(Math.floor(s / 3600))}:${p2(Math.floor((s % 3600) / 60))}:${p2(s % 60)},000`
}

function saveAs(kind: 'srt' | 'txt') {
  if (!detail.value) return
  let body = ''
  if (kind === 'txt') body = plain()
  else {
    body = detail.value.segs
      .map((s, i) => {
        const x = segText(s)
        const next = detail.value!.segs[i + 1]
        const end = next ? segText(next).start : x.start + 3
        const tr = x.tr && showTr.value ? `\n${x.tr}` : ''
        return `${i + 1}\n${stamp(x.start)} --> ${stamp(end)}\n${x.t}${tr}\n`
      })
      .join('\n')
  }
  const blob = new Blob([body], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = (detail.value.name.replace(/\.[^.]+$/, '') || 'subs') + '.' + kind
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 4000)
}

onMounted(() => {
  load()
  timer = window.setInterval(() => load(true), 3000)
})

onUnmounted(() => window.clearInterval(timer))
</script>

<template>
  <div class="mon">
    <header class="m-head">
      <button class="m-back" aria-label="返回" @click="props.close()"><Ico name="arrow-left" :size="22" /></button>
      <b class="m-title">听监控</b>
      <button class="m-refresh" aria-label="刷新" @click="load()"><Ico name="refresh" :size="19" /></button>
    </header>

    <div class="m-state">
      <span class="pill" :class="online ? 'ok' : 'bad'">{{ online ? '中枢正常' : '中枢离线' }}</span>
      <span class="m-note">{{ err ? '连不上听服务' : `队列 ${running} 在转 · ${queued} 排队 · 实时听不进队列` }}</span>
    </div>

    <div class="m-max">
      <span class="m-max-t">同时转写</span>
      <div class="m-seg">
        <b v-for="n in [1, 2, 3]" :key="n" :class="{ on: maxActive === n }" @click="setMax(n)">{{ n }} 个</b>
      </div>
    </div>

    <div class="m-tabs">
      <button :class="{ on: tab === 0 }" @click="tab = 0">进行中{{ running > 0 ? ' ' + running : '' }}</button>
      <button :class="{ on: tab === 1 }" @click="tab = 1">已转好 {{ done }}</button>
      <button :class="{ on: tab === 2 }" @click="tab = 2">已停止 {{ stopped }}</button>
    </div>

    <div class="m-list">
      <p v-if="loading" class="m-empty">加载中…</p>
      <p v-else-if="!shown.length" class="m-empty">{{ emptyText }}</p>
      <template v-else>
        <div v-for="j in shown" :key="j.id" class="m-card">
          <div class="m-row1">
            <b class="m-name">{{ j.name }}</b>
            <span class="pill" :class="pillCls(j)">{{ labelOf(j) }}</span>
          </div>
          <div class="m-folder">
            <Ico name="folder" :size="12" />
            <span>{{ cleanFolder(j) || j.lang || '—' }}</span>
          </div>
          <div class="m-bar">
            <span :style="{ width: (pct(j) * 100).toFixed(1) + '%', background: barColor(j) }"></span>
          </div>
          <div class="m-meta">{{ metaOf(j) }}</div>
          <div class="m-btns">
            <button :disabled="!j.segments" @click="open(j)">查看</button>
            <button v-if="j.state === 'done'" :disabled="!j.segments" @click="translate(j)">翻译</button>
            <button :disabled="!j.segments" @click="exportSrt(j)">导出 .srt</button>
            <button @click="again(j)">重新转写</button>
            <button class="danger" @click="del(j)">删除</button>
          </div>
        </div>
      </template>
    </div>

    <!-- 字幕稿 -->
    <div v-if="detail" class="sub-mask" @click.self="detail = null">
      <div class="sub-sheet">
        <div class="sub-head">
          <button class="sub-back" aria-label="关闭" @click="detail = null"><Ico name="arrow-left" :size="20" /></button>
          <div class="sub-tt">
            <b>{{ detail.name }}</b>
            <i>{{ detail.segs.length }} 句 · {{ detail.lang || '未知语言' }}</i>
          </div>
          <button class="sub-tr" :class="{ on: showTr }" title="译文" @click="showTr = !showTr">
            <Ico name="translate" :size="18" />
          </button>
        </div>
        <div class="sub-rows">
          <div v-for="(s, i) in detail.segs" :key="i" class="seg">
            <span class="t">{{ mmss(segText(s).start) }}</span>
            <span class="tx">
              <span class="src">{{ segText(s).t }}</span>
              <span v-if="showTr && segText(s).tr" class="tr">{{ segText(s).tr }}</span>
            </span>
          </div>
          <div v-if="!detail.segs.length" class="m-empty">这个任务还没有出字幕</div>
        </div>
        <div class="sub-bar">
          <button @click="copyAll"><Ico name="copy" :size="16" /> 复制全文</button>
          <button @click="saveAs('srt')"><Ico name="download" :size="16" /> 导出 .srt</button>
          <button @click="saveAs('txt')"><Ico name="download" :size="16" /> 导出 .txt</button>
        </div>
      </div>
    </div>

    <div v-if="busy" class="sub-loading">读取字幕稿…</div>
  </div>
</template>

<style scoped>
.mon {
  display: flex;
  flex-direction: column;
  min-height: calc(100vh - 130px);
}

/* ---------- 顶栏 ---------- */
.m-head {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 2px 0;
  margin: 0 0 2px;
}

.m-back,
.m-refresh {
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

.m-refresh {
  color: var(--ink3, #93a3b8);
  margin-left: auto;
}

.m-back:active,
.m-refresh:active {
  background: var(--bg2, #eef1f5);
}

.m-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--ink, #26364a);
  letter-spacing: -0.2px;
}

/* ---------- 中枢状态 ---------- */
.m-state {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 2px 0 10px;
}

.pill {
  font-size: 11.5px;
  font-weight: 600;
  padding: 3px 9px;
  border-radius: 999px;
  white-space: nowrap;
}

.pill.ok {
  color: #0e9d78;
  background: rgba(14, 157, 120, 0.12);
}

.pill.bad {
  color: #e45e53;
  background: rgba(228, 94, 83, 0.12);
}

.pill.run {
  color: var(--ac, var(--ac));
  background: var(--acw, rgba(22, 119, 248, 0.12));
}

.m-note {
  font-size: 11.5px;
  color: var(--ink3, #8795a8);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* ---------- 同时转写 ---------- */
.m-max {
  display: flex;
  align-items: center;
  padding: 0 0 12px;
}

.m-max-t {
  font-size: 13px;
  color: var(--ink2, #5b6b82);
}

.m-seg {
  margin-left: auto;
  display: flex;
  gap: 8px;
}

.m-seg b {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--ink2, #5b6b82);
  background: var(--bg2, #eef1f5);
  padding: 6px 14px;
  border-radius: 999px;
  cursor: pointer;
}

.m-seg b.on {
  background: var(--ac, var(--ac));
  color: #fff;
}

/* ---------- 分页 ---------- */
.m-tabs {
  display: flex;
  padding: 3px;
  background: var(--bg2, #eef1f5);
  border-radius: 11px;
  margin: 0 0 8px;
}

.m-tabs button {
  flex: 1;
  height: 32px;
  border: 0;
  background: transparent;
  border-radius: 9px;
  font-size: 12.5px;
  font-weight: 500;
  color: var(--ink3, #8795a8);
  font-family: inherit;
  cursor: pointer;
}

.m-tabs button.on {
  background: var(--surface, #fff);
  color: var(--ink, #26364a);
  font-weight: 700;
  box-shadow: 0 1px 3px rgba(16, 24, 40, 0.06);
}

/* ---------- 任务卡 ---------- */
.m-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 2px 0 40px;
}

.m-empty {
  text-align: center;
  font-size: 12.5px;
  color: var(--ink3, #8795a8);
  padding: 46px 0;
}

.m-card {
  background: var(--surface, #fff);
  border: 1px solid var(--line, #e9eef5);
  border-radius: 16px;
  padding: 12px 13px;
  box-shadow: 0 2px 10px rgba(53, 99, 156, 0.05);
}

.m-row1 {
  display: flex;
  align-items: flex-start;
  gap: 8px;
}

.m-name {
  flex: 1;
  min-width: 0;
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink, #26364a);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.m-folder {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 4px;
  font-size: 11px;
  color: var(--ink3, #8795a8);
  min-width: 0;
}

.m-folder span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.m-bar {
  height: 5px;
  border-radius: 99px;
  background: var(--bg2, #eef1f5);
  margin-top: 9px;
  overflow: hidden;
}

.m-bar span {
  display: block;
  height: 100%;
  border-radius: 99px;
  transition: width 0.4s ease;
}

.m-meta {
  margin-top: 8px;
  font-size: 11.5px;
  color: var(--ink3, #8795a8);
  font-variant-numeric: tabular-nums;
}

.m-btns {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 10px;
}

.m-btns button {
  border: 1px solid var(--line, #e4eaf3);
  background: var(--bg2, #f7fafe);
  color: var(--ink2, #4a5f7a);
  border-radius: 9px;
  padding: 6px 11px;
  font-size: 12px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
}

.m-btns button:disabled {
  opacity: 0.45;
}

.m-btns button.danger {
  color: #e45e53;
  background: #fff5f4;
  border-color: #fadcd9;
}

/* ---------- 字幕稿 ---------- */
.sub-mask {
  position: fixed;
  inset: 0;
  background: rgba(16, 24, 40, 0.3);
  z-index: 30;
  display: flex;
  align-items: flex-end;
  justify-content: center;
}

.sub-sheet {
  width: 100%;
  max-width: 720px;
  height: 88vh;
  background: var(--bg, #f6f8fb);
  border-radius: 18px 18px 0 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.sub-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  border-bottom: 1px solid var(--line, #e9eef5);
  background: var(--surface, #fff);
}

.sub-back,
.sub-tr {
  border: 0;
  background: transparent;
  color: var(--ink2, #44526a);
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  border-radius: 9px;
}

.sub-tr.on {
  color: var(--ac, var(--ac));
}

.sub-tt {
  flex: 1;
  min-width: 0;
}

.sub-tt b {
  display: block;
  font-size: 13px;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sub-tt i {
  display: block;
  font-style: normal;
  font-size: 11.5px;
  color: var(--ink3, #8795a8);
  margin-top: 2px;
}

.sub-rows {
  flex: 1;
  overflow-y: auto;
  padding: 10px 14px 14px;
}

.seg {
  display: flex;
  gap: 12px;
  padding: 9px 0;
}

.t {
  width: 44px;
  flex: none;
  font-size: 11.5px;
  color: var(--ink3, #8795a8);
  font-variant-numeric: tabular-nums;
  padding-top: 2px;
}

.tx {
  flex: 1;
  min-width: 0;
}

.src {
  display: block;
  font-size: 14.5px;
  line-height: 1.5;
  color: var(--ink, #26364a);
}

.tr {
  display: block;
  margin-top: 3px;
  font-size: 13px;
  line-height: 1.5;
  color: var(--ink3, #8795a8);
}

.sub-bar {
  display: flex;
  gap: 6px;
  padding: 8px 12px calc(10px + env(safe-area-inset-bottom));
  border-top: 1px solid var(--line, #e9eef5);
  background: var(--surface, #fff);
}

.sub-bar button {
  flex: 1;
  border: 0;
  background: transparent;
  color: var(--ink2, #44526a);
  font-size: 12px;
  font-family: inherit;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 8px 0;
  border-radius: 9px;
}

.sub-loading {
  position: fixed;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  background: rgba(24, 34, 48, 0.88);
  color: #fff;
  font-size: 12.5px;
  padding: 9px 16px;
  border-radius: 999px;
  z-index: 31;
}
</style>
