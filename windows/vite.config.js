import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

// Two pages: the window (index.html) and the dictation HUD (hud.html).
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: { port: 5173, strictPort: true },
  build: {
    target: 'chrome120',
    rollupOptions: { input: { index: 'index.html', hud: 'hud.html' } },
  },
});
