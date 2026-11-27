// Register in a disposable worker-enabled host; pass its HOME as argv[1].
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <dispatch/dispatch.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static dispatch_semaphore_t ready;
static void receivedInterrupt(int number) { interrupted = 1; }
static void *ordinaryThread(void *unused) {
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGINT);
    pthread_sigmask(SIG_UNBLOCK, &signals, NULL);
    ios_storeThreadId(pthread_self());
    dispatch_semaphore_signal(ready);
    for (int n = 0; n < 100 && !interrupted; n++) usleep(10000);
    return NULL;
}
static int checkExhaustion(const char *home, char **environment, char **command) {
    char *marker;
    if (asprintf(&marker, "%s/spawn-exhaust-XXXXXX", home) < 0) return 1;
    int fd = mkstemp(marker);
    if (fd < 0) { free(marker); return 1; }
    close(fd);
    if (unlink(marker)) { free(marker); return 1; }
    pid_t children[256];
    size_t count = 0;
    int error = 0;
    for (; count < sizeof(children) / sizeof(children[0]); ++count) {
        error = ios_posix_spawn(&children[count], command[0], NULL, NULL, command, environment);
        if (error) break;
        // Complete each worker before starting another, so the broker's worker limit is not the PID limit.
        ios_waitpid(children[count]);
    }
    if (!count || error != EAGAIN) {
        fprintf(thread_stderr, "worker PID exhaustion: FAIL (count=%zu spawn=%d)\n", count, error);
        free(marker);
        return 1;
    }

    // An absent cwd distinguishes an early EAGAIN from attempting broker admission.
    ios_posix_spawn_file_actions_t actions;
    ios_posix_spawn_file_actions_init(&actions);
    int setup = ios_posix_spawn_file_actions_addchdir_np(&actions, marker);
    pid_t excess = -1;
    int fullInvalidCwd = setup ? setup : ios_posix_spawn(&excess, command[0], &actions, NULL, command, environment);
    char *writeMarker[] = { "dash", "-c", ": > \"$1\"", "dash", marker, NULL };
    int fullValidCwd = ios_posix_spawn(&excess, writeMarker[0], NULL, NULL, writeMarker, environment);
    BOOL notAdmitted = fullInvalidCwd == EAGAIN && fullValidCwd == EAGAIN;

    // Rescue a blocked allocator after a bounded delay so the original bug yields a receipt.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_group_t watchdog = dispatch_group_create();
    pid_t first = children[0];
    __block BOOL rescued = NO;
    dispatch_group_async(watchdog, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) {
            rescued = YES;
            ios_wait4(first, NULL, 0, NULL, NULL);
        }
    });
    errno = 0;
    pid_t attempt = ios_fork();
    int savedError = errno;
    if (attempt > 0) ios_storeThreadId(NULL);
    dispatch_semaphore_signal(done);
    dispatch_group_wait(watchdog, DISPATCH_TIME_FOREVER);

    int status = -1;
    BOOL reaped = rescued || (ios_wait4(first, &status, 0, NULL, NULL) == first &&
                             WIFEXITED(status) && WEXITSTATUS(status) == 7);
    BOOL noMarker = access(marker, F_OK) == -1 && errno == ENOENT;
    if (!noMarker) unlink(marker);
    // Only one slot is free: a failed admission must return it for the next spawn.
    int rejected = setup ? setup : ios_posix_spawn(&excess, command[0], &actions, NULL, command, environment);
    ios_posix_spawn_file_actions_destroy(&actions);
    int next = ios_posix_spawn(&excess, command[0], NULL, NULL, command, environment);
    status = -1;
    BOOL rolledBack = rejected != 0 && rejected != EAGAIN && next == 0 &&
                      ios_wait4(excess, &status, 0, NULL, NULL) == excess &&
                      WIFEXITED(status) && WEXITSTATUS(status) == 7;
    for (size_t n = 1; n < count; ++n) {
        if (ios_wait4(children[n], &status, 0, NULL, NULL) != children[n] ||
            !WIFEXITED(status) || WEXITSTATUS(status) != 7) reaped = NO;
    }
    pid_t recovered = ios_fork();
    if (recovered > 0) ios_storeThreadId(NULL);
    BOOL passed = !rescued && attempt == -1 && savedError == EAGAIN && reaped && recovered > 0 &&
                  notAdmitted && noMarker && rolledBack;
    fprintf(thread_stdout, "unreaped worker PID exhaustion: %s (children=%zu blocked=%d fork=%d EAGAIN=%d reaped=%d recovered=%d invalidCwd=%d validCwd=%d noMarker=%d rollback=%d)\n",
            passed ? "PASS" : "FAIL", count, rescued, attempt, savedError == EAGAIN, reaped, recovered > 0,
            fullInvalidCwd, fullValidCwd, noMarker, rolledBack);
    free(marker);
    return passed ? 0 : 1;
}

static int checkFullWait(pid_t child) {
    int status = -1;
    pid_t waited = ios_full_waitpid(child, &status, 0);
    int secondStatus = -1;
    pid_t secondWait = ios_wait4(child, &secondStatus, WNOHANG, NULL, NULL);
    BOOL consumed = secondWait == -1 && errno == ECHILD;
    BOOL passed = waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 7 && consumed;
    fprintf(thread_stdout, "legacy wait reaps worker PID: %s (child=%d waited=%d status=%d consumed=%d)\n",
            passed ? "PASS" : "FAIL", child, waited, status, consumed);
    return passed ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 64;
    BOOL exhaust = argc == 3 && !strcmp(argv[2], "exhaust");
    BOOL fullWait = argc == 3 && !strcmp(argv[2], "full-wait");
    if (argc == 3 && !exhaust && !fullWait) return 64;
    interrupted = 0;
    char *home;
    if (asprintf(&home, "HOME=%s", argv[1]) < 0) return 1;
    char *environment[] = { home, NULL }, *command[] = { "dash", "-c", "exit 7", NULL };
    if (exhaust) {
        int result = checkExhaustion(argv[1], environment, command);
        free(home);
        return result;
    }
    alarm(30);
    pid_t child = -1;
    int status = -1;
    int error = ios_posix_spawn(&child, command[0], NULL, NULL, command, environment);
    free(home);
    if (error) {
        fprintf(thread_stderr, "ios_posix_spawn failed: %d\n", error);
        return 1;
    }
    if (fullWait) {
        int result = checkFullWait(child);
        alarm(0);
        return result;
    }
    // Let the worker and its proxy finish without consuming its exit status.
    for (int n = 0; n < 500 && ios_getThreadId(child) != 0; n++) usleep(10000);
    if (ios_getThreadId(child) != 0) return 1;

    BOOL reusedBeforeWait = NO;
    for (int n = 0; n < 256; n++) {
        pid_t candidate = ios_fork();
        if (candidate < 0) return 1;
        ios_storeThreadId(NULL);
        if (candidate == child) {
            reusedBeforeWait = YES;
            break;
        }
    }
    pid_t waited = ios_wait4(child, &status, WNOHANG, NULL, NULL);
    BOOL retained = !reusedBeforeWait && waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 7;
    fprintf(thread_stdout, "unreaped worker PID: %s (reused=%d child=%d waited=%d status=%d)\n",
            retained ? "PASS" : "FAIL", reusedBeforeWait, child, waited, status);
    if (!retained) return 1;
    if (ios_wait4(child, &status, WNOHANG, NULL, NULL) != -1 || errno != ECHILD) {
        fprintf(thread_stderr, "second wait did not fail with ECHILD\n");
        return 1;
    }
    BOOL passed = NO;
    for (int n = 0; n < 256; n++) {
        pid_t candidate = ios_fork();
        if (candidate < 0) return 1;
        if (candidate != child) { ios_storeThreadId(NULL); continue; }
        struct sigaction action = {0}, saved = {0};
        action.sa_handler = receivedInterrupt;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGINT, &action, &saved)) return 1;
        ready = dispatch_semaphore_create(0);
        pthread_t thread;
        if (pthread_create(&thread, NULL, ordinaryThread, NULL)) return 1;
        dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
        BOOL registered = ios_getThreadId(candidate) == thread;
        int killed = ios_killpid(candidate, SIGINT);
        void *result = NULL;
        pthread_join(thread, &result);
        passed = registered && killed == 0 && interrupted && result != PTHREAD_CANCELED;
        fprintf(thread_stdout, "reused=%d child=%d kill=%d signal=%d cancelled=%d registered=%d\n", candidate, child, killed, interrupted, result == PTHREAD_CANCELED, registered);
        ios_releaseThreadId(candidate);
        sigaction(SIGINT, &saved, NULL);
        break;
    }
    fprintf(thread_stdout, "reused worker PID delivers ordinary-thread SIGINT: %s\n", passed ? "PASS" : "FAIL");
    alarm(0);
    return passed ? 0 : 1;
}
