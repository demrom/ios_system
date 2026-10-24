// Native pipe sessions must use real descriptor state without changing UI sessions.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

static void timedOut(int signal) { _Exit(124); }

int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(10);
        int sockets[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 2;
        FILE *stream = fdopen(sockets[0], "r+");
        if (!stream) return 2;
        ios_switchSession("native-tty-probe");
        ios_setStreams(stream, stream, stream);
        thread_stdin = thread_stdout = thread_stderr = stream;
        int before = ios_isatty(STDIN_FILENO);
        void (*useNativeTTY)(bool) = dlsym(RTLD_DEFAULT, "ios_useNativeTTY");
        if (useNativeTTY) useNativeTTY(true);
        int input = ios_isatty(STDIN_FILENO);
        int output = ios_isatty(STDOUT_FILENO);
        int error = ios_isatty(STDERR_FILENO);
        int descriptor = ios_isatty(fileno(stream));
        if (useNativeTTY) useNativeTTY(false);
        int after = ios_isatty(STDIN_FILENO);
        FILE *duplicate = fdopen(dup(fileno(stream)), "r+");
        if (!duplicate) return 2;
        thread_stdout = duplicate;
        int duplicateTTY = ios_isatty(STDOUT_FILENO);
        int sink = open("/dev/null", O_RDWR);
        if (sink < 0 || dup2(sink, fileno(stream)) < 0) return 2;
        close(sink);
        int savedTTY = ios_isatty(STDOUT_FILENO);
        int originalTTY = ios_isatty(fileno(stream));
        thread_stdout = stream;
        int redirectedTTY = ios_isatty(STDOUT_FILENO);
        BOOL passed = before == 1 && !input && !output && !error && !descriptor && after == 1 &&
            duplicateTTY == 1 && savedTTY == 1 && redirectedTTY == 0 && originalTTY == 0;
        dprintf(STDERR_FILENO, "duplicated terminal: duplicate=%d saved=%d redirected=%d %s\n", duplicateTTY, savedTTY, redirectedTTY, passed ? "PASS" : "FAIL");
        dprintf(STDERR_FILENO, "socket tty: default=%d native=%d/%d/%d descriptor=%d restored=%d %s\n", before, input, output, error, descriptor, after, passed ? "PASS" : "FAIL");
        FILE *file = tmpfile();
        FILE *duplicateFile = file ? fdopen(dup(fileno(file)), "r+") : NULL;
        if (!file || !duplicateFile) return 2;
        ios_setStreams(file, file, file);
        thread_stdout = duplicateFile;
        int redirectedFile = ios_isatty(STDOUT_FILENO);
        passed = passed && redirectedFile == 0;
        dprintf(STDERR_FILENO, "regular-file redirect tty=%d %s\n", redirectedFile, redirectedFile == 0 ? "PASS" : "FAIL");
        int channel[2], unrelated[2];
        if (pipe(channel) || pipe(unrelated)) return 2;
        FILE *pipeOutput = fdopen(channel[1], "w");
        FILE *otherOutput = fdopen(unrelated[1], "w");
        FILE *savedOutput = fdopen(dup(channel[1]), "w");
        if (!pipeOutput || !otherOutput || !savedOutput) return 2;
        ios_setStreams(stdin, pipeOutput, pipeOutput);
        thread_stdout = savedOutput;
        int pipeTTY = ios_isatty(STDOUT_FILENO);
        thread_stdout = otherOutput;
        int unrelatedTTY = ios_isatty(STDOUT_FILENO);
        thread_stdout = savedOutput;
        sink = open("/dev/null", O_RDWR);
        if (sink < 0 || dup2(sink, channel[1]) < 0) return 2;
        close(sink);
        int savedPipeTTY = ios_isatty(STDOUT_FILENO);
        int originalPipeTTY = ios_isatty(channel[1]);
        BOOL pipesPassed = pipeTTY == 1 && !unrelatedTTY && savedPipeTTY == 1 && !originalPipeTTY;
        passed = passed && pipesPassed;
        dprintf(STDERR_FILENO, "pipe tty: duplicate=%d unrelated=%d saved=%d original=%d %s\n", pipeTTY, unrelatedTTY, savedPipeTTY, originalPipeTTY, pipesPassed ? "PASS" : "FAIL");
        ios_setStreams(stdin, stdout, stderr);
        thread_stdin = stdin;
        thread_stdout = stdout;
        thread_stderr = stderr;
        ios_closeSession("native-tty-probe");
        fclose(pipeOutput);
        fclose(otherOutput);
        fclose(savedOutput);
        close(channel[0]);
        close(unrelated[0]);
        fclose(duplicateFile);
        fclose(file);
        fclose(duplicate);
        fclose(stream);
        close(sockets[1]);
        alarm(0);
        return passed ? 0 : 1;
    }
}
