#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <unistd.h>

static int childReady[2], childGate[2], leafDone[2];
int unforked_child(int argc, char **argv) {
    char byte;
    write(childReady[1], "R", 1);
    return read(childGate[0], &byte, 1) == 1 ? 23 : 3;
}
int unforked_parent(int argc, char **argv) {
    char *arguments[] = {"unforked-child", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    int status;
    return ios_full_waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 23 ? 0 : 4;
}
int unforked_leaf(int argc, char **argv) { return 0; }
static void *run_leaf(void *unused) {
    ios_switchSession("unforked-leaf"); ios_setStreams(stdin, stdout, stderr);
    ios_system("unforked-leaf");
    write(leafDone[1], "D", 1);
    return NULL;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(childReady) || pipe(childGate) || pipe(leafDone)) return 2;
        initializeEnvironment();
        ios_switchSession("unforked-leaf"); ios_setStreams(stdin, stdout, stderr);
        ios_switchSession("unforked-parent"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"unforked-parent", @"unforked_parent", false);
        replaceCommand(@"unforked-child", @"unforked_child", false);
        replaceCommand(@"unforked-leaf", @"unforked_leaf", false);
        joinMainThread = false;
        pid_t parent = ios_fork(); ios_system("unforked-parent");
        char byte;
        if (read(childReady[0], &byte, 1) != 1) return 3;
        joinMainThread = true;
        pthread_t leaf;
        if (pthread_create(&leaf, NULL, run_leaf, NULL)) return 4;
        struct pollfd completion = {leafDone[0], POLLIN, 0};
        int early = poll(&completion, 1, 250);
        if (write(childGate[1], "G", 1) != 1) return 5;
        pthread_join(leaf, NULL);
        int status;
        if (ios_full_waitpid(parent, &status, 0) != parent) return 6;
        bool passed = early == 1 && WIFEXITED(status) && !WEXITSTATUS(status);
        dprintf(2, "unforked session leaves another session child running: early=%d %s\n", early, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
