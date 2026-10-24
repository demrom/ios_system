#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

int exit_writer(int argc, char **argv) {
    char bytes[4096] = {0};
    while (fwrite(bytes, 1, sizeof(bytes), thread_stdout) == sizeof(bytes)) {}
    return 0;
}

int exit_branch(int argc, char **argv) {
    char *arguments[] = {"exit-writer", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    return error ? error : 17;
}

int exit_parent(int argc, char **argv) {
    for (int round = 0; round < 256; round++) {
        int channel[2];
        if (ios_spawn_pipe(channel)) return 2;
        ios_spawn_options options = {fileno(thread_stdin), channel[1], fileno(thread_stderr), NULL, IOS_SPAWN_CANCEL_OUTPUT};
        char *arguments[] = {"exit-branch", NULL};
        pid_t child;
        int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
        close(channel[1]);
        if (error) return error;
        int status;
        if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 17) return 3;
        close(channel[0]);
    }
    return 0;
}

static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(20);
        initializeEnvironment(); ios_switchSession("native-parent-exit");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"exit-parent", @"exit_parent", false);
        replaceCommand(@"exit-branch", @"exit_branch", false);
        replaceCommand(@"exit-writer", @"exit_writer", false);
        joinMainThread = true;
        int result = ios_system("exit-parent");
        dprintf(2, "256 parent exits with live writer and reusable child slots: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        return result == 0 ? 0 : 1;
    }
}
