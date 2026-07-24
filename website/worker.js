import page from './src/index.html';
import clientScript from './src/app.client.js';
import themeScript from './src/theme-init.client.js';
import stylesheet from './src/styles.css';
import favicon from './src/favicon.svg';
import socialCard from './src/og-card.svg';
import webManifest from './src/site.webmanifest';
import robots from './src/robots.txt';
import sitemap from './src/sitemap.xml';

const assets = new Map([
  ['/', { body: page, contentType: 'text/html; charset=utf-8' }],
  ['/index.html', { body: page, contentType: 'text/html; charset=utf-8' }],
  ['/styles.css', { body: stylesheet, contentType: 'text/css; charset=utf-8' }],
  ['/app.js', { body: clientScript, contentType: 'text/javascript; charset=utf-8' }],
  ['/theme.js', { body: themeScript, contentType: 'text/javascript; charset=utf-8' }],
  ['/favicon.svg', { body: favicon, contentType: 'image/svg+xml; charset=utf-8' }],
  ['/og-card.svg', { body: socialCard, contentType: 'image/svg+xml; charset=utf-8' }],
  ['/site.webmanifest', { body: webManifest, contentType: 'application/manifest+json; charset=utf-8' }],
  ['/robots.txt', { body: robots, contentType: 'text/plain; charset=utf-8' }],
  ['/sitemap.xml', { body: sitemap, contentType: 'application/xml; charset=utf-8' }],
]);

const securityHeaders = {
  'Content-Security-Policy': "default-src 'self'; base-uri 'self'; connect-src 'none'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'; upgrade-insecure-requests",
  'Permissions-Policy': 'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
};

export default {
  async fetch(request) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', {
        status: 405,
        headers: { ...securityHeaders, Allow: 'GET, HEAD' },
      });
    }

    const url = new URL(request.url);
    const asset = assets.get(url.pathname);
    if (!asset) {
      return new Response('Not found', { status: 404, headers: securityHeaders });
    }

    const isDocument = asset.contentType.startsWith('text/html');
    return new Response(request.method === 'HEAD' ? null : asset.body, {
      status: 200,
      headers: {
        ...securityHeaders,
        'Cache-Control': isDocument
          ? 'public, max-age=0, must-revalidate'
          : 'public, max-age=3600',
        'Content-Type': asset.contentType,
      },
    });
  },
};
