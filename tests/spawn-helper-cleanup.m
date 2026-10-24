#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

static int ready[2], blocked[2];
static void helper_cleanup(void *unused) {
    fputs("HELPER", thread_stdout);
    fflush(thread_stdout);
}
static void *helper_worker(void *unused) {
    pthread_cleanup_push(helper_cleanup, NULL);
    char byte = 'R';
    write(ready[1], &byte, 1);
    read(blocked[0], &byte, 1);
    pthread_cleanup_pop(1);
    return NULL;
}
int helper_parent(int argc, char **argv) {
    int (*create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_DEFAULT, "ios_command_thread_create");
    if (!create) return 7;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t helper;
    int error = create(&helper, &attributes, helper_worker, NULL);
    pthread_attr_destroy(&attributes);
    if (error) return error;
    char byte;
    if (read(ready[0], &byte, 1) != 1 || byte != 'R') return 8;
    return 17;
}
int helper_next(int argc, char **argv) {
    fputs("NEXT", thread_stdout);
    return 0;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(ready) || pipe(blocked)) return 2;
        initializeEnvironment(); ios_switchSession("native-helper-cleanup");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        ios_setStreams(input, output, error);
        replaceCommand(@"helper-parent", @"helper_parent", false);
        replaceCommand(@"helper-next", @"helper_next", false);
        joinMainThread = true;
        int parentResult = ios_system("helper-parent");
        int nextResult = ios_system("helper-next");
        rewind(output);
        char observed[11] = {0};
        size_t count = fread(observed, 1, sizeof(observed) - 1, output);
        bool passed = parentResult == 17 && !nextResult && count == 10 && !strcmp(observed, "HELPERNEXT");
        dprintf(2, "returning parent cancels helper before next command: parent=%d next=%d bytes=%zu %s\n", parentResult, nextResult, count, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
