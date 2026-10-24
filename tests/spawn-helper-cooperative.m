#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
static int helperReady[2], parentReady[2], parentGate[2];
static atomic_int finished;
static bool cancelMode;
static void *cooperative_worker(void *unused) {
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (write(helperReady[1], "R", 1) != 1) return NULL;
    while (!ios_command_cancelled()) usleep(1000);
    atomic_fetch_add(&finished, 1);
    return NULL;
}
int cooperative_parent(int argc, char **argv) {
    pthread_t helper;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    int error = ios_command_cancelled() ? ECANCELED : ios_command_thread_create(&helper, &attributes, cooperative_worker, NULL);
    pthread_attr_destroy(&attributes);
    if (error) return 2;
    char byte;
    if (read(helperReady[0], &byte, 1) != 1) return 3;
    if (cancelMode) {
        if (write(parentReady[1], "R", 1) != 1) return 4;
        read(parentGate[0], &byte, 1);
    }
    // Runtime cleanup must stop and retain this helper even without a join here.
    return 17;
}
int cooperative_driver(int argc, char **argv) {
    for (int mode = 0; mode < 2; mode++) {
        cancelMode = mode;
        char *arguments[] = {"cooperative-parent", NULL};
        pid_t child;
        if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 2;
        if (mode) {
            struct pollfd ready = {parentReady[0], POLLIN, 0};
            if (poll(&ready, 1, 5000) != 1 || ios_spawn_cancel(child)) return 3;
        }
        int status;
        if (ios_full_waitpid(child, &status, 0) != child) return 4;
        bool passed = WIFEXITED(status) && WEXITSTATUS(status) == (mode ? 130 : 17) && atomic_load(&finished) == mode + 1;
        dprintf(2, "COOPERATIVE_HELPER mode=%s status=%d finished=%d %s\n", mode ? "cancel" : "return", status, atomic_load(&finished), passed ? "PASS" : "FAIL");
        if (!passed) return 5;
    }
    return 0;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        if (pipe(helperReady) || pipe(parentReady) || pipe(parentGate)) return 2;
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("cooperative-helper"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"cooperative-parent", @"cooperative_parent", false);
        replaceCommand(@"cooperative-driver", @"cooperative_driver", false);
        joinMainThread = true;
        return ios_system("cooperative-driver") ? 1 : 0;
    }
}
