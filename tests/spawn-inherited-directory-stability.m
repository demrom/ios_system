#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>

static int continued[2];
static char changedDirectory[PATH_MAX];
int unchanged_child(int argc, char **argv) {
    char byte;
    return read(continued[0], &byte, 1) == 1 ? 0 : 2;
}
int changed_parent(int argc, char **argv) {
    char *arguments[] = {"unchanged-child", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    if (chdir(changedDirectory) || write(continued[1], "C", 1) != 1) return 3;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 4;
    char observed[PATH_MAX];
    return getcwd(observed, sizeof(observed)) && !strcmp(observed, changedDirectory) ? 0 : 5;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(continued)) return 2;
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL];
        initializeEnvironment(); ios_switchSession("inherited-directory-stability");
        ios_setStreams(stdin, stdout, stderr);
        ios_setDirectoryURL([NSURL fileURLWithPath:temporary]);
        if (!getcwd(changedDirectory, sizeof(changedDirectory))) return 3;
        NSString *root = [temporary stringByDeletingLastPathComponent];
        ios_setDirectoryURL([NSURL fileURLWithPath:root]);
        replaceCommand(@"changed-parent", @"changed_parent", false);
        replaceCommand(@"unchanged-child", @"unchanged_child", false);
        joinMainThread = true;
        int result = ios_system("changed-parent");
        dprintf(2, "child without directory changes preserves parent cwd: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        [manager removeItemAtPath:temporary error:NULL];
        return result == 0 ? 0 : 1;
    }
}
