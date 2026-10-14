import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon.svg'],
      manifest: {
        name: 'ClassPay', short_name: 'ClassPay', description: 'Classes, fees and receipts for independent teachers and academies',
        start_url: '/', scope: '/', display: 'standalone', orientation: 'portrait', background_color: '#f6f7fb', theme_color: '#3735a8',
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
        ]
      },
      workbox: {
        // App shell is cached; API traffic is never cached so money state is always fresh.
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/rest\//, /^\/auth\//, /^\/functions\//, /^\/storage\//],
        runtimeCaching: [{ urlPattern: ({ url }) => /\/(rest|auth|functions|storage)\//.test(url.pathname), handler: 'NetworkOnly' }]
      }
    })
  ],
  server: { port: 5173 }
});
