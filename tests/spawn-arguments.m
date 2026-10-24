#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <dlfcn.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

extern int ios_execv(const char *path, char *const argv[]);
static char *arguments[] = {
    "argument-child", "", "two words", "literal\\backslash", "single'quote",
    "double\"quote", "both'\"quotes", "line\nbreak", "dollar$HOME",
    "all'\" \036quotes", NULL
};
static bool nativeSpawn;

int argument_child(int argc, char **argv) {
    int expected = sizeof(arguments) / sizeof(arguments[0]) - 1;
    int passed = argc == expected;
    dprintf(2, "argc expected=%d observed=%d\n", expected, argc);
    for (int i = 0; i < argc && i < expected; i++) {
        if (strcmp(arguments[i], argv[i])) {
            dprintf(2, "argument %d differs: expected_bytes=%zu observed_bytes=%zu\n",
                    i, strlen(arguments[i]), strlen(argv[i]));
            passed = 0;
        }
    }
    return passed ? 0 : 1;
}

int argument_parent(int argc, char **argv) {
    int (*spawn)(pid_t *, const char *, const ios_spawn_options *, char *const [], char *const []) = dlsym(RTLD_DEFAULT, "ios_spawn");
    pid_t child;
    nativeSpawn = spawn != NULL;
    if (spawn) {
        int error = spawn(&child, arguments[0], NULL, arguments, NULL);
        if (error) return error;
    } else {
        // Exercise the existing public interface on the same baseline binary.
        child = ios_fork();
        ios_execv(arguments[0], arguments);
    }
    int status = 0;
    ios_full_waitpid(child, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 2;
}

static void timed_out(int number) { _Exit(124); }

int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timed_out);
        alarm(10);
        initializeEnvironment();
        replaceCommand(@"argument-child", @"argument_child", false);
        replaceCommand(@"argument-parent", @"argument_parent", false);
        for (int joined = 0; joined < 2; joined++) {
            ios_switchSession(joined ? "spawn-arguments-joined" : "spawn-arguments-detached");
            ios_setStreams(stdin, stdout, stderr);
            joinMainThread = joined;
            pid_t parent = ios_fork();
            ios_system("argument-parent");
            int status = 0;
            ios_full_waitpid(parent, &status, 0);
            int result = WIFEXITED(status) ? WEXITSTATUS(status) : 2;
            dprintf(2, "argument preservation: joined=%d native_spawn=%d status=%d %s\n",
                    joined, nativeSpawn, result, result == 0 && nativeSpawn ? "PASS" : "FAIL");
            if (result || !nativeSpawn) return 1;
        }
        alarm(0);
        return 0;
    }
}
