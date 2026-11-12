// The make-believe workspaces the mockups show: hosts, their projects and
// sessions, as the app's sidebar lists them. The mockup templates render
// their first frame from this at build time; the browser animates from the
// same starting point.

/** Hosts: the two toolbar donuts are load per core and memory (0–1). */
export const hosts = {
  'mac-mini': { load: 0.34, memory: 0.52 },
  'gpu-box': { load: 0.81, memory: 0.67 },
  macbook: { load: 0.12, memory: 0.44 },
  'hetzner-1': { load: 0.22, memory: 0.31 },
};

/**
 * The hero window's workspace. A session's `agent` is its reported state
 * (working, blocked, done), `cold` one with no connection yet (a grey dot),
 * `git` the toolbar's change counts and `pr` its pull request.
 */
export const hero = {
  selected: 'auth',
  projects: [
    {
      id: 'api',
      name: 'api',
      host: 'mac-mini',
      sessions: [
        { id: 'auth', name: 'auth-refactor', caption: '✳ Refactor token refresh', agent: 'working', git: [86, 31], title: '✳ Refactor token refresh' },
        { id: 'flaky', name: 'fix-flaky-tests', caption: '✳ Fix flaky upload test', agent: 'blocked', git: [12, 4], title: '✳ Fix flaky upload test' },
        { id: 'dev', name: 'dev-server', caption: 'npm run dev', git: [0, 0], title: 'npm run dev' },
      ],
    },
    {
      id: 'trainer',
      name: 'trainer',
      host: 'gpu-box',
      sessions: [{ id: 'sweep', name: 'sweep-lr', caption: 'python train.py', git: [7, 2], title: 'python train.py' }],
    },
    {
      id: 'dotfiles',
      name: 'dotfiles',
      host: 'macbook',
      sessions: [{ id: 'scratch', name: 'scratch', caption: '', cold: true, git: [3, 1], title: 'zsh' }],
    },
  ],
};

/** The three devices of the sync section share this one. */
export const synced = {
  selected: 'deploy',
  projects: [
    {
      id: 'api',
      name: 'api',
      host: 'mac-mini',
      sessions: [
        { id: 'deploy', name: 'deploy', caption: 'zsh', git: [24, 6], title: 'zsh' },
        { id: 'agent', name: 'auth-refactor', caption: '✳ Refactor token refresh', agent: 'working', git: [86, 31] },
      ],
    },
    {
      id: 'trainer',
      name: 'trainer',
      host: 'gpu-box',
      sessions: [{ id: 'sweep', name: 'sweep-lr', caption: 'python train.py', git: [7, 2] }],
    },
  ],
};

/** The project that arrives over iCloud while you watch. */
export const arriving = {
  id: 'infra',
  name: 'infra',
  host: 'hetzner-1',
  sessions: [{ id: 'tf', name: 'terraform', caption: '', cold: true, git: [0, 0] }],
};

export const findSession = (world, id) => {
  for (const project of world.projects) {
    const session = project.sessions.find((s) => s.id === id);
    if (session) return { project, session };
  }
  return null;
};
