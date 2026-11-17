<script setup lang="ts">
import Ico from '../components/Ico.vue'
import { icoName } from '../ic'
import { computed, ref, watch } from 'vue'
import { api, humanSize, type Entry } from '../api'
import { toneOf } from '../tone'
const emit = defineEmits<{ open: [string] }>()
const q = ref('')
const kind = ref<string | null>(null)
const items = ref<Entry[]>([])
const total = ref(0)
const took = ref(0)
const loading = ref(false)
let timer: number | undefined
// 结果里同一个目录往往一大串，按目录收一下比翻一百行强
const activeDir = ref<string | null>(null)

const dirs = computed(() => {
  const m = new Map<string, number>()
  for (const e of items.value) {
    const d = e.is_dir ? e.path : dirOf(e.path)
    m.set(d, (m.get(d) ?? 0) + 1)
  }
  return [...m.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 8)
    .map(([path, n]) => ({ path, n, label: path === '/' ? '根目录' : (path.split('/').filter(Boolean).pop() ?? '/') }))
})

const shown = computed(() =>
  activeDir.value ? items.value.filter((e) => (e.is_dir ? e.path : dirOf(e.path)) === activeDir.value) : items.value,
)

async function run() {
  loading.value = true
  activeDir.value = null
  try {
    const r = await api.search(q.value, kind.value ?? undefined, 100)
    items.value = r.items
    total.value = r.total
    took.value = r.took_ms
  } catch {
    items.value = []
    total.value = 0
  } finally {
    loading.value = false
  }
}

watch(q, () => {
  window.clearTimeout(timer)
  timer = window.setTimeout(run, 260)
})

function pickDir(d: string | null) {
  activeDir.value = activeDir.value === d ? null : d
}

function dirOf(p: string) {
  const i = p.lastIndexOf('/')
  return i <= 0 ? '/' : p.slice(0, i)
}
</script>

<template>
  <header class="brandbar">
    <div class="brand-name">云匣</div>
  </header>

  <h1 class="page-title">搜索</h1>

  <div class="field">
    <Ico class="emoji" :name="icoName('🔍')" />
    <input v-model="q" placeholder="搜文件、文件夹" @keyup.enter="run" />
  </div>


  <p v-if="loading" class="muted">搜索中…</p>
  <div v-else-if="!items.length" class="empty">
    <span class="empty-ico"><Ico name="search" :size="30" /></span>
    <span class="empty-txt">{{ q ? '没有找到匹配的文件' : '输入关键词开始搜' }}</span>
  </div>

  <template v-else>
    <div v-if="dirs.length > 1" class="chips dirchips">
      <button class="chip" :class="{ on: activeDir === null }" @click="pickDir(null)">
        全部 <span class="cnt">{{ items.length }}</span>
      </button>
      <button
        v-for="d in dirs"
        :key="d.path"
        class="chip"
        :class="{ on: activeDir === d.path }"
        :title="d.path"
        @click="pickDir(d.path)"
      >
        {{ d.label }} <span class="cnt">{{ d.n }}</span>
      </button>
    </div>
    <div class="rows">
      <div class="row" v-for="e in shown" :key="e.path" @click="emit('open', e.is_dir ? e.path : dirOf(e.path))">
        <span
          class="icon"
          :style="{ background: toneOf(e.name, e.is_dir).bg, color: toneOf(e.name, e.is_dir).fg }"
        >
          <Ico :name="toneOf(e.name, e.is_dir).icon" :size="20" />
        </span>
        <div style="flex: 1; min-width: 0">
          <div class="name">{{ e.name }}</div>
          <div class="meta">{{ dirOf(e.path) || '/' }}</div>
        </div>
        <span class="size">{{ e.is_dir ? '' : humanSize(e.size) }}</span>
      </div>
    </div>
  </template>
</template>

<style scoped>
.dirchips {
  margin-top: 6px;
  margin-bottom: 4px;
}

.cnt {
  display: inline-block;
  margin-left: 4px;
  padding: 0 5px;
  border-radius: 999px;
  background: rgba(20, 30, 50, 0.08);
  font-size: 10.5px;
  color: inherit;
  opacity: 0.75;
}

.chips {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin: 12px 0 16px;
}

.muted {
  color: var(--ink3);
  font-size: 11.5px;
}

.icon {
  width: 43px;
  height: 43px;
  border-radius: 13px;
  display: grid;
  place-items: center;
  flex: none;
}

.name {
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.meta {
  margin-top: 3px;
  font-size: 11px;
  color: var(--ink3);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.size {
  font-size: 11px;
  color: var(--ink3);
  white-space: nowrap;
}

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

.empty {
  margin-top: 96px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
}

.empty-ico {
  color: #c3ccd9;
  display: grid;
  place-items: center;
}

.empty-txt {
  font-size: 13px;
  color: #a8b2c0;
}
</style>
