#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

static int rootGate[2];
static bool waitForRootGate;
int binding_first(int argc, char **argv) { return 7; }
int binding_second(int argc, char **argv) { return 23; }
int binding_branch(int argc, char **argv) {
    pid_t original = ios_currentPid();
    pid_t first = ios_fork();
    if (first < 0) return 2;
    ios_system("binding-first");
    pid_t second = ios_fork();
    if (second < 0) return 3;
    ios_system("binding-second");
    int firstStatus, secondStatus;
    if (ios_full_waitpid(first, &firstStatus, 0) != first || WEXITSTATUS(firstStatus) != 7) return 4;
    if (ios_full_waitpid(second, &secondStatus, 0) != second || WEXITSTATUS(secondStatus) != 23) return 5;
    pid_t observed = ios_currentPid();
    dprintf(2, "native caller after two legacy launches/waits: expected=%d observed=%d\n", original, observed);
    return original == observed ? 0 : 6;
}
int binding_parent(int argc, char **argv) {
    if (waitForRootGate) {
        char ready;
        if (read(rootGate[0], &ready, 1) != 1) return 8;
    }
    char *arguments[] = {"binding-branch", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 7;
    return WEXITSTATUS(status);
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-legacy-pid");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"binding-parent", @"binding_parent", false);
        replaceCommand(@"binding-branch", @"binding_branch", false);
        replaceCommand(@"binding-first", @"binding_first", false);
        replaceCommand(@"binding-second", @"binding_second", false);
        joinMainThread = true;
        int result = ios_system("binding-parent");
        dprintf(2, "native caller PID survives legacy pipeline dispatch: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        if (result) return 1;
        if (pipe(rootGate)) return 2;
        char output[] = "/private/tmp/native-legacy-pid-XXXXXX";
        int descriptor = mkstemp(output);
        if (descriptor < 0) return 3;
        close(descriptor);
        waitForRootGate = true;
        joinMainThread = false;
        pid_t root = ios_fork();
        if (root < 0) return 4;
        char command[PATH_MAX];
        snprintf(command, sizeof(command), "binding-parent > %s", output);
        ios_system(command);
        if (write(rootGate[1], "R", 1) != 1) return 5;
        int status;
        pid_t waited = ios_full_waitpid(root, &status, 0);
        close(rootGate[0]); close(rootGate[1]); unlink(output);
        bool passed = waited == root && WIFEXITED(status) && WEXITSTATUS(status) == 0;
        dprintf(2, "asynchronous session root survives native legacy descendants: %s\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 6;
    }
}
