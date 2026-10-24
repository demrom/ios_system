#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <sys/resource.h>
#include <unistd.h>

static int calls;
int descriptor_child(int argc, char **argv) {
    calls++;
    return fputs("LIMIT_OK\n", thread_stdout) == EOF;
}
static void timedOut(int number) { _Exit(124); }

int descriptor_spawn_parent(int argc, char **argv) {
    struct rlimit saved, limit;
    if (getrlimit(RLIMIT_NOFILE, &saved)) return 2;
    limit = saved; limit.rlim_cur = 64;
    if (setrlimit(RLIMIT_NOFILE, &limit)) return 2;
    int held[64], count = 0, fd, result = 0;
    while ((fd = open("/dev/null", O_RDONLY)) >= 0) {
        if (count == 64) return 2;
        held[count++] = fd;
    }
    if (errno != EMFILE) return 2;
    int descriptors[2];
    errno = 0;
    int pipeResult = ios_spawn_pipe(descriptors), pipeError = errno;
    if (pipeResult != -1 || pipeError != EMFILE) result = 1;
    for (int available = 0; available < 3; available++) {
        ios_spawn_options options = {fileno(thread_stdin), fileno(thread_stdout), fileno(thread_stderr), NULL, 0};
        char *arguments[] = {"descriptor-child", NULL};
        pid_t child = -1;
        int spawnError = ios_spawn(&child, arguments[0], &options, arguments, NULL);
        fprintf(thread_stderr, "spawn (%d free): %s; pipe: %s\n", available, strerror(spawnError), strerror(pipeError));
        if (spawnError != EMFILE || calls) result = 1;
        close(held[--count]);
    }
    while (count) close(held[--count]);
    if (setrlimit(RLIMIT_NOFILE, &saved)) return 2;
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (argc == 2 && (!strcmp(argv[1], "startup") || !strcmp(argv[1], "startup-maximum"))) {
            struct rlimit before, after;
            if (getrlimit(RLIMIT_NOFILE, &before)) return 2;
            rlim_t bound = before.rlim_max < OPEN_MAX ? before.rlim_max : OPEN_MAX;
            if (!strcmp(argv[1], "startup-maximum")) {
                before.rlim_cur = before.rlim_max;
                if (setrlimit(RLIMIT_NOFILE, &before)) return 2;
            }
            initializeEnvironment();
            if (getrlimit(RLIMIT_NOFILE, &after)) return 2;
            rlim_t expected = before.rlim_cur < bound ? bound : before.rlim_cur;
            bool passed = after.rlim_cur == expected && after.rlim_max == before.rlim_max;
            dprintf(2, "%s before=%llu hard=%llu OPEN_MAX=%d after=%llu expected=%llu %s\n", argv[1], before.rlim_cur, before.rlim_max, OPEN_MAX, after.rlim_cur, expected, passed ? "PASS" : "FAIL");
            return passed ? 0 : 1;
        }
        initializeEnvironment(); ios_switchSession("descriptor-limits");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        if (!input || !output || !error) return 2;
        void *registration = NULL;
        if (ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"descriptor-child", @"descriptor_child", false);
        replaceCommand(@"descriptor-parent", @"descriptor_spawn_parent", false);
        joinMainThread = true;
        struct rlimit saved, limit;
        if (getrlimit(RLIMIT_NOFILE, &saved)) return 2;
        limit = saved;
        int result = 0;
        if (argc == 2 && !strcmp(argv[1], "maximum")) {
            limit.rlim_cur = limit.rlim_max;
            if (setrlimit(RLIMIT_NOFILE, &limit)) return 2;
            result = ios_system("descriptor-child");
            if (getrlimit(RLIMIT_NOFILE, &limit)) return 2;
            if (result || calls != 1 || limit.rlim_cur != saved.rlim_max) return 1;
        } else if (argc == 2 && !strcmp(argv[1], "spawn")) {
            result = ios_system("descriptor-parent");
            ios_setStreams(input, output, error);
        } else {
            limit.rlim_cur = 64;
            if (setrlimit(RLIMIT_NOFILE, &limit)) return 2;
            int held[64], count = 0, fd;
            while ((fd = open("/dev/null", O_RDONLY)) >= 0) {
                if (count == 64) return 2;
                held[count++] = fd;
            }
            if (errno != EMFILE) return 2;
            int status = ios_system("descriptor-child | descriptor-child");
            fflush(error); rewind(error);
            char diagnostic[512] = {0};
            fread(diagnostic, 1, sizeof(diagnostic) - 1, error);
            if (!status || calls || !strstr(diagnostic, strerror(EMFILE))) result = 1;
            dprintf(2, "pipeline status=%d diagnostic=%s\n", status, diagnostic);
            while (count) close(held[--count]);
        }
        if (setrlimit(RLIMIT_NOFILE, &saved)) return 2;
        if (ios_system("descriptor-child")) return 1;
        ashell_wait_owned_streams(registration);
        if (calls != (argc == 2 && !strcmp(argv[1], "maximum") ? 2 : 1)) return 1;
        fflush(output); rewind(output);
        char bytes[32] = {0};
        size_t length = fread(bytes, 1, sizeof(bytes), output);
        const char *expected = argc == 2 && !strcmp(argv[1], "maximum") ? "LIMIT_OK\nLIMIT_OK\n" : "LIMIT_OK\n";
        if (length != strlen(expected) || memcmp(bytes, expected, length)) return 1;
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        fclose(input); fclose(output); fclose(error);
        dprintf(2, "descriptor limits %s: %s\n", argc == 2 ? argv[1] : "pipeline", result ? "FAIL" : "PASS");
        return result;
    }
}
