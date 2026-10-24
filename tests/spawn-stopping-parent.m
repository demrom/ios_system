#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
static int helperReady[2];
static atomic_int launchError;
static atomic_int leafCalls;
static bool legacySystem;
int stopping_leaf(int argc, char **argv) {
    atomic_fetch_add(&leafCalls, 1);
    if (legacySystem) { char byte; read(helperReady[0], &byte, 1); }
    return 0;
}
static void *late_helper(void *unused) {
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (write(helperReady[1], "R", 1) != 1) return NULL;
    while (!ios_command_cancelled()) usleep(1000);
    if (legacySystem) {
        ios_system("stopping-leaf");
        return NULL;
    }
    char *arguments[] = {"stopping-leaf", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    atomic_store(&launchError, error);
    if (!error) { int status; ios_full_waitpid(child, &status, 0); }
    return NULL;
}
int stopping_parent(int argc, char **argv) {
    pthread_t helper;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    int error = ios_command_thread_create(&helper, &attributes, late_helper, NULL);
    pthread_attr_destroy(&attributes);
    if (error) return 2;
    char byte;
    return read(helperReady[0], &byte, 1) == 1 ? 17 : 3;
}
int stopping_driver(int argc, char **argv) {
    char *arguments[] = {"stopping-parent", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 2;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 3;
    bool passed = WIFEXITED(status) && WEXITSTATUS(status) == 17 &&
        (legacySystem ? atomic_load(&leafCalls) == 0 : atomic_load(&launchError) == ECANCELED);
    dprintf(2, "STOPPING_PARENT system=%d status=%d launch_error=%d leaf_calls=%d %s\n", legacySystem, status, atomic_load(&launchError), atomic_load(&leafCalls), passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void timedOut(int number) { _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (pipe(helperReady)) return 2;
        atomic_store(&launchError, -1);
        legacySystem = argc > 1 && !strcmp(argv[1], "system");
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("stopping-parent"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"stopping-leaf", @"stopping_leaf", false);
        replaceCommand(@"stopping-parent", @"stopping_parent", false);
        replaceCommand(@"stopping-driver", @"stopping_driver", false);
        joinMainThread = true;
        return ios_system("stopping-driver") ? 1 : 0;
    }
}
