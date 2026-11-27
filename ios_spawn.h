#ifndef IOS_SPAWN_H
#define IOS_SPAWN_H
#include <sys/types.h>
#include <stddef.h>
#include <sys/resource.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Isolated worker processes inherit only stdin, stdout and stderr. */
typedef struct { int source, target; } ios_spawn_action;
typedef struct {
    ios_spawn_action *actions;
    size_t count;
    char *cwd;
} ios_posix_spawn_file_actions_t;
int ios_posix_spawn_file_actions_init(ios_posix_spawn_file_actions_t *);
int ios_posix_spawn_file_actions_destroy(ios_posix_spawn_file_actions_t *);
int ios_posix_spawn_file_actions_adddup2(ios_posix_spawn_file_actions_t *, int, int);
int ios_posix_spawn_file_actions_addclose(ios_posix_spawn_file_actions_t *, int);
int ios_posix_spawn_file_actions_addchdir_np(ios_posix_spawn_file_actions_t *, const char *);
int ios_posix_spawn(pid_t *, const char *, const ios_posix_spawn_file_actions_t *, const void *, char *const [], char *const []);
/* Probe an unreaped worker with signal 0, or request broker cancellation with
 * SIGHUP, SIGINT, SIGQUIT, SIGKILL or SIGTERM. Returns an errno value (0 on
 * success). Never sends a host signal. Like wait, this requires ownership of
 * the returned PID and an unreaped child. */
#define IOS_WORKER_KILL_SUPPORTED 1
int ios_kill_worker(pid_t, int);
/* Reap an ios_posix_spawn PID; options is 0 or WNOHANG. Returns PID, 0 while
 * running, or -1 with errno. Even after cancellation, the caller must reap the
 * child to release its PID. For status without usage, waitpid and
 * ios_full_waitpid also reap a positive worker PID. They accept WUNTRACED
 * and WCONTINUED, but workers report termination only. ios_waitpid only
 * blocks. Only one waiter may reap a child. Status uses waitpid
 * encoding (acknowledged ios_kill_worker cancellation: signal termination;
 * legacy ios_killpid cancellation: exit 128 + signal; worker transport
 * failure: exit 125).
 * Optional usage is the isolated worker's RUSAGE_SELF snapshot at command exit,
 * including process startup. availability is required when usage is requested;
 * zero means unavailable (including cancellation), never a measured zero. */
pid_t ios_wait4(pid_t, int *, int, struct rusage *, int *availability);
#ifdef __cplusplus
}
#endif
#endif
