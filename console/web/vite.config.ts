import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'

// 打包成單一自包含 HTML（canopy 同款）：go:embed 只需要吞一個檔案，
// 也不用管 hashed asset 的 MIME 與路徑。
export default defineConfig({
  plugins: [react(), viteSingleFile()],
})
