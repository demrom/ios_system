#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

static pid_t expectedPid;
int context_leaf(int argc, char **argv) {
    fputs("CHILD", thread_stdout);
    return 0;
}
static void *context_worker(void *unused) {
    if (ios_currentPid() != expectedPid) return (void *)2;
    const char *value = ios_getenv("HELPER_TOKEN");
    if (!value || strcmp(value, "per-command")) return (void *)3;
    if (!thread_stdin || !thread_stdout || !thread_stderr) return (void *)4;
    if (fgetc(thread_stdin) != 'Q') return (void *)5;
    fputs("OUT", thread_stdout); fflush(thread_stdout);
    char *arguments[] = {"context-leaf", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return (void *)(intptr_t)error;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || WEXITSTATUS(status)) return (void *)6;
    return NULL;
}
int context_parent(int argc, char **argv) {
    int (*create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_DEFAULT, "ios_command_thread_create");
    if (!create) return 7;
    expectedPid = ios_currentPid();
    ios_setenv("HELPER_TOKEN", "per-command", 1);
    pthread_t helper;
    int error = create(&helper, NULL, context_worker, NULL);
    if (error) return error;
    void *result;
    if (pthread_join(helper, &result)) return 8;
    return (int)(intptr_t)result;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-helper-context");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        fputs("Q", input); rewind(input);
        ios_setStreams(input, output, error);
        replaceCommand(@"context-parent", @"context_parent", false);
        replaceCommand(@"context-leaf", @"context_leaf", false);
        joinMainThread = true;
        int result = ios_system("context-parent");
        rewind(output);
        char observed[9] = {0};
        size_t count = fread(observed, 1, sizeof(observed) - 1, output);
        bool passed = !result && count == 8 && !strcmp(observed, "OUTCHILD");
        dprintf(2, "helper inherits PID/environment/streams and can spawn: result=%d bytes=%zu %s\n", result, count, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
