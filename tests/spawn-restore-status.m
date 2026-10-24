#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

static char parentDirectory[PATH_MAX], childDirectory[PATH_MAX], baseDirectory[PATH_MAX];
int restore_status_child(int argc, char **argv) {
    return rmdir(parentDirectory) == 0 ? 17 : 2;
}
int restore_status_parent(int argc, char **argv) {
    int before = ios_getCommandStatus();
    ios_spawn_options options = {fileno(thread_stdin), fileno(thread_stdout), fileno(thread_stderr), childDirectory, 0};
    char *arguments[] = {"restore-status-child", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], &options, arguments, NULL)) return 3;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 4;
    int after = ios_getCommandStatus();
    bool passed = WIFEXITED(status) && WEXITSTATUS(status) == 126 && after == before;
    chdir(baseDirectory);
    dprintf(2, "native directory restore failure: child=%d session=%d->%d %s\n", WEXITSTATUS(status), before, after, passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *name in @[@"parent", @"child"])
            [manager createDirectoryAtPath:[base stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:NULL];
        snprintf(baseDirectory, sizeof(baseDirectory), "%s", base.UTF8String);
        snprintf(parentDirectory, sizeof(parentDirectory), "%s/parent", baseDirectory);
        snprintf(childDirectory, sizeof(childDirectory), "%s/child", baseDirectory);
        initializeEnvironment(); ios_switchSession("restore-status"); ios_setStreams(stdin, stdout, stderr);
        chdir(parentDirectory);
        replaceCommand(@"restore-status-parent", @"restore_status_parent", false);
        replaceCommand(@"restore-status-child", @"restore_status_child", false);
        joinMainThread = true;
        int result = ios_system("restore-status-parent");
        chdir("/"); [manager removeItemAtPath:base error:NULL];
        return result;
    }
}
