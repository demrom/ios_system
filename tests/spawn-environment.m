#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <signal.h>
#include <dlfcn.h>
#include "ios_spawn.h"
#include <unistd.h>

extern int ios_execve(const char *, char *const [], char **);
static int releaseChild[2];
static char parentValue[32], childValue[32];

int environment_child(int argc, char **argv) {
    char byte;
    if (read(releaseChild[0], &byte, 1) != 1) return 2;
    const char *value = ios_getenv("NATIVE_ENV_PROBE");
    snprintf(childValue, sizeof(childValue), "%s", value ? value : "missing");
    return strcmp(childValue, "child") != 0;
}

int environment_parent(int argc, char **argv) {
    if (pipe(releaseChild) || ios_setenv("NATIVE_ENV_PROBE", "parent", 1)) return 2;
    pid_t child;
    char *arguments[] = {"environment-child", NULL};
    char *environment[] = {"NATIVE_ENV_PROBE=child", NULL};
    int (*spawn)(pid_t *, const char *, const ios_spawn_options *, char *const [], char *const []) = dlsym(RTLD_DEFAULT, "ios_spawn");
    if (!spawn) return 3;
    int error = spawn(&child, arguments[0], NULL, arguments, environment);
    if (error) { close(releaseChild[0]); close(releaseChild[1]); return error; }
    const char *value = ios_getenv("NATIVE_ENV_PROBE");
    snprintf(parentValue, sizeof(parentValue), "%s", value ? value : "missing");
    if (write(releaseChild[1], "x", 1) != 1) return 2;
    ios_waitpid(child);
    close(releaseChild[0]);
    close(releaseChild[1]);
    return strcmp(parentValue, "parent") || strcmp(childValue, "child") ? 1 : 0;
}

static void timedOut(int number) { _Exit(124); }

int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(10);
        initializeEnvironment();
        ios_switchSession("native-child-environment");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"environment-child", @"environment_child", false);
        replaceCommand(@"environment-parent", @"environment_parent", false);
        joinMainThread = true;
        int result = ios_system("environment-parent");
        dprintf(STDERR_FILENO, "parent expected=parent observed=%s; child expected=child observed=%s: %s\n", parentValue, childValue, result == 0 ? "PASS" : "FAIL");
        alarm(0);
        return result == 0 ? 0 : 1;
    }
}
