/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    exclude: ['tests/e2e/**', 'node_modules/**'],
  },
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      '/api': {
        // Prefer the eavd daemon on :3002. If you're shadow-testing
        // against the legacy Express server, override with VITE_API_TARGET.
        target: process.env.VITE_API_TARGET ?? 'http://localhost:3002',
        changeOrigin: true,
      },
    },
  },
})
