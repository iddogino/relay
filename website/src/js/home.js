// The landing page: the hero window you can use, and the demos below it.

import { hero } from './data.js';
import { agents, checks, family, fleet, links, load, persist, upload } from './demos.js';
import { runHero } from './scripts.js';
import { Clock, reduced } from './term.js';
import { startPage, toast } from './ui.js';
import { DeviceView, World } from './world.js';

startPage();

// ── The hero window ───────────────────────────────────────────────────

const stage = document.getElementById('hero-stage');
const world = new World(hero);
const clock = new Clock(stage);
new DeviceView(stage.querySelector('.mac'), world, { interactive: true });
const typeInShell = runHero(world, clock);

const order = [...world.sessions.keys()];

// Screens too narrow for the sidebar get the sessions as chips instead.
const chips = document.getElementById('hero-chips');
chips.innerHTML = order.map((id) => `<button type="button" class="chip" data-chip="${id}"><i></i>${world.get(id).name}</button>`).join('');
chips.addEventListener('click', (event) => {
  const chip = event.target.closest('[data-chip]');
  if (!chip) return;
  yours = true;
  world.select(chip.dataset.chip);
});
world.views.add({
  sync() {
    for (const chip of chips.children) {
      const session = world.get(chip.dataset.chip);
      chip.setAttribute('aria-pressed', String(session.id === world.selected));
      chip.classList.toggle('needs', session.agent === 'blocked');
      chip.firstElementChild.className = { attached: 'green', connecting: 'yellow', idle: '' }[session.phase];
    }
  },
});
world.changed();

let yours = false; // once you've touched it, it stops showing itself around
let typing = false; // the window has the page's keyboard

stage.addEventListener('relay:select', () => (yours = true));
document.addEventListener('pointerdown', (event) => {
  typing = stage.contains(event.target);
  if (typing) yours = true;
});

document.addEventListener('keydown', (event) => {
  if (!clock.running || event.target.closest?.('input, textarea, select, [contenteditable]')) return;
  // The plain shell takes what you type, once you've clicked the window.
  if (typing && world.selected === 'scratch' && typeInShell(event)) {
    event.preventDefault();
    return;
  }
  // ⌘1–⌘9 in the app; the browser keeps those, so plain digits here.
  if (!event.metaKey && !event.ctrlKey && !event.altKey && /^[1-5]$/.test(event.key)) {
    yours = true;
    world.select(order[Number(event.key) - 1]);
  }
});

// A link in a terminal: say what ⌘-clicking it does in the app.
stage.addEventListener('click', (event) => {
  const link = event.target.closest('[data-href]');
  if (!link) return;
  const host = world.current.project.host;
  const url = link.dataset.href;
  const rewritten = url.replace('//localhost', `//${host}`);
  toast(
    rewritten !== url
      ? `In Relay, <kbd>⌘</kbd>-click opens <code>${rewritten}</code> — localhost, pointed at ${host}.`
      : `In Relay, <kbd>⌘</kbd>-click opens <code>${url}</code> in your browser.`,
    4600,
  );
});

// Until you take over, look in on the other sessions now and then.
(async () => {
  const tour = ['dev', 'sweep', 'flaky', 'auth'];
  for (let stop = 0; !reduced; stop++) {
    await clock.sleep(stop ? 8500 : 11000);
    if (yours) return;
    world.select(tour[stop % tour.length]);
  }
})();

// The window leans back until it's scrolled into the middle of the view.
if (!reduced) {
  let queued = false;
  const lean = () => {
    queued = false;
    const top = stage.getBoundingClientRect().top;
    const progress = Math.min(1, Math.max(0, (top - innerHeight * 0.22) / (innerHeight * 0.6)));
    stage.style.setProperty('--tilt', (progress * 10).toFixed(2));
  };
  window.addEventListener(
    'scroll',
    () => {
      if (!queued) requestAnimationFrame(lean);
      queued = true;
    },
    { passive: true },
  );
  window.addEventListener('resize', lean);
  lean();
}

// ── The sections' demos ───────────────────────────────────────────────

const start = (id, demo) => {
  const element = document.getElementById(id);
  if (!element) return;
  try {
    demo(element);
  } catch (error) {
    console.error(`demo ${id}:`, error);
  }
};

start('fleet', fleet);
start('persist', persist);
start('family', family);
start('demo-upload', upload);
start('demo-links', links);
start('demo-agents', agents);
start('demo-load', load);
start('gh-demo', checks);
