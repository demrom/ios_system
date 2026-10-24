#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
int logReady[2], logGate[2];
atomic_bool holdLog;
int logging_child(int argc, char **argv) { ios_stopInteractive(); return 17; }
int logging_parent(int argc, char **argv) {
    atomic_store(&holdLog, true);
    char *arguments[] = {"logging-child", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 2;
    struct pollfd ready = {logReady[0], POLLIN, 0};
    if (poll(&ready, 1, 5000) != 1 || ios_spawn_cancel(child)) return 3;
    if (write(logGate[1], "G", 1) != 1) return 4;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 5;
    bool passed = WIFEXITED(status) && WEXITSTATUS(status) == 130;
    dprintf(2, "LOG_CANCEL status=%d %s\n", status, passed ? "PASS" : "FAIL");
    return passed ? 0 : 6;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        if (pipe(logReady) || pipe(logGate)) return 2;
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("log-cancellation"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"logging-child", @"logging_child", false);
        replaceCommand(@"logging-parent", @"logging_parent", false);
        joinMainThread = true;
        return ios_system("logging-parent") ? 1 : 0;
    }
}
