// The App Store's screenshots, as pages (store.mjs renders each to a PNG):
// a headline, and under it the app — the same HTML mockups the landing page
// uses, showing one demo workspace. Everything a screenshot says is here:
// the headlines, the workspace, what each terminal shows, the diff.
//
// The mockups stand in for the app, so they have to stay true to it. To
// check them against the real thing, Scripts/store-screenshots.sh takes the
// same screens from the app itself.

import { macWindow, padDevice, phoneDevice } from './mocks.js';

const span = (cls) => (text) => `<span class="${cls}">${text}</span>`;
// The terminal's palette (term.js), by the first letter of the color.
const [k, r, g, y, c, o, bold, dim] = ['k', 'r', 'g', 'y', 'c', 'o', 'B', 'D'].map(span);
// The highlighter's (mock.css): keyword, type, function, string, number,
// operator, comment, punctuation.
const [kw, ty, fn, st, nu, op, cm, pu] = ['kw', 'ty', 'fn', 'st', 'nu', 'op', 'cm', 'pu'].map(span);

// ── The workspace ─────────────────────────────────────────────────────

const projects = [
  {
    id: 'api',
    name: 'api',
    host: 'mac-mini',
    sessions: [
      { id: 'auth', name: 'auth-refactor', caption: 'zsh', title: 'zsh', git: [6, 3], pr: { number: 482 } },
      { id: 'flaky', name: 'fix-flaky-tests', caption: '✳ Fix flaky upload test', title: '✳ Fix flaky upload test', agent: 'blocked', git: [12, 4] },
      { id: 'dev', name: 'dev-server', caption: 'npm run dev', title: 'npm run dev', git: [0, 0] },
    ],
  },
  {
    id: 'trainer',
    name: 'trainer',
    host: 'gpu-box',
    sessions: [
      { id: 'sweep', name: 'sweep-lr', caption: 'python3 train.py', title: 'python3 train.py', git: [7, 2] },
      { id: 'eval', name: 'eval-nightly', caption: '✳ Evaluate checkpoints', title: '✳ Evaluate checkpoints', agent: 'working', git: [0, 0] },
    ],
  },
  {
    id: 'infra',
    name: 'infra',
    host: 'hetzner-1',
    sessions: [{ id: 'tf', name: 'terraform', caption: 'zsh', title: 'zsh', agent: 'done', git: [3, 1] }],
  },
];
const world = (selected) => ({ selected, projects });

// ── What the terminals show ───────────────────────────────────────────
// Each takes the device, as a phone's terminal is half as wide.

const prompt = (folder) => `${c(folder)} ${g('❯')} `;

function tests(device) {
  const ms = (n) => (device === 'phone' ? '' : ` ${dim(`(${n} ms)`)}`);
  const pass = (name, n) => `  ${g('✓')} ${name}${ms(n)}`;
  return {
    lines: [
      '',
      ` ${bold('auth/session.test.ts')}`,
      pass('rotates the session on refresh', 12),
      pass('keeps the old token until the new one is used', 8),
      pass('refuses a refresh after sign-out', 5),
      pass('refreshes once for concurrent requests', 31),
      pass('treats a session as expiring 5 minutes early', 2),
      '',
      ` ${bold('auth/token.test.ts')}`,
      pass('signs with the current key', 4),
      pass('accepts the previous key during rotation', 6),
      pass('rejects an expired token', 1),
      '',
      ` ${g(bold('8 passed'))} ${dim('in 0.41 s')}`,
      '',
    ],
    current: prompt('api'),
  };
}

function training(device) {
  const width = device === 'phone' ? 10 : 20;
  const lines = [`${bold('sweep-lr')}  lr=3e-4  batch=256  2x GPU`, ''];
  let loss = 2.31;
  for (let epoch = 1; epoch <= 14; epoch++) {
    loss = 0.18 + (loss - 0.18) * 0.82;
    // Block characters, as a terminal draws them: without seams.
    const bar = `<span class="bar" style="--n:${Math.round((epoch / 20) * width)};--of:${width}"></span>`;
    lines.push(
      `epoch ${String(epoch).padStart(2)}/20 ${bar} loss ${loss.toFixed(3)}  acc ${g(`${((1 - loss / 2.6) * 100).toFixed(1)}%`)}`,
    );
  }
  lines.push('', `${k('checkpoint saved:')} runs/sweep-lr/epoch-14.pt`);
  return { lines, current: '' };
}

/** A coding agent that has stopped to ask. */
function agent(device) {
  const width = device === 'phone' ? 44 : 58;
  const row = (text, raw) => `${k('│')} ${text}${' '.repeat(Math.max(0, width - 2 - raw.length))} ${k('│')}`;
  const command = device === 'phone' ? 'npm test -- upload --repeat 50' : 'npm test -- upload.test.ts --repeat 50';
  return {
    lines: [
      `${k('>')} find out why the upload test fails one run in ten`,
      '',
      `${g('⏺')} ${bold('Read')}(test/upload.test.ts)`,
      `  ${k('⎿')}  Read 96 lines`,
      '',
      `${g('⏺')} ${bold('Search')}(pattern: ${y('"setTimeout"')})`,
      `  ${k('⎿')}  Found 3 matches in 2 files`,
      '',
      '⏺ The test waits a fixed 200 ms for the upload to',
      '  finish. I’d like to run it in a loop to confirm.',
      '',
      k(`╭${'─'.repeat(width)}╮`),
      row(bold('Run this command?'), 'Run this command?'),
      row('', ''),
      row(`  ${c(command)}`, `  ${command}`),
      row('', ''),
      row(`${o('❯')} 1. Yes`, '❯ 1. Yes'),
      row('  2. Yes, and don’t ask again', '  2. Yes, and don’t ask again'),
      row('  3. No, tell it what to do instead', '  3. No, tell it what to do instead'),
      k(`╰${'─'.repeat(width)}╯`),
    ],
    current: '',
    cursor: false,
  };
}

// ── The diff ──────────────────────────────────────────────────────────

const p = (text) => pu(text);
const diff = {
  session: 'auth-refactor',
  files: [
    {
      path: 'src/auth/session.ts',
      add: 6,
      del: 3,
      lines: [
        [1, 1, ' ', `${kw('import')} ${p('{')} sessions${p(',')} ${kw('type')} ${ty('User')} ${p('}')} ${kw('from')} ${st("'../store'")}`],
        [null, 2, '+', `${kw('import')} ${p('{')} once ${p('}')} ${kw('from')} ${st("'../util/once'")}`],
        [2, 3, ' ', ''],
        [3, 4, ' ', `${kw('const')} ${nu('REFRESH_WINDOW')} ${kw('=')} ${nu('5')} ${op('*')} ${nu('60')} ${op('*')} ${nu('1000')}`],
        [4, 5, ' ', ''],
        [5, null, '-', `${kw('export async function')} ${fn('refresh')}${p('(')}user${op(':')} User${p(')')} ${p('{')}`],
        [null, 6, '+', cm('// Concurrent requests share one refresh instead of racing.')],
        [null, 7, '+', `${kw('export const')} refresh ${kw('=')} ${fn('once')}${p('(')}${kw('async')} ${p('(')}user${op(':')} User${p(')')} ${op('=>')} ${p('{')}`],
        [6, 8, ' ', `  ${kw('const')} session ${kw('=')} ${kw('await')} sessions${p('.')}${fn('find')}${p('(')}user${p('.')}id${p(')')}`],
        [7, null, '-', `  ${kw('return')} session${p('.')}${fn('rotate')}${p('()')}`],
        [8, null, '-', p('}')],
        [null, 9, '+', `  ${kw('if')} ${p('(')}session${p('.')}revoked${p(')')} ${kw('throw new')} ${ty('SignedOutError')}${p('(')}user${p('.')}id${p(')')}`],
        [null, 10, '+', `  ${kw('return')} session${p('.')}${fn('rotate')}${p('({')} keepPrevious${op(':')} ${nu('true')} ${p('})')}`],
        [null, 11, '+', p('})')],
        [9, 12, ' ', ''],
        [10, 13, ' ', `${kw('export function')} ${fn('expiresSoon')}${p('(')}expiresAt${op(':')} ${ty('number')}${p(')')} ${p('{')}`],
        [11, 14, ' ', `  ${kw('return')} expiresAt ${op('−')} Date${p('.')}${fn('now')}${p('()')} ${op('<')} ${nu('REFRESH_WINDOW')}`],
        [12, 15, ' ', p('}')],
      ],
    },
  ],
};

// ── The screenshots ───────────────────────────────────────────────────

/**
 * One per screen, in the App Store's order. `title` is the headline (its
 * <em> is the part in white), `session` the one on screen, `terminal` what
 * it shows; `phone` says what an iPhone shows of it: the list, the
 * terminal, the terminal with the keyboard up, or the diff's sheet.
 */
const screens = [
  {
    name: 'sessions',
    title: 'Every machine. <em>One terminal.</em>',
    text: 'A Mac mini, a GPU box, a server in the cloud: every project and session in one place.',
    session: 'auth',
    terminal: tests,
    phone: 'list',
  },
  {
    name: 'persist',
    title: 'Close the lid. <em>Nothing stops.</em>',
    text: 'Sessions keep running on your machines. Relay picks up right where you left them.',
    session: 'sweep',
    terminal: training,
    phone: 'keyboard',
  },
  {
    name: 'agents',
    title: 'Know when an agent <em>needs you.</em>',
    text: 'See which sessions are working, waiting on you, or done.',
    session: 'flaky',
    terminal: agent,
    phone: 'terminal',
  },
  {
    name: 'changes',
    title: 'See what a session <em>changed.</em>',
    text: 'A syntax-highlighted diff of the work so far, a tap away.',
    session: 'auth',
    terminal: tests,
    tray: diff,
    phone: 'sheet',
  },
  // The three devices together, showing one session. Apple's names here
  // follow its guidelines for third parties (App Store Marketing
  // Guidelines; Guidelines for Using Apple Trademarks and Copyrights): none
  // in the headline, "works with" in the text, each spelled as Apple spells
  // it and never plural, possessive or a verb, and no cloud beside "iCloud"
  // — Apple's logos and icons aren't a third party's to use. The credit
  // line they ask for goes once, where the legal text is: it closes the App
  // Store description ("iCloud, iCloud Keychain, Mac, Mac mini, iPad and
  // iPhone are trademarks of Apple Inc., registered in the U.S. and other
  // countries and regions.").
  {
    name: 'sync',
    title: 'Start on one device. <em>Finish on another.</em>',
    text: 'Relay works with iCloud and iCloud Keychain: your hosts, projects and SSH keys follow you from Mac to iPad to iPhone.',
    session: 'auth',
    terminal: tests,
    phone: 'terminal',
    family: 'hosts · projects · SSH keys',
  },
];

/**
 * The canvases, in CSS pixels; `scale` is the device pixel ratio they're
 * rendered at, which makes the sizes App Store Connect asks for:
 * 2880 × 1800 (Mac), 2752 × 2064 (13-inch iPad), 1320 × 2868 (6.9-inch iPhone).
 */
const canvases = {
  mac: { width: 1440, height: 900, scale: 2 },
  ipad: { width: 1376, height: 1032, scale: 2 },
  iphone: { width: 660, height: 1434, scale: 2 },
};

function fill(html, { lines, current = '', cursor = true }) {
  const body = lines.map((line) => `<span class="l">${line || ' '}</span>`);
  if (current || cursor) body.push(`<span class="l">${current}${cursor ? '<i class="cur"></i>' : ''}</span>`);
  return html.replace(/(<div class="term-body" data-body>)(<\/div>)/, `$1${body.join('')}$2`);
}

function device(kind, screen) {
  const options = { tray: screen.tray ?? null };
  const show = world(screen.session);
  if (kind === 'mac') return fill(macWindow(show, options), screen.terminal('mac'));
  // Beside the tray an iPad's terminal is as narrow as a phone's.
  if (kind === 'ipad') return fill(padDevice(show, options), screen.terminal(screen.tray ? 'phone' : 'pad'));
  const phone = fill(phoneDevice(show, options), screen.terminal('phone'));
  // The list is the first of its two screens; the terminal is "pushed".
  const pushed = screen.phone === 'list' ? phone : phone.replace('class="phone-stack"', 'class="phone-stack pushed"');
  return screen.phone === 'keyboard' ? pushed : pushed.replace('class="phone"', 'class="phone no-kbd"');
}

/**
 * The Mac, the iPad and the iPhone on one session, under what syncs between
 * them. Each is drawn narrow, so each shows the terminal as a phone does.
 */
function family(screen, kind) {
  const narrow = { ...screen, terminal: () => screen.terminal('phone') };
  const { width, height, chip, ...places } = families[kind];
  // Each in a layer of its own, the smaller in front.
  const place = ([left, top, wide], layer) => `left:${left}px;top:${top}px;width:${wide}px;z-index:${layer}`;
  // From under the chip to the top of each device, which hides the end.
  const line = ([left, top, wide]) => {
    const x = left + wide / 2;
    return `<path d="M${chip} 40 C ${chip} ${40 + (top - 40) * 0.6}, ${x} ${top * 0.4}, ${x} ${top + 8}"/>`;
  };
  return `<div class="family" style="width:${width}px;height:${height}px">
    <div class="glow"></div>
    <svg class="sync-lines" viewBox="0 0 ${width} ${height}">${Object.values(places).map(line).join('')}</svg>
    <p class="sync-chip" style="left:${chip}px"><i class="dot green"></i><b>iCloud</b><span>${screen.family}</span></p>
    <div class="stage" style="${place(places.mac, 1)}">${device('mac', narrow)}</div>
    <div class="stage" style="${place(places.pad, 2)}">${device('ipad', narrow)}</div>
    <div class="stage" style="${place(places.phone, 3)}">${device('iphone', narrow)}</div>
  </div>`;
}

/**
 * Where the three stand on each canvas: [left, top, width] in a box of
 * `width` × `height`, the chip centered at `chip`. The iPad and the iPhone
 * keep their real sizes relative to each other (281.6 mm and 78 mm wide),
 * as Apple asks of pictures of its products together.
 */
const families = {
  mac: { width: 1240, height: 660, chip: 620, mac: [0, 60, 760], pad: [540, 250, 540], phone: [1090, 338, 150] },
  ipad: { width: 1220, height: 780, chip: 610, mac: [0, 60, 800], pad: [420, 320, 610], phone: [1051, 420, 169] },
  iphone: { width: 600, height: 1015, chip: 300, mac: [0, 60, 600], pad: [0, 420, 600], phone: [425, 660, 167] },
};

/** Every screenshot: its file name, its canvas and its page's body. */
export const shots = Object.entries(canvases).flatMap(([kind, canvas]) =>
  screens.map((screen, index) => ({
    name: `${kind}-${index + 1}-${screen.name}`,
    ...canvas,
    body: `<main class="shot shot-${kind}${screen.family ? ' shot-family' : ''}">
  <header class="copy"><h1>${screen.title}</h1><p>${screen.text}</p></header>
  ${screen.family ? family(screen, kind) : `<div class="stage"><div class="glow"></div>${device(kind, screen)}</div>`}
</main>`,
  })),
);
