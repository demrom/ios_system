#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <unistd.h>

static int firstReady[2], firstGate[2], childReady[2], childGate[2], firstDone[2];
static pid_t firstPid;
static int firstStatus;
int reaping_first(int argc, char **argv) {
    char byte;
    write(firstReady[1], "R", 1);
    return read(firstGate[0], &byte, 1) == 1 ? 0 : 2;
}
int reaping_child(int argc, char **argv) {
    char byte;
    write(childReady[1], "R", 1);
    return read(childGate[0], &byte, 1) == 1 ? 23 : 3;
}
int reaping_second(int argc, char **argv) {
    char *arguments[] = {"reaping-child", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    int status;
    return ios_full_waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 23 ? 0 : 4;
}
static void *wait_first(void *unused) {
    if (ios_full_waitpid(firstPid, &firstStatus, 0) == firstPid)
        write(firstDone[1], "D", 1);
    return NULL;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(firstReady) || pipe(firstGate) || pipe(childReady) || pipe(childGate) || pipe(firstDone)) return 2;
        initializeEnvironment(); ios_switchSession("reaping-first"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"reaping-first", @"reaping_first", false);
        replaceCommand(@"reaping-second", @"reaping_second", false);
        replaceCommand(@"reaping-child", @"reaping_child", false);
        joinMainThread = false;
        firstPid = ios_fork(); ios_system("reaping-first");
        char byte;
        if (read(firstReady[0], &byte, 1) != 1) return 3;
        ios_switchSession("reaping-second"); ios_setStreams(stdin, stdout, stderr);
        pid_t second = ios_fork(); ios_system("reaping-second");
        if (read(childReady[0], &byte, 1) != 1) return 4;
        pthread_t waiter;
        if (pthread_create(&waiter, NULL, wait_first, NULL)) return 5;
        if (write(firstGate[1], "G", 1) != 1) return 6;
        struct pollfd completion = {firstDone[0], POLLIN, 0};
        int early = poll(&completion, 1, 250);
        if (write(childGate[1], "G", 1) != 1) return 7;
        int secondStatus;
        if (ios_full_waitpid(second, &secondStatus, 0) != second) return 8;
        pthread_join(waiter, NULL);
        bool passed = early == 1 && WIFEXITED(firstStatus) && !WEXITSTATUS(firstStatus) && WIFEXITED(secondStatus) && !WEXITSTATUS(secondStatus);
        dprintf(2, "session A cleanup leaves session B child running: early=%d %s\n", early, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
