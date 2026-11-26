// Exercise the public command dispatcher with the shipping utility frameworks.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

int writer_main(int argc, char **argv) {
    sigset_t interrupts, pending;
    sigemptyset(&interrupts);
    sigaddset(&interrupts, SIGINT);
    pthread_sigmask(SIG_BLOCK, &interrupts, NULL);
    fcntl(fileno(thread_stdout), F_SETNOSIGPIPE, 1);
    bool untilClosed = argc > 1 && strcmp(argv[1], "until-closed") == 0;
    unsigned int count = argc > 1 ? (unsigned int)atoi(argv[1]) : 10000;
    for (unsigned int i = 0; untilClosed || i < count; i++) {
        sigpending(&pending);
        if (sigismember(&pending, SIGINT)) {
            fprintf(thread_stderr, "WRITER interrupted after %u lines\n", i);
            return untilClosed ? 1 : 0;
        }
        if (fprintf(thread_stdout, "x %06u abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\n", i) < 0) {
            if (errno != EPIPE) return 1;
            if (untilClosed) fprintf(thread_stderr, "WRITER downstream closed\n");
            return 0;
        }
    }
    return fflush(thread_stdout) == 0 || errno == EPIPE ? 0 : 1;
}

int late_main(int argc, char **argv) {
    int status = writer_main(argc, argv);
    pid_t pid = ios_fork();
    ios_system("writer 1");
    ios_waitpid(pid);
    ios_releaseThreadId(pid);
    return status;
}

int nested_main(int argc, char **argv) {
    return ios_system("writer 10000 | head");
}

static void timed_out(int signal) {
    static const char message[] = "PIPELINE did not return before the 10s watchdog\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _Exit(124);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 64;
        signal(SIGALRM, timed_out);
        alarm(10);
        initializeEnvironment();
        if (!dlopen("@rpath/rg.framework/rg", RTLD_NOW | RTLD_GLOBAL)) {
            fprintf(stderr, "rg framework: %s\n", dlerror());
            return 2;
        }
        replaceCommand(@"rg", @"rg_ios_main", false);
        replaceCommand(@"writer", @"writer_main", false);
        replaceCommand(@"late", @"late_main", false);
        replaceCommand(@"nested", @"nested_main", false);
        joinMainThread = atoi(argv[1]);
        ios_switchSession("native-pipeline");
        FILE *input = fopen("/dev/null", "r");
        FILE *output = tmpfile();
        FILE *errors = tmpfile();
        if (!input || !output || !errors) return 2;
        ios_setStreams(input, output, errors);
        FILE *keyboard = NULL;
        if (strstr(argv[2], " | less") || strstr(argv[2], " | more")) {
            if (!dlopen("@rpath/files.framework/files", RTLD_NOW | RTLD_GLOBAL)) return 2;
            replaceCommand(@"less", @"less_main", false);
            replaceCommand(@"more", @"less_main", false);
            setenv("TERM", "xterm", 1);
            keyboard = tmpfile();
            if (!keyboard) return 2;
            fputs("q", keyboard);
            rewind(keyboard);
            ios_settty(keyboard);
            ios_setWindowSize(80, 24, "native-pipeline");
        }
        pid_t pid = ios_fork();
        int returned = ios_system(argv[2]);
        ios_waitpid(pid);
        ios_waitpid(0);
        int status = ios_getCommandStatus();
        if (keyboard) {
            pid_t next = ios_fork();
            int nextReturned = ios_system("writer 1");
            ios_waitpid(next);
            ios_waitpid(0);
            fprintf(errors, "FOLLOWUP returned=%d status=%d\n", nextReturned, ios_getCommandStatus());
            fclose(keyboard);
        }
        fflush(output);
        fflush(errors);
        rewind(output);
        rewind(errors);
        char buffer[4096];
        size_t count;
        while ((count = fread(buffer, 1, sizeof buffer, output))) write(STDOUT_FILENO, buffer, count);
        while ((count = fread(buffer, 1, sizeof buffer, errors))) write(STDERR_FILENO, buffer, count);
        int length = snprintf(buffer, sizeof buffer, "RESULT returned=%d status=%d\n", returned, status);
        write(STDERR_FILENO, buffer, length);
        alarm(0);
        return status;
    }
}
