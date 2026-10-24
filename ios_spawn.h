#ifndef IOS_SPAWN_H
#define IOS_SPAWN_H
#include <sys/types.h>
#include <stddef.h>
#include <sys/resource.h>
#include <pthread.h>
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
/* Wait for an ios_posix_spawn PID; options is 0 or WNOHANG. Returns PID, 0 while
 * running, or -1 with errno. Status uses waitpid encoding (ios_killpid with SIGINT, SIGTERM, SIGKILL, SIGHUP or SIGQUIT: exit 128 + signal; worker transport failure: exit 125).
 * Optional usage is the isolated worker's RUSAGE_SELF snapshot at command exit,
 * including process startup. availability is required when usage is requested;
 * zero means unavailable (including cancellation), never a measured zero. */
pid_t ios_wait4(pid_t, int *, int, struct rusage *, int *availability);

enum {
    IOS_SPAWN_CANCEL_INPUT = 1,
    IOS_SPAWN_CANCEL_OUTPUT = 2,
    IOS_SPAWN_CANCEL_ERROR = 4
};

typedef struct {
    int input;
    int output;
    int error;
    const char *directory;
    // Channels belonging to this child, eligible for shutdown on cancellation.
    unsigned cancelStreams;
} ios_spawn_options;

// Launch from a running native command; path must equal argv[0].
// NULL options borrow its streams and inherit cwd; NULL envp inherits environment.
// Explicit stream descriptors are duplicated; the caller retains its originals.
// Arguments are copied without shell parsing. The current directory is per-process,
// like other ios_system commands. A supplied directory is restored at child cleanup;
// concurrent commands and session changes share it. Use absolute paths when needed.
// Return 0 after launch or an error number; reap once with ios_full_waitpid.
int ios_spawn(pid_t *pid, const char *path, const ios_spawn_options *options,
              char *const argv[], char *const envp[]);

// Create a cancellable byte channel: descriptors[0] reads, descriptors[1] writes.
// The caller owns both descriptors. Cancel shuts down the child stream endpoints.
// Return 0, or -1 with errno set, like pipe(2).
int ios_spawn_pipe(int descriptors[2]);

// Cancel command channels and the command tree; wait still reaps the command.
int ios_spawn_cancel(pid_t pid);

// Return whether the running command was cancelled or is finishing. Helpers may
// disable pthread cancellation and poll this at points where they hold no locks.
int ios_command_cancelled(void);

// Borrow the running command's environment until its next environment mutation.
// Unforked roots use the host environment rather than another session's PID.
char **ios_command_environment(void);

// Create a library helper thread with the current command's PID, environment,
// session and borrowed streams. The command retains its context until helpers
// exit and cancels them during command cleanup. Normal pthread join/attr rules apply.
int ios_command_thread_create(pthread_t *thread, const pthread_attr_t *attributes,
                              void *(*function)(void *), void *argument);

#ifdef __cplusplus
}
#endif
#endif
