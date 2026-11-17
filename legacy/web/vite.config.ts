import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 挂 /app/ 下，与老的 dufs 前端并存（P7 验收通过后才切默认入口）
export default defineConfig({
  base: '/app/',
  plugins: [vue()],
  server: {
    port: 5180,
    proxy: {
      '/api': { target: 'http://192.168.1.10:5007', changeOrigin: true },
      '/ws': { target: 'ws://192.168.1.10:5007', ws: true },
      '/f': { target: 'http://192.168.1.10:5007', changeOrigin: true },
    },
  },
  build: { outDir: 'dist', assetsDir: 'assets', sourcemap: false },
})
