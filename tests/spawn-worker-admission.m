// The external worker transport writes a marker if admission is attempted.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <errno.h>
#include <signal.h>
#include <unistd.h>

static FILE *admissions;
int ashell_worker_spawn_ex(const char *line, const char *cwd, unsigned columns, unsigned rows,
                          const char *const *environment, void *options, int *fd, void **job) {
    fputs("EXTERNAL_WORKER_STARTED\n", admissions);
    fflush(admissions);
    return EIO;
}
int ashell_worker_cancel(void *job) { return 0; }
void ashell_worker_release(void *job) {}
int ashell_worker_poll(void *job, int *status) { return EIO; }
int ashell_worker_close_stdin(void *job) { return 0; }

int admission_leaf(int argc, char **argv) { return 0; }
int admission_parent(int argc, char **argv) {
    pid_t held[128];
    int count = 0, error = 0;
    char *leaf[] = {"admission-leaf", NULL};
    while (count < 128) {
        error = ios_spawn(&held[count], leaf[0], NULL, leaf, NULL);
        if (error) break;
        ++count;
    }
    char *command[] = {"external-command", NULL};
    pid_t child;
    int result = ios_posix_spawn(&child, command[0], NULL, NULL, command, NULL);
    fflush(admissions);
    rewind(admissions);
    bool started = fgetc(admissions) != EOF;
    for (int i = 0; i < count; ++i) ios_full_waitpid(held[i], NULL, 0);
    bool passed = count > 0 && error == EAGAIN && result == EAGAIN && !started;
    fprintf(thread_stdout, "WORKER_ADMISSION held=%d exhausted=%d result=%d started=%d %s\n", count, error, result, started, passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
static void timed_out(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timed_out); alarm(20);
        admissions = tmpfile();
        if (!admissions) return 1;
        initializeEnvironment(); ios_switchSession("worker-admission"); ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"admission-leaf", @"admission_leaf", false);
        replaceCommand(@"admission-parent", @"admission_parent", false);
        joinMainThread = true;
        int result = ios_system("admission-parent");
        fclose(admissions);
        return result ? 1 : 0;
    }
}
