<script setup lang="ts">
/* 听译队列 —— 只从「设置 → 听·译 → 听译队列」和文件页 ⋯ →「查看字幕作业」进来，
   所以不出现在主导航里。风格照 SettingsView：顶栏 + 汇总 + 卡片列表。 */
import Ico from '../components/Ico.vue'
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, ApiError, type SubJob, type SubSeg, type SubState } from '../api'
import { confirmBox } from '../ask'

const props = defineProps<{ toast: (t: string) => void }>()
const emit = defineEmits<{ back: [] }>()

const jobs = ref<SubJob[]>([])
const st = ref<SubState | null>(null)
const loading = ref(false)
const err = ref('')
let timer: number | undefined

/* 展开某一条看段落（最多 200 条，够看得懂内容又不至于卡） */
const openId = ref('')
const segs = ref<SubSeg[]>([])
const segLoading = ref(false)

const LABEL: Record<string, string> = {
  queued: '排队中',
  asr: '转写中',
  translating: '翻译中',
  done: '已完成',
  error: '失败',
  cancelled: '已停止',
}
function label(s: string) {
  return LABEL[s] || s || '未知'
}
function tone(s: string) {
  if (s === 'done') return 'ok'
  if (s === 'error') return 'bad'
  if (s === 'cancelled') return 'off'
  return 'run'
}
function running(j: SubJob) {
  return j.state === 'queued' || j.state === 'asr' || j.state === 'translating'
}

const counts = computed(() => {
  let run = 0
  let queued = 0
  let done = 0
  for (const j of jobs.value) {
    if (j.state === 'asr' || j.state === 'translating') run++
    else if (j.state === 'queued') queued++
    else if (j.state === 'done') done++
  }
  return { run, queued, done }
})
const anyRunning = computed(() => jobs.value.some(running))

const trReady = computed(() => !!st.value?.translate?.ready)

async function load(quiet = false) {
  if (!quiet) loading.value = true
  try {
    const r = await api.subsList()
    jobs.value = r.jobs || []
    st.value = r
    err.value = ''
  } catch (e) {
    if (e instanceof ApiError && e.status === 503) err.value = e.message
    else err.value = `读队列失败：${e instanceof ApiError ? e.message : e}`
  } finally {
    loading.value = false
  }
  schedule()
}

/* 有活干的时候每 2.5 秒自己刷一次，全都跑完就停（不留定时器） */
function schedule() {
  window.clearTimeout(timer)
  if (anyRunning.value) timer = window.setTimeout(() => load(true), 2500)
}

function mmss(sec: number) {
  const x = Math.max(0, Math.floor(sec || 0))
  const h = Math.floor(x / 3600)
  const m = Math.floor((x % 3600) / 60)
  const s = x % 60
  return `${h ? h + ':' : ''}${h ? String(m).padStart(2, '0') : m}:${String(s).padStart(2, '0')}`
}

function pctOf(j: SubJob) {
  return Math.min(100, Math.max(0, Math.round(j.pct || 0)))
}

function metaOf(j: SubJob) {
  const bits: string[] = []
  if (j.lang) bits.push(j.lang)
  if (j.dur) bits.push(mmss(j.dur))
  if (j.model) bits.push(j.model)
  bits.push(`${j.segments || 0} 句`)
  if (j.pending) bits.push(`待译 ${j.pending}`)
  if (j.created) {
    const d = new Date(j.created * 1000)
    const p2 = (n: number) => String(n).padStart(2, '0')
    bits.push(`${p2(d.getMonth() + 1)}/${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`)
  }
  return bits.join(' · ')
}

async function toggleOpen(j: SubJob) {
  if (openId.value === j.id) {
    openId.value = ''
    return
  }
  openId.value = j.id
  segs.value = []
  segLoading.value = true
  try {
    const d = await api.subsDetail(j.id, 0)
    segs.value = (d.segments_list || []).slice(0, 200)
  } catch (e) {
    props.toast(`读段落失败：${e instanceof ApiError ? e.message : e}`)
  } finally {
    segLoading.value = false
  }
}

async function cancel(j: SubJob) {
  if (!(await confirmBox('停止这条转写？', j.name, '停止', false))) return
  try {
    await api.subsCancel(j.id)
    props.toast('已停止')
    load(true)
  } catch (e) {
    props.toast(`停止失败：${e instanceof ApiError ? e.message : e}`)
  }
}

async function del(j: SubJob) {
  if (!(await confirmBox(`删除「${j.name}」的字幕？`, '字幕和进度一起删掉，视频文件不动。', '删除'))) return
  try {
    await api.subsDelete(j.id)
    if (openId.value === j.id) openId.value = ''
    props.toast('已删除')
    load(true)
  } catch (e) {
    props.toast(`删除失败：${e instanceof ApiError ? e.message : e}`)
  }
}

/** 重新转写：先删掉旧任务再提交，服务端对「跑着/done」的重复提交是复用，不删就永远拿到旧结果 */
async function retry(j: SubJob) {
  if (!(await confirmBox('重新转写？', '会清掉现在的字幕，从头跑一遍。', '重新转写', false))) return
  try {
    await api.subsDelete(j.id)
    const n = await api.subsAdd(j.source, j.path, j.name)
    props.toast(running(n) ? '已重新排队' : n.state === 'done' ? '已有字幕，直接可用' : '已提交')
    load(true)
  } catch (e) {
    props.toast(`重新转写失败：${e instanceof ApiError ? e.message : e}`)
  }
}

async function translate(j: SubJob) {
  try {
    await api.subsTranslate(j.id)
    props.toast('开始翻译')
    load(true)
  } catch (e) {
    props.toast(`翻译失败：${e instanceof ApiError ? e.message : e}`)
  }
}

function exportSrt(j: SubJob) {
  const a = document.createElement('a')
  a.href = api.subsSrtUrl(j.id, true)
  a.download = `${j.name.replace(/\.[^.]+$/, '') || j.id}.zh.srt`
  a.rel = 'noopener'
  // 游离的 <a>.click() 在部分浏览器会被忽略，必须挂进文档
  document.body.appendChild(a)
  a.click()
  a.remove()
  props.toast('开始导出 SRT')
}

onMounted(() => load())
onUnmounted(() => window.clearTimeout(timer))
</script>

<template>
  <div class="subs-page">
    <div class="topbar">
      <button class="back" title="返回" @click="emit('back')"><Ico name="arrow-left" :size="19" /></button>
      <span class="tb-title">听译</span>
      <button class="tb-btn" :disabled="loading" title="刷新" @click="load()">
        <Ico name="refresh" :size="18" />
      </button>
    </div>

    <p class="sub">本机 faster-whisper · 一条一条排队跑</p>
    <h1 class="page-title">听译队列</h1>

    <div class="sumline">
      <span>{{ counts.run }} 个在转</span>
      <span class="dot">·</span>
      <span>{{ counts.queued }} 排队</span>
      <span class="dot">·</span>
      <span>{{ counts.done }} 已完成</span>
    </div>

    <div v-if="st" class="cfg">
      <span class="cfg-cell">模型 <b>{{ st.model || '—' }}</b></span>
      <span class="vline" />
      <span class="cfg-cell">同开 <b>{{ st.max_active }}</b></span>
      <span class="vline" />
      <span class="cfg-cell">
        翻译
        <b :class="{ dim: !trReady }">{{ trReady ? st.translate.model || '已配置' : '未配置' }}</b>
      </span>
    </div>

    <div v-if="err" class="errbox">{{ err }}</div>
    <p v-else-if="loading && !jobs.length" class="muted">加载中…</p>
    <div v-else-if="!jobs.length" class="empty card">还没有听译任务 · 在视频的 ⋯ 菜单里点「生成字幕」</div>

    <div v-else class="list">
      <div v-for="j in jobs" :key="j.id" class="job">
        <div class="j-top">
          <span class="j-ico" :class="tone(j.state)"><Ico name="translate" :size="18" /></span>
          <div class="j-tx">
            <div class="j-name">{{ j.name }}</div>
            <div class="j-meta">{{ metaOf(j) }}</div>
          </div>
          <span class="pill" :class="tone(j.state)">{{ label(j.state) }}</span>
        </div>

        <div class="j-bar"><i :style="{ width: pctOf(j) + '%' }" :class="tone(j.state)"></i></div>
        <div class="j-nums">
          <span class="j-msg">{{ j.state === 'error' ? j.error || j.msg : j.msg }}</span>
          <span class="j-pct">{{ pctOf(j) }}%</span>
        </div>

        <div class="acts">
          <button class="act" @click="toggleOpen(j)">{{ openId === j.id ? '收起' : '查看' }}</button>
          <button v-if="running(j)" class="act" @click="cancel(j)">取消</button>
          <button v-if="j.state === 'done' && j.pending" class="act" :disabled="!trReady" @click="translate(j)">
            {{ trReady ? `翻译 ${j.pending} 句` : '翻译未配置' }}
          </button>
          <button v-if="j.state === 'done'" class="act" @click="exportSrt(j)">导出 SRT</button>
          <button class="act" @click="retry(j)">重新转写</button>
          <button class="act danger" @click="del(j)">删除</button>
        </div>

        <div v-if="openId === j.id" class="segs">
          <p v-if="segLoading" class="muted">读取中…</p>
          <p v-else-if="!segs.length" class="muted">还没有段落</p>
          <template v-else>
            <div v-for="(s, i) in segs" :key="i" class="seg-row">
              <span class="seg-t">{{ mmss(Number(s[0])) }}</span>
              <span class="seg-tx">
                <span class="seg-tr">{{ s.length > 3 && s[3] ? s[3] : s[2] }}</span>
                <span v-if="s.length > 3 && s[3] && s[3] !== s[2]" class="seg-src">{{ s[2] }}</span>
              </span>
            </div>
            <p v-if="j.segments > segs.length" class="muted more">只显示前 {{ segs.length }} 句（共 {{ j.segments }}）</p>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.subs-page {
  padding: 14px 19px 40px;
  max-width: 780px;
  margin: 0 auto;
}

.topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
}

.back,
.tb-btn {
  width: 36px;
  height: 36px;
  flex: none;
  border: 0;
  border-radius: 11px;
  background: none;
  color: var(--ink2);
  display: grid;
  place-items: center;
}

.back:hover,
.tb-btn:hover {
  background: var(--surface2);
}

.tb-btn:disabled {
  opacity: 0.4;
}

.tb-title {
  flex: 1;
  font-size: 13px;
  font-weight: 600;
  color: var(--ink3);
  letter-spacing: 0.3px;
}

.sub {
  font-size: 12px;
  color: var(--ink3);
  margin: 0 0 5px;
}

.page-title {
  font-size: 26px;
  font-weight: 750;
  letter-spacing: -0.6px;
  margin: 0 0 12px;
  color: var(--ink);
}

.sumline {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 12.5px;
  color: var(--ink2);
  margin-bottom: 10px;
  font-variant-numeric: tabular-nums;
}

.dot {
  color: var(--ink3);
  opacity: 0.6;
}

.cfg {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 14px;
  margin-bottom: 12px;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 14px;
  box-shadow: 0 2px 10px var(--sh);
  font-size: 12px;
  color: var(--ink3);
  flex-wrap: wrap;
}

.cfg-cell b {
  color: var(--ink);
  font-weight: 600;
}

.cfg-cell b.dim {
  color: #e08a16;
  font-weight: 600;
}

.vline {
  width: 1px;
  height: 14px;
  background: var(--line2);
}

.errbox {
  padding: 14px;
  border-radius: 14px;
  background: color-mix(in srgb, #e45e53 10%, var(--surface));
  color: #c9433a;
  font-size: 12.5px;
  line-height: 1.6;
}

.empty {
  padding: 40px 20px;
  text-align: center;
  color: var(--ink3);
  font-size: 12.5px;
}

.list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.job {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 17px;
  box-shadow: 0 2px 10px var(--sh);
  padding: 13px 14px;
}

.j-top {
  display: flex;
  align-items: center;
  gap: 11px;
}

.j-ico {
  width: 32px;
  height: 32px;
  flex: none;
  border-radius: 10px;
  display: grid;
  place-items: center;
  background: var(--surface2);
  color: var(--ink2);
}

.j-ico.run {
  background: color-mix(in srgb, var(--ac) 14%, var(--surface));
  color: var(--ac);
}

.j-ico.ok {
  background: color-mix(in srgb, #16a34a 14%, var(--surface));
  color: #16a34a;
}

.j-ico.bad {
  background: color-mix(in srgb, #e45e53 14%, var(--surface));
  color: #e45e53;
}

.j-tx {
  flex: 1;
  min-width: 0;
}

.j-name {
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.j-meta {
  margin-top: 3px;
  font-size: 11.5px;
  color: var(--ink3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}

.pill {
  flex: none;
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 600;
  background: var(--surface2);
  color: var(--ink3);
}

.pill.run {
  background: var(--acw);
  color: var(--ac);
}

.pill.ok {
  background: color-mix(in srgb, #16a34a 12%, var(--surface));
  color: #12813c;
}

.pill.bad {
  background: color-mix(in srgb, #e45e53 12%, var(--surface));
  color: #cf4a41;
}

.j-bar {
  height: 4px;
  margin: 11px 0 7px;
  border-radius: 99px;
  background: var(--line2);
  overflow: hidden;
}

.j-bar i {
  display: block;
  height: 100%;
  border-radius: 99px;
  background: var(--ac);
  transition: width 0.35s ease;
}

.j-bar i.ok {
  background: #16a34a;
}

.j-bar i.bad {
  background: #e45e53;
}

.j-bar i.off {
  background: #b9c2cf;
}

.j-nums {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 11.5px;
  color: var(--ink3);
  font-variant-numeric: tabular-nums;
}

.j-msg {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.j-pct {
  flex: none;
}

.acts {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 10px;
  padding-top: 10px;
  border-top: 1px solid var(--line2);
}

.act {
  border: 0;
  background: none;
  padding: 2px 0;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--ac);
}

.act.danger {
  color: #e45e53;
}

.act:disabled {
  color: var(--ink3);
  opacity: 0.7;
}

.segs {
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px dashed var(--line2);
  max-height: 340px;
  overflow: auto;
}

.seg-row {
  display: flex;
  gap: 9px;
  padding: 5px 0;
}

.seg-t {
  flex: none;
  font-size: 11px;
  color: var(--ink3);
  font-variant-numeric: tabular-nums;
  padding-top: 2px;
}

.seg-tx {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.seg-tr {
  font-size: 12.5px;
  line-height: 1.5;
  color: var(--ink);
}

.seg-src {
  font-size: 11.5px;
  line-height: 1.45;
  color: var(--ink3);
}

.muted {
  color: var(--ink3);
  font-size: 12px;
  margin: 6px 0;
}

.more {
  margin: 8px 0 2px;
}

@media (max-width: 760px) {
  .subs-page {
    padding: 12px 16px 32px;
  }

  .page-title {
    font-size: 24px;
  }
}
</style>
