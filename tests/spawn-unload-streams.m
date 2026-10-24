#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
int unload_parent(int argc, char **argv) {
    int channel[2];
    if (pipe(channel)) return 2;
    ios_spawn_options options = {fileno(thread_stdin), fileno(thread_stdout), channel[1], NULL, 0};
    char *arguments[] = {"unload-job", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    close(channel[1]);
    if (error) return error;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 3;
    char bytes[64] = {0};
    ssize_t count = read(channel[0], bytes, sizeof(bytes));
    close(channel[0]);
    bool passed = count == 14 && !memcmp(bytes, "IMAGE_CLEANUP\n", 14);
    dprintf(2, "image cleanup retains child stderr: bytes=%zd %s\n", count, passed ? "PASS" : "FAIL");
    return passed ? 0 : 4;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-unload-streams");
        ios_setStreams(stdin, stdout, stderr); joinMainThread = true;
        replaceCommand(@"unload-parent", @"unload_parent", false);
        return ios_system("unload-parent") ? 1 : 0;
    }
}
