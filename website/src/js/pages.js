// The mockups the pages embed, rendered by the build (build.mjs) into the
// HTML: the first frame of each, there before any script runs.

import { arriving, hero, synced } from './data.js';
import { macWindow, padDevice, phoneDevice, projectGroup } from './mocks.js';

/** The window of the "nothing stops" demo: one session, no sidebar. */
const persistWorld = {
  selected: 'migrate',
  projects: [
    {
      id: 'api',
      name: 'api',
      host: 'mac-mini',
      sessions: [{ id: 'migrate', name: 'migrate-shards', caption: '', git: [0, 0], title: './scripts/migrate.sh --all' }],
    },
  ],
};

export const mocks = {
  hero: macWindow(hero, { id: 'hero-window' }),
  persist: macWindow(persistWorld, { solo: true }),
  syncMac: macWindow(synced),
  syncPad: padDevice(synced),
  syncPhone: phoneDevice(synced),
  arrivingGroup: projectGroup(arriving, null),
};
