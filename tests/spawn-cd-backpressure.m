#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int ready[2], output[2];
static FILE *blockedError;
static int write_diagnostic(void *context, const char *buffer, int count) {
    if (write(ready[1], "R", 1) != 1) return -1;
    return (int)write(*(int *)context, buffer, (size_t)count);
}
int cd_probe_leaf(int argc, char **argv) { return 23; }
int cd_probe_driver(int argc, char **argv) {
    char *arguments[] = {"cd-probe-leaf", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    int status = 0;
    bool passed = !error && ios_full_waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 23;
    dprintf(2, "CD_BACKPRESSURE launch_error=%d status=%d %s\n", error, status, passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void *run_cd(void *unused) {
    @autoreleasepool {
        ios_switchSession("cd-blocked");
        ios_setStreams(stdin, stdout, blockedError);
        ios_system("cd /nonexistent-directory-cd-backpressure");
        return NULL;
    }
}
static void timedOut(int number) { dprintf(2, "CD_BACKPRESSURE watchdog FAIL\n"); _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(ready) || pipe(output)) return 2;
        fcntl(output[1], F_SETFL, O_NONBLOCK);
        char buffer[1024] = {0};
        while (write(output[1], buffer, sizeof(buffer)) > 0) {}
        if (errno != EAGAIN) return 3;
        fcntl(output[1], F_SETFL, 0);
        blockedError = funopen(&output[1], NULL, write_diagnostic, NULL, NULL);
        setvbuf(blockedError, NULL, _IONBF, 0);
        initializeEnvironment(); ios_switchSession("cd-blocked"); ios_switchSession("cd-other");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"cd-probe-leaf", @"cd_probe_leaf", false);
        replaceCommand(@"cd-probe-driver", @"cd_probe_driver", false);
        joinMainThread = true;
        pthread_t cdThread;
        if (pthread_create(&cdThread, NULL, run_cd, NULL)) return 4;
        char byte;
        if (read(ready[0], &byte, 1) != 1) return 5;
        int result = ios_system("cd-probe-driver");
        read(output[0], buffer, sizeof(buffer));
        pthread_join(cdThread, NULL);
        return result ? 1 : 0;
    }
}
