// Redirecting stderr to the active stdout must preserve the caller's stream.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "../ios_error.h"

static BOOL pendingMode;
static BOOL sameFdMode;
static const char *pendingPath;

int dup2_stdout_stderr_main(int argc, char **argv) {
    FILE *input = NULL, *output = NULL, *error = NULL;
    int pendingFd = -1;
    FILE *borrowedError = thread_stderr;
    if (pendingMode) {
        int fd = open(pendingPath, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd < 0 || ios_dup2(fd, STDOUT_FILENO) != STDOUT_FILENO) return 2;
        pendingFd = fd;
    }
    if (ios_dup2(sameFdMode ? pendingFd : fileno(thread_stdout), STDERR_FILENO) != STDERR_FILENO) return 2;
    ios_activateChildStreams(&input, &output, &error);
    FILE *activeOutput = thread_stdout, *activeError = thread_stderr;
    int result = pendingMode
        ? (fputs("pending-out\n", thread_stdout) == EOF || fflush(thread_stdout) || fputs("pending-err\n", thread_stderr) == EOF || fflush(thread_stderr))
        : (fputs("redirected\n", thread_stderr) == EOF || fflush(thread_stderr));
    if (input) thread_stdin = input;
    if (output) thread_stdout = output;
    if (error) thread_stderr = error;
    if (pendingMode) {
        if (activeError != activeOutput && activeError != borrowedError && fclose(activeError)) result = 1;
        if (fclose(activeOutput)) result = 1;
    }
    return result || fputs("recovery\n", thread_stdout) == EOF;
}

static void timedOut(int signal) { _Exit(124); }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 2 || (argc == 2 && strcmp(argv[1], "pending") && strcmp(argv[1], "same-fd"))) return 2;
        pendingMode = argc == 2;
        sameFdMode = pendingMode && !strcmp(argv[1], "same-fd");
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        pendingPath = path.fileSystemRepresentation;
        signal(SIGALRM, timedOut);
        alarm(5);
        initializeEnvironment();
        ios_switchSession("dup2-stdout-stderr");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *registration = NULL;
        if (!input || !output || !error || ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"dup2-stdout-stderr", @"dup2_stdout_stderr_main", false);
        joinMainThread = true;
        BOOL commandsOK = YES;
        for (int iteration = 0; iteration < 3; iteration++) {
            if (ios_system("dup2-stdout-stderr")) commandsOK = NO;
            ashell_wait_owned_streams(registration);
        }
        fflush(output);
        fflush(error);
        rewind(output);
        rewind(error);
        char actual[128] = {0};
        size_t length = fread(actual, 1, sizeof(actual) - 1, output);
        int errorByte = fgetc(error);
        BOOL pendingFile = YES;
        if (pendingMode) {
            FILE *file = fopen(pendingPath, "r");
            char contents[64] = {0};
            pendingFile = file && fread(contents, 1, sizeof contents - 1, file) == 24 && !strcmp(contents, "pending-out\npending-err\n");
            if (file) fclose(file);
            unlink(pendingPath);
        }
        const char *expected = pendingMode ? "recovery\nrecovery\nrecovery\n" : "redirected\nrecovery\nredirected\nrecovery\nredirected\nrecovery\n";
        BOOL passed = commandsOK && !strcmp(actual, expected) && errorByte == EOF && pendingFile;
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        ios_closeSession("dup2-stdout-stderr");
        if (fclose(input) || fclose(output) || fclose(error)) return 1;
        alarm(0);
        dprintf(STDOUT_FILENO, "stdout=%zu stderr-empty=%d pending-file=%d %s\n", length, errorByte == EOF, pendingFile, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
