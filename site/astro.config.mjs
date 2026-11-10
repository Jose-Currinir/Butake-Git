import { defineConfig } from 'astro/config'

// GitHub Pages sirve el sitio del proyecto en /Butake-Git/.
export default defineConfig({
  site: 'https://jose-currinir.github.io',
  base: '/Butake-Git',
  trailingSlash: 'ignore',
  build: { assets: 'assets' },
})
