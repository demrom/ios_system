// Register spawn_signal_main in a worker-enabled host; argv[1] is its HOME.
#import "ios_system.h"
#include "ios_spawn.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    char home[sizeof("HOME=") + PATH_MAX];
    int length = snprintf(home, sizeof(home), "HOME=%s", argv[1]);
    if (length < 0 || (size_t)length >= sizeof(home)) return 65;
    char *environment[] = {home, NULL};
    char *sleeper[] = {"sleep", "10", NULL};
    char *normal[] = {"dash", "-c", "exit 143", NULL};
    pid_t child;
    int status = -123;
    if (ios_kill_worker(0, SIGTERM) != ENOTSUP) return 90;
    if (ios_kill_worker(0x7fffffff, 0) != ESRCH) return 91;
    int error = ios_posix_spawn(&child, sleeper[0], NULL, NULL, sleeper, environment);
    if (error) return 92;
    if (ios_kill_worker(child, 0) || ios_wait4(child, &status, WNOHANG, NULL, NULL) || status != -123) return 93;
    if (ios_peek_worker(child) != 0) return 101;
    if (ios_kill_worker(child, SIGUSR1) != ENOTSUP || ios_kill_worker(child, -1) != EINVAL) return 94;
    if (ios_kill_worker(child, SIGTERM)) return 95;
    ios_waitpid(child); // Completion barrier, not a reap.
    if (ios_peek_worker(child) != child || ios_peek_worker(child) != child) return 102;
    if (ios_full_waitpid(child, &status, 0) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) return 96;
    if (ios_kill_worker(child, 0) != ESRCH) return 97;
    if (ios_peek_worker(child) != -1 || errno != ECHILD) return 103;

    error = ios_posix_spawn(&child, normal[0], NULL, NULL, normal, environment);
    if (error) return 98;
    ios_waitpid(child); // Completion barrier, not a reap.
    if (ios_kill_worker(child, SIGTERM) || ios_kill_worker(child, 0)) return 99;
    if (ios_peek_worker(child) != child) return 104;
    if (ios_wait4(child, &status, 0, NULL, NULL) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 143) return 100;
    fprintf(thread_stdout, "worker signal and normal exit distinguished: PASS\n");
    return 0;
}
