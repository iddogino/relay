// The app, redrawn in HTML: the Mac window, the iPad and the iPhone, from
// the SwiftUI views in Sources/RelayUI (SidebarView, TerminalDetailView,
// AgentStatusViews, PRStatusViews, MachineLoadViews, TerminalKeyBar).
//
// Every size is in em, so a mockup scales with its font size like a
// picture would. The build renders the first frame into the page (so it's
// there before any script runs); the browser then drives the same markup
// through the data-* hooks.

import { icons as I } from './icons.js';
import { findSession, hosts } from './data.js';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ── Pieces shared by every device ─────────────────────────────────────

/** The trailing glyph of a session row (AgentStatusGlyph). */
export function agentGlyph(state, unseen = false) {
  switch (state) {
    case 'working':
      return '<i class="ring"></i>';
    case 'blocked':
      return '<i class="target"></i>';
    case 'done':
      return unseen ? `<i class="done unseen">${I.checkCircle}</i>` : `<i class="done">${I.check}</i>`;
    default:
      return unseen ? '<i class="unread"></i>' : '';
  }
}

const level = (fraction) => (fraction >= 0.9 ? 'red' : fraction >= 0.7 ? 'orange' : 'green');

/** One of the load pill's donuts. */
export const donut = (fraction) => `<i class="donut ${level(fraction)}" style="--f:${fraction}"></i>`;

export function sessionRow(session, selected) {
  return `<div class="row session${selected ? ' selected' : ''}" data-session="${session.id}">
      <span class="glyph"><i class="dot ${session.cold ? 'grey' : 'green'}" data-dot></i></span>
      <span class="text"><span class="name" data-name>${esc(session.name)}</span><span class="cap" data-cap>${esc(session.caption ?? '')}</span></span>
      <span class="trail" data-trail>${agentGlyph(session.agent)}</span>
    </div>`;
}

export function projectGroup(project, selected) {
  const needs = project.sessions.filter((s) => s.agent === 'blocked').length;
  return `<div class="group" data-project="${project.id}">
    <div class="row project">
      <span class="chev">${I.chevronDown}</span>
      <span class="glyph">${I.folder}</span>
      <span class="name">${esc(project.name)}</span>
      <span class="host${needs ? ' needs' : ''}" data-host="${esc(project.host)}">${needs ? `${needs} needs you` : esc(project.host)}</span>
      <i class="dot green"></i>
    </div>
    ${project.sessions.map((s) => sessionRow(s, s.id === selected)).join('\n    ')}
    <div class="row new"><span class="glyph">${I.plusCircle}</span><span class="name">New Session</span></div>
  </div>`;
}

const groups = (world) => world.projects.map((p) => projectGroup(p, world.selected)).join('\n');

const terminal = (extra = '') =>
  `<div class="term" data-term><div class="term-body" data-body></div><div class="term-over" data-over></div>${extra}</div>`;

function toolbarItems(project, session) {
  const host = hosts[project.host];
  return `<span class="tool load" data-load>${donut(host.load)}${donut(host.memory)}</span>
        <span class="tool pr" data-pr${session.pr ? '' : ' hidden'}>${I.pull}<span data-pr-number>#${session.pr?.number ?? ''}</span><i class="pr-state" data-pr-state></i></span>
        <span class="tool diff" data-diff><span class="add" data-add>+${session.git[0]}</span><span class="del" data-del>−${session.git[1]}</span></span>`;
}

/**
 * The diff tray (DiffTrayView): what a session changed, a file at a time.
 * `diff` is { session, files: [{ path, add, del, lines }] }; a line is
 * [old number, new number, '+' | '-' | ' ', its code as HTML].
 */
export function diffTray(diff) {
  const line = ([was, now, sign, code]) =>
    `<span class="dl${sign === '+' ? ' plus' : sign === '-' ? ' minus' : ''}"><i>${was ?? ''}</i><i>${now ?? ''}</i><i class="sign">${sign === ' ' ? '' : sign === '-' ? '−' : sign}</i><span class="code">${code}</span></span>`;
  return `<div class="tray" data-tray>
    <div class="tray-head"><b>Changes</b><span class="t2">${esc(diff.session)}</span><span class="tray-refresh">${I.refresh}</span></div>
    <div class="tray-body">
      ${diff.files
        .map(
          (file) => `<div class="tray-file"><span class="chev">${I.chevronDown}</span><span class="path">${esc(file.path)}</span><span class="tray-acts">${I.copy}${I.doc}<span class="diff"><span class="add">+${file.add}</span><span class="del">−${file.del}</span></span></span></div>
      <div class="tray-gap">⋯</div>
      <div class="tray-lines">${file.lines.map(line).join('')}</div>`,
        )
        .join('\n      ')}
    </div>
  </div>`;
}

// ── Mac ───────────────────────────────────────────────────────────────

/**
 * The Mac window. `solo` leaves the sidebar out (the window with its
 * sidebar hidden), for the demos that are about one session; `tray` opens
 * the diff tray beside the terminal.
 */
export function macWindow(world, { id = '', solo = false, tray = null } = {}) {
  const { project, session } = findSession(world, world.selected);
  const lights = '<i class="light r"></i><i class="light y"></i><i class="light g"></i>';
  return `<div class="mac${solo ? ' solo' : ''}" data-device="mac"${id ? ` id="${id}"` : ''}>
  ${
    solo
      ? ''
      : `<div class="mac-side">
    <div class="mac-chrome">${lights}<span class="side-toggle">${I.sidebar}</span></div>
    <div class="list" data-list>
      <div class="row head"><span>Projects</span><span class="acts">${I.ellipsis}${I.plus}</span></div>
      ${groups(world)}
    </div>
  </div>`
  }
  <div class="mac-main">
    <div class="mac-toolbar">
      ${solo ? `<span class="mac-chrome">${lights}<span class="side-toggle">${I.sidebar}</span></span>` : ''}
      <span class="mac-title">Relay</span>
      <span class="tools" data-tools>
        ${toolbarItems(project, session)}
      </span>
    </div>
    ${tray ? '<div class="mac-split"><div class="mac-pane">' : ''}
    <div class="hbar">
      <i class="dot green" data-hdot></i>
      <span class="crumbs"><span class="t2" data-hproject>${esc(project.name)}</span><span class="t3">/</span><b data-hsession>${esc(session.name)}</b><span class="t3">·</span><span class="t2" data-hhost>${esc(project.host)}</span></span>
      <span class="htitle" data-htitle>${esc(session.title ?? '')}</span>
    </div>
    ${terminal()}
    ${tray ? `</div>${diffTray(tray)}</div>` : ''}
  </div>
</div>`;
}

// ── iPhone and iPad ───────────────────────────────────────────────────

const keys = ['esc', 'tab', 'ctrl', '←', '↓', '↑', '→', 'alt', '~', '|', '/', '-', '`'];

/** TerminalKeyBar: the scrolling keys, then Paste and Hide Keyboard. */
const keyBar = () =>
  `<div class="keybar">
        <div class="keys">${keys.map((k) => `<span class="key${k.length > 1 ? ' word' : ''}" data-key="${k}">${k}</span>`).join('')}</div>
        <span class="sep"></span>
        <span class="key icon">${I.paste}</span><span class="key icon">${I.keyboardDown}</span>
      </div>`;

const keyboard = () => {
  const row = (letters) => [...letters].map((l) => `<i data-key="${l}">${l}</i>`).join('');
  return `<div class="kbd">
        <div>${row('qwertyuiop')}</div>
        <div class="inset">${row('asdfghjkl')}</div>
        <div><i class="mod">⇧</i>${row('zxcvbnm')}<i class="mod">⌫</i></div>
        <div><i class="mod wide">123</i><i class="space" data-key=" ">space</i><i class="mod wide go" data-key="⏎">return</i></div>
      </div>`;
};

/** The terminal screen's title: the session, then its project and host. */
const navTitle = (project, session) =>
  `<div class="ios-title"><b data-hsession>${esc(session.name)}</b><span><i class="dot green" data-hdot></i><span data-hsub>${esc(project.name)} · ${esc(project.host)}</span></span></div>`;

const statusBar = () =>
  `<div class="ios-status"><b>9:41</b><span class="ios-status-icons">
        <svg viewBox="0 0 18 12" aria-hidden="true"><rect x="0" y="8" width="3" height="4" rx=".8"/><rect x="5" y="5.5" width="3" height="6.5" rx=".8"/><rect x="10" y="3" width="3" height="9" rx=".8"/><rect x="15" y="0" width="3" height="12" rx=".8"/></svg>
        <svg viewBox="0 0 16 12" aria-hidden="true"><path d="M8 2.2c2.3 0 4.4.9 6 2.4l1-1.1A10 10 0 0 0 8 .6 10 10 0 0 0 1 3.5l1 1.1a8.500 8.500 0 0 1 6-2.400Zm0 3.300c1.400 0 2.700.5 3.700 1.400l1-1.100A7 7 0 0 0 8 3.900a7 7 0 0 0-4.700 1.900l1 1.100c1-.9 2.300-1.400 3.700-1.400Zm0 3.300c.6 0 1.200.2 1.600.6L8 11.400 6.400 9.400c.4-.4 1-.6 1.600-.6Z"/></svg>
        <svg viewBox="0 0 26 12" aria-hidden="true"><rect x=".5" y=".5" width="22" height="11" rx="3.2" fill="none" stroke="currentColor" opacity=".4"/><rect x="2" y="2" width="19" height="8" rx="1.9"/><path d="M24 4v4c.8-.3 1.400-1.100 1.400-2s-.6-1.700-1.400-2Z" opacity=".45"/></svg>
      </span></div>`;

/**
 * The list of projects: under a large title on an iPhone, under the
 * sidebar's own bar (`inline`) on an iPad.
 */
const iosList = (world, inline = false) =>
  `${
    inline
      ? `<div class="ios-bar"><span class="glass round">${I.gear}</span><b class="ios-inline">Relay</b><span class="glass round">${I.plus}</span><span class="glass round">${I.sidebar}</span></div>`
      : `<div class="ios-bar"><span class="glass round">${I.gear}</span><span class="glass round">${I.plus}</span></div>
      <div class="ios-large">Relay</div>`
  }
      <div class="list ios" data-list>
      ${groups(world)}
      </div>`;

/** `tray` opens the diff tray: the iPad's inspector, the iPhone's sheet. */
export function padDevice(world, { tray = null } = {}) {
  const { project, session } = findSession(world, world.selected);
  return `<div class="pad${tray ? ' with-tray' : ''}" data-device="pad">
  <div class="pad-screen">
    <div class="pad-side">
      ${iosList(world, true)}
    </div>
    <div class="pad-main">
      <div class="ios-nav">
        ${navTitle(project, session)}
        <span class="ios-tools">
          <span class="glass" data-load>${donut(hosts[project.host].load)}${donut(hosts[project.host].memory)}</span>
          <span class="glass"><span class="diff"><span class="add" data-add>+${session.git[0]}</span><span class="del" data-del>−${session.git[1]}</span></span>${I.ellipsisCircle}</span>
        </span>
      </div>
      ${terminal()}
      ${keyBar()}
    </div>
    ${tray ? diffTray(tray) : ''}
  </div>
</div>`;
}

export function phoneDevice(world, { tray = null } = {}) {
  const { project, session } = findSession(world, world.selected);
  return `<div class="phone" data-device="phone">
  <div class="phone-screen">
    <span class="island"></span>
    ${statusBar()}
    <div class="phone-stack" data-stack>
      <div class="screen list-screen">
        ${iosList(world)}
      </div>
      <div class="screen term-screen">
        <div class="ios-nav">
          <span class="glass round back">${I.chevronLeft}</span>
          ${navTitle(project, session)}
          <span class="glass"><span class="diff"><span class="add" data-add>+${session.git[0]}</span><span class="del" data-del>−${session.git[1]}</span></span>${I.ellipsisCircle}</span>
        </div>
        ${terminal()}
        ${keyBar()}
        ${keyboard()}
      </div>
    </div>
    ${tray ? `<div class="sheet">${diffTray(tray)}</div>` : ''}
    <span class="home-bar"></span>
  </div>
</div>`;
}
