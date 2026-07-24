# AudioBridge landing page

Static AudioBridge product site deployed as a Cloudflare Worker. The main
Worker imports each page asset as a separate text module so HTML, CSS, and
client JavaScript stay independently verifiable.

## Local development

```powershell
cd website
npm install
npm run dev
```

Edit files in `src`. `worker.js` serves those files with explicit content types,
cache behavior, and security headers.

## Deploy

```powershell
npm run deploy
```

The Cloudflare Worker name is `audiobridge-site`.
