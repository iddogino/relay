// A pretend terminal: lines of colored text that scripts print and type
// into, shown in any number of elements at once (the same session on a
// Mac, an iPad and an iPhone is one Term with three views).

export const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

export const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const span = (cls) => (text) => `<span class="${cls}">${text}</span>`;
/** Ghostty's default palette, by the first letter of the color. */
export const k = span('k');
export const r = span('r');
export const g = span('g');
export const y = span('y');
export const b = span('b');
export const m = span('m');
export const c = span('c');
export const w = span('w');
export const o = span('o');
export const bold = span('B');
export const dim = span('D');

export const pad = (n, width = 2, fill = '0') => String(n).padStart(width, fill);
export const clockTime = (date = new Date()) => `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
export const pick = (list) => list[Math.floor(Math.random() * list.length)];
export const between = (min, max) => min + Math.random() * (max - min);

/**
 * A demo's clock. Its sleeps only run out while the demo is on screen and
 * the tab is showing, so nothing animates unseen. With reduced motion,
 * sleeps return at once and `settle()` never does: a script runs to its
 * first settled frame and stays there.
 */
export class Clock {
  #visible = false;
  #waiting = [];

  constructor(element) {
    new IntersectionObserver(
      (entries) => {
        this.#visible = entries.some((e) => e.isIntersecting);
        this.#wake();
      },
      { rootMargin: '120px' },
    ).observe(element);
    document.addEventListener('visibilitychange', () => this.#wake());
  }

  get running() {
    return this.#visible && !document.hidden;
  }

  #wake() {
    if (this.running) this.#waiting.splice(0).forEach((resume) => resume());
  }

  async sleep(ms) {
    if (reduced) return;
    await new Promise((resolve) => setTimeout(resolve, ms));
    while (!this.running) await new Promise((resolve) => this.#waiting.push(resolve));
  }

  /** A point where the picture is worth keeping still. */
  settle() {
    return reduced ? new Promise(() => {}) : Promise.resolve();
  }
}

export class Term {
  /** Finished lines (HTML), oldest first. */
  lines = [];
  /** The line being written: a prompt, something half typed. */
  current = '';
  cursor = true;
  /** How many lines were ever printed (the demos count what you missed). */
  printed = 0;
  #views = new Set();
  #scheduled = false;

  constructor({ scrollback = 300, shown = 70 } = {}) {
    this.scrollback = scrollback;
    this.shown = shown;
  }

  attach(element) {
    this.#views.add(element);
    this.#paint(element);
  }

  detach(element) {
    this.#views.delete(element);
  }

  print(html = '') {
    this.lines.push(html);
    this.printed++;
    if (this.lines.length > this.scrollback) this.lines.splice(0, this.lines.length - this.scrollback);
    this.#touch();
  }

  /** Replaces the line being written. */
  set(html) {
    this.current = html;
    this.#touch();
  }

  /** Ends the line being written (Return). */
  enter() {
    this.print(this.current);
    this.current = '';
  }

  clear() {
    this.lines = [];
    this.current = '';
    this.#touch();
  }

  /** Types text after `prefix`, a key at a time. `onKey` hears each one. */
  async type(clock, text, { prefix = '', cps = 17, onKey } = {}) {
    for (let i = 1; i <= text.length; i++) {
      this.set(prefix + esc(text.slice(0, i)));
      onKey?.(text[i - 1]);
      await clock.sleep((1000 / cps) * between(0.55, 1.5));
    }
  }

  #touch() {
    if (this.#scheduled) return;
    this.#scheduled = true;
    requestAnimationFrame(() => {
      this.#scheduled = false;
      for (const view of this.#views) this.#paint(view);
    });
  }

  #paint(element) {
    const lines = this.lines.slice(-this.shown).map((line) => `<span class="l">${line || ' '}</span>`);
    const caret = this.cursor ? '<i class="cur"></i>' : '';
    if (this.current || this.cursor) lines.push(`<span class="l">${this.current}${caret}</span>`);
    element.innerHTML = lines.join('');
    element.scrollTop = element.scrollHeight;
  }
}
