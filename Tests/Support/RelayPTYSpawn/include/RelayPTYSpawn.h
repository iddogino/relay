#ifndef RELAY_PTY_SPAWN_H
#define RELAY_PTY_SPAWN_H

#include <sys/types.h>

/// Starts `path` with `argv`/`envp` as the session leader of a new
/// session whose controlling terminal is the pty slave `slave_fd` (also
/// its stdin, stdout and stderr), in `cwd` if non-NULL. The parent's
/// copy of `slave_fd` is left open. Returns the child's pid, or -1 with
/// errno set. Test support only: Swift can't fork, and posix_spawn can't
/// give a child a controlling terminal, which job control and SIGWINCH
/// need.
pid_t relay_spawn_on_pty(const char *path,
                         char *const argv[],
                         char *const envp[],
                         int slave_fd,
                         const char *cwd);

#endif
