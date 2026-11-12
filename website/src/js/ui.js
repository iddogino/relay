// What both pages do: the navigation's backdrop once you scroll, sections
// easing in as they arrive, the light that follows the pointer over cards,
// toasts, and copy buttons.

import { startField } from './field.js';

let toastTimer = null;

/** A short message at the bottom of the window. HTML is the caller's. */
export function toast(html, ms = 3200) {
  const element = document.getElementById('toast');
  if (!element) return;
  element.innerHTML = html;
  element.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => element.classList.remove('show'), ms);
}

export function startPage() {
  const field = document.getElementById('field');
  if (field) startField(field);

  const nav = document.getElementById('nav');
  const onScroll = () => nav?.classList.toggle('scrolled', window.scrollY > 12);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  const reveal = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('in');
        reveal.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.08 },
  );
  for (const element of document.querySelectorAll('.reveal')) reveal.observe(element);

  for (const card of document.querySelectorAll('.card')) {
    card.addEventListener('pointermove', (event) => {
      const box = card.getBoundingClientRect();
      card.style.setProperty('--mx', `${event.clientX - box.left}px`);
      card.style.setProperty('--my', `${event.clientY - box.top}px`);
    });
  }

  document.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-copy]');
    if (!button) return;
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      toast('Copied to the clipboard');
    } catch {
      toast('Couldn’t reach the clipboard — select the text instead');
    }
  });
}
