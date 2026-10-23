// Redirecting stderr to the active stdout must preserve the caller's stream.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include "../ios_error.h"

int dup2_stdout_stderr_main(int argc, char **argv) {
    FILE *input = NULL, *output = NULL, *error = NULL;
    if (ios_dup2(fileno(thread_stdout), STDERR_FILENO) != STDERR_FILENO) return 2;
    ios_activateChildStreams(&input, &output, &error);
    int result = fputs("redirected\n", thread_stderr) == EOF || fflush(thread_stderr);
    if (input) thread_stdin = input;
    if (output) thread_stdout = output;
    if (error) thread_stderr = error;
    return result || fputs("recovery\n", thread_stdout) == EOF;
}

static void timedOut(int signal) { _Exit(124); }

int main(void) {
    @autoreleasepool {
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
        for (int iteration = 0; iteration < 3; iteration++) {
            if (ios_system("dup2-stdout-stderr")) return 2;
            ashell_wait_owned_streams(registration);
        }
        fflush(output);
        fflush(error);
        rewind(output);
        rewind(error);
        char actual[128] = {0};
        size_t length = fread(actual, 1, sizeof(actual) - 1, output);
        int errorByte = fgetc(error);
        BOOL passed = !strcmp(actual, "redirected\nrecovery\nredirected\nrecovery\nredirected\nrecovery\n") && errorByte == EOF;
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        ios_closeSession("dup2-stdout-stderr");
        if (fclose(input) || fclose(output) || fclose(error)) return 1;
        alarm(0);
        dprintf(STDOUT_FILENO, "stdout=%zu stderr-empty=%d %s\n", length, errorByte == EOF, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
