#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
static bool inheritedLeak;
int environment_leaf(int argc, char **argv) { return 0; }
int environment_returning_parent(int argc, char **argv) {
    if (ios_setenv("RETURNED_ROOT_LEAK", "private", 1)) return 2;
    char *arguments[] = {"environment-leaf", NULL};
    pid_t child;
    int status;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 3;
    return ios_full_waitpid(child, &status, 0) == child && !status ? 0 : 4;
}
int environment_next_root(int argc, char **argv) {
    inheritedLeak = ios_getenv("RETURNED_ROOT_LEAK") != NULL;
    return inheritedLeak ? 1 : 0;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        unsetenv("RETURNED_ROOT_LEAK");
        initializeEnvironment(); ios_switchSession("legacy-environment-return");
        ios_setStreams(stdin, stdout, stderr); joinMainThread = true;
        replaceCommand(@"environment-leaf", @"environment_leaf", false);
        replaceCommand(@"returning-parent", @"environment_returning_parent", false);
        replaceCommand(@"next-root", @"environment_next_root", false);
        pid_t before = ios_currentPid();
        pid_t root = ios_fork();
        int first = ios_system("returning-parent"); ios_waitpid(root);
        pid_t after = ios_currentPid();
        root = ios_fork();
        int second = ios_system("next-root"); ios_waitpid(root);
        bool passed = !first && !second && !inheritedLeak && before == after;
        dprintf(2, "LEGACY_ENV_RETURN before=%d after=%d leaked=%d %s\n", before, after, inheritedLeak, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
