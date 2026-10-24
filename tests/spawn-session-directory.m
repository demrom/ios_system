#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <poll.h>
#include <signal.h>
#include <unistd.h>

static int ready[2], continued[2], switching[2], switched[2];
static char childDirectory[PATH_MAX], otherDirectory[PATH_MAX];
int session_directory_child(int argc, char **argv) {
    char byte;
    if (write(ready[1], "R", 1) != 1 || read(continued[0], &byte, 1) != 1) return 2;
    FILE *file = fopen("child.txt", "w");
    if (!file) return 3;
    fputs("CHILD", file); fclose(file);
    return 0;
}
int session_directory_parent(int argc, char **argv) {
    ios_spawn_options options = {fileno(thread_stdin), fileno(thread_stdout), fileno(thread_stderr), childDirectory, 0};
    char *arguments[] = {"session-directory-child", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    if (error) return error;
    int status;
    return ios_full_waitpid(child, &status, 0) == child && WIFEXITED(status) ? WEXITSTATUS(status) : 4;
}
int session_directory_other(int argc, char **argv) {
    FILE *file = fopen("other.txt", "w");
    if (!file) return 2;
    fputs("OTHER", file); fclose(file);
    return 0;
}
static void *switch_session(void *unused) {
    write(switching[1], "S", 1);
    ios_switchSession("native-directory-other");
    ios_setDirectoryURL([NSURL fileURLWithPath:@(otherDirectory)]);
    ios_setStreams(stdin, stdout, stderr);
    pid_t second = ios_fork();
    ios_system("session-directory-other");
    int status;
    if (ios_full_waitpid(second, &status, 0) == second && WIFEXITED(status) && !WEXITSTATUS(status))
        write(switched[1], "D", 1);
    return NULL;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(ready) || pipe(continued) || pipe(switching) || pipe(switched)) return 2;
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *name in @[@"child", @"other"])
            [manager createDirectoryAtPath:[temporary stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:NULL];
        snprintf(childDirectory, sizeof(childDirectory), "%s/child", temporary.UTF8String);
        snprintf(otherDirectory, sizeof(otherDirectory), "%s/other", temporary.UTF8String);
        initializeEnvironment(); ios_switchSession("native-directory-other");
        ios_setDirectoryURL([NSURL fileURLWithPath:@(otherDirectory)]);
        ios_switchSession("native-directory-parent");
        ios_setDirectoryURL([NSURL fileURLWithPath:temporary]);
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"session-directory-parent", @"session_directory_parent", false);
        replaceCommand(@"session-directory-child", @"session_directory_child", false);
        replaceCommand(@"session-directory-other", @"session_directory_other", false);
        joinMainThread = false;
        pid_t parent = ios_fork();
        ios_system("session-directory-parent");
        char byte;
        if (read(ready[0], &byte, 1) != 1) return 3;
        pthread_t ui;
        if (pthread_create(&ui, NULL, switch_session, NULL)) return 4;
        if (read(switching[0], &byte, 1) != 1) return 5;
        struct pollfd completion = {switched[0], POLLIN, 0};
        int early = poll(&completion, 1, 250);
        if (write(continued[1], "C", 1) != 1) return 6;
        int status;
        ios_full_waitpid(parent, &status, 0);
        pthread_join(ui, NULL);
        NSString *expected = [NSString stringWithContentsOfFile:[@(childDirectory) stringByAppendingPathComponent:@"child.txt"] encoding:NSUTF8StringEncoding error:NULL];
        bool misplaced = [manager fileExistsAtPath:[@(otherDirectory) stringByAppendingPathComponent:@"child.txt"]];
        bool otherFinished = [manager fileExistsAtPath:[@(otherDirectory) stringByAppendingPathComponent:@"other.txt"]];
        bool passed = early == 1 && WIFEXITED(status) && !WEXITSTATUS(status) && !expected && misplaced && otherFinished;
        dprintf(2, "session B completes while native child runs: early=%d childFile=%d sharedDirectory=%d %s\n", early, [expected isEqualToString:@"CHILD"], misplaced, passed ? "PASS" : "FAIL");
        [manager removeItemAtPath:temporary error:NULL];
        return passed ? 0 : 1;
    }
}
