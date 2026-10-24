#include "RelayPTYSpawn.h"

#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

pid_t relay_spawn_on_pty(const char *path,
                         char *const argv[],
                         char *const envp[],
                         int slave_fd,
                         const char *cwd) {
    pid_t pid = fork();
    if (pid != 0) return pid;

    // Child: only async-signal-safe calls from here to exec.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    struct sigaction dfl = {0};
    dfl.sa_handler = SIG_DFL;
    for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &dfl, NULL);

    if (setsid() < 0) _exit(126);
    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) _exit(126);
    if (dup2(slave_fd, 0) < 0 || dup2(slave_fd, 1) < 0 || dup2(slave_fd, 2) < 0) _exit(126);
    if (slave_fd > 2) close(slave_fd);
    // Don't leak the test process's descriptors (e.g. other ptys, which
    // would keep them open past their programs).
    int max_fd = getdtablesize();
    for (int fd = 3; fd < max_fd; fd++) close(fd);
    if (cwd != NULL && chdir(cwd) < 0) _exit(126);
    execve(path, argv, envp);
    _exit(127);
}
