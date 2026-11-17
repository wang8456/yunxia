<script setup lang="ts">
/* 设置 → 更多：照 App 的 settings_more_page.dart
   Android 专属的两条权限（系统亮度 / 安装未知应用）网页没有对应物，按规矩不搬过来 */
import Ico from '../components/Ico.vue'
import { onMounted, ref } from 'vue'

const props = defineProps<{ toast: (t: string) => void; close: () => void }>()

const health = ref<'idle' | 'ping' | 'ok' | 'bad'>('idle')
const healthMs = ref(0)
const server = ref(location.origin)

async function ping() {
  health.value = 'ping'
  const t0 = performance.now()
  try {
    const r = await fetch('/api/v1/healthz', { headers: { Accept: 'application/json' } })
    healthMs.value = Math.round(performance.now() - t0)
    health.value = r.ok ? 'ok' : 'bad'
  } catch {
    healthMs.value = Math.round(performance.now() - t0)
    health.value = 'bad'
  }
}

function clearCache() {
  let n = 0
  for (const k of Object.keys(localStorage)) {
    if (k.startsWith('yunxia.cache.') || k.startsWith('yunxia.thumb.')) {
      localStorage.removeItem(k)
      n++
    }
  }
  props.toast(n ? `清掉 ${n} 项缓存` : '缓存是干净的')
}

onMounted(ping)
</script>

<template>
  <div class="more">
    <header class="topbar">
      <button class="back" @click="props.close()"><Ico name="arrow-left" :size="20" /></button>
      <div class="tt"><b>更多</b><i>连接、缓存</i></div>
    </header>

    <div class="card">
      <button class="row" @click="ping">
        <span class="ico" style="background: #eaf2ff; color: var(--ac)"><Ico name="recent" :size="18" /></span>
        <span class="txt">
          <b>连接检测</b>
          <i>打一次 /healthz，看通不通</i>
        </span>
        <span class="end" :class="health">
          {{ health === 'ping' ? '…' : health === 'ok' ? `${healthMs}ms` : health === 'bad' ? '不通' : '' }}
        </span>
      </button>

      <button class="row" @click="clearCache">
        <span class="ico" style="background: #fff3df; color: #c78218"><Ico name="trash" :size="18" /></span>
        <span class="txt">
          <b>清理缓存</b>
          <i>清掉网页存下的临时数据</i>
        </span>
        <Ico name="chevron-right" :size="17" class="chev" />
      </button>

      <button class="row" @click="props.toast('云匣 · ' + server)">
        <span class="ico" style="background: #f0f3f8; color: #5b6b82"><Ico name="info" :size="18" /></span>
        <span class="txt">
          <b>关于云匣</b>
          <i>连的是 {{ server }}</i>
        </span>
        <Ico name="chevron-right" :size="17" class="chev" />
      </button>
    </div>
  </div>
</template>

<style scoped>
.more {
  padding-bottom: 20px;
}

.topbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 0 12px;
}

.back {
  border: 0;
  background: transparent;
  color: var(--ink2, #44526a);
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  flex: none;
}

.tt {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.tt b {
  font-size: 16px;
  font-weight: 700;
}

.tt i {
  font-size: 11.5px;
  font-style: normal;
  color: var(--ink3);
}

.card {
  background: var(--surface, #fff);
  border: 1px solid #e9eef5;
  border-radius: 17px;
  overflow: hidden;
}

.row {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px;
  border: 0;
  background: transparent;
  text-align: left;
}

.row + .row {
  border-top: 1px solid #f2f5f9;
}

.ico {
  width: 38px;
  height: 38px;
  border-radius: 12px;
  display: grid;
  place-items: center;
  flex: none;
}

.txt {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.txt b {
  font-size: 14.5px;
  font-weight: 600;
  color: var(--ink);
}

.txt i {
  font-size: 12px;
  font-style: normal;
  color: var(--ink3);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.end {
  font-size: 12px;
  color: var(--ink3);
}

.end.ok {
  color: #2ec27e;
  font-weight: 600;
}

.end.bad {
  color: #e0515f;
  font-weight: 600;
}

.chev {
  color: #c9d1dd;
}

.note {
  margin-top: 14px;
  font-size: 11.5px;
  line-height: 1.6;
  color: var(--ink3);
  padding: 0 4px;
}
</style>
