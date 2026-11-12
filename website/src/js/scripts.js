// What runs in the hero window's five sessions. Each is a loop that prints
// into its session's terminal and reports state to the world, as a real
// session's program would through its title and Relay's status hooks —
// whether or not the session is the one on screen.

import { b, between, bold, c, clockTime, dim, esc, g, k, m, o, pad, pick, r, reduced, y } from './term.js';

const FRAMES = ['·', '✢', '✳', '✶', '✻', '✽'];

/** The pieces of a coding agent's transcript. */
function agent(world, id, clock) {
  const t = world.term(id);
  const say = async (...lines) => {
    lines.forEach((line, i) => t.print(`${i ? ' ' : '⏺'} ${line}`));
    t.print('');
    await clock.sleep(650);
  };
  /** A status line that counts while the agent thinks. */
  const think = async (ms, verb) => {
    if (reduced) return;
    const started = Date.now();
    for (let frame = 0; Date.now() - started < ms; frame++) {
      const seconds = Math.floor((Date.now() - started) / 1000);
      t.set(`${o(FRAMES[frame % FRAMES.length])} ${o(`${verb}…`)} ${k(`(${seconds}s · esc to interrupt)`)}`);
      await clock.sleep(140);
    }
    t.set('');
  };
  const tool = async (name, argument, result, { verb = 'Working', ms = 1500, extra = [] } = {}) => {
    t.print(`${g('⏺')} ${bold(name)}(${argument})`);
    await think(ms, verb);
    t.print(`  ${k('⎿')}  ${result}`);
    extra.forEach((line) => t.print(`     ${line}`));
    t.print('');
  };
  const banner = (worktree) => {
    t.clear();
    t.cursor = false;
    t.print(`${o('✻')} ${bold('Claude Code')}  ${k(`~/code/api · worktree ${worktree}`)}`);
    t.print('');
  };
  const ask = (text) => {
    t.print(`${k('>')} ${text}`);
    t.print('');
  };
  return { t, say, think, tool, banner, ask };
}

/** api / auth-refactor: an agent mid-refactor, then opening its PR. */
async function auth(world, clock) {
  const id = 'auth';
  const { t, say, think, tool, banner, ask } = agent(world, id, clock);
  const done = () => world.update(id, { agent: 'done', unseen: world.selected !== id });
  for (;;) {
    banner('auth-refactor');
    world.update(id, { agent: 'working', unseen: false, git: [0, 0], pr: null });
    ask('move token refresh onto the new session store');
    await think(1300, 'Thinking');
    await say('I’ll read the current refresh flow first.');
    await tool('Read', 'src/auth/refresh.ts', 'Read 148 lines', { verb: 'Reading', ms: 900 });
    await tool('Search', `pattern: ${y('"legacyRefresh"')}`, 'Found 6 matches in 3 files', { verb: 'Searching', ms: 1100 });
    await say('Three callers. I’ll move them onto sessions.rotate() and', 'drop the token cache along the way.');
    await tool('Update', 'src/auth/refresh.ts', `Updated with ${g('23 additions')} and ${r('9 removals')}`, {
      verb: 'Refactoring',
      ms: 2400,
      extra: [
        `${k('39')} <span class="no">- const token = await legacyRefresh(user)      </span>`,
        `${k('39')} <span class="ok">+ const session = await sessions.find(user.id) </span>`,
        `${k('40')} <span class="ok">+ const token = await session.rotate()         </span>`,
      ],
    });
    world.update(id, { git: [23, 9] });
    await clock.settle();
    await tool('Update', 'src/auth/session-store.ts', `Updated with ${g('51 additions')} and ${r('14 removals')}`, {
      verb: 'Refactoring',
      ms: 2600,
    });
    world.update(id, { git: [74, 23] });
    await tool('Bash', 'npm test -- auth', `${g('✓')} 42 passed ${k('(3.1s)')}`, { verb: 'Running tests', ms: 3200 });
    world.update(id, { git: [86, 31] });
    await say('Done. Token refresh goes through the session store now,', 'and all 42 auth tests pass.');
    done();
    await clock.sleep(6500);

    ask('open a pull request');
    world.update(id, { agent: 'working', unseen: false });
    await tool('Bash', 'git push -u origin auth-refactor', `branch ${c('auth-refactor')} set up to track origin`, { verb: 'Pushing', ms: 1700 });
    await tool('Bash', 'gh pr create --fill', `<span class="lnk" data-href="https://github.com/acme/api/pull/482">https://github.com/acme/api/pull/482</span>`, {
      verb: 'Opening the pull request',
      ms: 1900,
    });
    world.update(id, { pr: { number: 482, state: 'pending' } });
    await say('Opened #482. CI is running.');
    done();
    await clock.sleep(7000);
    world.update(id, { pr: { number: 482, state: 'ok' } });
    await clock.sleep(12000);
  }
}

/** api / fix-flaky-tests: an agent that stops to ask, until you look. */
async function flaky(world, clock) {
  const id = 'flaky';
  const { t, say, tool, banner, ask } = agent(world, id, clock);
  const box = (lines) => {
    const width = 54;
    const row = (text, raw = text) => `${k('│')} ${text}${' '.repeat(Math.max(0, width - 2 - raw.length))} ${k('│')}`;
    t.print(k(`╭${'─'.repeat(width)}╮`));
    lines.forEach(([text, raw]) => t.print(row(text, raw ?? text)));
    t.print(k(`╰${'─'.repeat(width)}╯`));
  };
  for (;;) {
    banner('fix-flaky-tests');
    world.update(id, { agent: 'working', unseen: false, git: [0, 0] });
    ask('the upload test fails about one run in five — find out why');
    await tool('Bash', 'npm test -- upload --repeat 20', `${g('17 passed')}, ${r('3 failed')}`, { verb: 'Running tests', ms: 2600 });
    await say('The failures share a temp directory: two workers write', '.cache/jest/upload.bin at once. I’d like to clear the cache', 'and re-run in one process to confirm.');
    const command = 'rm -rf .cache/jest && npm test -- upload -i';
    box([
      [bold('Bash command'), 'Bash command'],
      [''],
      [`  ${command}`],
      [''],
      ['Do you want to proceed?'],
      [`${b('❯ 1. Yes')}`, '❯ 1. Yes'],
      ['  2. Yes, and don’t ask again in this project'],
      ['  3. No, and tell Claude what to do differently'],
    ]);
    world.update(id, { agent: 'blocked' });
    await clock.settle();

    // It waits for you: select the session, and a moment later it's answered.
    while (world.selected !== id) await clock.sleep(250);
    await clock.sleep(3200);
    t.lines.splice(-10);
    world.update(id, { agent: 'working' });
    await tool('Bash', command, `${g('✓')} 20 passed ${k('(41.8s)')}`, { verb: 'Running tests', ms: 3000 });
    await tool('Update', 'test/upload.test.ts', `Updated with ${g('12 additions')} and ${r('4 removals')}`, { verb: 'Fixing', ms: 2200 });
    world.update(id, { git: [12, 4] });
    await say('Fixed: each worker gets its own temp directory now.', '20 of 20 runs pass.');
    world.update(id, { agent: 'done', unseen: world.selected !== id });
    await clock.sleep(16000);
  }
}

/** api / dev-server: a dev server with a localhost link worth clicking. */
async function dev(world, clock) {
  const t = world.term('dev');
  const link = (url) => `<span class="lnk c" data-href="${url}">${url}</span>`;
  const routes = ['/api/session', '/api/session/refresh', '/api/users/me', '/api/projects', '/api/uploads', '/healthz', '/api/projects/41/members'];
  t.cursor = false;
  t.print(`${g('❯')} npm run dev`);
  t.print('');
  t.print(k('> api@2.4.0 dev'));
  t.print(k('> vite --host'));
  t.print('');
  t.print(`  ${g(bold('VITE'))} ${g('v6.3.1')}  ${k('ready in')} 412 ms`);
  t.print('');
  t.print(`  ${g('➜')}  ${bold('Local:')}   ${link('http://localhost:5173/')}`);
  t.print(`  ${g('➜')}  ${bold('Network:')} ${link('http://10.0.1.20:5173/')}`);
  t.print(`  ${k('➜  press h + enter to show help')}`);
  t.print('');
  await clock.settle();
  for (;;) {
    await clock.sleep(between(500, 2600));
    if (Math.random() < 0.14) {
      t.print(`${k(clockTime())} ${c('[vite]')} ${g('hmr update')} ${k('/src/auth/refresh.ts')}`);
      continue;
    }
    const status = Math.random() < 0.08 ? 401 : Math.random() < 0.1 ? 304 : 200;
    const color = status === 401 ? y : status === 304 ? c : g;
    const method = Math.random() < 0.2 ? 'POST' : 'GET ';
    t.print(`${k(clockTime())} ${bold(method)} ${pick(routes).padEnd(26)} ${color(status)} ${k(`${Math.ceil(between(1, 38))}ms`)}`);
  }
}

/** trainer / sweep-lr: a training run on the GPU box. */
async function sweep(world, clock) {
  const t = world.term('sweep');
  t.cursor = false;
  t.print(`${g('❯')} python train.py --config sweeps/lr-3e-4.yaml`);
  t.print(`${k('[gpu-box]')} 2× RTX 4090 · bf16 · 48.2M params · batch 256`);
  t.print(`${k('[gpu-box]')} resuming from ${c('ckpt/step-12000.pt')}`);
  t.print('');
  let step = 12000;
  let loss = 1.912;
  let accuracy = 68.4;
  await clock.settle();
  for (;;) {
    step += 20;
    loss = Math.max(0.42, loss - between(-0.004, 0.011));
    const rate = between(13.6, 14.9).toFixed(1);
    const left = Math.max(0, 200000 - step) / 14.2 / 3600;
    t.print(
      `${k('step')} ${String(step).padStart(6)}  ${k('loss')} ${loss.toFixed(4)}  ${k('lr')} 3.00e-04  ${m(`${rate} it/s`)}  ${k(`eta ${Math.floor(left)}h${pad(Math.floor((left % 1) * 60))}m`)}`,
    );
    if (step % 500 === 0) {
      accuracy = Math.min(94, accuracy + between(0.1, 0.5));
      t.print(`${b('eval')}  ${k('top-1')} ${bold(`${accuracy.toFixed(1)}%`)}  ${g('✓')} checkpoint ${c(`ckpt/step-${step}.pt`)}`);
    }
    await clock.sleep(between(520, 900));
  }
}

/** dotfiles / scratch: a plain shell — and it takes your keys. */
function scratch(world) {
  const t = world.term('scratch');
  const prompt = `${c('~/.dotfiles')} ${m('main')} ${g('❯')} `;
  t.print(`${prompt}git status -sb`);
  t.print(`${g('## main')}...${r('origin/main')}`);
  t.print(` ${r('M')} zsh/aliases.zsh`);
  t.print(`${prompt}tmux ls`);
  t.print('rterm-52d1c0a9e7b34f18: 1 windows (created Mon Nov  9 09:14:22 2026)');
  t.print(`${prompt}${dim('# this one is yours: click here and type')}`);
  t.set(prompt);

  const files = ['README.md', 'ghostty/', 'git/', 'install.sh', 'nvim/', 'ssh/', 'tmux/', 'zsh/'];
  const commands = {
    help: () => ['A pretend shell. Try: ls, pwd, whoami, hostname, date, uname, relay, clear'],
    ls: () => [files.map((f) => (f.endsWith('/') ? b(f) : f)).join('  ')],
    pwd: () => ['/Users/you/.dotfiles'],
    whoami: () => ['you'],
    hostname: () => ['macbook'],
    date: () => [new Date().toString()],
    uname: () => ['Darwin'],
    relay: () => [`${g('●')} connected · tmux keeps this session running when you leave`],
    tmux: () => ['rterm-52d1c0a9e7b34f18: 1 windows (attached)'],
    git: () => [`${g('## main')}...${r('origin/main')}`, ` ${r('M')} zsh/aliases.zsh`],
    exit: () => ['Nice try. The session outlives the window anyway.'],
  };
  let line = '';
  /** A key from the page's keyboard, when this session has it. */
  return (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return false;
    if (event.key === 'Enter') {
      t.set(prompt + esc(line));
      t.enter();
      const [name] = line.trim().split(/\s+/);
      if (name === 'clear') t.clear();
      else if (commands[name]) commands[name]().forEach((out) => t.print(out));
      else if (name) t.print(`zsh: command not found: ${esc(name)}`);
      line = '';
    } else if (event.key === 'Backspace') {
      line = line.slice(0, -1);
    } else if (event.key.length === 1 && line.length < 60) {
      line += event.key;
    } else {
      return false;
    }
    t.set(prompt + esc(line));
    return true;
  };
}

/** Starts every session's program; returns the plain shell's key handler. */
export function runHero(world, clock) {
  auth(world, clock);
  flaky(world, clock);
  dev(world, clock);
  sweep(world, clock);
  return scratch(world);
}
