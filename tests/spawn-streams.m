#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
extern int ios_fflush(FILE *stream);

static int descriptors(void) {
    int count = 0;
    for (int fd = 0; fd < 256; fd++) if (fcntl(fd, F_GETFD) >= 0) count++;
    return count;
}

int streams_child(int argc, char **argv) {
    char input[8] = {0};
    if (fread(input, 1, 5, thread_stdin) != 5 || strcmp(input, "input")) return 2;
    fputs("output", thread_stdout);
    fputs("error", thread_stderr);
    if (ios_fflush(NULL)) return 8;
    char acknowledged;
    if (fread(&acknowledged, 1, 1, thread_stdin) != 1 || acknowledged != 'R') return 9;
    return 7;
}

int streams_parent(int argc, char **argv) {
    int before = descriptors();
    for (int iteration = 0; iteration < 20; iteration++) {
        int input[2], output[2], error[2];
        if (pipe(input) || pipe(output) || pipe(error)) return 2;
        ios_spawn_options options = {input[0], output[1], error[1], NULL, 0};
        char *arguments[] = {"streams-child", NULL};
        pid_t child;
        int result = ios_spawn(&child, arguments[0], &options, arguments, NULL);
        close(input[0]); close(output[1]); close(error[1]);
        if (result) { dprintf(2, "spawn error=%d\n", result); return result; }
        if (write(input[1], "input", 5) != 5) return 2;
        char out[16] = {0}, err[16] = {0};
        ssize_t outLength = read(output[0], out, sizeof(out) - 1);
        ssize_t errLength = read(error[0], err, sizeof(err) - 1);
        if (write(input[1], "R", 1) != 1) return 6;
        close(input[1]);
        char byte;
        if (read(output[0], &byte, 1) != 0 || read(error[0], &byte, 1) != 0) return 3;
        close(output[0]); close(error[0]);
        int status = 0;
        if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 7) return 4;
        if (outLength != 6 || strcmp(out, "output") || errLength != 5 || strcmp(err, "error")) return 5;
    }
    int after = descriptors();
    dprintf(2, "stream bytes and EOF: 20 repetitions; descriptors before=%d after=%d\n", before, after);
    return after > before + 2;
}

static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-streams");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"streams-child", @"streams_child", false);
        replaceCommand(@"streams-parent", @"streams_parent", false);
        joinMainThread = true;
        int result = ios_system("streams-parent");
        dprintf(2, "separate streams: %s\n", result == 0 ? "PASS" : "FAIL");
        return result == 0 ? 0 : 1;
    }
}
