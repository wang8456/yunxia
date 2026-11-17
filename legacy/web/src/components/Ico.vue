<script setup lang="ts">
/* 统一图标：直接渲染 App 那套 SVG（src/icons.ts），颜色跟 currentColor 走。
   线宽 1.5 写在图元上，外层不再压 stroke-width，和 App 完全一致。 */
import { ICONS } from '../icons'

const props = withDefaults(defineProps<{ name: string; size?: number | string }>(), {
  size: 20,
})

function inner(): string {
  return ICONS[props.name] || ''
}
</script>

<template>
  <svg
    class="ic"
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    aria-hidden="true"
    v-html="inner()"
  />
</template>

<style scoped>
.ic {
  display: block;
  flex: none;
}
</style>
