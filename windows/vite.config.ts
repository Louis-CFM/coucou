import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420, strictPort: true, host: "127.0.0.1",
    watch: { ignored: ["**/target/**", "**/src-tauri/**"] },
  },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: "chrome110", minify: "esbuild", sourcemap: false, emptyOutDir: true,
    rollupOptions: { input: {
      island: resolve(__dirname, "index.html"),
      settings: resolve(__dirname, "settings.html"),
      nova: resolve(__dirname, "nova.html"),
    } },
  },
});
