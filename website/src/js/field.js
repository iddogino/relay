// The page's background: a terminal's grid of cells, fixed behind the
// content. The pointer leaves a wake of characters in it (rings around
// where it is, fading where it was), a click sends a ripple out, and now
// and then a signal runs along the grid's lines, turning at a crossing —
// something being relayed from one place to another.
//
// Two canvases: the resting grid is drawn once per resize; only the cells
// with any energy are drawn each frame, on the other — and only those cells
// are cleared again, so a frame touches a few hundred small squares rather
// than the whole window. With the pointer at rest it runs at half rate.

import { reduced } from './term.js';

const GLYPHS = ['-', '\\', '|', '/', '+'];
const MAJOR = 6; // every sixth line is one signals travel along
const WHITE = '#d5d9e0';
const GREEN = '#30d158';

export function startField(container) {
  const base = document.createElement('canvas');
  const live = document.createElement('canvas');
  container.append(base, live);
  const baseContext = base.getContext('2d');
  const context = live.getContext('2d');

  let cell = 26;
  let columns = 0;
  let rows = 0;
  let width = 0;
  let height = 0;
  let ratio = 1;
  let energy = new Float32Array(0);
  let glyph = new Uint8Array(0);
  let green = new Uint8Array(0);

  const pointer = { x: -1e4, y: -1e4, lastX: 0, lastY: 0, speed: 0, seen: 0 };
  const ripples = [];
  const signals = [];
  let nextSignal = 0;
  let last = 0;
  let running = false;
  let drawn = []; // the cells the last frame drew
  let skipped = false;

  function resize() {
    width = window.innerWidth;
    height = window.innerHeight;
    ratio = Math.min(window.devicePixelRatio || 1, 2);
    cell = width < 700 ? 22 : 26;
    columns = Math.ceil(width / cell) + 1;
    rows = Math.ceil(height / cell) + 1;
    energy = new Float32Array(columns * rows);
    glyph = new Uint8Array(columns * rows);
    green = new Uint8Array(columns * rows);
    signals.length = 0;
    drawn = [];
    for (const canvas of [base, live]) {
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
    }
    baseContext.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    drawBase();
  }

  /** The resting grid: a dot per cell, a small cross where major lines meet. */
  function drawBase() {
    baseContext.clearRect(0, 0, width, height);
    for (let row = 0; row < rows; row++) {
      for (let column = 0; column < columns; column++) {
        const x = column * cell;
        const y = row * cell;
        if (column % MAJOR === 0 && row % MAJOR === 0) {
          baseContext.fillStyle = 'rgba(255,255,255,0.2)';
          baseContext.fillRect(x - 3, y - 0.5, 7, 1);
          baseContext.fillRect(x - 0.5, y - 3, 1, 7);
        } else {
          baseContext.fillStyle = 'rgba(255,255,255,0.11)';
          baseContext.fillRect(x - 0.6, y - 0.6, 1.2, 1.2);
        }
      }
    }
  }

  /** Which line follows a circle around (cx, cy) at this cell. */
  function tangent(dx, dy) {
    // Perpendicular to the radius, folded into the four line glyphs.
    const angle = Math.atan2(dy, dx) + Math.PI / 2;
    return ((Math.round(angle / (Math.PI / 4)) % 4) + 4) % 4;
  }

  /** Lifts cells around a point, up to `strength`, falling off by `radius`. */
  function stir(cx, cy, radius, strength) {
    const c0 = Math.max(0, Math.floor((cx - radius) / cell));
    const c1 = Math.min(columns - 1, Math.ceil((cx + radius) / cell));
    const r0 = Math.max(0, Math.floor((cy - radius) / cell));
    const r1 = Math.min(rows - 1, Math.ceil((cy + radius) / cell));
    for (let row = r0; row <= r1; row++) {
      for (let column = c0; column <= c1; column++) {
        const dx = column * cell - cx;
        const dy = row * cell - cy;
        const distance = Math.hypot(dx, dy);
        if (distance > radius) continue;
        const fall = 1 - distance / radius;
        const value = fall * fall * strength;
        const index = row * columns + column;
        if (value > energy[index]) {
          energy[index] = value;
          glyph[index] = distance < cell * 0.8 ? 4 : tangent(dx, dy);
          green[index] = fall > 0.62 ? 1 : 0;
        }
      }
    }
  }

  function ring(ripple, now) {
    const age = (now - ripple.start) / 1000;
    const radius = age * 460;
    const band = 46;
    const fade = 1 - age / ripple.life;
    if (fade <= 0) return false;
    const c0 = Math.max(0, Math.floor((ripple.x - radius - band) / cell));
    const c1 = Math.min(columns - 1, Math.ceil((ripple.x + radius + band) / cell));
    const r0 = Math.max(0, Math.floor((ripple.y - radius - band) / cell));
    const r1 = Math.min(rows - 1, Math.ceil((ripple.y + radius + band) / cell));
    for (let row = r0; row <= r1; row++) {
      for (let column = c0; column <= c1; column++) {
        const dx = column * cell - ripple.x;
        const dy = row * cell - ripple.y;
        const off = Math.abs(Math.hypot(dx, dy) - radius);
        if (off > band) continue;
        const value = (1 - off / band) * fade;
        const index = row * columns + column;
        if (value > energy[index]) {
          energy[index] = value;
          glyph[index] = tangent(dx, dy);
          green[index] = value > 0.55 ? 1 : 0;
        }
      }
    }
    return true;
  }

  function spawnSignal() {
    const horizontal = Math.random() < 0.6;
    const forward = Math.random() < 0.5;
    const majorRows = Math.floor(rows / MAJOR);
    const majorColumns = Math.floor(columns / MAJOR);
    signals.push(
      horizontal
        ? { column: forward ? 0 : columns - 1, row: Math.floor(Math.random() * (majorRows + 1)) * MAJOR, dx: forward ? 1 : -1, dy: 0, wait: 0 }
        : { column: Math.floor(Math.random() * (majorColumns + 1)) * MAJOR, row: forward ? 0 : rows - 1, dx: 0, dy: forward ? 1 : -1, wait: 0 },
    );
  }

  function stepSignals(elapsed) {
    for (let i = signals.length - 1; i >= 0; i--) {
      const signal = signals[i];
      signal.wait -= elapsed;
      while (signal.wait <= 0) {
        signal.wait += 38;
        signal.column += signal.dx;
        signal.row += signal.dy;
        if (signal.column < 0 || signal.column >= columns || signal.row < 0 || signal.row >= rows) {
          signals.splice(i, 1);
          break;
        }
        const index = signal.row * columns + signal.column;
        energy[index] = 1;
        green[index] = 1;
        const crossing = signal.column % MAJOR === 0 && signal.row % MAJOR === 0;
        glyph[index] = crossing ? 4 : signal.dx ? 0 : 2;
        // At a crossing, sometimes take the other line.
        if (crossing && Math.random() < 0.3) {
          const turn = Math.random() < 0.5 ? 1 : -1;
          [signal.dx, signal.dy] = signal.dx ? [0, turn] : [turn, 0];
        }
      }
    }
  }

  function frame(now) {
    if (!running) return;
    // Only signals moving: every other frame is plenty.
    const resting = now - pointer.seen >= 1400 && ripples.length === 0;
    if (resting && (skipped = !skipped)) {
      requestAnimationFrame(frame);
      return;
    }
    const elapsed = Math.min(now - last || 16, 64);
    last = now;

    // Everything fades; what's stirred below is lifted again.
    const decay = Math.pow(0.9, elapsed / 16.7);
    for (let i = 0; i < energy.length; i++) energy[i] *= decay;

    if (now - pointer.seen < 1400) {
      pointer.speed *= Math.pow(0.86, elapsed / 16.7);
      stir(pointer.x, pointer.y, 150 + pointer.speed * 90, 0.5 + pointer.speed * 0.5);
    }
    for (let i = ripples.length - 1; i >= 0; i--) {
      if (!ring(ripples[i], now)) ripples.splice(i, 1);
    }
    if (now > nextSignal && signals.length < 5) {
      spawnSignal();
      nextSignal = now + 500 + Math.random() * 1500;
    }
    stepSignals(elapsed);

    for (const index of drawn) {
      const column = index % columns;
      context.clearRect(column * cell - cell / 2, ((index - column) / columns) * cell - cell / 2, cell, cell);
    }
    drawn.length = 0;
    context.font = `500 ${cell * 0.52}px "JetBrains Mono", ui-monospace, Menlo, monospace`;
    context.textAlign = 'center';
    context.textBaseline = 'middle';
    for (let pass = 0; pass < 2; pass++) {
      context.fillStyle = pass ? GREEN : WHITE;
      for (let row = 0; row < rows; row++) {
        for (let column = 0; column < columns; column++) {
          const index = row * columns + column;
          const value = energy[index];
          if (value < 0.035 || green[index] !== pass) continue;
          drawn.push(index);
          context.globalAlpha = Math.min(1, value) * (pass ? 0.95 : 0.6);
          context.fillText(GLYPHS[glyph[index]], column * cell, row * cell + 0.5);
        }
      }
    }
    context.globalAlpha = 1;
    requestAnimationFrame(frame);
  }

  function setRunning(value) {
    if (value === running) return;
    running = value;
    if (running) {
      last = 0;
      requestAnimationFrame(frame);
    }
  }

  resize();
  let resizing = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizing);
    resizing = setTimeout(resize, 120);
  });
  if (reduced) return;

  window.addEventListener(
    'pointermove',
    (event) => {
      if (event.pointerType === 'touch') return;
      const now = performance.now();
      const distance = Math.hypot(event.clientX - pointer.lastX, event.clientY - pointer.lastY);
      pointer.speed = Math.min(1, pointer.speed + distance / 160);
      pointer.x = pointer.lastX = event.clientX;
      pointer.y = pointer.lastY = event.clientY;
      pointer.seen = now;
    },
    { passive: true },
  );
  window.addEventListener(
    'pointerdown',
    (event) => {
      ripples.push({ x: event.clientX, y: event.clientY, start: performance.now(), life: 1.5 });
    },
    { passive: true },
  );
  document.addEventListener('visibilitychange', () => setRunning(!document.hidden));
  setRunning(!document.hidden);
}
