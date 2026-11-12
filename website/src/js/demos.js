// The landing page's demos, one function each: the fleet's load graphs,
// the connection you can break, the three devices sharing a session, the
// bento's four small scenes, and the pull request's checks.

import { arriving, synced } from './data.js';
import { icons } from './icons.js';
import { agentGlyph } from './mocks.js';
import { Clock, Term, b, between, bold, c, clockTime, esc, g, k, m, o, pad, reduced } from './term.js';
import { DeviceView, World } from './world.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

// ── Graphs ────────────────────────────────────────────────────────────

/** Draws values (0–1) into an svg with .area and .stroke paths. */
function sparkline(svg, values) {
  const [, , width, height] = svg.getAttribute('viewBox').split(' ').map(Number);
  const step = width / (values.length - 1);
  const points = values.map((v, i) => `${(i * step).toFixed(1)} ${(height - 2 - clamp(v, 0, 1) * (height - 5)).toFixed(1)}`);
  svg.querySelector('.stroke').setAttribute('d', `M${points.join('L')}`);
  svg.querySelector('.area').setAttribute('d', `M0 ${height}L${points.join('L')}L${width} ${height}Z`);
}

/** A wandering series around `center`. */
function series(center, spread, length = 44) {
  const values = [];
  let value = center;
  const next = () => {
    value = clamp(value + between(-spread, spread) + (center - value) * 0.12, 0.03, 0.99);
    return value;
  };
  for (let i = 0; i < length; i++) values.push(next());
  return { values, next: () => (values.shift(), values.push(next()), value) };
}

const level = (fraction) => (fraction >= 0.9 ? 'red' : fraction >= 0.7 ? 'orange' : 'green');

export function fleet(root) {
  const clock = new Clock(root);
  const loads = { 'mac-mini': [0.34, 0.07], 'gpu-box': [0.81, 0.05], macbook: [0.12, 0.04] };
  const cards = [...root.querySelectorAll('.host-card')].map((card) => {
    const [center, spread] = loads[card.dataset.host];
    const data = series(center, spread);
    const svg = card.querySelector('.spark');
    sparkline(svg, data.values);
    return { data, svg, donut: card.querySelector('.donut') };
  });
  (async () => {
    await clock.settle();
    for (;;) {
      await clock.sleep(1100);
      for (const card of cards) {
        const value = card.data.next();
        sparkline(card.svg, card.data.values);
        card.donut.style.setProperty('--f', value.toFixed(2));
        card.donut.className = `donut ${level(value)}`;
      }
    }
  })();
}

// ── 02: break the connection ──────────────────────────────────────────

export function persist(root) {
  const clock = new Clock(root);
  const term = new Term({ scrollback: 400 });
  const local = root.querySelector('[data-body]');
  const over = root.querySelector('[data-over]');
  const dot = root.querySelector('[data-hdot]');
  const title = root.querySelector('[data-htitle]');
  const state = root.querySelector('[data-local-state]');
  const missed = root.querySelector('[data-missed]');
  const veil = {
    icon: root.querySelector('[data-veil-icon]'),
    title: root.querySelector('[data-veil-title]'),
    note: root.querySelector('[data-veil-note]'),
  };
  const buttons = [...root.querySelectorAll('[data-cut]')];
  const command = './scripts/migrate.sh --all';

  term.cursor = false;
  term.attach(root.querySelector('[data-remote-body]'));
  term.attach(local);

  // The job on the host. It never learns what happens to the window.
  (async () => {
    let shard = 16;
    term.print(`${g('❯')} ${command}`);
    term.print(k('240 shards · 3 workers · resumable'));
    for (let i = 12; i <= shard; i++) line(i);
    await clock.settle();
    for (;;) {
      await clock.sleep(between(380, 820));
      shard++;
      if (shard > 240) {
        term.print(`${g('✓')} ${bold('all 240 shards migrated')}`);
        await clock.sleep(4000);
        term.clear();
        term.print(`${g('❯')} ${command}`);
        shard = 1;
      }
      line(shard);
    }
    function line(n) {
      const rows = Math.round(between(8000, 16000)).toLocaleString('en-US');
      term.print(`${k(`[${clockTime()}]`)} shard ${pad(n, 3)}/240  ${g('✓')} ${rows.padStart(6)} rows  ${k(`${between(0.6, 1.9).toFixed(1)}s`)}`);
    }
  })();

  // The session's uptime, ticking.
  const uptime = root.querySelector('[data-uptime]');
  let seconds = 3 * 86400 + 4 * 3600 + 12 * 60 + 9;
  if (!reduced) {
    setInterval(() => {
      if (!clock.running) return;
      seconds++;
      const days = Math.floor(seconds / 86400);
      uptime.textContent = `up ${days}d ${pad(Math.floor((seconds % 86400) / 3600))}:${pad(Math.floor((seconds % 3600) / 60))}:${pad(seconds % 60)}`;
    }, 1000);
  }

  const cuts = {
    lid: { state: 'asleep', icon: icons.moon, title: 'Lid closed', note: 'Your Mac is asleep. mac-mini isn’t.' },
    wifi: { state: 'offline' },
    quit: { state: 'not running', icon: icons.power, title: 'Relay isn’t running', note: 'The session can’t tell the difference.' },
  };
  let cut = null;
  let leftAt = 0;
  let restoreTimer = null;

  function setCut(kind) {
    clearTimeout(restoreTimer);
    if (cut) restore({ quiet: true });
    cut = kind;
    leftAt = term.printed;
    root.dataset.cut = kind;
    // The window keeps what it last drew; the host keeps going.
    term.detach(local);
    const info = cuts[kind];
    state.textContent = info.state;
    missed.textContent = '';
    for (const button of buttons) button.setAttribute('aria-pressed', String(button.dataset.cut === kind));
    if (kind === 'wifi') {
      dot.className = 'dot yellow';
      title.textContent = 'Reconnecting…';
      over.innerHTML = `<div class="over-card"><i class="spin"></i><span class="t2">Reconnecting to mac-mini…</span><small>Attempt 2</small><span class="push">Retry Now</span></div>`;
      over.classList.add('show');
    } else {
      veil.icon.innerHTML = info.icon;
      veil.title.textContent = info.title;
      veil.note.textContent = info.note;
    }
    restoreTimer = setTimeout(() => restore(), 7000);
  }

  function restore({ quiet = false } = {}) {
    clearTimeout(restoreTimer);
    if (!cut) return;
    cut = null;
    delete root.dataset.cut;
    over.classList.remove('show');
    dot.className = 'dot green';
    title.textContent = command;
    state.textContent = 'connected';
    for (const button of buttons) button.setAttribute('aria-pressed', 'false');
    // Reattached: everything that ran meanwhile is there, in scrollback.
    term.attach(local);
    if (!quiet) {
      const lines = term.printed - leftAt;
      missed.textContent = lines > 0 ? `Reattached — ${lines} line${lines === 1 ? '' : 's'} ran while you were away, all in scrollback.` : 'Reattached.';
    }
  }

  for (const button of buttons) {
    button.addEventListener('click', () => (cut === button.dataset.cut ? restore() : setCut(button.dataset.cut)));
  }
}

// ── 03: one session, three devices ────────────────────────────────────

export function family(root) {
  const clock = new Clock(root);
  const world = new World(synced);
  const views = {
    mac: new DeviceView(root.querySelector('.mac'), world),
    pad: new DeviceView(root.querySelector('.pad'), world),
    phone: new DeviceView(root.querySelector('.phone'), world),
  };
  const stages = Object.fromEntries([...root.querySelectorAll('[data-on]')].map((s) => [s.dataset.on, s]));
  const cloud = root.querySelector('[data-cloud]');
  const lines = Object.fromEntries([...root.querySelectorAll('[data-line]')].map((p) => [p.dataset.line, p]));
  const caption = root.querySelector('[data-caption]');
  const stack = root.querySelector('[data-stack]');
  const keyboard = root.querySelector('.kbd');
  const term = world.term('deploy');
  const prompt = `${c('api')} ${m('main')} ${g('❯')} `;

  const say = (text) => (caption.textContent = text);
  const use = (device) => {
    for (const [name, stage] of Object.entries(stages)) stage.classList.toggle('active', name === device);
  };
  /** The key a finger lands on, on the iPhone's keyboard. */
  const tap = (key) => {
    const element = keyboard.querySelector(`[data-key="${key === '\n' ? '⏎' : key.toLowerCase()}"]`);
    if (!element) return;
    element.classList.add('down');
    setTimeout(() => element.classList.remove('down'), 130);
  };
  const run = async (command, output, { onKey, cps = 15 } = {}) => {
    await term.type(clock, command, { prefix: prompt, cps, onKey });
    await clock.sleep(320);
    onKey?.('\n');
    term.enter();
    for (const line of output) {
      await clock.sleep(between(90, 340));
      term.print(line);
    }
    term.set(prompt);
  };

  /** A dot running along one of the cloud's lines. */
  const pulse = (name, { up = false } = {}) =>
    new Promise((resolve) => {
      const path = lines[name];
      const svg = path.ownerSVGElement;
      if (reduced || !svg.clientWidth) return resolve();
      const [, , boxWidth, boxHeight] = svg.getAttribute('viewBox').split(' ').map(Number);
      const length = path.getTotalLength();
      const dotElement = document.createElementNS('http://www.w3.org/2000/svg', 'ellipse');
      // The svg is stretched to its box; keep the dot round.
      dotElement.setAttribute('rx', (4.5 * boxWidth) / svg.clientWidth);
      dotElement.setAttribute('ry', (4.5 * boxHeight) / svg.clientHeight);
      dotElement.setAttribute('class', 'cloud-dot');
      svg.append(dotElement);
      const started = performance.now();
      const step = (now) => {
        const progress = clamp((now - started) / 750, 0, 1);
        const eased = progress < 0.5 ? 2 * progress * progress : 1 - (-2 * progress + 2) ** 2 / 2;
        const point = path.getPointAtLength(length * (up ? 1 - eased : eased));
        dotElement.setAttribute('cx', point.x);
        dotElement.setAttribute('cy', point.y);
        if (progress < 1) return requestAnimationFrame(step);
        dotElement.remove();
        resolve();
      };
      requestAnimationFrame(step);
    });

  (async () => {
    for (;;) {
      // On the Mac.
      world.removeProject(arriving.id);
      Object.values(views).forEach((view) => view.hideProject(arriving.id));
      stack.classList.remove('pushed');
      term.clear();
      term.set(prompt);
      use('mac');
      say('Start on your Mac');
      await clock.sleep(1100);
      await run('git pull --rebase', [
        'Updating 3f9a2c1..b81d07e',
        'Fast-forward',
        ` src/auth/refresh.ts     | 32 ${g('+++++')}${'<span class="r">---</span>'}`,
        ` src/auth/session-store | 65 ${g('+++++++')}${'<span class="r">--</span>'}`,
        ' 3 files changed, 86 insertions(+), 31 deletions(-)',
      ]);
      await clock.settle();
      await clock.sleep(1500);

      // A project added on the Mac reaches the others through iCloud.
      say('Add a project on one device…');
      world.addProject(arriving);
      views.mac.showProject(arriving);
      await clock.sleep(500);
      cloud.classList.add('busy');
      await pulse('mac', { up: true });
      say('…and it’s on the others a moment later');
      await Promise.all([pulse('pad'), pulse('phone')]);
      views.pad.showProject(arriving);
      views.phone.showProject(arriving);
      world.changed();
      await clock.sleep(700);
      cloud.classList.remove('busy');
      await clock.sleep(1900);

      // On the iPad.
      use('pad');
      say('Pick the session up on your iPad');
      await clock.sleep(900);
      await run('npm test', [
        `${g('✓')} auth ${k('(42 tests)')} ${k('3.1s')}`,
        `${g('✓')} uploads ${k('(18 tests)')} ${k('1.4s')}`,
        `${g('✓')} projects ${k('(27 tests)')} ${k('2.2s')}`,
        '',
        `${bold('Tests')}  ${g('87 passed')} ${k('(87)')}`,
      ]);
      await clock.sleep(1700);

      // On the iPhone: the list, then the same terminal.
      use('phone');
      say('Or finish from your iPhone');
      await clock.sleep(900);
      stack.classList.add('pushed');
      await clock.sleep(1000);
      await run('git push', ['To github.com:acme/api.git', `   b81d07e..4c2e9aa  ${b('main')} -> ${b('main')}`], { onKey: tap, cps: 9 });
      say('One session, on every device');
      await clock.sleep(4200);
    }
  })();
}

// ── 04: the bento ─────────────────────────────────────────────────────

const bytes = (n) => (n >= 1e9 ? `${(n / 1e9).toFixed(2)} GB` : n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : n >= 1e3 ? `${Math.round(n / 1e3)} KB` : `${n} bytes`);
const scratchName = () => Array.from({ length: 8 }, () => 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'[Math.floor(Math.random() * 56)]).join('');

/** Drop a file, get a path — the page's own files too (they stay here). */
export function upload(card) {
  const clock = new Clock(card);
  const win = card.querySelector('[data-drop]');
  const over = win.querySelector('[data-over]');
  const flying = win.querySelector('[data-fly]');
  const term = new Term({ shown: 30 });
  term.attach(win.querySelector('[data-body]'));
  let turn = 0;
  let yoursUntil = 0;

  const reset = () => {
    term.clear();
    term.cursor = true;
    term.print(`${o('✻')} ${bold('Claude Code')}  ${k('~/code/api')}`);
    term.print('');
    term.print(`${k('>')} make the settings page match this mockup:`);
    term.set('  ');
  };
  const target = (shown) => {
    if (shown) {
      over.innerHTML = `<div class="drop-target"><div class="over-card">${icons.uploadDoc}<b>Drop to upload to mac-mini</b><small>Hold ⌥ to insert the local path instead</small></div></div>`;
    }
    over.classList.toggle('show', shown);
  };

  async function play(name, size, { fly }) {
    const mine = ++turn;
    const live = () => mine === turn;
    reset();
    if (fly) {
      const box = win.getBoundingClientRect();
      flying.querySelector('[data-fly-name]').textContent = name;
      await clock.sleep(900);
      if (!live()) return;
      const flight = flying.animate(
        [
          { transform: `translate(${box.width * 0.78}px, ${-box.height * 0.34}px) rotate(7deg)`, opacity: 0 },
          { opacity: 1, offset: 0.2 },
          { transform: `translate(${box.width * 0.36}px, ${box.height * 0.42}px) rotate(-3deg)`, opacity: 1 },
        ],
        { duration: 1300, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', fill: 'forwards' },
      );
      await clock.sleep(650);
      if (!live()) return flight.cancel();
      target(true);
      await clock.sleep(1150);
      flying.animate([{ opacity: 1 }, { opacity: 0, scale: 0.7 }], { duration: 220, fill: 'forwards' }).finished.then(() => {
        flight.cancel();
      });
      if (!live()) return;
    }

    // "120 MB of 300 MB · 19.7 MB/s · 9s left"
    const seconds = clamp(size / 3.4e6, 1.5, 2.8);
    const rate = size / seconds;
    over.innerHTML = `<div class="over-card"><div class="bar"><i></i></div><span class="t2">Uploading “${esc(name)}” to mac-mini…</span><small data-detail></small><span class="push">Cancel</span></div>`;
    over.classList.add('show');
    const bar = over.querySelector('.bar');
    const detail = over.querySelector('[data-detail]');
    const steps = Math.ceil(seconds / 0.15);
    for (let i = 0; i <= steps && !reduced; i++) {
      const done = i / steps;
      bar.style.setProperty('--p', done);
      const left = Math.max(1, Math.round(seconds * (1 - done)));
      detail.textContent = `${bytes(size * done)} of ${bytes(size)} · ${bytes(rate * between(0.9, 1.1))}/s · ${left}s left`;
      await clock.sleep(150);
      if (!live()) return;
    }
    over.classList.remove('show');
    await clock.sleep(250);
    if (!live()) return;
    const path = `/tmp/relay-drop.${scratchName()}/${name}`;
    await term.type(clock, `'${path.replace(/'/g, `'\\''`)}'`, { prefix: '  ', cps: 90 });
    await clock.settle();
  }

  // Real files: nothing is uploaded — only the name and size are read.
  let depth = 0;
  card.addEventListener('dragenter', (event) => {
    event.preventDefault();
    if (depth++ === 0) {
      turn++;
      yoursUntil = Date.now() + 15000;
      reset();
      target(true);
    }
  });
  card.addEventListener('dragover', (event) => event.preventDefault());
  card.addEventListener('dragleave', () => {
    if (--depth <= 0) {
      depth = 0;
      target(false);
    }
  });
  card.addEventListener('drop', (event) => {
    event.preventDefault();
    depth = 0;
    const file = event.dataTransfer?.files?.[0];
    yoursUntil = Date.now() + 12000;
    play(file?.name ?? 'dropped-item', file?.size || 2.4e6, { fly: false });
  });

  (async () => {
    for (;;) {
      if (Date.now() >= yoursUntil) await play('mockup.png', 4.8e6, { fly: !reduced });
      await clock.sleep(3200);
    }
  })();
}

/** ⌘-click: a localhost link in a browser, a path in Quick Look. */
export function links(card) {
  const clock = new Clock(card);
  const demo = card.querySelector('.card-demo');
  const pointer = card.querySelector('[data-pointer]');
  const browser = card.querySelector('[data-browser]');
  const quicklook = card.querySelector('[data-quicklook]');
  const host = card.querySelector('[data-url-host]');
  const url = card.querySelector('[data-link="url"]');
  const file = card.querySelector('[data-link="file"]');

  const reach = async (link) => {
    const outer = demo.getBoundingClientRect();
    const box = link.getBoundingClientRect();
    pointer.style.opacity = 1;
    pointer.style.transform = `translate(${box.left - outer.left + box.width * 0.55}px, ${box.top - outer.top + box.height * 0.45}px)`;
    await clock.sleep(950);
    link.classList.add('hover');
    await clock.sleep(380);
    pointer.classList.add('click');
    await clock.sleep(160);
    pointer.classList.remove('click');
  };

  (async () => {
    if (reduced) {
      host.textContent = 'mac-mini';
      host.classList.add('swapped');
      browser.classList.add('show');
      return;
    }
    for (;;) {
      await clock.sleep(700);
      await reach(url);
      host.textContent = 'localhost';
      host.classList.remove('swapped');
      browser.classList.add('show');
      await clock.sleep(950);
      host.textContent = 'mac-mini';
      host.classList.add('swapped');
      await clock.sleep(3000);
      browser.classList.remove('show');
      url.classList.remove('hover');

      await reach(file);
      quicklook.classList.add('show');
      await clock.sleep(3400);
      quicklook.classList.remove('show');
      file.classList.remove('hover');
    }
  })();
}

/** Agent status: rows changing state, and the notification that says so. */
export function agents(card) {
  const clock = new Clock(card);
  const rows = [...card.querySelectorAll('[data-agent-row]')];
  const label = card.querySelector('[data-agents-host]');
  const notice = card.querySelector('[data-notif]');
  const setRow = (index, state, unseen = false) => {
    rows[index].querySelector('.trail').innerHTML = agentGlyph(state, unseen);
    rows[index].classList.toggle('unseen', unseen);
  };
  const needs = (count) => {
    label.textContent = count ? `${count} needs you` : 'mac-mini';
    label.classList.toggle('needs', count > 0);
  };
  const notify = async (title, session, task, ms) => {
    notice.querySelector('[data-notif-title]').textContent = title;
    notice.querySelector('[data-notif-sub]').textContent = session;
    notice.querySelector('[data-notif-body]').textContent = task;
    notice.classList.add('show');
    await clock.settle();
    await clock.sleep(ms);
    notice.classList.remove('show');
  };

  (async () => {
    for (;;) {
      rows.forEach((_, i) => setRow(i, 'working'));
      needs(0);
      await clock.sleep(2400);
      setRow(1, 'blocked');
      needs(1);
      await notify('Claude Code needs you', 'api / fix-flaky-tests', 'Fix flaky upload test', 3800);
      await clock.sleep(500);
      setRow(1, 'working');
      needs(0);
      await clock.sleep(2000);
      setRow(2, 'done', true);
      await notify('Codex finished', 'api / write-docs', 'Document the session store', 3600);
      await clock.sleep(1000);
      setRow(2, 'done');
      await clock.sleep(2600);
    }
  })();
}

/** The load pill's popover: three graphs and the busiest processes. */
export function load(card) {
  const clock = new Clock(card);
  const metrics = {
    load: { data: series(0.81, 0.05), text: (v) => `${Math.round(v * 100)}% of capacity` },
    memory: { data: series(0.67, 0.012), text: (v) => `${Math.round(v * 100)}% · ${Math.round(v * 128)} GB of 128 GB` },
    gpu: { data: series(0.95, 0.03), text: (v) => `2× RTX 4090 · ${Math.round(v * 100)}%` },
  };
  for (const [name, metric] of Object.entries(metrics)) {
    metric.root = card.querySelector(`[data-metric="${name}"]`);
    metric.svg = metric.root.querySelector('svg');
    metric.value = metric.root.querySelector('[data-value]');
    sparkline(metric.svg, metric.data.values);
  }
  const processes = [...card.querySelectorAll('[data-proc]')];
  (async () => {
    await clock.settle();
    for (;;) {
      await clock.sleep(1000);
      for (const metric of Object.values(metrics)) {
        const value = metric.data.next();
        sparkline(metric.svg, metric.data.values);
        metric.value.textContent = metric.text(value);
      }
      processes[0].textContent = `${Math.round(between(1780, 1900))}%`;
      processes[1].textContent = `${Math.round(between(22, 46))}%`;
    }
  })();
}

// ── 05: a pull request's checks ───────────────────────────────────────

export function checks(root) {
  const clock = new Clock(root);
  const rows = [...root.querySelectorAll('.check')];
  const headline = root.querySelector('[data-headline]');
  const summary = root.querySelector('[data-summary]');
  const pill = root.querySelector('[data-pr-state]');
  const took = ['Successful in 41s', 'Successful in 1m 12s', 'Successful in 2m 3s', 'Successful in 3m 48s'];
  const time = (seconds) => `${Math.floor(seconds / 60)}:${pad(seconds % 60)}`;

  const draw = (finished, elapsed) => {
    rows.forEach((row, i) => {
      const done = i < finished;
      row.dataset.check = done ? 'ok' : 'run';
      row.querySelector('span').textContent = done ? took[i] : `In progress · ${time(elapsed + i * 7)}`;
    });
    const running = rows.length - finished;
    headline.textContent = running ? 'Some checks haven’t completed yet' : 'All checks have passed';
    headline.classList.toggle('good', !running);
    summary.textContent = running ? `${running} in progress and ${finished} successful checks` : `${finished} successful checks`;
    pill.className = `pr-state ${running ? 'pending' : 'ok'}`;
  };

  (async () => {
    for (;;) {
      let elapsed = 38;
      for (let finished = 1; finished < rows.length; finished++) {
        for (let tick = 0; tick < 3; tick++) {
          draw(finished, elapsed++);
          await clock.sleep(1000);
        }
      }
      draw(rows.length, elapsed);
      await clock.settle();
      await clock.sleep(6000);
    }
  })();
}
