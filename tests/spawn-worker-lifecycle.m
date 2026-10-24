// Register in a disposable worker-enabled host; pass its HOME and a test mode.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t delivered;
static void observedSignal(int number) { delivered = 1; }

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    alarm(30);
    ios_setDirectoryURL([NSURL fileURLWithPath:[@(argv[1]) stringByAppendingPathComponent:@"Documents"]]);
    char *home;
    if (asprintf(&home, "HOME=%s", argv[1]) < 0) return 1;
    char *environment[] = {home, NULL};
    if (!strcmp(argv[2], "orphan-parent")) {
        char *command[] = {"sleep", "5", NULL};
        pid_t pid;
        int error = ios_posix_spawn(&pid, command[0], NULL, NULL, command, environment);
        free(home);
        return error ? 2 : 23;
    }
    if (!strcmp(argv[2], "orphan")) {
        char *command[] = {"worker-lifecycle", argv[1], "orphan-parent", NULL};
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        pid_t pid;
        int error = ios_spawn(&pid, command[0], NULL, command, environment);
        int status = -1;
        pid_t waited = error ? -1 : ios_full_waitpid(pid, &status, 0);
        clock_gettime(CLOCK_MONOTONIC, &end);
        double seconds = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
        bool passed = !error && waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 23 && seconds < 3;
        fprintf(thread_stdout, "WORKER_ORPHAN error=%d waited=%d status=%d seconds=%.3f %s\n", error, waited, WIFEXITED(status) ? WEXITSTATUS(status) : -1, seconds, passed ? "PASS" : "FAIL");
        free(home); alarm(0);
        return passed ? 0 : 1;
    }
    if (!strcmp(argv[2], "interrupt")) {
        char *command[] = {"sleep", "30", NULL};
        pid_t pid;
        int error = ios_posix_spawn(&pid, command[0], NULL, NULL, command, environment);
        if (error) return 2;
        int interrupted = ios_interruptpid(pid);
        if (interrupted) ios_killpid(pid, SIGKILL);
        int status = -1;
        pid_t waited = ios_wait4(pid, &status, 0, NULL, NULL);
        bool passed = !interrupted && waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 130;
        fprintf(thread_stdout, "WORKER_INTERRUPT result=%d waited=%d status=%d %s\n", interrupted, waited, WIFEXITED(status) ? WEXITSTATUS(status) : -1, passed ? "PASS" : "FAIL");
        free(home); alarm(0);
        return passed ? 0 : 1;
    }
    if (!strcmp(argv[2], "signal")) {
        char *command[] = {"sleep", "30", NULL};
        pid_t pid;
        int error = ios_posix_spawn(&pid, command[0], NULL, NULL, command, environment);
        if (error) return 2;
        struct sigaction action = {0}, previous;
        action.sa_handler = observedSignal;
        sigemptyset(&action.sa_mask);
        sigaction(SIGUSR1, &action, &previous);
        delivered = 0;
        int probe = ios_killpid(pid, 0);
        int unsupported = ios_killpid(pid, SIGUSR1);
        usleep(50000);
        int observed = delivered;
        ios_killpid(pid, SIGKILL);
        int status;
        pid_t waited = ios_wait4(pid, &status, 0, NULL, NULL);
        sigaction(SIGUSR1, &previous, NULL);
        bool passed = !probe && unsupported == EINVAL && !observed && waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 137;
        fprintf(thread_stdout, "WORKER_SIGNAL probe=%d unsupported=%d handler=%d %s\n", probe, unsupported, observed, passed ? "PASS" : "FAIL");
        free(home); alarm(0);
        return passed ? 0 : 1;
    }
    if (!strcmp(argv[2], "admission")) {
        pid_t held[128];
        int count = 0, error = 0;
        char *missing[] = {"worker-exhaustion-missing-command", NULL};
        while (count < 128) {
            error = ios_spawn(&held[count], missing[0], NULL, missing, NULL);
            if (error) break;
            ++count;
        }
        NSString *marker = [@(argv[1]) stringByAppendingPathComponent:[@"Documents/admission-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        char *touch[] = {"touch", (char *)marker.fileSystemRepresentation, NULL};
        pid_t child = -1;
        int admission = ios_posix_spawn(&child, touch[0], NULL, NULL, touch, environment);
        usleep(500000);
        bool ran = [NSFileManager.defaultManager fileExistsAtPath:marker];
        for (int i = 0; i < count; ++i) ios_full_waitpid(held[i], NULL, 0);
        bool passed = count > 0 && error == EAGAIN && admission == EAGAIN && !ran;
        fprintf(thread_stdout, "WORKER_ADMISSION held=%d exhausted=%d admission=%d ran=%d %s\n", count, error, admission, ran, passed ? "PASS" : "FAIL");
        free(home); alarm(0);
        return passed ? 0 : 1;
    }
    if (strcmp(argv[2], "reap")) return 64;
    char *command[] = {"awk", "BEGIN {exit 23}", NULL};
    pid_t pid;
    int status = -1;
    int error = ios_posix_spawn(&pid, command[0], NULL, NULL, command, environment);
    if (error) return 2;
    bool first = ios_wait4(pid, &status, 0, NULL, NULL) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 23;
    errno = 0;
    pid_t repeated = ios_wait4(pid, &status, WNOHANG, NULL, NULL);
    int repeatedError = errno;
    bool passed = first && repeated == -1 && repeatedError == ECHILD;
    fprintf(thread_stdout, "WORKER_REAP first=%d repeated=%d errno=%d %s\n", first, repeated, repeatedError, passed ? "PASS" : "FAIL");
    free(home);
    alarm(0);
    return passed ? 0 : 1;
}
