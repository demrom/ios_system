#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>

static int legacyInput[2];
static pid_t legacyPID;

int cancellation_leaf(int argc, char **argv) {
    fputc('R', thread_stdout); fflush(thread_stdout);
    char byte;
    return read(legacyInput[0], &byte, 1) == 1 ? 1 : 2;
}
int cancellation_branch(int argc, char **argv) {
    legacyPID = ios_fork();
    ios_system("cancellation-leaf");
    ios_waitpid(legacyPID);
    return 3;
}
int cancellation_parent(int argc, char **argv) {
    int (*cancel)(pid_t) = dlsym(RTLD_DEFAULT, "ios_spawn_cancel");
    if (!cancel) return 6;
    if (pipe(legacyInput)) return 2;
    int input[2], output[2];
    int (*channel)(int [2]) = dlsym(RTLD_DEFAULT, "ios_spawn_pipe");
    if (!channel) channel = pipe;
    if (channel(input) || channel(output)) {
        dprintf(2, "channel creation failed errno=%d %s\n", errno, strerror(errno));
        return 2;
    }
    ios_spawn_options options = {input[0], output[1], fileno(thread_stderr), NULL, IOS_SPAWN_CANCEL_INPUT | IOS_SPAWN_CANCEL_OUTPUT};
    char *arguments[] = {"cancellation-branch", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    close(input[0]); close(output[1]);
    if (error) return error;
    char ready;
    if (read(output[0], &ready, 1) != 1 || ready != 'R') return 3;
    if (cancel(child)) return 4;
    int status;
    pid_t waited = ios_full_waitpid(child, &status, 0);
    dprintf(2, "wait child=%d observed=%d raw_status=%d exit=%d\n", child, waited, status, WEXITSTATUS(status));
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 130) return 5;
    if (ios_full_waitpid(legacyPID, &status, 0) != legacyPID || WEXITSTATUS(status) != 130) return 8;
    if (read(output[0], &ready, 1) != 0) return 7;
    close(legacyInput[0]); close(legacyInput[1]);
    close(input[1]); close(output[0]);
    return 0;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-cancellation");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"cancellation-parent", @"cancellation_parent", false);
        replaceCommand(@"cancellation-branch", @"cancellation_branch", false);
        replaceCommand(@"cancellation-leaf", @"cancellation_leaf", false);
        joinMainThread = true;
        int result = ios_system("cancellation-parent");
        dprintf(2, "cancel branch and legacy descendant on non-spawn fd, status130 and output EOF: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        return result == 0 ? 0 : 1;
    }
}
