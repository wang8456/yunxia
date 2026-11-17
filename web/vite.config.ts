import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 开源版直接挂在站点根路径；/api 与 /hermes（对话网关）都转发给本机服务端
export default defineConfig({
  base: '/',
  plugins: [vue()],
  server: {
    port: 5180,
    proxy: {
      '/api': { target: 'http://127.0.0.1:8686', changeOrigin: true },
      '/hermes': { target: 'http://127.0.0.1:8686', changeOrigin: true },
    },
  },
  build: { outDir: 'dist', assetsDir: 'assets', sourcemap: false },
})
