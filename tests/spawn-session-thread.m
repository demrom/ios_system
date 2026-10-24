#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

int session_leaf(int argc, char **argv) {
    char byte;
    return fread(&byte, 1, 1, thread_stdin) == 1 ? 0 : 2;
}
int session_parent(int argc, char **argv) {
    pthread_t before = ios_getLastThreadId();
    int input[2];
    if (ios_spawn_pipe(input)) return 2;
    ios_spawn_options options = {input[0], fileno(thread_stdout), fileno(thread_stderr), NULL, IOS_SPAWN_CANCEL_INPUT};
    char *arguments[] = {"session-leaf", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    close(input[0]);
    if (error) return error;
    pthread_t after = ios_getLastThreadId();
    if (write(input[1], "X", 1) != 1) return 3;
    close(input[1]);
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status)) return 4;
    dprintf(2, "native child preserves session last thread: %s\n", before == after ? "PASS" : "FAIL");
    return before == after ? 0 : 5;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-session-thread");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"session-parent", @"session_parent", false);
        replaceCommand(@"session-leaf", @"session_leaf", false);
        joinMainThread = true;
        int result = ios_system("session-parent");
        return result == 0 ? 0 : 1;
    }
}
