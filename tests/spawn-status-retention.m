#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
extern void ios_exit(int status);

int retention_first(int argc, char **argv) { return 7; }
int retention_later(int argc, char **argv) { return 23; }
int retention_exit(int argc, char **argv) { ios_exit(31); return 0; }
int retention_parent(int argc, char **argv) {
    int parentStatus = ios_getCommandStatus();
    pid_t first;
    char *initial[] = {"retention-first", NULL};
    if (ios_spawn(&first, initial[0], NULL, initial, NULL)) return 2;
    for (int i = 0; i < 256; i++) {
        pid_t child;
        char *arguments[] = {"retention-later", NULL};
        if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 3;
        int status;
        if (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status) != 23) return 4;
    }
    int status;
    if (ios_full_waitpid(first, &status, 0) != first) return 5;
    if (ios_getCommandStatus() != parentStatus) return 6;
    pid_t exited;
    char *exitArguments[] = {"retention-exit", NULL};
    if (ios_spawn(&exited, exitArguments[0], NULL, exitArguments, NULL)) return 7;
    int exitStatus;
    if (ios_full_waitpid(exited, &exitStatus, 0) != exited || WEXITSTATUS(exitStatus) != 31) return 8;
    if (ios_getCommandStatus() != parentStatus) return 9;
    pid_t missing;
    char *missingArguments[] = {"retention-missing-command", NULL};
    if (ios_spawn(&missing, missingArguments[0], NULL, missingArguments, NULL)) return 10;
    int missingStatus;
    if (ios_full_waitpid(missing, &missingStatus, 0) != missing || WEXITSTATUS(missingStatus) != 127) return 11;
    if (ios_getCommandStatus() != parentStatus) return 12;
    dprintf(2, "unreaped first child after256 later launches: expected7 observed%d\n", WEXITSTATUS(status));
    return WIFEXITED(status) && WEXITSTATUS(status) == 7 ? 0 : 1;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(20);
        initializeEnvironment(); ios_switchSession("native-retention");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"retention-first", @"retention_first", false);
        replaceCommand(@"retention-later", @"retention_later", false);
        replaceCommand(@"retention-exit", @"retention_exit", false);
        replaceCommand(@"retention-parent", @"retention_parent", false);
        joinMainThread = true;
        int result = ios_system("retention-parent");
        dprintf(2, "unreaped PID retention: %s\n", result == 0 ? "PASS" : "FAIL");
        return result == 0 ? 0 : 1;
    }
}
