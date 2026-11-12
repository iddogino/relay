#!/usr/bin/env node
// Builds relayapp.sh into dist/.
//
//   node build.mjs            build (fetches the releases from GitHub)
//   node build.mjs --offline  build from the last fetched releases
//   node build.mjs --serve    build, serve on :4321 and rebuild on change
//
// The pages are plain HTML templates in src/ ({{value}}, {{{raw}}} and
// <!-- @include name -->), the app mockups are rendered here from the same
// modules that animate them in the browser, and /releases is generated from
// the repository's GitHub releases. GITHUB_TOKEN (or GH_TOKEN) is used when
// set — the unauthenticated API allows 60 requests an hour per address,
// which CI runners share.

import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync, watch } from 'node:fs';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));
const src = join(root, 'src');
const dist = join(root, 'dist');
const cacheFile = join(root, '.cache', 'github.json');

const SITE = 'https://relayapp.sh';
const REPO = 'iddogino/relay';
const REPO_URL = `https://github.com/${REPO}`;

const args = new Set(process.argv.slice(2));
const offline = args.has('--offline');
const serve = args.has('--serve');

// ───────────────────────────────────────────────────────────── GitHub

async function github(path) {
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'relay-website-build',
  };
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`https://api.github.com${path}`, { headers });
  if (!response.ok) {
    throw new Error(`GitHub ${path}: ${response.status} ${(await response.text()).slice(0, 200)}`);
  }
  return response.json();
}

let fetched = null;

/** The repository's releases and star count, from GitHub or the cache. */
async function loadGitHub() {
  // While serving, every rebuild reuses the first fetch.
  fetched ??= await fetchGitHub();
  return fetched;
}

async function fetchGitHub() {
  if (offline) {
    if (!existsSync(cacheFile)) throw new Error('--offline: nothing fetched yet (run a build online first)');
    return JSON.parse(await readFile(cacheFile, 'utf8'));
  }
  try {
    const releases = [];
    for (let page = 1; page <= 5; page++) {
      const batch = await github(`/repos/${REPO}/releases?per_page=100&page=${page}`);
      releases.push(...batch);
      if (batch.length < 100) break;
    }
    const repo = await github(`/repos/${REPO}`);
    const data = { fetchedAt: new Date().toISOString(), stars: repo.stargazers_count, releases };
    await mkdir(dirname(cacheFile), { recursive: true });
    await writeFile(cacheFile, JSON.stringify(data));
    return data;
  } catch (error) {
    // A deploy must never publish stale or empty release notes; a local
    // build may carry on with what it fetched last.
    if (process.env.CI || !existsSync(cacheFile)) throw error;
    console.warn(`! ${error.message}\n! using the releases fetched earlier`);
    return JSON.parse(await readFile(cacheFile, 'utf8'));
  }
}

// ──────────────────────────────────────────────────────── release notes

const esc = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** A GitHub URL as people write it: #19, v0.1.0...v0.2.0, or the bare host and path. */
function shortURL(url) {
  let m = url.match(/^https:\/\/github\.com\/[^/]+\/[^/]+\/(?:pull|issues)\/(\d+)/);
  if (m) return `#${m[1]}`;
  m = url.match(/^https:\/\/github\.com\/[^/]+\/[^/]+\/compare\/(.+)$/);
  if (m) return m[1];
  return url.replace(/^https?:\/\//, '').replace(/\/$/, '');
}

/** Inline Markdown: code, links, bare URLs, bold, italics, @mentions. */
function inline(text) {
  return text
    .split(/(`[^`]+`)/)
    .map((part) => {
      if (/^`[^`]+`$/.test(part)) return `<code>${esc(part.slice(1, -1))}</code>`;
      let t = esc(part);
      t = t.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
      t = t.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (_, pre, url) => `${pre}<a href="${url}">${shortURL(url)}</a>`);
      t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
      t = t.replace(/(^|[\s(])_([^_]+)_(?=$|[\s).,;:!?])/g, '$1<em>$2</em>');
      t = t.replace(/(^|[\s(])@([A-Za-z0-9][A-Za-z0-9-]*)/g, '$1<a href="https://github.com/$2">@$2</a>');
      return t;
    })
    .join('');
}

/** Block Markdown, as much of it as release notes use. */
function markdown(source) {
  const lines = source.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let paragraph = [];
  let list = null; // { tag, items }
  const flushParagraph = () => {
    if (paragraph.length) out.push(`<p>${inline(paragraph.join(' '))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (list) out.push(`<${list.tag}>${list.items.map((i) => `<li>${inline(i)}</li>`).join('')}</${list.tag}>`);
    list = null;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^```/.test(line)) {
      flushParagraph();
      flushList();
      const code = [];
      for (i++; i < lines.length && !/^```/.test(lines[i]); i++) code.push(lines[i]);
      out.push(`<pre><code>${esc(code.join('\n'))}</code></pre>`);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      flushParagraph();
      flushList();
      const level = Math.min(Math.max(heading[1].length + 1, 3), 5);
      out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      continue;
    }
    const bullet = line.match(/^\s*[*+-]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (bullet || numbered) {
      flushParagraph();
      const tag = bullet ? 'ul' : 'ol';
      if (list && list.tag !== tag) flushList();
      list ??= { tag, items: [] };
      list.items.push((bullet || numbered)[1]);
      continue;
    }
    if (/^\s+\S/.test(line) && list) {
      list.items[list.items.length - 1] += ` ${line.trim()}`;
      continue;
    }
    if (!line.trim()) {
      flushParagraph();
      flushList();
      continue;
    }
    flushList();
    paragraph.push(line.trim());
  }
  flushParagraph();
  flushList();
  return out.join('\n');
}

/** Splits a release body at its level-2 headings: [{ title, text }]. */
function sections(body) {
  const result = [{ title: '', text: [] }];
  let fenced = false;
  for (const line of body.replace(/\r\n/g, '\n').split('\n')) {
    if (/^```/.test(line)) fenced = !fenced;
    const heading = !fenced && line.match(/^##\s+(.*)$/);
    if (heading) result.push({ title: heading[1].trim(), text: [] });
    else result[result.length - 1].text.push(line);
  }
  return result.map((s) => ({ title: s.title, text: s.text.join('\n').trim() }));
}

const megabytes = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`;

/** What the pages show of one GitHub release. */
function parseRelease(release) {
  const body = release.body || '';
  const dmg = release.assets.find((a) => a.name.endsWith('.dmg'));
  const sha = body.match(/\b([0-9a-f]{64})\s+\S+\.dmg/);
  let changes = [];
  let compare = null;
  const notes = [];
  for (const section of sections(body)) {
    // The download button and the checksum row say these already.
    if (/^install$/i.test(section.title) || /^sha-?256$/i.test(section.title)) continue;
    let text = section.text.replace(/^\*\*Full Changelog\*\*:\s*(\S+)\s*$/m, (_, url) => {
      compare = url;
      return '';
    });
    if (/^what'?s changed$/i.test(section.title)) {
      const rest = [];
      for (const line of text.split('\n')) {
        const item = line.match(/^\s*[*-]\s+(.*?)\s+by\s+@([A-Za-z0-9-]+)\s+in\s+(https:\/\/github\.com\/\S+\/pull\/(\d+))\s*$/);
        if (item) changes.push({ title: item[1], user: item[2], url: item[3], number: item[4] });
        else rest.push(line);
      }
      text = rest.join('\n').trim();
      if (text) notes.push(markdown(text));
      continue;
    }
    text = text.trim();
    if (!text && !section.title) continue;
    notes.push((section.title ? `<h3>${inline(section.title)}</h3>\n` : '') + markdown(text));
  }
  const version = release.tag_name.replace(/^v/, '');
  return {
    tag: release.tag_name,
    version,
    prerelease: release.prerelease,
    date: release.published_at,
    url: release.html_url,
    dmg: dmg && { name: dmg.name, url: dmg.browser_download_url, size: megabytes(dmg.size) },
    sha256: sha?.[1] ?? null,
    changes,
    compare,
    notes: notes.join('\n'),
  };
}

const dateFormat = new Intl.DateTimeFormat('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

function releaseHTML(release, { latest }) {
  const owner = REPO.split('/')[0];
  const changes = release.changes.length
    ? `<ul class="changes">${release.changes
        .map(
          (c) =>
            `<li><span>${inline(c.title)}${c.user !== owner ? ` <span class="by">by <a href="https://github.com/${c.user}">@${c.user}</a></span>` : ''}</span><a class="pr" href="${c.url}">#${c.number}</a></li>`,
        )
        .join('')}</ul>`
    : '';
  const badge = release.prerelease
    ? '<span class="badge is-pre">Pre-release</span>'
    : latest
      ? '<span class="badge is-latest">Latest</span>'
      : '';
  const download = release.dmg
    ? `<a class="btn ${latest ? 'primary' : 'ghost'} small" href="${release.dmg.url}" data-download>
         {{{icon.download}}}<span>${esc(release.dmg.name)}</span><small>${release.dmg.size}</small>
       </a>`
    : '';
  const checksum = release.sha256
    ? `<div class="checksum"><span class="label">SHA-256</span><code>${release.sha256}</code><button type="button" class="copy" data-copy="${release.sha256}" aria-label="Copy the SHA-256 checksum">{{{icon.copy}}}</button></div>`
    : '';
  const links = [
    `<a href="${release.url}">View on GitHub</a>`,
    release.compare ? `<a href="${esc(release.compare)}">Full changelog</a>` : '',
  ]
    .filter(Boolean)
    .join('<span aria-hidden="true">·</span>');
  return `
<article class="release reveal" id="${esc(release.tag)}" data-channel="${release.prerelease ? 'pre' : 'stable'}">
  <header>
    <h2><a href="#${esc(release.tag)}">${esc(release.version)}</a></h2>
    ${badge}
    <time datetime="${release.date}">${dateFormat.format(new Date(release.date))}</time>
  </header>
  <div class="release-body">
    ${changes}
    ${release.notes ? `<div class="prose">${release.notes}</div>` : ''}
    ${!changes && !release.notes ? '<p class="quiet">No notes for this build.</p>' : ''}
    <div class="release-actions">${download}${checksum}</div>
    <p class="release-links">${links}</p>
  </div>
</article>`;
}

// ─────────────────────────────────────────────────────────── templates

async function partial(name) {
  return readFile(join(src, 'partials', `${name}.html`), 'utf8');
}

/** Expands includes, then {{{raw}}} and {{escaped}} values (dotted paths). */
async function render(template, values) {
  let html = template;
  for (let depth = 0; depth < 4 && /<!--\s*@include\s+[\w-]+\s*-->/.test(html); depth++) {
    const names = [...html.matchAll(/<!--\s*@include\s+([\w-]+)\s*-->/g)].map((m) => m[1]);
    const parts = Object.fromEntries(await Promise.all([...new Set(names)].map(async (n) => [n, await partial(n)])));
    html = html.replace(/<!--\s*@include\s+([\w-]+)\s*-->/g, (_, name) => parts[name]);
  }
  const lookup = (path) => {
    const value = path.split('.').reduce((v, key) => v?.[key], values);
    if (value === undefined) throw new Error(`template: no value for {{${path}}}`);
    return value;
  };
  // Twice: values (the release list) carry icon placeholders of their own.
  for (let pass = 0; pass < 2; pass++) {
    html = html.replace(/\{\{\{\s*([\w.]+)\s*\}\}\}/g, (_, path) => String(lookup(path)));
  }
  return html.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, path) => esc(lookup(path)));
}

// ────────────────────────────────────────────────────────────── build

async function build() {
  const started = Date.now();
  const data = await loadGitHub();
  const releases = data.releases.filter((r) => !r.draft).map(parseRelease);
  const stable = releases.find((r) => !r.prerelease && r.dmg);
  const newest = releases.find((r) => r.dmg);
  if (!stable) throw new Error('no stable release with a DMG');
  // A release candidate is worth offering only while it's ahead of stable.
  const candidate = newest && newest.prerelease && new Date(newest.date) > new Date(stable.date) ? newest : null;

  await rm(dist, { recursive: true, force: true });
  await mkdir(join(dist, 'assets'), { recursive: true });

  // Scripts and styles: bundled, minified, named by content.
  const bundle = await esbuild.build({
    entryPoints: {
      home: join(src, 'js', 'home.js'),
      releases: join(src, 'js', 'releases.js'),
      plain: join(src, 'js', 'plain.js'),
      site: join(src, 'css', 'site.css'),
    },
    outdir: join(dist, 'assets'),
    entryNames: '[name].[hash]',
    assetNames: '[name].[hash]',
    bundle: true,
    minify: !serve,
    sourcemap: serve ? 'inline' : false,
    format: 'esm',
    target: ['es2022', 'safari16'],
    loader: { '.woff2': 'file', '.svg': 'file', '.png': 'file' },
    metafile: true,
    logLevel: 'warning',
  });
  const asset = {};
  const font = {};
  for (const [file, output] of Object.entries(bundle.metafile.outputs)) {
    // The terminal's font is worth a preload; its name carries a hash.
    if (/JetBrainsMono-Regular\.[^.]+\.woff2$/.test(file)) font.mono = `/assets/${file.split('/').pop()}`;
    if (!output.entryPoint) continue;
    const name = output.entryPoint.split('/').pop().replace(/\.(js|css)$/, '');
    asset[name] = `/assets/${file.split('/').pop()}`;
  }

  await cp(join(root, 'public'), dist, { recursive: true });

  // The mockups, from the modules the browser animates them with.
  // (Bundled first, so a rebuild sees edits to them and what they import.)
  const templates = await esbuild.build({
    stdin: {
      contents: `export { mocks } from './pages.js'; export { icons } from './icons.js';`,
      resolveDir: join(src, 'js'),
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
  });
  const { mocks, icons } = await import(
    `data:text/javascript;base64,${Buffer.from(templates.outputFiles[0].text).toString('base64')}`
  );

  const values = {
    site: SITE,
    repo: REPO_URL,
    repoName: REPO,
    stars: data.stars,
    starsLabel: data.stars >= 1000 ? `${(data.stars / 1000).toFixed(1)}k` : String(data.stars),
    // A count worth showing; until then the link speaks for itself.
    starsClass: data.stars >= 25 ? '' : 'hidden',
    year: new Date().getUTCFullYear(),
    asset,
    font,
    icon: icons,
    mock: mocks,
    stable,
    candidate: candidate ?? { version: '', tag: '', dmg: { url: '', size: '' } },
    candidateClass: candidate ? '' : 'hidden',
    releaseCount: releases.length,
    releaseList: releases.map((r) => releaseHTML(r, { latest: r === stable })).join('\n'),
    liveReload: serve
      ? '<script>let v;setInterval(async()=>{try{const n=await(await fetch("/__version")).text();if(v&&n!==v)location.reload();v=n}catch{}},700)</script>'
      : '',
  };

  for (const page of ['index', 'releases', '404']) {
    let html = await render(await readFile(join(src, `${page}.html`), 'utf8'), { ...values, page });
    // The navigation's link to the page you're on.
    html = html.replace(` data-nav="${page}"`, ' aria-current="page"').replace(/ data-nav="[\w-]+"/g, '');
    await writeFile(join(dist, `${page}.html`), html);
  }

  // Stable addresses for the newest builds (the README can link them too).
  const redirects = [
    `/download ${stable.dmg.url} 302`,
    `/download/latest ${stable.dmg.url} 302`,
    candidate ? `/download/rc ${candidate.dmg.url} 302` : `/download/rc ${stable.dmg.url} 302`,
    `/github ${REPO_URL} 302`,
    `/source ${REPO_URL} 302`,
    `/issues ${REPO_URL}/issues 302`,
    `/changelog /releases 301`,
  ];
  await writeFile(join(dist, '_redirects'), redirects.join('\n') + '\n');

  await writeFile(
    join(dist, 'sitemap.xml'),
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
      ['/', '/releases'].map((p) => `  <url><loc>${SITE}${p}</loc></url>`).join('\n') +
      `\n</urlset>\n`,
  );
  await writeFile(join(dist, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${SITE}/sitemap.xml\n`);

  const size = await directorySize(dist);
  console.log(
    `built dist/ in ${Date.now() - started} ms — ${releases.length} releases, stable ${stable.version}` +
      (candidate ? `, candidate ${candidate.version}` : '') +
      `, ${(size / 1024).toFixed(0)} KB`,
  );
  return redirects;
}

async function directorySize(dir) {
  let total = 0;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    total += entry.isDirectory() ? await directorySize(path) : (await stat(path)).size;
  }
  return total;
}

// ──────────────────────────────────────────────────────── development

const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.xml': 'application/xml',
  '.txt': 'text/plain; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

async function develop() {
  let redirects = await build();
  let version = Date.now();
  let timer = null;
  // Requests wait for a rebuild in progress (dist/ is emptied first).
  let building = Promise.resolve();
  const rebuild = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      building = building.then(async () => {
        try {
          redirects = await build();
          version = Date.now();
        } catch (error) {
          console.error(error.message);
        }
      });
    }, 80);
  };
  for (const dir of ['src', 'public']) watch(join(root, dir), { recursive: true }, rebuild);

  const port = Number(process.env.PORT || 4321);
  createServer(async (request, response) => {
    try {
      await building;
      await respond(request, response);
    } catch (error) {
      response.writeHead(500, { 'Content-Type': 'text/plain' });
      response.end(String(error.message));
    }
  }).listen(port, () => console.log(`http://localhost:${port}`));

  async function respond(request, response) {
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/__version') return response.end(String(version));
    const redirect = redirects.map((r) => r.split(' ')).find(([from]) => from === url.pathname);
    if (redirect) {
      response.writeHead(Number(redirect[2]), { Location: redirect[1] });
      return response.end();
    }
    // As Pages serves them: /releases is releases.html, anything else 404.html.
    const path = url.pathname.endsWith('/') ? `${url.pathname}index.html` : url.pathname;
    for (const candidate of [path, `${path}.html`]) {
      const file = join(dist, candidate);
      if (file.startsWith(dist) && existsSync(file) && (await stat(file)).isFile()) {
        response.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
        return response.end(await readFile(file));
      }
    }
    response.writeHead(404, { 'Content-Type': types['.html'] });
    response.end(await readFile(join(dist, '404.html')));
  }
}

if (serve) await develop();
else await build();
