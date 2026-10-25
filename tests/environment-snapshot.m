#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

extern int ios_execve(const char *, char *const [], char **);
static int ready[2], proceed[2];
static pid_t identities[2];
static int failures[2];

int snapshot_command(int argc, char **argv) {
    int index = atoi(argv[1]);
    const char *expected = index ? "second" : "first";
    identities[index] = ios_currentPid();
    const char *held = ios_getenv("SNAPSHOT_PROBE");
    char **heldEnvironment = environmentVariables(identities[index]);
    if (!held || strcmp(held, expected)) return 2;
    char byte;
    if (write(ready[1], "x", 1) != 1 || read(proceed[0], &byte, 1) != 1) return 3;
    failures[index] = ios_currentPid() != identities[index] ||
        !ios_getenv("SNAPSHOT_PROBE") || strcmp(ios_getenv("SNAPSHOT_PROBE"), expected);
    // Returned pointers survive replacement, removal, and another environment query.
    if (ios_setenv("SNAPSHOT_PROBE", "replacement-value-longer-than-original", 1) ||
        ios_unsetenv("SNAPSHOT_PROBE") || ios_setenv("ANOTHER_PROBE", "present", 1)) return 4;
    if (!ios_getenv("ANOTHER_PROBE")) return 5;
    failures[index] |= strcmp(held, expected) != 0;
    bool found = false;
    for (size_t i = 0; heldEnvironment[i]; i++) {
        if (!strncmp(heldEnvironment[i], "SNAPSHOT_PROBE=", 15)) {
            found = !strcmp(heldEnvironment[i] + 15, expected);
        }
    }
    failures[index] |= !found;
    return failures[index];
}
static void timedOut(int signalNumber) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("environment-snapshot");
        ios_setStreams(stdin, stdout, stderr); joinMainThread = false;
        replaceCommand(@"snapshot-command", @"snapshot_command", false);
        if (pipe(ready) || pipe(proceed)) return 2;
        pid_t root = ios_currentPid(), children[2];
        for (int i = 0; i < 2; i++) {
            char *arguments[] = {"snapshot-command", i ? "1" : "0", NULL};
            char *values[] = {i ? "SNAPSHOT_PROBE=second" : "SNAPSHOT_PROBE=first", NULL};
            children[i] = ios_fork();
            ios_execve(arguments[0], arguments, values);
            char byte;
            if (read(ready[0], &byte, 1) != 1) return 3;
        }
        if (write(proceed[1], "xx", 2) != 2) return 4;
        bool passed = ios_currentPid() == root;
        for (int i = 0; i < 2; i++) {
            int status;
            passed &= ios_full_waitpid(children[i], &status, 0) == children[i] && !status;
            passed &= identities[i] == children[i] && !failures[i];
        }
        dprintf(2, "legacy identity and environment pointer lifetime: %s\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
