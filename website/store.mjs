#!/usr/bin/env node
// Renders the App Store's screenshots: each one a page (src/js/store.js:
// a headline over the app's HTML mockups, on the site's background),
// pictured by headless Chrome at the size App Store Connect asks for.
//
//   node store.mjs [folder]          every screenshot, into the folder
//   node store.mjs [folder] ipad     only those whose name has "ipad"
//   node store.mjs [folder] --html   only the pages (open them to work on one)
//
// The folder defaults to ../build/store/screenshots; the pages go in its
// html/ folder. Chrome is found in /Applications, or named by CHROME.

import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { deflateSync, inflateSync } from 'node:zlib';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));
const src = join(root, 'src');
const args = process.argv.slice(2);
const htmlOnly = args.includes('--html');
const [folder = join(root, '..', 'build', 'store', 'screenshots'), only = ''] = args.filter((a) => !a.startsWith('--'));
const out = resolve(folder);

// One stylesheet, fonts and all, so a page is a single file.
const styles = await esbuild.build({
  entryPoints: [join(src, 'css', 'store.css')],
  bundle: true,
  write: false,
  minify: true,
  loader: { '.woff2': 'dataurl' },
  logLevel: 'warning',
});
const css = styles.outputFiles[0].text;

// The screenshots, from the modules the site draws its mockups with.
const module = await esbuild.build({
  entryPoints: [join(src, 'js', 'store.js')],
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'node',
  logLevel: 'warning',
});
const { shots } = await import(`data:text/javascript;base64,${Buffer.from(module.outputFiles[0].text).toString('base64')}`);

// The site's field at rest (src/js/field.js): a dot at every cell, a small
// cross where every sixth lines meet.
const CELL = 26;
const MAJOR = 6;
let marks = '';
for (let row = 0; row < MAJOR; row++) {
  for (let column = 0; column < MAJOR; column++) {
    const [x, y] = [column * CELL, row * CELL];
    marks +=
      row === 0 && column === 0
        ? `<path fill="#fff" fill-opacity=".2" d="M${x + 10} ${y + 12.5}h7v1h-7zM${x + 12.5} ${y + 10}h1v7h-1z"/>`
        : `<rect fill="#fff" fill-opacity=".11" x="${x + 12.4}" y="${y + 12.4}" width="1.2" height="1.2"/>`;
  }
}
const tile = CELL * MAJOR;
const grid = `url("data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="${tile}" height="${tile}">${marks}</svg>`,
)}")`;

const page = (shot) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${shot.name} (${shot.width * shot.scale} × ${shot.height * shot.scale})</title>
<style>:root { --grid: ${grid}; }</style>
<style>${css}</style>
</head>
<body>
${shot.body}
</body>
</html>
`;

const chrome =
  process.env.CHROME ||
  ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium'].find(
    existsSync,
  );

/**
 * Chrome's PNGs carry an alpha channel, which App Store Connect refuses in
 * a screenshot: the same picture, without it.
 */
function opaque(png) {
  const chunks = [];
  for (let at = 8; at < png.length; ) {
    const length = png.readUInt32BE(at);
    chunks.push({ type: png.toString('latin1', at + 4, at + 8), data: png.subarray(at + 8, at + 8 + length) });
    at += 12 + length;
  }
  const header = chunks.find((chunk) => chunk.type === 'IHDR').data;
  const [width, height] = [header.readUInt32BE(0), header.readUInt32BE(4)];
  if (header[8] !== 8 || header[9] !== 6 || header[12] !== 0) return { png, width, height };
  const raw = inflateSync(Buffer.concat(chunks.filter((chunk) => chunk.type === 'IDAT').map((chunk) => chunk.data)));
  const stride = width * 4;
  const rgb = Buffer.alloc(height * (1 + width * 3));
  let above = Buffer.alloc(stride);
  for (let row = 0; row < height; row++) {
    const filter = raw[row * (stride + 1)];
    const line = Buffer.from(raw.subarray(row * (stride + 1) + 1, (row + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const left = i >= 4 ? line[i - 4] : 0;
      const up = above[i];
      const corner = i >= 4 ? above[i - 4] : 0;
      let predicted = 0;
      if (filter === 1) predicted = left;
      else if (filter === 2) predicted = up;
      else if (filter === 3) predicted = (left + up) >> 1;
      else if (filter === 4) {
        const estimate = left + up - corner;
        const [a, b, c] = [Math.abs(estimate - left), Math.abs(estimate - up), Math.abs(estimate - corner)];
        predicted = a <= b && a <= c ? left : b <= c ? up : corner;
      }
      line[i] = (line[i] + predicted) & 255;
    }
    const to = row * (1 + width * 3) + 1;
    for (let x = 0; x < width; x++) line.copy(rgb, to + x * 3, x * 4, x * 4 + 3);
    above = line;
  }
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let bit = 0; bit < 8; bit++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    let crc = 0xffffffff;
    for (const byte of body) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
    const framed = Buffer.alloc(12 + data.length);
    framed.writeUInt32BE(data.length, 0);
    body.copy(framed, 4);
    framed.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 8 + data.length);
    return framed;
  };
  const opaqueHeader = Buffer.from(header);
  opaqueHeader[9] = 2; // RGB
  return {
    png: Buffer.concat([png.subarray(0, 8), chunk('IHDR', opaqueHeader), chunk('IDAT', deflateSync(rgb)), chunk('IEND', Buffer.alloc(0))]),
    width,
    height,
  };
}

await mkdir(join(out, 'html'), { recursive: true });
const wanted = shots.filter((shot) => shot.name.includes(only));
if (!wanted.length) throw new Error(`no screenshot named like "${only}"`);
if (!htmlOnly && !chrome) throw new Error('no Chrome in /Applications: name one with CHROME, or pass --html');

for (const shot of wanted) {
  const html = join(out, 'html', `${shot.name}.html`);
  await writeFile(html, page(shot));
  if (htmlOnly) {
    console.log(html);
    continue;
  }
  const file = join(out, `${shot.name}.png`);
  await promisify(execFile)(chrome, [
    '--headless=new',
    '--hide-scrollbars',
    '--disable-gpu',
    `--force-device-scale-factor=${shot.scale}`,
    `--window-size=${shot.width},${shot.height}`,
    // Long enough for the fonts (in the page) to be laid out.
    '--virtual-time-budget=3000',
    `--screenshot=${file}`,
    pathToFileURL(html).href,
  ]);
  const { png, width, height } = opaque(await readFile(file));
  const [w, h] = [shot.width * shot.scale, shot.height * shot.scale];
  if (width !== w || height !== h) throw new Error(`${shot.name}: ${width} × ${height}, not ${w} × ${h}`);
  await writeFile(file, png);
  console.log(`${shot.name}.png  ${width} × ${height}`);
}
