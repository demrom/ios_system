#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *mode;
static int childReady[2], childGate[2], lockReady[2];
int buffered_child(int argc, char **argv) {
    char byte;
    write(childReady[1], "R", 1);
    return read(childGate[0], &byte, 1) == 1 ? 0 : 2;
}
static void unlockOutput(void *stream) { funlockfile(stream); }
static void *hold_output(void *unused) {
    flockfile(thread_stdout);
    pthread_cleanup_push(unlockOutput, thread_stdout);
    char byte;
    write(lockReady[1], "R", 1);
    read(childGate[0], &byte, 1);
    pthread_cleanup_pop(1);
    return NULL;
}
int buffered_branch(int argc, char **argv) {
    if (setvbuf(thread_stdout, NULL, _IOFBF, BUFSIZ)) return 3;
    char *arguments[] = {"buffered-child", NULL};
    pid_t child;
    if (ios_spawn(&child, arguments[0], NULL, arguments, NULL)) return 4;
    char byte;
    if (read(childReady[0], &byte, 1) != 1) return 5;
    if (!strcmp(mode, "full")) {
        int fd = fileno(thread_stdout), flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return 6;
        char bytes[4096] = {0};
        while (write(fd, bytes, sizeof(bytes)) > 0) {}
        if (fcntl(fd, F_SETFL, flags)) return 7;
    }
    if (fputs("BUFFERED\n", thread_stdout) < 0) return 8;
    if (!strcmp(mode, "contended")) {
        pthread_t helper;
        if (ios_command_thread_create(&helper, NULL, hold_output, NULL)) return 9;
        if (read(lockReady[0], &byte, 1) != 1) return 10;
    }
    return 17;
}
int buffered_parent(int argc, char **argv) {
    int output[2];
    if (ios_spawn_pipe(output)) return 2;
    int capacity = 1024;
    if (setsockopt(output[1], SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity))) return 3;
    ios_spawn_options options = {fileno(thread_stdin), output[1], fileno(thread_stderr), NULL, IOS_SPAWN_CANCEL_OUTPUT};
    char *arguments[] = {"buffered-branch", NULL};
    pid_t child;
    int error = ios_spawn(&child, arguments[0], &options, arguments, NULL);
    close(output[1]);
    if (error) return error;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child) return 4;
    char bytes[8192];
    size_t total = 0;
    ssize_t length;
    while ((length = read(output[0], bytes + total, sizeof(bytes) - total)) > 0) total += length;
    close(output[0]);
    bool passed = WIFEXITED(status) && WEXITSTATUS(status) == (!strcmp(mode, "full") ? 126 : 17);
    if (!strcmp(mode, "normal")) passed &= total == 9 && !memcmp(bytes, "BUFFERED\n", 9);
    dprintf(2, "buffered parent return: mode=%s bytes=%zu status=%d %s\n", mode, total, WEXITSTATUS(status), passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void timedOut(int number) { _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        mode = argv[1];
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(childReady) || pipe(childGate) || pipe(lockReady)) return 3;
        initializeEnvironment(); ios_switchSession("buffered-return"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"buffered-parent", @"buffered_parent", false);
        replaceCommand(@"buffered-branch", @"buffered_branch", false);
        replaceCommand(@"buffered-child", @"buffered_child", false);
        joinMainThread = true;
        return ios_system("buffered-parent") ? 1 : 0;
    }
}
