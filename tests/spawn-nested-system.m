#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

static int ready[2], releaseChild[2];
static char capture[PATH_MAX];
static bool cancelNested;
int nested_held(int argc, char **argv) {
    char byte;
    if (write(ready[1], "R", 1) != 1 || read(releaseChild[0], &byte, 1) != 1) return 2;
    return 23;
}
int nested_leaf(int argc, char **argv) { fputs("LEAF", thread_stdout); return 0; }
int nested_wait(int argc, char **argv) {
    char byte;
    if (write(ready[1], "R", 1) != 1) return 2;
    read(releaseChild[0], &byte, 1);
    return 0;
}
int nested_parent(int argc, char **argv) {
    char *arguments[] = {"nested-held", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 2;
    char byte;
    if (read(ready[0], &byte, 1) != 1) return 3;
    if (cancelNested) {
        ios_system("nested-wait");
        return read(ready[0], &byte, 1) == 1 ? 17 : 6;
    }
    char command[PATH_MAX + 32];
    snprintf(command, sizeof(command), "nested-leaf > %s", capture);
    int result = ios_system(command);
    bool completed = false;
    for (int attempt = 0; attempt < 1000 && !completed; attempt++) {
        FILE *file = fopen(capture, "r");
        char output[5] = {0};
        if (file) { completed = fread(output, 1, 4, file) == 4 && !strcmp(output, "LEAF"); fclose(file); }
        if (!completed) usleep(1000);
    }
    if (write(releaseChild[1], "C", 1) != 1) return 4;
    int status;
    pid_t waited = ios_full_waitpid(child, &status, 0);
    bool passed = completed && !result && waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 23;
    dprintf(2, "NESTED_SYSTEM completed=%d result=%d waited=%d child=%d status=%d %s\n", completed, result, waited, child, status, passed ? "PASS" : "FAIL");
    return passed ? 17 : 5;
}
int nested_driver(int argc, char **argv) {
    char *arguments[] = {"nested-parent", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 2;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 3;
    dprintf(2, "NESTED_PARENT cancel=%d status=%d %s\n", cancelNested, status, WIFEXITED(status) && WEXITSTATUS(status) == 17 ? "PASS" : "FAIL");
    return WIFEXITED(status) && WEXITSTATUS(status) == 17 ? 0 : 4;
}
static void timedOut(int number) { dprintf(2, "NESTED_SYSTEM watchdog FAIL\n"); _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (pipe(ready) || pipe(releaseChild)) return 2;
        snprintf(capture, sizeof(capture), "%snested-system-XXXXXX", NSTemporaryDirectory().UTF8String);
        int descriptor = mkstemp(capture);
        if (descriptor < 0) return 3;
        close(descriptor);
        signal(SIGALRM, timedOut); alarm(10);
        cancelNested = argc > 1 && !strcmp(argv[1], "cancel");
        initializeEnvironment(); ios_switchSession("nested-system"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"nested-held", @"nested_held", false);
        replaceCommand(@"nested-leaf", @"nested_leaf", false);
        replaceCommand(@"nested-wait", @"nested_wait", false);
        replaceCommand(@"nested-parent", @"nested_parent", false);
        replaceCommand(@"nested-driver", @"nested_driver", false);
        joinMainThread = true;
        int result = ios_system("nested-driver") ? 1 : 0;
        unlink(capture);
        return result;
    }
}
