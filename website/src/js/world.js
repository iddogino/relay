// A mockup's state — its sessions, which one is selected, which are
// connected — and the views that draw it into the markup mocks.js made.
// It behaves as the app does: the last few sessions you looked at stay
// connected (green), the rest are grey until you select them; every
// session's terminal keeps going either way.

import { hosts } from './data.js';
import { agentGlyph, donut, projectGroup } from './mocks.js';
import { Term } from './term.js';

const WARM = 4;

export class World {
  sessions = new Map();
  views = new Set();
  #queued = false;

  constructor(definition) {
    this.projects = structuredClone(definition.projects);
    this.selected = definition.selected;
    for (const project of this.projects) this.#adopt(project);
    // Most recently viewed last; the selected one is always the newest.
    this.recent = [...this.sessions.values()].filter((s) => s.phase === 'attached' && s.id !== this.selected).map((s) => s.id);
    this.recent.push(this.selected);
  }

  #adopt(project) {
    for (const session of project.sessions) {
      this.sessions.set(session.id, {
        ...session,
        project,
        phase: session.cold ? 'idle' : 'attached',
        unseen: false,
        pr: session.pr ?? null,
        git: session.git ?? [0, 0],
        term: new Term(),
      });
    }
  }

  get(id) {
    return this.sessions.get(id);
  }

  get current() {
    return this.sessions.get(this.selected);
  }

  term(id) {
    return this.sessions.get(id).term;
  }

  /** Changes a session's state; the views catch up on the next frame. */
  update(id, patch) {
    Object.assign(this.sessions.get(id), patch);
    this.changed();
  }

  changed() {
    if (this.#queued) return;
    this.#queued = true;
    queueMicrotask(() => {
      this.#queued = false;
      for (const view of this.views) view.sync();
    });
  }

  /** Selects a session: connects it if it wasn't, and marks it seen. */
  select(id) {
    const session = this.sessions.get(id);
    if (!session || id === this.selected) return;
    this.selected = id;
    session.unseen = false;
    this.recent = this.recent.filter((other) => other !== id);
    this.recent.push(id);
    if (session.phase === 'idle') {
      session.phase = 'connecting';
      setTimeout(() => {
        session.phase = 'attached';
        // The least recently viewed connection makes room.
        while (this.recent.length > WARM) this.sessions.get(this.recent.shift()).phase = 'idle';
        this.changed();
      }, 750);
    }
    this.changed();
  }

  /** A project arriving (over iCloud): in the model and in every list. */
  addProject(project) {
    if (this.projects.some((p) => p.id === project.id)) return;
    const copy = structuredClone(project);
    this.projects.push(copy);
    this.#adopt(copy);
  }

  removeProject(id) {
    const project = this.projects.find((p) => p.id === id);
    if (!project) return;
    this.projects = this.projects.filter((p) => p !== project);
    for (const session of project.sessions) this.sessions.delete(session.id);
  }
}

const set = (element, text) => {
  if (element && element.textContent !== text) element.textContent = text;
};
const setHTML = (element, html) => {
  if (element && element.dataset.html !== html) {
    element.dataset.html = html;
    element.innerHTML = html;
  }
};
const dotClass = { attached: 'green', connecting: 'yellow', idle: 'grey' };

/** Draws a World into one device's markup (Mac, iPad or iPhone). */
export class DeviceView {
  #attached = null;

  constructor(root, world, { interactive = false } = {}) {
    this.root = root;
    this.world = world;
    this.list = root.querySelector('[data-list]');
    this.body = root.querySelector('[data-body]');
    this.over = root.querySelector('[data-over]');
    world.views.add(this);
    if (interactive) {
      this.list?.addEventListener('click', (event) => {
        const row = event.target.closest('[data-session]');
        if (row) {
          world.select(row.dataset.session);
          root.dispatchEvent(new CustomEvent('relay:select', { bubbles: true }));
        }
      });
    } else {
      root.style.pointerEvents = 'none';
    }
    this.sync();
  }

  /** Adds a project's rows to this device's list, announcing itself. */
  showProject(project) {
    if (!this.list || this.list.querySelector(`[data-project="${project.id}"]`)) return;
    this.list.insertAdjacentHTML('beforeend', projectGroup(project, null));
    this.list.lastElementChild.classList.add('arriving');
  }

  hideProject(id) {
    this.list?.querySelector(`[data-project="${id}"]`)?.remove();
  }

  sync() {
    const { world, root } = this;
    const current = world.current;

    for (const row of root.querySelectorAll('[data-session]')) {
      const session = world.get(row.dataset.session);
      if (!session) continue;
      row.classList.toggle('selected', session.id === world.selected);
      row.classList.toggle('unseen', session.unseen);
      row.querySelector('[data-dot]').className = `dot ${dotClass[session.phase]}`;
      set(row.querySelector('[data-cap]'), session.caption ?? '');
      setHTML(row.querySelector('[data-trail]'), agentGlyph(session.agent, session.unseen));
    }
    for (const group of root.querySelectorAll('[data-project]')) {
      const project = world.projects.find((p) => p.id === group.dataset.project);
      const label = group.querySelector('[data-host]');
      if (!project || !label) continue;
      const needs = project.sessions.filter((s) => world.get(s.id)?.agent === 'blocked').length;
      label.classList.toggle('needs', needs > 0);
      set(label, needs ? `${needs} needs you` : project.host);
    }

    const project = current.project;
    const status = current.phase === 'connecting' ? 'Connecting…' : null;
    set(root.querySelector('[data-hproject]'), project.name);
    set(root.querySelector('[data-hsession]'), current.name);
    set(root.querySelector('[data-hhost]'), project.host);
    set(root.querySelector('[data-hsub]'), status ?? `${project.name} · ${project.host}`);
    const title = root.querySelector('[data-htitle]');
    if (title) {
      set(title, status ?? current.title ?? '');
      title.classList.toggle('t2', Boolean(status));
    }
    const dot = root.querySelector('[data-hdot]');
    if (dot) dot.className = `dot ${dotClass[current.phase] === 'grey' ? 'yellow' : dotClass[current.phase]}`;

    const load = hosts[project.host];
    setHTML(root.querySelector('[data-load]'), donut(load.load) + donut(load.memory));
    for (const element of root.querySelectorAll('[data-add]')) set(element, `+${current.git[0]}`);
    for (const element of root.querySelectorAll('[data-del]')) set(element, `−${current.git[1]}`);
    const pr = root.querySelector('[data-pr]');
    if (pr) {
      pr.hidden = !current.pr;
      if (current.pr) {
        set(pr.querySelector('[data-pr-number]'), `#${current.pr.number}`);
        pr.querySelector('[data-pr-state]').className = `pr-state ${current.pr.state}`;
      }
    }

    if (this.body && this.#attached !== current.term) {
      this.#attached?.detach(this.body);
      this.#attached = current.term;
      current.term.attach(this.body);
    }
    if (this.over) {
      const connecting = current.phase === 'connecting';
      if (connecting) {
        setHTML(this.over, `<div class="over-card"><i class="spin"></i><span class="t2">Connecting to ${project.host}…</span></div>`);
      }
      this.over.classList.toggle('show', connecting);
    }
  }
}
