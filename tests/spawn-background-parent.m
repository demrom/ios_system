#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

static int branchReady[2], branchGate[2], childReady[2], childGate[2], branchDone[2];
int background_child(int argc, char **argv) {
    char byte;
    write(childReady[1], "R", 1);
    return read(childGate[0], &byte, 1) == 1 ? 0 : 2;
}
int background_branch(int argc, char **argv) {
    char byte;
    write(branchReady[1], "R", 1);
    if (read(branchGate[0], &byte, 1) != 1) return 3;
    char *arguments[] = {"background-child", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    int status;
    bool passed = ios_full_waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status);
    write(branchDone[1], passed ? "P" : "F", 1);
    return passed ? 0 : 4;
}
int background_root(int argc, char **argv) {
    ios_system("background-branch");
    return 0;
}
int background_leaf(int argc, char **argv) { return 0; }
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(branchReady) || pipe(branchGate) || pipe(childReady) || pipe(childGate) || pipe(branchDone)) return 2;
        initializeEnvironment(); ios_switchSession("background-parent"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"background-root", @"background_root", false);
        replaceCommand(@"background-branch", @"background_branch", false);
        replaceCommand(@"background-child", @"background_child", false);
        replaceCommand(@"background-leaf", @"background_leaf", false);
        joinMainThread = false;
        pid_t root = ios_fork(); ios_system("background-root");
        char byte;
        if (read(branchReady[0], &byte, 1) != 1) return 3;
        int status;
        if (ios_full_waitpid(root, &status, 0) != root || WEXITSTATUS(status)) return 4;
        if (write(branchGate[1], "G", 1) != 1 || read(childReady[0], &byte, 1) != 1) return 5;
        ios_switchSession("background-observer"); ios_setStreams(stdin, stdout, stderr);
        joinMainThread = true;
        int leaf = ios_system("background-leaf");
        if (write(childGate[1], "G", 1) != 1 || read(branchDone[0], &byte, 1) != 1) return 6;
        bool passed = leaf == 0 && byte == 'P';
        dprintf(2, "background legacy branch survives completed parent: %s\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
