// The releases page: the channel filter, and a release's anchor link
// showing it even when the filter would hide it.

import { startPage } from './ui.js';

startPage();

const list = document.getElementById('release-list');
const buttons = [...document.querySelectorAll('[data-filter]')];
const empty = document.getElementById('release-empty');

function show(channel) {
  let shown = 0;
  for (const release of list.querySelectorAll('.release')) {
    const visible = channel === 'all' || release.dataset.channel === channel;
    release.hidden = !visible;
    if (visible) {
      shown++;
      // Hidden articles never crossed the reveal observer.
      release.classList.add('in');
    }
  }
  for (const button of buttons) button.setAttribute('aria-pressed', String(button.dataset.filter === channel));
  empty.hidden = shown > 0;
}

for (const button of buttons) button.addEventListener('click', () => show(button.dataset.filter));

// /releases#v0.2.0-rc.1 — make sure it's on the page, then point at it.
function showTarget() {
  const target = location.hash ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null;
  if (!target?.classList.contains('release')) return;
  if (target.hidden) show('all');
  target.classList.add('in', 'target');
  target.scrollIntoView({ block: 'start' });
}
window.addEventListener('hashchange', showTarget);
showTarget();
