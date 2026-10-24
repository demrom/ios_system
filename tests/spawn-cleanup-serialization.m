#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

int closing[2], releaseClose[2];
static int launching[2], launched[2];
struct stat selectedInput;
atomic_bool pauseClose;

int cleanup_leaf(int argc, char **argv) { return 0; }
static void *launch_during_cleanup(void *unused) {
    char *arguments[] = {"cleanup-leaf", NULL};
    pid_t child;
    int status;
    write(launching[1], "L", 1);
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    write(launched[1], "D", 1);
    if (!error && (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status))) error = 3;
    return (void *)(intptr_t)error;
}
int cleanup_parent(int argc, char **argv) {
    char *arguments[] = {"cleanup-leaf", NULL};
    pid_t child;
    int status;
    // Borrowed streams must not disable serialization of a later owned cleanup.
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error || ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status)) return 4;
    FILE *input = tmpfile();
    if (!input || fstat(fileno(input), &selectedInput)) return 5;
    atomic_store(&pauseClose, true);
    ios_spawn_options options = {fileno(input), fileno(thread_stdout), fileno(thread_stderr), NULL, 0};
    error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    if (error) return error;
    char byte;
    if (read(closing[0], &byte, 1) != 1) return 6;
    pthread_t helper;
    error = ios_command_thread_create(&helper, NULL, launch_during_cleanup, NULL);
    if (error || read(launching[0], &byte, 1) != 1) return 7;
    struct pollfd completion = {launched[0], POLLIN, 0};
    int early = poll(&completion, 1, 250);
    if (write(releaseClose[1], "R", 1) != 1) return 8;
    void *result;
    pthread_join(helper, &result);
    if (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status)) return 9;
    fclose(input);
    bool passed = early == 0 && result == NULL;
    dprintf(2, "launch waits for stream cleanup after borrowed child: early=%d %s\n", early, passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(closing) || pipe(releaseClose) || pipe(launching) || pipe(launched)) return 2;
        initializeEnvironment(); ios_switchSession("cleanup-serialization");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"cleanup-parent", @"cleanup_parent", false);
        replaceCommand(@"cleanup-leaf", @"cleanup_leaf", false);
        joinMainThread = true;
        return ios_system("cleanup-parent");
    }
}
