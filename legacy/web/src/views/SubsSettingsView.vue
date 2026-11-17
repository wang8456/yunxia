<script setup lang="ts">
/* 听设置：照 App 的 subs_settings_page.dart
   播放时实时听 / 识别精度 / 同时转写 / 听服务地址 / 刷新状态 */
import Ico from '../components/Ico.vue'
import { onMounted, reactive, ref } from 'vue'
import { api } from '../api'
import { TR_MODEL, trEnsureKey, trLoad, trSave, trShownModel, trTranslate } from '../tr'

const props = defineProps<{ toast: (t: string) => void; close: () => void }>()

const live = ref(localStorage.getItem('yunxia.sublive') !== '0')
const model = ref(localStorage.getItem('yunxia.submodel') || 'turbo')

const hub = ref('')
const maxActive = ref<number | null>(null)
const active = ref<number | null>(null)
const jobs = ref<number | null>(null)
const online = ref(false)
const loading = ref(true)

function setLive() {
  live.value = !live.value
  localStorage.setItem('yunxia.sublive', live.value ? '1' : '0')
  props.toast(live.value ? '播放时实时听 已开' : '播放时实时听 已关')
}

function setModel(m: 'turbo' | 'small') {
  model.value = m
  localStorage.setItem('yunxia.submodel', m)
}

async function load() {
  loading.value = true
  try {
    const r = await api.subsConfig()
    hub.value = r.hub || ''
    maxActive.value = r.max_active ?? null
    active.value = r.active ?? null
    jobs.value = r.jobs ?? null
    online.value = !!r.online
  } catch {
    online.value = false
  }
  loading.value = false
}

async function cycleMax() {
  const next = ((maxActive.value ?? 1) % 3) + 1
  try {
    const r = await api.setSubsConfig({ max_active: next })
    maxActive.value = r.max_active ?? next
    props.toast(`同时转写改成 ${maxActive.value}`)
  } catch (e) {
    props.toast(`改不了：${e}`)
  }
}

/* ---- 翻译源：译在浏览器里跑，和 App 一样填自己的密钥 ---- */
const tr = reactive(trLoad())
const trMsg = ref('')
const trBusy = ref(false)

function persistTr() {
  const model = tr.model.trim() || TR_MODEL
  trSave({ provider: tr.provider, base: tr.base.trim(), model, key: tr.key.trim() })
  trMsg.value = tr.key.trim() ? `已保存 · ${model}` : '密钥是空的，翻译还用不了'
  props.toast(trMsg.value)
}

function setProvider(p: 'deepseek' | 'custom') {
  tr.provider = p
  persistTr()
}

async function testTr() {
  if (trBusy.value) return
  trBusy.value = true
  trMsg.value = '测试中…'
  try {
    const [one] = await trTranslate(['Hello, this is a test.'])
    trMsg.value = one ? `通了：${one}` : '模型没回译文'
  } catch (e) {
    trMsg.value = `不通：${e}`
  }
  trBusy.value = false
}

onMounted(async () => {
  load()
  if (!tr.key.trim() && (await trEnsureKey())) Object.assign(tr, trLoad())
})
</script>

<template>
  <div class="cfg">
    <header class="topbar">
      <button class="back" @click="props.close()"><Ico name="arrow-left" :size="20" /></button>
      <div class="tt"><b>听设置</b><i>{{ online ? '听译中枢在线' : '连不上听译中枢' }}</i></div>
    </header>

    <div class="card">
      <button class="row" @click="setLive">
        <span class="ico" style="background: #eaf2ff; color: var(--ac)"><Ico name="translate" :size="18" /></span>
        <span class="txt">
          <b>播放时实时听</b>
          <i>{{ live ? '边播边出 · 只转播放位置之后' : '整片转完再出' }}</i>
        </span>
        <span class="sw" :class="{ on: live }"><span></span></span>
      </button>

      <button class="row" @click="setModel(model === 'turbo' ? 'small' : 'turbo')">
        <span class="ico" style="background: #efeaff; color: #7c5cf0"><Ico name="speed" :size="18" /></span>
        <span class="txt">
          <b>识别精度</b>
          <i>{{ model === 'turbo' ? '高质量 · 慢一些' : '快速 · 先出字幕' }}</i>
        </span>
        <Ico name="chevron-right" :size="17" class="chev" />
      </button>

      <button class="row" @click="cycleMax">
        <span class="ico" style="background: #e5f8ef; color: #0e9d78"><Ico name="list" :size="18" /></span>
        <span class="txt">
          <b>同时转写</b>
          <i>{{ loading ? '读取中…' : `现在 ${active ?? 0} 个在跑 / 上限 ${maxActive ?? 1}` }}</i>
        </span>
        <span class="tap">改</span>
      </button>

      <button class="row" @click="props.toast(hub || '—')">
        <span class="ico" style="background: #e4f7f5; color: #0d9c9c"><Ico name="link" :size="18" /></span>
        <span class="txt">
          <b>听服务地址</b>
          <i>{{ loading ? '读取中…' : hub || '—' }}</i>
        </span>
        <Ico name="copy" :size="16" class="chev" />
      </button>

      <button class="row" @click="load">
        <span class="ico" style="background: #f0f3f8; color: #5b6b82"><Ico name="refresh" :size="18" /></span>
        <span class="txt">
          <b>刷新状态</b>
          <i>{{ loading ? '' : `共 ${jobs ?? 0} 个字幕任务` }}</i>
        </span>
      </button>
    </div>

    <div class="sec">翻译源</div>
    <div class="card">
      <div class="row">
        <span class="ico" style="background: #efeaff; color: #7c5cf0"><Ico name="translate" :size="18" /></span>
        <span class="txt">
          <b>翻译服务</b>
          <i>{{ tr.provider === 'custom' ? '自定义（OpenAI 兼容）' : 'DeepSeek' }}</i>
        </span>
        <span class="seg">
          <button :class="{ on: tr.provider === 'deepseek' }" @click="setProvider('deepseek')">DeepSeek</button>
          <button :class="{ on: tr.provider === 'custom' }" @click="setProvider('custom')">自定义</button>
        </span>
      </div>

      <div v-if="tr.provider === 'custom'" class="row col">
        <span class="lbl">地址</span>
        <input v-model="tr.base" class="in" placeholder="https://api.siliconflow.cn/v1" @blur="persistTr" />
      </div>

      <div class="row col">
        <span class="lbl">模型</span>
        <input v-model="tr.model" class="in" :placeholder="TR_MODEL" @blur="persistTr" />
      </div>

      <div class="row col">
        <span class="lbl">密钥</span>
        <input v-model="tr.key" class="in" type="password" placeholder="sk-…" @blur="persistTr" />
      </div>

      <div class="row">
        <span class="ico" style="background: #e5f8ef; color: #0e9d78"><Ico name="check" :size="18" /></span>
        <span class="txt">
          <b>{{ trMsg || (tr.key.trim() ? `已配置 · ${trShownModel(tr)}` : '还没填密钥') }}</b>
          <i>译文自己翻，不经过 NAS</i>
        </span>
        <button class="tap" :disabled="trBusy" @click="testTr">{{ trBusy ? '测试中' : '测试' }}</button>
      </div>
    </div>

    <p class="note">听（转写）在 NAS 上跑；译由浏览器直连你填的翻译服务，不走服务器也不占 NAS 额度。</p>
  </div>
</template>

<style scoped>
.cfg {
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

.sec {
  margin: 18px 4px 8px;
  font-size: 12px;
  font-weight: 600;
  color: var(--ink3);
}

.row.col {
  flex-direction: column;
  align-items: stretch;
  gap: 7px;
}

.lbl {
  font-size: 12.5px;
  color: var(--ink3);
}

.in {
  border: 1px solid #e6ebf2;
  background: #f7f9fc;
  border-radius: 11px;
  padding: 10px 12px;
  font-size: 14px;
  color: var(--ink);
  outline: none;
  font-family: inherit;
}

.in:focus {
  border-color: color-mix(in srgb, var(--ac) 45%, #e6ebf2);
  background: var(--surface);
}

.seg {
  display: flex;
  gap: 4px;
  background: #f1f4f9;
  border-radius: 10px;
  padding: 3px;
  flex: none;
}

.seg button {
  border: 0;
  background: transparent;
  font-size: 12.5px;
  padding: 5px 9px;
  border-radius: 8px;
  color: var(--ink2);
  font-family: inherit;
}

.seg button.on {
  background: var(--surface);
  color: var(--ac);
  font-weight: 600;
  box-shadow: 0 1px 3px rgba(30, 50, 80, 0.09);
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

.sw {
  width: 44px;
  height: 26px;
  border-radius: 99px;
  background: #e3e9f1;
  padding: 3px;
  flex: none;
  transition: background 0.2s;
}

.sw span {
  display: block;
  width: 20px;
  height: 20px;
  border-radius: 99px;
  background: #fff;
  box-shadow: 0 1px 3px rgba(40, 60, 90, 0.2);
  transition: transform 0.2s;
}

.sw.on {
  background: #34c759;
}

.sw.on span {
  transform: translateX(18px);
}

.chev {
  color: #c9d1dd;
}

.tap {
  font-size: 12.5px;
  color: var(--ac, var(--ac));
  font-weight: 600;
}

.note {
  margin-top: 14px;
  font-size: 11.5px;
  line-height: 1.6;
  color: var(--ink3);
  padding: 0 4px;
}
</style>
