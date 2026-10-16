// Vite builds and serves the console; vitest runs its tests. The fork test starts its own anvil,
// so it gets more time than a unit test.
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: { testTimeout: 180_000, hookTimeout: 120_000 },
})
