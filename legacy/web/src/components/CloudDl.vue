<script setup lang="ts">
// 云下载：磁力 / ed2k / http → CloudDrive 的离线下载，可直接选落到哪个目录。
// 入口是文件页那个悬浮的 "+"，默认定位在当前浏览目录。
import { ref, onMounted } from 'vue'
import Ico from './Ico.vue'
import { api } from '../api'

const props = defineProps<{ source: string; dir: string; toast: (t: string) => void }>()
const emit = defineEmits<{ close: [] }>()

const target = ref(props.dir || '/')
const text = ref('')
const busy = ref(false)
const msg = ref('')
const tasks = ref<any[]>([])

// 目录选择
const picking = ref(false)
const pickPath = ref(props.dir || '/')
const dirs = ref<any[]>([])
const pickBusy = ref(false)

function pct(t: any) {
  return Math.max(0, Math.min(100, Math.round(Number(t.percent || 0))))
}

async function loadTasks() {
  try {
    const r = await api.cd2OfflineList(target.value, props.source)
    tasks.value = (r.tasks || []).slice(0, 6)
  } catch {
    tasks.value = []
  }
}

async function submit() {
  const urls = text.value
    .split(/\s+/)
    .map((x) => x.trim())
    .filter(Boolean)
  if (!urls.length || busy.value) return
  busy.value = true
  msg.value = ''
  try {
    await api.cd2Offline(urls, target.value, props.source)
    text.value = ''
    msg.value = `已提交 ${urls.length} 个任务`
    props.toast(`已提交 ${urls.length} 个云下载任务`)
    setTimeout(loadTasks, 1200)
  } catch (e: any) {
    msg.value = e?.message || '提交失败'
  } finally {
    busy.value = false
  }
}

async function openPicker() {
  picking.value = true
  pickPath.value = target.value
  await loadDirs(pickPath.value)
}

async function loadDirs(p: string) {
  pickBusy.value = true
  try {
    const r = await api.list(props.source, p)
    dirs.value = (r.entries || []).filter((e: any) => e.is_dir)
  } catch {
    dirs.value = []
  } finally {
    pickBusy.value = false
  }
}

function enter(d: any) {
  pickPath.value = d.path
  loadDirs(d.path)
}

function up() {
  const p = pickPath.value.replace(/\/[^/]+$/, '') || '/'
  pickPath.value = p
  loadDirs(p)
}

function choose() {
  target.value = pickPath.value
  picking.value = false
  loadTasks()
}

onMounted(loadTasks)
</script>

<template>
  <div class="cdl-mask" @click.self="emit('close')">
    <div class="cdl-sheet">
      <div class="cdl-grip" />
      <div class="cdl-head">
        <b>{{ picking ? '选择目录' : '云下载' }}</b>
        <span v-if="!picking" class="cdl-tag">115 网盘</span>
        <button class="cdl-x" @click="picking ? (picking = false) : emit('close')">
          <Ico :name="picking ? 'chevron-left' : 'close'" :size="18" />
        </button>
      </div>

      <!-- 目录选择器 -->
      <template v-if="picking">
        <div class="cdl-crumb">
          <button class="cdl-up" :disabled="pickPath === '/'" @click="up()">
            <Ico name="chevron-left" :size="15" /> 上一级
          </button>
          <span class="cdl-path">{{ pickPath }}</span>
        </div>
        <div class="cdl-dirs">
          <button v-for="d in dirs.slice(0, 300)" :key="d.path" class="cdl-diritem" @click="enter(d)">
            <Ico name="folder" :size="17" />
            <span>{{ d.name }}</span>
            <Ico class="cdl-chev" name="chevron-right" :size="15" />
          </button>
          <div v-if="!dirs.length" class="cdl-empty">{{ pickBusy ? '读取中…' : '这一层没有子目录' }}</div>
          <div v-else-if="dirs.length > 300" class="cdl-empty">
            共 {{ dirs.length }} 个目录，先显示 300 个 · 点进去再挑
          </div>
        </div>
        <button class="cdl-go wide" @click="choose()">下载到这个目录</button>
      </template>

      <!-- 提交 -->
      <template v-else>
        <button class="cdl-dir" @click="openPicker()">
          <Ico name="folder" :size="17" />
          <span class="cdl-dir-t">{{ target }}</span>
          <span class="cdl-dir-a">更改</span>
        </button>
        <textarea
          v-model="text"
          class="cdl-ta"
          rows="3"
          placeholder="磁力 / ed2k / http，一行一个"
        />
        <div class="cdl-row">
          <span class="cdl-tip">{{ msg || '走 CloudDrive 的离线下载' }}</span>
          <button class="cdl-go" :disabled="busy || !text.trim()" @click="submit()">
            {{ busy ? '提交中…' : '开始下载' }}
          </button>
        </div>
        <div v-if="tasks.length" class="cdl-tasks">
          <div v-for="(t, i) in tasks" :key="i" class="cdl-task">
            <div class="cdl-tname">{{ t.name || t.hash }}</div>
            <div class="cdl-tbar"><i :style="{ width: pct(t) + '%' }" /></div>
            <div class="cdl-tmeta">{{ pct(t) }}%</div>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.cdl-mask {
  position: fixed;
  inset: 0;
  z-index: 60;
  background: rgba(15, 23, 34, 0.32);
  display: flex;
  align-items: flex-end;
  justify-content: center;
}
.cdl-sheet {
  width: 100%;
  max-width: 560px;
  background: var(--surface);
  border-radius: 18px 18px 0 0;
  padding: 8px 14px calc(16px + env(safe-area-inset-bottom));
  box-sizing: border-box;
  max-height: 86vh;
  overflow: auto;
}
@media (min-width: 761px) {
  .cdl-mask {
    align-items: center;
  }
  .cdl-sheet {
    border-radius: 16px;
    max-width: 480px;
    padding-bottom: 16px;
  }
}
.cdl-grip {
  width: 36px;
  height: 4px;
  border-radius: 2px;
  background: var(--line);
  margin: 0 auto 8px;
}
@media (min-width: 761px) {
  .cdl-grip {
    display: none;
  }
}
.cdl-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 0 10px;
}
.cdl-head b {
  font-size: 15px;
  font-weight: 600;
  color: var(--ink);
}
.cdl-tag {
  font-size: 11px;
  color: var(--ink3);
  background: var(--bg2, #f3f5f8);
  padding: 2px 7px;
  border-radius: 6px;
}
.cdl-x {
  margin-left: auto;
  width: 36px;
  height: 36px;
  display: grid;
  place-items: center;
  border: 0;
  border-radius: 10px;
  background: none;
  color: var(--ink2);
  cursor: pointer;
}
.cdl-dir {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 11px 12px;
  border: 0;
  border-radius: 11px;
  background: var(--bg2, #f5f7fa);
  color: var(--ink);
  font-size: 13px;
  cursor: pointer;
  text-align: left;
}
.cdl-dir-t {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cdl-dir-a {
  color: var(--ac);
  font-size: 12px;
  flex: none;
}
.cdl-ta {
  width: 100%;
  box-sizing: border-box;
  margin-top: 10px;
  padding: 11px 12px;
  border: 1px solid var(--line);
  border-radius: 11px;
  background: var(--surface);
  color: var(--ink);
  font-size: 13px;
  line-height: 1.5;
  resize: none;
  font-family: inherit;
}
.cdl-ta:focus {
  outline: none;
  border-color: var(--ac);
}
.cdl-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 10px;
}
.cdl-tip {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  color: var(--ink3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cdl-go {
  flex: none;
  padding: 10px 16px;
  min-height: 40px;
  border: 0;
  border-radius: 11px;
  background: var(--ac);
  color: #fff;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
}
.cdl-go:disabled {
  opacity: 0.45;
  cursor: default;
}
.cdl-go.wide {
  width: 100%;
  margin-top: 10px;
}
.cdl-tasks {
  margin-top: 12px;
  border-top: 1px solid var(--line2);
  padding-top: 8px;
}
.cdl-task {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 0;
}
.cdl-tname {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  color: var(--ink2);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cdl-tbar {
  flex: none;
  width: 90px;
  height: 5px;
  border-radius: 3px;
  background: var(--line2);
  overflow: hidden;
}
.cdl-tbar i {
  display: block;
  height: 100%;
  background: var(--ac);
  border-radius: 3px;
}
.cdl-tmeta {
  flex: none;
  width: 36px;
  text-align: right;
  font-size: 11px;
  color: var(--ink3);
}
.cdl-crumb {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 0 8px;
}
.cdl-up {
  display: flex;
  align-items: center;
  gap: 2px;
  min-height: 36px;
  padding: 0 8px;
  border: 0;
  border-radius: 9px;
  background: var(--bg2, #f5f7fa);
  color: var(--ink2);
  font-size: 12px;
  cursor: pointer;
}
.cdl-up:disabled {
  opacity: 0.4;
  cursor: default;
}
.cdl-path {
  font-size: 12px;
  color: var(--ink3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cdl-dirs {
  max-height: 46vh;
  overflow: auto;
  margin: 0 -4px;
}
.cdl-diritem {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 12px 6px;
  border: 0;
  border-bottom: 1px solid var(--line2);
  background: none;
  color: var(--ink);
  font-size: 13px;
  cursor: pointer;
  text-align: left;
}
.cdl-diritem span {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cdl-chev {
  color: var(--ink3);
}
.cdl-empty {
  padding: 22px 0;
  text-align: center;
  font-size: 12px;
  color: var(--ink3);
}
</style>
