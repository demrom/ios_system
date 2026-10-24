#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <pthread.h>
#include <unistd.h>

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t dispatched = PTHREAD_COND_INITIALIZER;
static bool proceed;
static void unlockGate(void *lock) { pthread_mutex_unlock(lock); }

int handoff_leaf(int argc, char **argv) { return 0; }
int handoff_branch(int argc, char **argv) {
    if (ios_fork() < 0) return 2;
    pthread_mutex_lock(&gate);
    pthread_cleanup_push(unlockGate, &gate);
    fputc('R', thread_stdout); fflush(thread_stdout);
    while (!proceed) pthread_cond_wait(&dispatched, &gate);
    pthread_cleanup_pop(1);
    ios_system("handoff-leaf");
    return 3;
}
int handoff_parent(int argc, char **argv) {
    int input[2], output[2];
    if (ios_spawn_pipe(input) || ios_spawn_pipe(output)) return 2;
    ios_spawn_options options = {input[0], output[1], fileno(thread_stderr), NULL, 0};
    char *arguments[] = {"handoff-branch", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    close(input[0]); close(output[1]);
    if (error) return error;
    char ready;
    if (read(output[0], &ready, 1) != 1 || ready != 'R') return 3;
    pthread_mutex_lock(&gate);
    int cancelled = ios_spawn_cancel(child);
    proceed = true;
    pthread_cond_signal(&dispatched);
    pthread_mutex_unlock(&gate);
    if (cancelled) return 4;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status) != 130) return 5;
    close(input[1]); close(output[0]);
    return 0;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-fork-cancellation");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"handoff-parent", @"handoff_parent", false);
        replaceCommand(@"handoff-branch", @"handoff_branch", false);
        replaceCommand(@"handoff-leaf", @"handoff_leaf", false);
        joinMainThread = true;
        int result = ios_system("handoff-parent");
        dprintf(2, "cancel between legacy fork and dispatch: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        return result == 0 ? 0 : 1;
    }
}
