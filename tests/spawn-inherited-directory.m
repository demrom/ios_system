#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

static int continued[2];
static char root[PATH_MAX], childDirectory[PATH_MAX], nestedDirectory[PATH_MAX];
static int launch(const char *command, const char *directory) {
    ios_spawn_options options = {fileno(thread_stdin), fileno(thread_stdout), fileno(thread_stderr), directory, 0};
    char *arguments[] = {(char *)command, NULL};
    pid_t child;
    int error = ios_spawn(&child, command, &options, arguments, NULL);
    if (error) return error;
    if (!strcmp(command, "directory-child") && write(continued[1], "x", 1) != 1) return 8;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status)) return 2;
    return WEXITSTATUS(status);
}
int directory_nested(int argc, char **argv) {
    FILE *file = fopen("nested.txt", "w");
    if (!file) return 2;
    fputs("nested", file); fclose(file);
    return 0;
}
int directory_child(int argc, char **argv) {
    char byte;
    if (read(continued[0], &byte, 1) != 1) return 8;
    if (chdir(childDirectory)) return 9;
    if (launch("directory-nested", nestedDirectory)) return 3;
    FILE *file = fopen("child.txt", "w");
    if (!file) return 2;
    fputs("child", file); fclose(file);
    return 0;
}
int directory_parent(int argc, char **argv) {
    if (pipe(continued)) return 8;
    int result = launch("directory-child", NULL);
    close(continued[0]); close(continued[1]);
    char restored[PATH_MAX];
    if (!getcwd(restored, sizeof(restored)) || strcmp(restored, root)) return 4;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/child.txt", childDirectory);
    if (access(path, F_OK)) return 5;
    snprintf(path, sizeof(path), "%s/nested.txt", nestedDirectory);
    if (access(path, F_OK)) return 6;
    return result;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:[temporary stringByAppendingPathComponent:@"child/nested"] withIntermediateDirectories:YES attributes:nil error:NULL];
        initializeEnvironment(); ios_switchSession("native-directory");
        ios_setStreams(stdin, stdout, stderr);
        chdir(temporary.UTF8String); getcwd(root, sizeof(root));
        snprintf(childDirectory, sizeof(childDirectory), "%s/child", root);
        snprintf(nestedDirectory, sizeof(nestedDirectory), "%s/child/nested", root);
        replaceCommand(@"directory-parent", @"directory_parent", false);
        replaceCommand(@"directory-child", @"directory_child", false);
        replaceCommand(@"directory-nested", @"directory_nested", false);
        joinMainThread = true;
        int result = ios_system("directory-parent");
        dprintf(2, "inherited cwd child changes directory; parent restoration: result=%d %s\n", result, result == 0 ? "PASS" : "FAIL");
        [manager removeItemAtPath:temporary error:NULL];
        return result == 0 ? 0 : 1;
    }
}
