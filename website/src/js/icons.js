// The site's icons: small line drawings in the spirit of the SF Symbols the
// app uses, as inline SVG strings (rendered at build time and by the
// browser alike). Each scales with the font size (1em) and takes the text
// color.

const line = (body, box = 16) =>
  `<svg class="i" viewBox="0 0 ${box} ${box}" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const solid = (body, box = 16) =>
  `<svg class="i" viewBox="0 0 ${box} ${box}" width="1em" height="1em" fill="currentColor" aria-hidden="true">${body}</svg>`;

export const icons = {
  // Relay's mark: the two blades of the app icon.
  mark: `<svg class="i mark" viewBox="0 0 155 225" width="0.69em" height="1em" aria-hidden="true"><path fill="currentColor" opacity=".55" d="M15.06 0h57c6 0 9.34 3 10 9 4 25 16.44 48.5 35.94 58 3.33 2.67 3 4.67-1 6-28 4-51.94 16-67.94 29-3.33 3.33-6.66 3.33-10 0-23-24-36-60-35-92C4.06 3.33 7.73 0 15.06 0Z"/><path fill="currentColor" d="M147 79c5.33 0 8 2.67 8 8v51c0 4-2 6.67-6 8-35 8-65.94 35-70.94 70-1.33 6-5 9-11 9h-53C4.06 225-.6 220.33.06 211c2-32 10-57 27-78C55.06 100 107 79 147 79Z"/></svg>`,

  folder: line('<path d="M1.75 4.4c0-.75.6-1.35 1.35-1.35h2.8c.4 0 .75.15 1 .45l.75.85h5.25c.75 0 1.35.6 1.35 1.35v5.9c0 .75-.6 1.35-1.35 1.35H3.1c-.75 0-1.35-.6-1.35-1.35z"/>'),
  chevronRight: line('<path d="M6 3.5 10.5 8 6 12.5"/>'),
  chevronDown: line('<path d="M3.5 6 8 10.5 12.5 6"/>'),
  chevronLeft: line('<path d="M10 3 5 8l5 5"/>'),
  plus: line('<path d="M8 3v10M3 8h10"/>'),
  plusCircle: line('<circle cx="8" cy="8" r="6"/><path d="M8 5.3v5.4M5.3 8h5.4"/>'),
  ellipsis: solid('<circle cx="3.2" cy="8" r="1.25"/><circle cx="8" cy="8" r="1.25"/><circle cx="12.8" cy="8" r="1.25"/>'),
  ellipsisCircle: `<svg class="i" viewBox="0 0 16 16" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.35" aria-hidden="true"><circle cx="8" cy="8" r="6.2"/><g fill="currentColor" stroke="none"><circle cx="5" cy="8" r=".9"/><circle cx="8" cy="8" r=".9"/><circle cx="11" cy="8" r=".9"/></g></svg>`,
  sidebar: line('<rect x="1.6" y="2.8" width="12.8" height="10.4" rx="2.4"/><path d="M6 2.8v10.4"/>'),
  pull: line('<circle cx="4" cy="3.6" r="1.6"/><circle cx="4" cy="12.4" r="1.6"/><circle cx="12" cy="12.4" r="1.6"/><path d="M4 5.2v5.6M12 10.8V7.1c0-1.4-1.1-2.5-2.5-2.5H7.6M9.3 2.8 7.5 4.6l1.8 1.8"/>'),
  check: line('<path d="m3.2 8.4 3 3 6.6-7"/>'),
  checkCircle: solid('<path fill-rule="evenodd" d="M8 1.2a6.8 6.8 0 1 0 0 13.6A6.8 6.8 0 0 0 8 1.2Zm3.5 5.1a.7.7 0 0 0-1.03-.95L7.1 9 5.5 7.4a.7.7 0 0 0-.99.99l2.13 2.13c.28.28.74.27 1-.02z"/>'),
  xCircle: solid('<path fill-rule="evenodd" d="M8 1.2a6.8 6.8 0 1 0 0 13.6A6.8 6.8 0 0 0 8 1.2ZM6.1 5.1a.7.7 0 0 0-1 1L7 8 5.1 9.9a.7.7 0 0 0 1 1L8 9l1.9 1.9a.7.7 0 0 0 1-1L9 8l1.9-1.9a.7.7 0 0 0-1-1L8 7z"/>'),
  clock: line('<circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8l2.3 1.5"/>'),
  refresh: line('<path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.75"/><path d="M13.3 2.3v2.4h-2.4" />'),
  external: line('<path d="M9.2 2.5h4.3v4.3M13.2 2.8 7.6 8.4"/><path d="M11.8 9.6v2.3c0 .9-.7 1.6-1.6 1.6H4.1c-.9 0-1.6-.7-1.6-1.6V5.8c0-.9.7-1.6 1.6-1.6h2.3"/>'),
  gear: line('<circle cx="8" cy="8" r="2.1"/><path d="M8 1.6v1.6M8 12.8v1.6M1.6 8h1.6M12.8 8h1.6M3.5 3.5l1.1 1.1M11.4 11.4l1.1 1.1M3.5 12.5l1.1-1.1M11.4 4.6l1.1-1.1"/>'),
  uploadDoc: line('<path d="M9.2 1.8H4.6c-.8 0-1.4.6-1.4 1.4v9.6c0 .8.6 1.4 1.4 1.4h6.8c.8 0 1.4-.6 1.4-1.4V5.4z"/><path d="M9.2 1.8v3.6h3.6M8 11.6V7.4M6.2 9l1.8-1.8L9.8 9"/>'),
  doc: line('<path d="M9.2 1.8H4.6c-.8 0-1.4.6-1.4 1.4v9.6c0 .8.6 1.4 1.4 1.4h6.8c.8 0 1.4-.6 1.4-1.4V5.4z"/><path d="M9.2 1.8v3.6h3.6"/>'),
  paste: line('<rect x="3" y="3" width="10" height="11.2" rx="1.6"/><path d="M6 3c0-.7.5-1.2 1.2-1.2h1.6c.7 0 1.2.5 1.2 1.2v.9H6z"/>'),
  keyboardDown: line('<rect x="1.6" y="2.2" width="12.8" height="7.6" rx="1.6"/><path d="M4.2 4.9h.01M6.7 4.9h.01M9.3 4.9h.01M11.8 4.9h.01M5 7.3h6M6 12.4l2 1.8 2-1.8"/>'),
  cloud: line('<path d="M4.4 12.6a3 3 0 0 1-.5-5.96 4.1 4.1 0 0 1 7.9-.64 3.3 3.3 0 0 1-.3 6.6z"/>'),
  cloudCheck: line('<path d="M4.4 12.6a3 3 0 0 1-.5-5.96 4.1 4.1 0 0 1 7.9-.64 3.3 3.3 0 0 1-.3 6.6z"/><path d="m6.3 9.1 1.4 1.4 2.4-2.7"/>'),
  lock: line('<rect x="3.2" y="7" width="9.6" height="7" rx="1.8"/><path d="M5.3 7V5a2.7 2.7 0 0 1 5.4 0v2"/>'),
  key: line('<circle cx="5.2" cy="10.8" r="2.9"/><path d="m7.3 8.7 6-6M11 5l1.9 1.9M9.3 6.7l1.4 1.4"/>'),
  download: line('<path d="M8 2.2v7.9M4.8 7.2 8 10.4l3.2-3.2M2.8 13.4h10.4"/>'),
  copy: line('<rect x="5.4" y="5.4" width="8.2" height="8.2" rx="1.6"/><path d="M10.6 5.4V4c0-.9-.7-1.6-1.6-1.6H4c-.9 0-1.6.7-1.6 1.6v5c0 .9.7 1.6 1.6 1.6h1.4"/>'),
  star: line('<path d="m8 1.9 1.85 3.9 4.25.55-3.1 2.95.8 4.2L8 11.45 4.2 13.5l.8-4.2-3.1-2.95 4.25-.55z"/>'),
  arrowRight: line('<path d="M2.8 8h10.4M9.4 4.2 13.2 8l-3.8 3.8"/>'),
  arrowUpRight: line('<path d="M4.6 11.4 11.4 4.6M5.6 4.6h5.8v5.8"/>'),
  terminal: line('<rect x="1.6" y="2.6" width="12.8" height="10.8" rx="2.2"/><path d="m4.4 6 2.2 2-2.2 2M8.2 10.2h3.2"/>'),
  bolt: line('<path d="M9 1.8 3.4 9h4l-.6 5.2L12.6 7h-4z"/>'),
  bell: line('<path d="M4 6.6a4 4 0 0 1 8 0c0 3.4 1.4 4.4 1.4 4.4H2.6S4 10 4 6.6ZM6.6 13.2a1.5 1.5 0 0 0 2.8 0"/>'),
  moon: line('<path d="M13.4 9.6A5.9 5.9 0 0 1 6.4 2.6a5.9 5.9 0 1 0 7 7Z"/>'),
  wifiOff: line('<path d="M2.2 2.2 13.8 13.8M4.9 9.3a4.5 4.5 0 0 1 2-1.1M9.7 8.4c.5.2 1 .5 1.4.9M2.6 6.9a8 8 0 0 1 2.2-1.5M7.4 4.6a8 8 0 0 1 6 2.3"/><circle cx="8" cy="12" r=".6" fill="currentColor"/>'),
  power: line('<path d="M8 2v5.4M4.5 4.2a5.4 5.4 0 1 0 7 0"/>'),
  laptop: line('<rect x="3" y="3" width="10" height="7.2" rx="1.2"/><path d="M1.4 12.8h13.2"/>'),
  phone: line('<rect x="4.4" y="1.6" width="7.2" height="12.8" rx="1.8"/><path d="M7.2 3.5h1.6"/>'),
  tablet: line('<rect x="2.6" y="1.8" width="10.8" height="12.4" rx="1.8"/><path d="M7.2 12.2h1.6"/>'),
  server: line('<rect x="2" y="2.4" width="12" height="4.6" rx="1.3"/><rect x="2" y="9" width="12" height="4.6" rx="1.3"/><path d="M4.6 4.7h.01M4.6 11.3h.01"/>'),
  cpu: line('<rect x="4" y="4" width="8" height="8" rx="1.4"/><path d="M6.4 1.8V4M9.6 1.8V4M6.4 12v2.2M9.6 12v2.2M1.8 6.4H4M1.8 9.6H4M12 6.4h2.2M12 9.6h2.2"/>'),
  link: line('<path d="M6.9 9.1a3 3 0 0 0 4.2 0l2-2a3 3 0 0 0-4.2-4.2l-.9.9"/><path d="M9.1 6.9a3 3 0 0 0-4.2 0l-2 2a3 3 0 0 0 4.2 4.2l.9-.9"/>'),
  eye: line('<path d="M1.4 8S3.8 3.6 8 3.6 14.6 8 14.6 8 12.2 12.4 8 12.4 1.4 8 1.4 8Z"/><circle cx="8" cy="8" r="1.9"/>'),
  branch: line('<circle cx="4.2" cy="3.6" r="1.6"/><circle cx="4.2" cy="12.4" r="1.6"/><circle cx="11.8" cy="5.2" r="1.6"/><path d="M4.2 5.2v5.6M11.8 6.8c0 2.4-2.4 3-4.6 3.2-1.6.2-3 .2-3 .8"/>'),
  command: line('<path d="M5.8 5.8h4.4v4.4H5.8zM5.8 5.8V4.2a1.6 1.6 0 1 0-1.6 1.6zM10.2 5.8V4.2a1.6 1.6 0 1 1 1.6 1.6zM5.8 10.2v1.6a1.6 1.6 0 1 1-1.6-1.6zM10.2 10.2v1.6a1.6 1.6 0 1 0 1.6-1.6z"/>'),
  shield: line('<path d="M8 1.6 2.8 3.6v4.2c0 3.1 2.1 5.5 5.2 6.6 3.1-1.1 5.2-3.5 5.2-6.6V3.6z"/><path d="m5.9 8 1.5 1.5L10.2 6.6"/>'),
  heart: line('<path d="M8 13.4S2 9.9 2 5.9a3.1 3.1 0 0 1 6-1.2 3.1 3.1 0 0 1 6 1.2c0 4-6 7.5-6 7.5Z"/>'),
  box: line('<path d="M8 1.8 2.4 4.6v6.8L8 14.2l5.6-2.8V4.6zM2.6 4.7 8 7.5l5.4-2.8M8 7.5v6.5"/>'),
  sparkle: line('<path d="M8 1.8v3M8 11.2v3M1.8 8h3M11.2 8h3M3.8 3.8l2 2M10.2 10.2l2 2M3.8 12.2l2-2M10.2 5.8l2-2"/>'),
  swap: line('<path d="M2.6 5.4h10.2M10 2.6l2.8 2.8L10 8.2M13.4 10.6H3.2M6 7.8l-2.8 2.8L6 13.4"/>'),
  cursor: solid('<path d="M3.2 1.9v11.2l3-2.7 1.9 4.2 1.9-.85-1.9-4.1 4-.3z" stroke="#000" stroke-width=".8" stroke-linejoin="round"/>'),
  github: solid('<path d="M8 .9a7.1 7.1 0 0 0-2.24 13.84c.35.06.48-.15.48-.34v-1.2c-1.98.43-2.4-.95-2.4-.95-.32-.82-.79-1.04-.79-1.04-.64-.44.05-.43.05-.43.71.05 1.09.73 1.09.73.63 1.09 1.66.77 2.07.59.06-.46.25-.77.45-.95-1.58-.18-3.24-.79-3.24-3.51 0-.78.28-1.41.73-1.91-.07-.18-.32-.9.07-1.88 0 0 .6-.19 1.95.73a6.8 6.8 0 0 1 3.56 0c1.35-.92 1.95-.73 1.95-.73.39.98.14 1.7.07 1.88.45.5.73 1.13.73 1.91 0 2.73-1.66 3.33-3.25 3.5.26.22.48.65.48 1.32v1.95c0 .19.13.41.49.34A7.1 7.1 0 0 0 8 .9Z"/>'),
};
