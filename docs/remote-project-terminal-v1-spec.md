# Remote Project Terminal — v1 Engineering Specification

**Working title:** Remote Project Terminal (internal namespace: `rterm`)  
**Status:** Build spec for engineering agent  
**Platform:** macOS only  
**Implementation:** Swift 6, SwiftUI + AppKit, libghostty/Metal  
**v1 runtime:** existing SSH hosts + vanilla `tmux`  

---

## 0. Agent operating instructions

This document is intended to be executable by an engineering agent. Treat the requirements and acceptance criteria as the source of truth.

Before changing code:

1. Read this spec fully.
2. Inspect the local macOS environment and existing repository before deciding build details.
3. Prefer the smallest implementation that satisfies the acceptance criteria.
4. Keep all SSH/tmux behavior behind the runtime/provider abstraction described below.
5. Use the user's existing OpenSSH configuration and binaries. Do **not** implement or vendor an SSH stack.
6. Do **not** install anything on remote hosts. In particular:
   - do not install a daemon/helper;
   - do not install `zmx` or another multiplexer;
   - do not install Ghostty terminfo;
   - do not edit shell rc files;
   - do not edit SSH/sshd config;
   - do not modify tmux config;
   - do not install packages with Homebrew/apt on remotes.
7. Live testing is expected against the two SSH remotes already configured on this Mac: one macOS host and one Ubuntu host. Discover them; do not hard-code their aliases.
8. Every live test must use uniquely namespaced temporary directories and tmux sessions and must clean them up. Never touch unrelated remote files or tmux sessions.
9. If a required remote prerequisite such as `tmux` is missing, report the missing prerequisite; **do not install it automatically**.
10. Do not add product features that are explicitly marked non-v1 simply because they are convenient to implement.

---

## 1. Product thesis

Build a very small, native Mac app that makes persistent remote terminal sessions feel like local terminal tabs.

The core hierarchy is:

```text
Remote (derived from ~/.ssh/config)
└── Project (a folder on that remote)
    └── Session (a persistent tmux session)
```

The app should feel like:

> A Ghostty-quality terminal with a project/session sidebar, where SSH and tmux are invisible implementation details.

The remote server remains ordinary and user-controlled. The only remote assumptions in v1 are:

- the machine is reachable through the user's existing `ssh` configuration;
- `tmux` exists on the remote;
- a POSIX shell exists;
- the project folder exists.

There is no custom remote agent, daemon, service, protocol, database, or helper executable.

---

## 2. Primary UX

Single-window macOS app:

```text
┌──────────────────────────────┬──────────────────────────────────────────────┐
│ REMOTES / PROJECTS           │                                              │
│                              │                                              │
│ macmini                      │              TERMINAL                        │
│   My iOS App                 │                                              │
│     ● auth refactor          │         libghostty / Metal                   │
│     ● settings               │                                              │
│     + New Session            │         ssh → tmux attach                    │
│                              │                                              │
│   Website                    │                                              │
│     ● checkout               │                                              │
│     + New Session            │                                              │
│                              │                                              │
│ ubuntu                       │                                              │
│   Backend                    │                                              │
│     ● migration              │                                              │
│     + New Session            │                                              │
└──────────────────────────────┴──────────────────────────────────────────────┘
```

The left sidebar is organizational state. The right side is a real terminal surface.

### 2.1 Remote

A Remote is discovered from the user's existing local OpenSSH config. It is not manually recreated in the app.

Examples:

```text
macmini
ubuntu
prod-bastion
```

The app uses the SSH **alias** exactly as configured by the user.

### 2.2 Project

A Project is configured locally and has:

- stable UUID;
- display name;
- runtime/workspace reference;
- remote folder path;
- resolved remote folder path after validation;
- optional launch command used for newly-created sessions;
- optional shutdown command used when a Session is explicitly archived.

Example:

```text
Name: My iOS App
Remote: macmini
Path: ~/code/my-ios-app
Launch command: ~/bin/new-agent-worktree claude "$RTERM_SESSION_NAME"
Shutdown command: ~/bin/cleanup-agent-worktree "$RTERM_SESSION_ID"
```

### 2.3 Session

A Session is a persistent remote execution session.

For v1, one app Session maps one-to-one to one **ordinary tmux session** on the remote.

The app owns the session metadata and lifecycle, but tmux owns process persistence.

A session has:

- stable UUID;
- user-visible display name;
- project UUID;
- remote/runtime-specific session identifier;
- creation timestamp;
- state: discovered / connecting / attached / reconnecting / ended / error.

The tmux session name itself should be an opaque app-generated identifier, not the user display name, e.g.:

```text
rterm-2f8a17d9d71e4dbe
```

This avoids quoting, rename, Unicode, collision, and injection problems.

---

## 3. v1 user stories

### US-1 — discover remotes automatically

When the app launches, I see concrete SSH host aliases from my Mac's SSH configuration without configuring them again.

### US-2 — add a project to a remote

I can choose a remote, click **Add Project**, enter a display name and folder path, validate it, and save it.

### US-3 — create a persistent session

Inside a project, I click **New Session**, give it a name, and the app creates a tmux session rooted in that project folder and attaches the terminal to it.

### US-4 — launch my preferred agent automatically

A project can have a launch command. If configured, each new session starts by running that command in the project directory.

This is intentionally generic. The app must not know what Claude Code, Codex, worktrees, Node, Xcode, etc. are.

### US-5 — disconnect without killing work

If I close the app, close the window, switch sessions, put the laptop to sleep, lose Wi-Fi, or kill the local SSH process, the remote tmux session and its processes keep running.

### US-6 — resume naturally

When I select an existing session, the app reconnects over SSH and reattaches to the existing tmux session.

### US-7 — explicitly kill a session

Killing a session is a separate, destructive escape hatch. It requires explicit user intent and kills the corresponding remote tmux session without running Project cleanup hooks.

### US-8 — archive a finished session cleanly

When I am done with a Session, I can choose **Archive Session…**. The app detaches any local SSH attachment, terminates the corresponding remote tmux session, optionally runs the Project's configured shutdown command, and removes the Session from the active sidebar.

Archiving is the normal finalization path. **Kill Session…** remains the force/destructive path for a stuck session or a failed cleanup workflow.

---

## 4. Explicit non-goals for v1

Do **not** implement these in v1:

- Daytona integration;
- E2B integration;
- cloud workspace provisioning;
- ephemeral machine lifecycle;
- Docker workspace management;
- local projects;
- file browser;
- Git UI;
- worktree UI;
- Claude/Codex-specific UI;
- agent status parsing;
- agent notifications;
- browser/preview pane;
- terminal splits;
- multiple simultaneous terminal panes;
- collaboration;
- iOS client;
- remote helper daemon;
- remote helper binary;
- custom multiplexer;
- SSH key management;
- password vault;
- editing `~/.ssh/config`;
- package installation on remotes;
- Ghostty terminfo installation on remotes;
- full Ghostty settings UI;
- arbitrary tmux-session management for sessions the app did not create.

The launch command is the escape hatch for advanced workflows such as creating a worktree and launching an agent.

---

## 5. Architecture principle: runtime abstraction

Although v1 is SSH + tmux, the UI/domain layer must **not** encode the assumption that a workspace is always an SSH host or that a persistent session is always tmux.

Future goal, not a v1 feature:

```text
UI / Projects / Sessions
        │
        ▼
RuntimeProvider
   ├── SSHTmuxRuntimeProvider        ← v1
   ├── DaytonaRuntimeProvider        ← future
   └── E2BRuntimeProvider            ← future
```

A future Project might target a Daytona/E2B account/template, provision an ephemeral workspace when the first session is created, and tear it down later. That future feature should require a provider implementation and some UI, not a rewrite of Project/Session views.

### 5.1 Domain types

Use names similar to the following; exact Swift spelling may vary:

```swift
struct ProviderID: Hashable, Codable, Sendable { ... }
struct WorkspaceRef: Hashable, Codable, Sendable { ... }
struct ProjectID: Hashable, Codable, Sendable { ... }
struct SessionID: Hashable, Codable, Sendable { ... }

struct WorkspaceDescriptor: Identifiable, Sendable {
    let id: WorkspaceRef
    let displayName: String
    let providerID: ProviderID
}

struct Project: Identifiable, Codable, Sendable {
    let id: ProjectID
    var name: String
    var workspace: WorkspaceRef
    var pathInput: String
    var resolvedPath: String
    var launchCommand: String?
    var shutdownCommand: String?
}

struct RemoteSession: Identifiable, Sendable {
    let id: SessionID
    let projectID: ProjectID
    let displayName: String
    let createdAt: Date
    let backendID: String
}
```

For v1 an SSH alias is represented as a workspace ref, e.g. conceptually:

```text
provider = ssh-tmux
workspace opaque ID = "macmini"
```

Do not put fields such as `hostname`, `sshCommand`, or `tmuxSessionName` directly into UI models.

### 5.2 Runtime provider interface

The UI should depend on a small protocol along these lines:

```swift
protocol RuntimeProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: RuntimeCapabilities { get }

    func discoverWorkspaces() async throws -> [WorkspaceDescriptor]
    func validate(project: Project) async throws -> ProjectValidation

    func listSessions(for project: Project) async throws -> [RemoteSession]
    func createSession(
        for project: Project,
        request: NewSessionRequest
    ) async throws -> RemoteSession

    func makeTerminalLaunch(
        for session: RemoteSession,
        project: Project
    ) async throws -> TerminalLaunchSpec

    func sessionExists(_ session: RemoteSession, project: Project) async throws -> Bool

    // Normal finalization path. Provider is responsible for ordering runtime
    // termination and the Project shutdown hook safely for that backend.
    func archiveSession(_ session: RemoteSession, project: Project) async throws

    // Force/destructive escape hatch. No Project shutdown hook is run.
    func destroySession(_ session: RemoteSession, project: Project) async throws
}
```

`TerminalLaunchSpec` is a backend-produced description of how to attach the terminal. For v1 it can be a child-process launch spec:

```swift
struct TerminalLaunchSpec: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
}
```

The SwiftUI views should never construct SSH/tmux commands.

It is acceptable for the interface to evolve when a future provider needs a byte-stream/WebSocket-backed terminal. Do not prematurely build E2B/Daytona transport now. The important v1 boundary is: **no SSH/tmux knowledge above the SSH runtime module**.

### 5.3 Capabilities

Define a small capability set now so the domain does not assume all future providers can do everything:

```swift
struct RuntimeCapabilities: OptionSet, Sendable {
    static let persistentSessions = ...
    static let staticWorkspaces = ...

    // reserved for future use; do not implement UI in v1
    static let provisionWorkspaces = ...
    static let destroyWorkspaces = ...
    static let suspendResume = ...
    static let snapshots = ...
}
```

`SSHTmuxRuntimeProvider` advertises `persistentSessions` and `staticWorkspaces` only.

---

## 6. Native macOS implementation requirements

### 6.1 Required stack

- Swift 6
- SwiftUI for app structure/sidebar/forms
- AppKit where needed for terminal embedding/window behavior
- libghostty for terminal emulation/rendering
- Metal rendering supplied by libghostty
- Foundation `Process` for one-shot system commands where appropriate
- `/usr/bin/ssh` for SSH
- remote system `tmux`

### 6.2 Forbidden stack

Do not introduce:

- Electron;
- Tauri;
- React;
- WebView-based terminal rendering;
- xterm.js;
- Rust daemon;
- Node helper process;
- Python runtime;
- libssh/libssh2;
- custom SSH protocol implementation;
- custom remote service.

### 6.3 Dependency budget

Target **one substantive third-party source dependency: official Ghostty/libghostty**.

Prefer system frameworks and in-repo Swift code for everything else.

Do not add a random third-party SSH config parser or terminal wrapper merely to save code.

### 6.4 App Sandbox

The macOS App Sandbox should be **off** in v1 because the app must:

- read `~/.ssh/config` and included SSH config files;
- execute `/usr/bin/ssh`;
- allow libghostty to spawn a real child process/PTY.

Do not weaken SSH security to compensate for this. Hardened Runtime/signing can be addressed normally for distribution.

---

## 7. libghostty integration

### 7.1 Requirement

The terminal on the right must be a real libghostty-backed native terminal surface using Ghostty's Metal renderer. Do not build a renderer yourself on top of `libghostty-vt` unless the official embedding API makes that unavoidable.

Expected terminal behaviors:

- normal TTY/PTY behavior;
- fast Metal rendering;
- Unicode/grapheme correctness;
- ANSI/256-color/true-color rendering;
- selection;
- copy/paste;
- scrollback;
- keyboard modifiers;
- alternate screen applications such as Claude Code, vim, htop, etc.;
- resize propagation;
- IME/input behavior expected from a native Mac terminal.

### 7.2 Source policy

Use **official `ghostty-org/ghostty` source as the source of truth**. Ghostty is MIT licensed, but its branding/icons are not part of this product and must not be reused.

libghostty's embedding API is still evolving. Therefore:

1. pin Ghostty to an exact known-good commit/tag;
2. isolate all libghostty C/API interaction inside a narrow module such as `GhosttyTerminalHost`;
3. do not leak Ghostty C types throughout the application;
4. include a reproducible build script or Xcode build phase for the pinned library;
5. document the pin in the repo;
6. an upstream Ghostty bump must be a deliberate change with terminal smoke tests.

Do not silently track Ghostty `main`.

Implementation inspiration may be taken from Ghostty's own macOS app and minimal Swift/libghostty projects, but do not add those projects as runtime dependencies.

### 7.3 Terminal environment

Do **not** require installing `xterm-ghostty` terminfo on remote hosts.

For v1, launch the local SSH child with a conservative interoperable environment, at minimum:

```text
TERM=xterm-256color
COLORTERM=truecolor
TERM_PROGRAM=<app name>
```

The allocated SSH PTY will propagate `TERM`, avoiding the common failure where a remote host lacks Ghostty's terminfo entry.

Inside tmux, the remote `TERM` will normally become `tmux-256color` or another tmux-configured value.

Do not run Ghostty's automatic remote terminfo installer in v1.

### 7.4 Resource policy

There should be **at most one actively attached terminal per app window** in v1.

When the user selects another sidebar session:

1. terminate/detach the local SSH attachment for the previous session;
2. keep the remote tmux session alive;
3. create a terminal attachment for the newly selected session.

This deliberately trades a small reconnect cost for very low local process/memory use and simple lifecycle semantics.

No hidden terminal surfaces should remain rendering in the background.

---

## 8. SSH config discovery

### 8.1 Source of truth

Read the user's existing OpenSSH configuration starting at:

```text
~/.ssh/config
```

Support recursively included files via `Include` sufficiently to discover concrete aliases.

### 8.2 What to render

Render concrete aliases appearing in `Host` declarations.

Given:

```sshconfig
Host macmini
    HostName macmini.example.ts.net
    User me

Host ubuntu gpu
    HostName 10.0.0.25
    User ubuntu

Host *
    ServerAliveInterval 30
```

render:

```text
macmini
ubuntu
gpu
```

Do not render wildcard/negated patterns such as:

```text
*
*.internal
!bastion
foo?
```

Deduplicate aliases while preserving intuitive config order.

### 8.3 Do not reimplement OpenSSH resolution

Parsing is only for **enumerating aliases**.

For actual behavior, always invoke system OpenSSH with the alias:

```bash
/usr/bin/ssh macmini ...
```

This preserves the user's real configuration, including:

- `HostName`;
- `User`;
- `Port`;
- `IdentityFile`;
- ssh-agent/Keychain;
- Tailscale hostnames;
- `ProxyJump`;
- `ProxyCommand`;
- `ControlMaster`;
- `Match`;
- known_hosts;
- any other OpenSSH behavior.

When resolved metadata is useful for display/debugging, use:

```bash
/usr/bin/ssh -G <alias>
```

Do not construct a new SSH connection from parsed values.

### 8.4 Refresh behavior

- Discover aliases at app launch.
- Re-read config when the app becomes active, or expose a lightweight Refresh action.
- Do not continuously poll config files.
- If a persisted Project references an alias that no longer exists, keep the Project and show it as **Missing Remote** rather than deleting it.

### 8.5 Authentication behavior

The app does not manage passwords or keys.

Management commands may use non-interactive SSH (`BatchMode=yes`) to avoid hanging on password prompts. If authentication/host verification is not ready, surface a clear error such as:

> SSH connection requires interactive setup. Verify `ssh <alias>` works in Terminal, then retry.

Never use `StrictHostKeyChecking=no`.

Never alter `known_hosts` automatically.

---

## 9. Project creation and validation

### 9.1 Add Project UI

From a Remote row:

```text
Add Project…

Name          [ My iOS App                    ]
Remote        [ macmini ]   (read-only here)
Folder        [ ~/code/my-ios-app             ]
Launch command
┌─────────────────────────────────────────────┐
│ claude                                      │
└─────────────────────────────────────────────┘

                 [Cancel] [Validate & Add]
```

Launch command is optional.

### 9.2 Validation

Validation must confirm:

- SSH alias is reachable enough to execute a short command;
- folder exists;
- folder is a directory;
- `tmux` exists;
- the app can obtain a canonical/resolved path.

Use a read-only remote command conceptually equivalent to:

```sh
command -v tmux
cd <safe-path>
pwd -P
```

Do not create files during Project validation.

### 9.3 Tilde handling

Users must be able to enter paths such as:

```text
~/code/foo
```

Do not simply single-quote `~/...` and thereby prevent tilde expansion.

Implement a safe path renderer that treats:

- `~` as remote `$HOME`;
- `~/foo` as `$HOME/foo`;
- all other input as a literal path.

Do not support arbitrary shell expansion in project paths (`$VAR`, command substitution, globbing, etc.) in v1.

Store both the user's path text and the canonical remote path returned by validation.

---

## 10. Launch command behavior

### 10.1 Semantics

A Project can define one optional launch command.

If blank, a new tmux session opens the remote user's normal shell in the project directory.

If present, a new tmux session starts in the project directory and executes the launch command using the remote user's shell in a login-capable mode.

The launch command is intentionally trusted arbitrary shell code configured by the user.

Examples:

```text
claude
codex
~/bin/start-agent-worktree claude "$RTERM_SESSION_NAME"
./scripts/dev-shell
```

### 10.2 Environment exposed to launch commands

Provide a small stable set of environment variables to the launched process:

```text
RTERM_PROJECT_ID
RTERM_PROJECT_NAME
RTERM_PROJECT_PATH
RTERM_SESSION_ID
RTERM_SESSION_NAME
RTERM_REMOTE
```

Values must be passed safely; they must not be interpolated into shell source without quoting.

This gives users enough context to build worktree/agent launchers without the app understanding worktrees.

Example user script:

```bash
#!/usr/bin/env bash
set -euo pipefail

name="$RTERM_SESSION_NAME"
root="$RTERM_PROJECT_PATH"
worktree="${root}-worktrees/${name// /-}"
branch="agent/${name// /-}"

git -C "$root" worktree add "$worktree" -b "$branch"
cd "$worktree"
exec claude
```

The app should not generate or manage this script.

### 10.3 Shell safety

Build a dedicated, unit-tested POSIX shell quoting utility for values that must appear in remote command strings.

Never concatenate unescaped user paths, display names, IDs, or environment values into a remote shell command.

The **launch command itself** is executable shell text by design. Treat it as trusted user input, but quote it correctly when nesting it inside a remote login-shell invocation.

Do not log launch-command text by default; it may contain sensitive arguments.

### 10.4 Shutdown command semantics

A Project may define one optional **shutdown command**. This is intentionally symmetric with the launch command but is only invoked by an explicit **Archive Session…** action.

The shutdown command exists primarily to support user-owned cleanup such as:

- removing a per-session Git worktree;
- deleting a temporary branch or scratch directory when the user's own script decides that is safe;
- stopping auxiliary resources created by the launch script;
- writing final metadata/log markers.

The app must not understand or implement worktree cleanup itself. The shutdown command is trusted arbitrary shell code configured by the user.

For the SSH+tmux provider, the archive ordering is:

1. detach/terminate the local interactive SSH attachment, if present;
2. snapshot the Session/Project metadata needed by the hook;
3. terminate the remote tmux session so the coding agent and shell are no longer actively using the worktree/resources;
4. if a shutdown command is configured, execute it as a **separate one-shot SSH management command** from the Project's resolved base path;
5. on success (or if no hook is configured), remove the Session from the active sidebar/cache;
6. if the shutdown command fails, surface the failure clearly and retain a lightweight local **Cleanup Failed** record with actions to **Retry Cleanup** or **Dismiss**. Do not recreate the killed tmux session automatically.

Run the shutdown command with the same stable Session/Project context variables used by the launch command, plus:

```text
RTERM_SHUTDOWN_REASON=archive
```

The command must run with at least:

```text
RTERM_PROJECT_ID
RTERM_PROJECT_NAME
RTERM_PROJECT_PATH
RTERM_SESSION_ID
RTERM_SESSION_NAME
RTERM_REMOTE
RTERM_SHUTDOWN_REASON
```

The shutdown hook must **not** run when:

- merely switching sessions;
- closing the app/window;
- losing network;
- detaching;
- the remote tmux session exits on its own;
- using **Kill Session…**.

This keeps cleanup predictable and always tied to explicit user intent in v1. Automatic cleanup on natural process exit is a future feature, if ever desired.

A shutdown command may take time. Execute it asynchronously, never on the main thread. The UI should show an **Archiving…** state while it is running. A hanging cleanup must be cancellable from the UI; cancellation leaves the session in **Cleanup Failed / Incomplete** state rather than pretending cleanup succeeded.

Do not log shutdown-command text by default. Apply the same shell-quoting/sensitive-value rules as launch commands.

---

## 11. tmux backend

### 11.1 Rule

Use the remote machine's ordinary `tmux` binary. Do not vendor or configure a multiplexer.

The app must work with sessions that remain fully accessible outside the app:

```bash
ssh macmini
tmux ls
tmux attach -t rterm-...
```

If the app disappears forever, the user's running sessions must still be ordinary tmux sessions.

### 11.2 Session creation

Creation is a short one-shot SSH management operation.

Conceptually:

1. generate a session UUID and safe tmux name locally;
2. create the detached tmux session rooted at the canonical project path;
3. start the configured launch command or shell;
4. attach app metadata as tmux user options;
5. if metadata setup fails, clean up the just-created tmux session;
6. return the session model;
7. attach the terminal using a separate interactive SSH process.

Do not use user-provided display names as tmux identifiers.

### 11.3 tmux metadata

Use tmux user options to mark sessions created by the app. Suggested schema:

```text
@rterm_schema=1
@rterm_project_id=<uuid>
@rterm_session_id=<uuid>
@rterm_session_name_b64=<base64 utf8>
@rterm_created_at=<unix timestamp>
```

Base64 is recommended for the display name so tmux format output remains parseable even with spaces/Unicode.

Do not store secrets or launch commands in tmux metadata.

### 11.4 Session discovery

For each Project, `listSessions` queries tmux on the corresponding remote and returns only sessions whose:

- `@rterm_schema` is recognized;
- `@rterm_project_id` matches the local Project UUID.

The remote tmux state is authoritative for whether a session is alive.

The local app may cache session display metadata for UI responsiveness, but it must reconcile with tmux.

### 11.5 Unmanaged tmux sessions

Do not adopt, rename, kill, or show arbitrary user tmux sessions in the primary project hierarchy in v1.

The app must never mistake an unrelated tmux session for one of its own.

### 11.6 Attach

Interactive attachment should ultimately execute the equivalent of:

```bash
/usr/bin/ssh -tt <alias> tmux attach-session -t <safe-session-id>
```

Use `-tt` or the necessary equivalent so an interactive PTY is allocated reliably.

The actual argv must be produced by `SSHTmuxRuntimeProvider`, not by the terminal UI.

### 11.7 Detach

Detaching means terminating the **local SSH attachment**, not the remote tmux session.

Switching sessions, closing the window, or quitting the app must not call `tmux kill-session`.

### 11.8 Archive

The explicit **Archive Session…** action is the normal end-of-life path for a Session. For `SSHTmuxRuntimeProvider` it must:

- detach/terminate any local SSH attachment;
- invoke `tmux kill-session -t <safe-id>` through a short management SSH operation;
- run the optional Project shutdown command according to §10.4;
- refresh remote/project state;
- remove the Session from the active sidebar after successful cleanup;
- never infer or delete worktrees/files itself.

The user-facing term **Archive** does not imply an archived-history browser in v1. It means "finalize this live session and remove it from the active navigation." Retaining a tiny local tombstone for cleanup retry/error handling is allowed.

### 11.9 Kill

The explicit **Kill Session…** action is a force/destructive escape hatch:

- asks for confirmation;
- invokes `tmux kill-session -t <safe-id>` through SSH;
- does **not** run the Project shutdown command;
- refreshes project session state;
- never removes project files/worktrees itself.

Use this when a Session or cleanup workflow is stuck. The confirmation should warn that user-managed cleanup (for example a worktree cleanup script) will be skipped.

### 11.10 tmux version

Do not depend on bleeding-edge tmux features unless needed.

At minimum, preflight and surface the remote version with `tmux -V`. If a particular implementation choice introduces a minimum version, encode that requirement explicitly and test both live remotes.

---

## 12. Terminal attach/reconnect lifecycle

### 12.1 State machine

A selected session should approximately follow:

```text
idle
  ↓
connecting
  ↓
attached
  ↓ network/sleep/process interruption
reconnecting
  ├── session still exists → attached
  ├── host unreachable → backoff/retry
  └── session gone → ended
```

### 12.2 Reconnect

If the interactive SSH process exits unexpectedly while the selected session should still exist:

1. do not create a new tmux session;
2. determine whether the host/session is reachable when practical;
3. retry attaching to the same session with bounded exponential backoff;
4. stop retrying when:
   - the user selects another session;
   - the user closes the window/app;
   - the remote reports that the tmux session no longer exists;
   - the user cancels/retries manually after a persistent error.

Suggested backoff:

```text
0.5s → 1s → 2s → 4s → 8s → 10s max
```

No fast polling loops.

### 12.3 macOS sleep/wake

Observe normal macOS workspace sleep/wake/network lifecycle only as needed to make reconnect feel immediate. Do not add a background daemon.

On wake, a selected disconnected session should attempt reattachment.

### 12.4 What persistence means

After reconnect, tmux must restore the running program and current terminal screen state.

Do **not** promise preservation of libghostty's local scrollback buffer across a completely new SSH/terminal attachment. Historical remote output remains available through tmux's own history/copy mode; reconstructing local scrollback is not a v1 requirement.

---

## 13. Persistence on the Mac

### 13.1 Keep it simple

Persist only small app-owned configuration locally:

- Projects;
- project order;
- sidebar expansion state if desired;
- last-selected project/session ID if useful;
- minimal terminal preferences if added.

Hosts are **not** persisted as independent connection records; they are rediscovered from SSH config.

Sessions are primarily reconciled from remote tmux metadata.

### 13.2 Storage technology

Prefer a small `Codable` JSON/plist document written atomically under Application Support over Core Data/SwiftData unless a concrete need emerges.

Example:

```text
~/Library/Application Support/<bundle-id>/state.json
```

There is not enough v1 data to justify a database framework.

### 13.3 Project removal

Removing a Project from the app is a local configuration operation.

It must **not** delete the remote project folder and must **not** implicitly kill tmux sessions.

If managed sessions still exist, warn the user that they will remain running remotely.

---

## 14. UI details

### 14.1 Sidebar

Use native SwiftUI/AppKit sidebar styling.

Hierarchy:

```text
Remote
  Project
    Session
    + New Session
```

Host rows should come from SSH aliases. Projects under them come from local state. Sessions under projects come from remote tmux discovery/cache.

### 14.2 Remote row actions

At minimum:

- Add Project…
- Refresh

Optional if trivial:

- Copy SSH Alias
- Open raw SSH shell (not required)

### 14.3 Project row actions

At minimum:

- New Session…
- Project Settings…
- Refresh Sessions
- Remove Project…

### 14.4 Project settings

Editable:

- name;
- path;
- launch command;
- shutdown command.

Changing the path requires revalidation.

Changing the launch command affects **new sessions only**.

Changing the shutdown command affects subsequent **Archive Session…** operations, including sessions that were created before the setting changed.

### 14.5 Session row actions

At minimum:

- Select/Attach;
- Archive Session…;
- Kill Session… (force/skip cleanup).

Do not overload a normal close action to mean kill or archive. Closing/switching remains a detach-only operation.

### 14.6 New Session sheet

Minimum:

```text
New Session

Name [ fix auth flow ]

Launches with project default:
~/bin/new-agent-worktree claude "$RTERM_SESSION_NAME"

[Cancel] [Create]
```

Session name:

- required;
- trimmed;
- 1–100 user-visible characters;
- reject control characters/newlines;
- Unicode allowed.

### 14.7 Terminal chrome

Keep terminal chrome minimal.

A thin native title/header may show:

```text
My iOS App  /  fix auth flow  ·  macmini
```

Do not build a heavy IDE toolbar.

### 14.8 Keyboard

Terminal input should receive keystrokes normally.

Reasonable app shortcuts:

- `⌘N` — New Session when a Project is selected;
- `⌘⇧R` — Refresh selected Project/Remote;
- `⌘,` — Settings if a settings view exists.

Do not steal common terminal key combinations unnecessarily.

---

## 15. Efficiency requirements

This app is intentionally a thin control plane, not an IDE.

### 15.1 Architectural efficiency

- no background server;
- no embedded web runtime;
- no custom multiplexer;
- no remote polling loop;
- one active terminal attachment per window;
- one-shot SSH processes for management actions;
- reuse the user's `ControlMaster` settings if they configured them; do not invent a parallel SSH connection cache in v1;
- event-driven UI updates;
- no session-output parsing.

### 15.2 Performance targets

Targets are engineering goals, not reasons to add complexity:

- app UI should become interactive within ~500 ms on a normal modern Mac after the executable is warm;
- no network access should block app launch or the main thread;
- idle CPU with no active terminal should be effectively zero (<1% sustained on a modern Apple Silicon Mac);
- idle CPU with one attached, idle terminal should remain <1% sustained excluding transient renderer work;
- local memory with one attached terminal should target <150 MB in Release, and should not grow without bound during normal use;
- switching sidebar selections must never block the main thread on SSH;
- all long-running process I/O is asynchronous.

If libghostty's baseline footprint causes a target miss, document the measured value rather than introducing a worse architecture to chase a synthetic number.

### 15.3 No premature caching

Do not poll every remote just to keep green dots fresh.

Refresh session lists:

- when a Project is expanded/selected;
- after create/kill;
- on app activation for Projects that were recently active if useful;
- on explicit Refresh.

---

## 16. Error handling

Errors must be actionable and should preserve remote work.

Examples:

### SSH unavailable

```text
Can't reach macmini.

ssh exited with status 255.
[Retry]
```

### Authentication not ready

```text
SSH needs interactive authentication or host verification.
Verify `ssh macmini` works in Terminal, then retry.
```

### tmux missing

```text
tmux is not available on ubuntu.
Install tmux on the remote host, then retry.
```

Do **not** offer to auto-install it.

### Project path missing

```text
~/code/my-app does not exist on macmini.
[Edit Project]
```

### Session ended

```text
This tmux session no longer exists on macmini.
[Remove From Sidebar] [New Session]
```

Avoid exposing giant raw command lines in normal UI. Include sanitized stderr in a disclosure/debug area where useful.

---

## 17. Security requirements

1. Use `/usr/bin/ssh`; do not ingest private-key contents.
2. Respect existing OpenSSH host-key validation.
3. Never set `StrictHostKeyChecking=no`.
4. Never modify `~/.ssh/config`, private keys, or `known_hosts` in v1.
5. Do not store passwords/tokens.
6. Do not transmit telemetry in v1.
7. Do not upload binaries to remote hosts.
8. Do not install terminfo remotely.
9. Do not log user launch commands or environment variable values at info level.
10. Unit-test shell quoting and safe tmux identifiers.
11. All destructive remote operations must target an exact app-managed session ID.
12. Never use broad cleanup commands such as `pkill tmux`, `tmux kill-server`, or wildcard deletion.
13. Project removal must not remove remote files.
14. Test cleanup must verify paths before `rm -rf`.

---

## 18. Suggested code organization

Keep types small and responsibilities obvious. A suggested layout:

```text
RemoteProjectTerminal/
├── App/
│   ├── RemoteProjectTerminalApp.swift
│   └── AppModel.swift
├── Domain/
│   ├── IDs.swift
│   ├── Project.swift
│   ├── RemoteSession.swift
│   ├── RuntimeProvider.swift
│   └── RuntimeCapabilities.swift
├── Providers/
│   └── SSHTmux/
│       ├── SSHTmuxRuntimeProvider.swift
│       ├── SSHConfigDiscovery.swift
│       ├── SSHCommandRunner.swift
│       ├── SSHResolvedConfig.swift
│       ├── RemotePath.swift
│       ├── TmuxSessionCodec.swift
│       ├── TmuxCommands.swift
│       └── POSIXShellQuote.swift
├── Terminal/
│   ├── GhosttyTerminalHost.swift
│   ├── GhosttyTerminalView.swift
│   ├── TerminalLaunchSpec.swift
│   └── TerminalReconnectController.swift
├── Persistence/
│   └── ProjectStore.swift
├── UI/
│   ├── MainSplitView.swift
│   ├── Sidebar/
│   ├── ProjectEditor/
│   ├── NewSession/
│   └── Errors/
├── Tests/
│   ├── Unit/
│   └── Integration/
├── Scripts/
│   ├── build-libghostty.sh
│   ├── live-e2e.sh
│   └── live-e2e-cleanup.sh
└── Vendor/
    └── ghostty/   (pinned official source/submodule or equivalent pin)
```

Names may change; preserve the module boundaries.

### 18.1 Concurrency

- UI state is `@MainActor`.
- Network/process operations are async and never block the main actor.
- Use Swift concurrency rather than ad hoc thread creation.
- A provider or command runner may be an `actor` if it owns mutable process state.
- Cancellation must propagate when switching sessions or closing the window.

---

## 19. Unit test requirements

At minimum, unit-test:

### SSH config discovery

- single `Host` alias;
- multiple aliases on one `Host` line;
- wildcard aliases skipped;
- negated/wildcard aliases skipped;
- duplicate aliases deduplicated;
- `Include` recursion;
- include cycle protection;
- missing config returns empty list without crash.

### POSIX shell quoting

Values containing:

- spaces;
- single quotes;
- double quotes;
- `$`;
- semicolons;
- backticks;
- parentheses;
- Unicode;
- leading `-`;
- newline/control characters where rejection is expected.

Test by round-tripping safe values through `/bin/sh` locally when practical.

### Remote path rendering

- `~`;
- `~/foo`;
- path with spaces;
- apostrophe in path;
- absolute path;
- literal `$` does not become shell expansion.

### tmux identifier generation

- always ASCII safe;
- stable prefix;
- no user-controlled input;
- collision probability negligible.

### tmux metadata codec

- Base64 display-name encode/decode;
- Unicode session names;
- malformed metadata ignored safely;
- unknown schema ignored.

### Runtime abstraction

Use a fake provider to prove UI/session view models do not depend on SSH/tmux concrete types.

### Persistence

- atomic save/load;
- corrupt file fails safely with recoverable error/back-up behavior;
- projects referencing missing SSH aliases remain present.

---

## 20. Live acceptance test environment

The development Mac is expected to have **two usable remotes already configured in SSH**:

- one remote macOS machine;
- one remote Ubuntu machine.

The engineering agent must discover them dynamically.

### 20.1 Discover candidate hosts

1. Use the same SSH config discovery implementation the app uses to enumerate concrete aliases.
2. Probe candidates read-only using non-interactive SSH with a short timeout.
3. Identify operating system:

macOS:

```sh
uname -s          # Darwin
sw_vers           # if available
```

Linux/Ubuntu:

```sh
uname -s          # Linux
. /etc/os-release && printf '%s\n' "$ID"
```

4. Select one reachable Darwin host and one reachable Ubuntu host.
5. Print/log only the aliases selected for the test. Do not persist test-specific assumptions in production code.

If the expected two hosts cannot be identified, stop the live test and report why.

### 20.2 Preflight each host

Read-only checks:

```sh
printf 'os='; uname -s
printf 'arch='; uname -m
command -v tmux
tmux -V
command -v git
git --version
printf 'shell=%s\n' "$SHELL"
printf 'home=%s\n' "$HOME"
```

Do not install missing prerequisites.

---

## 21. Live E2E test isolation and cleanup

### 21.1 Namespace

Each live test run creates a unique ID such as:

```text
rterm-e2e-20260827-4f91c8
```

Every remote artifact created by the test must contain or be associated with this run ID.

### 21.2 Temporary root

On each host create a temp directory with `mktemp`, rooted under the OS temp location:

```sh
root="$(mktemp -d "${TMPDIR:-/tmp}/rterm-e2e.XXXXXX")"
```

Immediately place a sentinel file inside:

```text
.rterm-e2e-sentinel
```

The cleanup script may remove a directory recursively **only if**:

- its path is under `${TMPDIR:-/tmp}` or the exact temp path recorded by the test;
- basename matches the expected E2E prefix;
- the sentinel exists and contains the test run ID.

### 21.3 tmux test sessions

All E2E tmux session names must begin with:

```text
rterm-e2e-
```

and also carry normal `@rterm_*` metadata plus an E2E marker:

```text
@rterm_e2e_run=<run-id>
```

### 21.4 Cleanup strategy

`Scripts/live-e2e.sh` must install a local cleanup trap where possible.

`Scripts/live-e2e-cleanup.sh` must be safe to run independently after a crash.

Cleanup may only:

- kill tmux sessions explicitly marked with the E2E run ID;
- delete the exact E2E temporary roots after sentinel validation;
- remove E2E Projects created in the app's local test state.

Cleanup must never:

- call `tmux kill-server`;
- kill tmux sessions without the E2E marker;
- delete user project folders;
- delete arbitrary `/tmp/rterm-*` paths without checking the sentinel;
- change dotfiles/configuration.

At the end of a successful E2E run, verify there are zero tmux sessions with `@rterm_e2e_run=<run-id>` on both hosts and the temporary roots no longer exist.

---

## 22. Acceptance criteria — P0 functional

The release is not v1-complete until **every P0 item passes**.

### AC-01 — native app stack

- [ ] App is a native macOS executable built in Swift.
- [ ] Main UI is SwiftUI/AppKit, not web technology.
- [ ] Terminal is rendered by libghostty/Metal.
- [ ] No Electron/Tauri/WebView terminal.
- [ ] No local background daemon.

### AC-02 — SSH host discovery

- [ ] App reads configured SSH aliases from `~/.ssh/config` and supported `Include` files.
- [ ] The two expected live test remotes appear without manually recreating host/user/key settings in the app.
- [ ] Wildcard-only `Host` patterns are not shown as remotes.
- [ ] Actual connections invoke `/usr/bin/ssh <alias>` and therefore honor the user's existing configuration.

### AC-03 — project creation on macOS remote

Using an E2E temp folder on the discovered Darwin remote:

- [ ] Add Project succeeds using a `~/...` or canonical temp path.
- [ ] Validation confirms directory and tmux availability.
- [ ] Project appears beneath the correct SSH alias.
- [ ] No files are created during validation.

### AC-04 — project creation on Ubuntu remote

Repeat AC-03 against the discovered Ubuntu remote.

### AC-05 — plain shell session on macOS remote

- [ ] With no Project launch command, New Session creates one app-owned tmux session on the macOS remote.
- [ ] Selecting it displays a working interactive shell in libghostty.
- [ ] `pwd` reports the Project's canonical directory.
- [ ] Typed commands execute correctly.
- [ ] Unicode input/output renders correctly.
- [ ] ANSI colors render correctly.
- [ ] Copy/paste works.
- [ ] Terminal resizing reaches the remote TTY/tmux client; `stty size` changes appropriately when the window is resized.

### AC-06 — plain shell session on Ubuntu remote

Repeat AC-05 on Ubuntu.

### AC-07 — custom launch command

On each live host configure the E2E Project launch command to something non-destructive that:

1. writes a marker inside the E2E temp root proving the command ran;
2. writes relevant `RTERM_*` environment variables to a test file;
3. then `exec`s an interactive shell so the session stays alive.

Verify:

- [ ] marker exists;
- [ ] launch command started in the Project directory;
- [ ] `RTERM_PROJECT_ID`, `RTERM_PROJECT_PATH`, `RTERM_SESSION_ID`, `RTERM_SESSION_NAME`, and `RTERM_REMOTE` are populated correctly;
- [ ] the terminal is interactive after launch.

### AC-08 — worktree-style launcher compatibility

On **at least one** live remote (prefer Ubuntu; repeat on macOS if inexpensive):

1. create an isolated Git repo inside the E2E temp root;
2. commit one file;
3. configure a Project launch command/script that creates a Git worktree **inside the E2E temp root**, `cd`s into it, writes a marker, and then `exec`s an interactive shell;
4. create a session.

Verify:

- [ ] worktree was created;
- [ ] terminal's `pwd` is the worktree path after launcher execution;
- [ ] no production/user repo was touched;
- [ ] cleanup removes the worktree and temp repo.

This proves the generic launch-command mechanism supports the intended “worktree + coding agent” workflow without any agent-specific feature.

### AC-09 — detach semantics

On each live host:

1. create a session;
2. start a long-running benign process in it (e.g. a loop that increments a counter file inside the E2E temp root every second);
3. switch to another sidebar item so the local SSH terminal attachment closes;
4. wait;
5. verify independently over SSH that:
   - tmux session still exists;
   - process/counter continued advancing.

- [ ] Switching sessions does not kill tmux.

### AC-10 — reconnect after forced local disconnect

On each live host:

1. attach to an E2E session;
2. force-kill **only the local SSH child process** used by the terminal attachment;
3. leave the remote tmux session untouched;
4. allow reconnect logic to run.

Verify:

- [ ] remote process remained alive;
- [ ] app reattached to the exact same tmux session;
- [ ] no duplicate tmux session was created;
- [ ] terminal becomes interactive again.

### AC-11 — app quit/relaunch persistence

On each live host:

1. create a session running a benign long-lived process;
2. quit the app entirely;
3. verify over ordinary SSH that the tmux session remains alive;
4. relaunch the app;
5. refresh/select the Project;
6. select the existing Session.

Verify:

- [ ] session is rediscovered;
- [ ] reattachment succeeds;
- [ ] same process is still running;
- [ ] no new session was created during recovery.

### AC-12 — explicit kill

On each live host:

- [ ] Kill Session requires explicit confirmation.
- [ ] It kills only the selected app-managed tmux session.
- [ ] `tmux has-session -t <id>` subsequently fails for that session.
- [ ] Another unrelated tmux session created specifically as a test control remains alive.

The control session must be removed during cleanup.

### AC-13 — existing user tmux safety

Before destructive E2E operations, snapshot the names/IDs of pre-existing tmux sessions on each host.

After the full test and cleanup:

- [ ] every pre-existing tmux session still exists exactly as before unless the user independently changed it;
- [ ] the app never invokes `tmux kill-server`;
- [ ] app session discovery does not adopt unrelated sessions.

### AC-14 — remote cleanup

After E2E on both hosts:

- [ ] no `@rterm_e2e_run=<run-id>` tmux sessions remain;
- [ ] no E2E temp roots remain;
- [ ] no shell/tmux/SSH config file changed;
- [ ] no package was installed;
- [ ] no helper binary was uploaded;
- [ ] no Ghostty terminfo was installed;
- [ ] no user project/repo outside the temp roots was modified.

---

## 23. Acceptance criteria — P0 architecture/safety

### AC-15 — runtime boundary

- [ ] SwiftUI views do not import/reference `tmux` command construction.
- [ ] SwiftUI views do not construct SSH argv.
- [ ] `Project` uses a provider/workspace reference rather than a raw concrete SSH connection struct.
- [ ] A fake `RuntimeProvider` can drive Project/Session view-model tests without SSH installed.
- [ ] `SSHTmuxRuntimeProvider` is the only production module that knows the combined SSH+tmux lifecycle.

### AC-16 — future provider friendliness

Code review can answer “yes” to:

> Could we add `E2BRuntimeProvider` later without rewriting the sidebar, Project model, New Session UI, or Session row UI?

It is acceptable that terminal attachment plumbing gains an additional transport type later. It is not acceptable that core views assume `tmuxSessionName` or `sshHost` are universal domain properties.

### AC-17 — no remote install

Search code and live-test logs:

- [ ] no `brew install`/`apt install`/`dnf`/package-manager invocation;
- [ ] no `scp`/SFTP upload of app executables;
- [ ] no remote `tic` terminfo install;
- [ ] no dotfile writes.

### AC-18 — shell injection safety

Automated unit/integration tests prove that a Project path containing spaces and `'` characters is handled safely.

Session display names containing shell metacharacters such as:

```text
fix $PATH; echo nope ' "
```

must not execute unintended remote shell code.

The generated opaque tmux session ID must contain no user-provided text.

---

## 24. Acceptance criteria — P1 quality

These should pass before calling the app pleasant to use, but a temporary P1 miss does not justify breaking P0 simplicity.

### AC-19 — app responsiveness

- [ ] No SSH call blocks the main thread.
- [ ] App window/sidebar appears immediately even if both remotes are offline.
- [ ] Expanding/selecting an offline Project yields an async error rather than a beachball.

### AC-20 — resource use

Measure a Release build on Apple Silicon:

- [ ] with no terminal attached, sustained idle CPU is <1%;
- [ ] with one idle terminal attached, sustained idle CPU is approximately <1% outside short renderer spikes;
- [ ] one-session memory is measured and documented; target <150 MB;
- [ ] switching among 10 existing remote sessions does not leave 10 live SSH child processes or hidden Metal surfaces behind.

### AC-21 — TERM compatibility

On both live remotes:

- [ ] no `unknown terminal type: xterm-ghostty` / `missing or unsuitable terminal` error;
- [ ] basic color terminal programs work;
- [ ] tmux attach works without installing remote terminfo.

### AC-22 — crash/error recovery

- [ ] Killing the selected remote tmux session externally causes the app to transition to ended/error rather than creating a replacement automatically.
- [ ] Restoring network availability allows Retry/reconnect.
- [ ] Corrupt local Project state fails recoverably and does not trigger destructive remote operations.

### AC-23 — archive lifecycle

On each live host, using only the isolated E2E namespace:

1. create an app-managed Session;
2. attach to it;
3. choose **Archive Session…** with no shutdown hook configured.

Verify:

- [ ] local interactive SSH attachment closes;
- [ ] selected remote tmux session no longer exists;
- [ ] Session disappears from the active sidebar after refresh/reconciliation;
- [ ] unrelated tmux sessions remain untouched;
- [ ] no files are deleted by the app itself.

### AC-24 — shutdown hook / worktree cleanup

On at least one live host (repeat on both if inexpensive):

1. create an isolated Git repo inside the E2E temp root;
2. configure a launch script that creates a worktree at a deterministic path based on `RTERM_SESSION_ID`, enters it, writes a marker, and then `exec`s an interactive shell;
3. configure a shutdown script that validates all paths are still inside the E2E temp root, records the received `RTERM_*` values, and removes that worktree **without using `--force`**;
4. create and attach the Session;
5. choose **Archive Session…**.

Verify:

- [ ] tmux session is terminated before the shutdown script performs cleanup;
- [ ] shutdown hook receives the correct Project/Session context and `RTERM_SHUTDOWN_REASON=archive`;
- [ ] worktree is removed;
- [ ] Session disappears from the active sidebar only after cleanup succeeds;
- [ ] no repository/path outside the E2E temp root is touched.

Then test a deliberate shutdown-hook failure:

- [ ] the tmux session remains terminated;
- [ ] the UI reports **Cleanup Failed** and provides **Retry Cleanup** and **Dismiss**;
- [ ] Retry Cleanup can succeed after the test condition is corrected;
- [ ] **Kill Session…** never runs the shutdown hook.

---

## 25. Manual UX smoke test

After automated/live acceptance, do a short human-style smoke test:

1. Launch app.
2. Confirm both SSH aliases are present.
3. Add a Project on the Mac remote.
4. Add a Project on the Ubuntu remote.
5. Set one Project launch command to `claude` **only if Claude Code is already installed and launching it is safe**; otherwise use a harmless shell command.
6. Create three sessions across the two hosts.
7. Rapidly switch among them.
8. Put the Mac to sleep for ~30 seconds if practical, wake it, and verify selected session reconnects.
9. Quit and reopen app.
10. Confirm sessions are still there and attach correctly.
11. Archive one session from the app; if a safe test shutdown hook is configured, confirm it runs and the session disappears from the active sidebar.
12. Force-kill a different disposable session and confirm its shutdown hook is skipped.
13. Confirm the other sessions continue.
14. Run E2E cleanup and confirm both remotes are clean.

Do not use a real production repository for this smoke test unless explicitly requested.

---

## 26. Build/release expectations

### 26.1 Reproducible libghostty pin

The repository must make it obvious which Ghostty source revision is linked.

A new engineer should be able to clone the repository, fetch the pinned Ghostty source, build the required library/XCFramework, and build the app from documented commands.

### 26.2 Release configuration

- build Release with compiler optimization;
- no debug logging in hot terminal paths;
- no telemetry SDK;
- no crash-reporting SDK in v1 unless explicitly approved;
- no bundled remote helper.

### 26.3 Signing

Development signing is sufficient while building v1. For external distribution, use a normal Apple Developer ID + notarization flow rather than instructing users to permanently bypass Gatekeeper. This is distribution work, not a reason to delay core v1 development.

---

## 27. Definition of done

v1 is done when:

1. The app builds as a native Swift macOS application with a libghostty/Metal terminal.
2. It automatically discovers the user's SSH aliases.
3. The user can attach Projects (remote folders) beneath aliases.
4. The user can configure a per-Project launch command.
5. Creating a Session creates a vanilla remote tmux session and attaches to it.
6. Switching/closing/quitting detaches locally while work keeps running remotely.
7. Selecting an existing Session reliably reattaches.
8. Killing a Session is explicit and targets only that tmux session.
9. The UI/domain talks to the runtime abstraction, not directly to SSH/tmux.
10. Live E2E acceptance passes on both the configured macOS and Ubuntu remotes.
11. The live tests leave no E2E sessions/files/config modifications on either remote.
12. The app is measurably lightweight and does not grow into an IDE.

---

## 28. Future direction (context only — do not implement)

The architecture should leave room for:

```text
Remote/Workspace Provider
├── SSH + tmux
├── Daytona
└── E2B
```

A future ephemeral-provider flow might be:

```text
Project configured with Daytona template
        ↓
New Session
        ↓
No live workspace exists
        ↓
Provider provisions workspace
        ↓
repo/bootstrap happens
        ↓
provider creates persistent process/session
        ↓
terminal attaches
```

The same Project/Session UI should remain conceptually intact.

Possible future capabilities:

- create/destroy ephemeral workspace;
- suspend/resume;
- snapshots;
- port forwarding;
- provider account credentials via Keychain;
- per-Project launch profiles;
- automatic worktree management;
- coding-agent attention indicators;
- multiple terminal panes.

None of these belong in v1.

---

## 29. Technical references for the engineering agent

Use these as implementation references, not as product dependencies unless explicitly chosen after review:

- Ghostty official repository / libghostty source: https://github.com/ghostty-org/ghostty
- Ghostty build documentation: https://ghostty.org/docs/install/build
- Ghostty SSH/TERM behavior: https://ghostty.org/docs/features/ssh
- Ghostty terminfo notes: https://ghostty.org/docs/help/terminfo
- Ghostling, official minimal libghostty example: https://github.com/ghostty-org/ghostling

Important current upstream facts:

- Ghostty's macOS app is itself a native Swift application consuming Ghostty's core/libghostty APIs.
- The macOS renderer is Metal-based.
- libghostty is intended for embedding, but its public API/versioning is still evolving; pin the exact source revision and isolate it behind an adapter.
- `xterm-ghostty` terminfo is not guaranteed to exist on arbitrary SSH remotes; v1 intentionally uses `TERM=xterm-256color` for the SSH terminal child to avoid mutating remote hosts.

---

## 30. Final implementation bias

When choosing between two designs, prefer the one that keeps this invariant true:

> If `/usr/bin/ssh <alias>` works and `tmux` exists on the remote, the app should work without changing the remote machine.

And keep the product narrow:

> **Remote → Project → persistent Session → excellent terminal.**

Everything else can come later.
