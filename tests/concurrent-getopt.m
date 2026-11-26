// Commands that run at the same time share libc's optind. Every command thread resets it at start, so one
// command's option parsing can move another's: the second command then skips its argument. Eight threads
// run two small commands that parse options and print their first operand, and check each answer.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "hang-dump.h"
#import "ios_error.h"
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

#define THREADS 8
#define ROUNDS 300

static int operand_main(int argc, char **argv) {
    int ch;
    while ((ch = getopt(argc, argv, "ab")) != -1) usleep(2000);
    fprintf(thread_stdout, "%s\n", argv[optind] ? argv[optind] : "(none)");
    fflush(thread_stdout);
    return 0;
}
int tapa_main(int argc, char **argv) { return operand_main(argc, argv); }
int tapb_main(int argc, char **argv) { return operand_main(argc, argv); }

static atomic_int wrong, finished;
static char directory[PATH_MAX];
static dispatch_semaphore_t firstParsed, secondParsed;
static atomic_bool firstPreserved, secondValid;

int getopt_first_main(int argc, char **argv) {
    int option = getopt(argc, argv, "a");
    int before = optind;
    dispatch_semaphore_signal(firstParsed);
    bool ready = dispatch_semaphore_wait(secondParsed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0;
    int after = optind;
    bool passed = ready && option == 'a' && argc == 3 && before == 2 && after == before && !strcmp(argv[after], "left");
    atomic_store(&firstPreserved, passed);
    dprintf(STDERR_FILENO, "GETOPT_OVERLAP first=%d after=%d sibling_ready=%d %s\n", before, after, ready, passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}

int getopt_second_main(int argc, char **argv) {
    int option = getopt(argc, argv, "a");
    bool passed = option == -1 && argc == 2 && optind == 1 && !strcmp(argv[optind], "right");
    atomic_store(&secondValid, passed);
    dispatch_semaphore_signal(secondParsed);
    return passed ? 0 : 1;
}

static bool checkOrderedOverlap(void) {
    firstParsed = dispatch_semaphore_create(0);
    secondParsed = dispatch_semaphore_create(0);
    pid_t first = ios_fork();
    ios_system("getopt-first -a left");
    if (dispatch_semaphore_wait(firstParsed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        dprintf(STDERR_FILENO, "GETOPT_OVERLAP first did not parse its option\n");
        return false;
    }
    // The first command has already advanced optind, but has not returned.
    pid_t second = ios_fork();
    ios_system("getopt-second right");
    ios_waitpid(first);
    ios_waitpid(second);
    return atomic_load(&firstPreserved) && atomic_load(&secondValid);
}

static void check(const char *command, const char *output, const char *expected) {
    FILE *f = fopen(output, "r");
    char buffer[256] = "";
    if (f) { fread(buffer, 1, sizeof(buffer) - 1, f); fclose(f); }
    if (strcmp(buffer, expected) != 0) {
        if (atomic_fetch_add(&wrong, 1) < 3) fprintf(stderr, "concurrent-getopt: \"%s\" printed \"%s\", expected \"%s\"\n", command, buffer, expected);
    }
}

static void *worker(void *cookie) {
    long id = (long)cookie;
    char output[PATH_MAX], command[PATH_MAX * 2];
    snprintf(output, sizeof(output), "%s/out.%ld", directory, id);
    for (int i = 0; i < ROUNDS; i++) {
        pid_t pid = ios_fork();
        if (id % 2 == 0) {
            snprintf(command, sizeof(command), "tapa -a -b operand > %s", output);
            ios_system(command);
            ios_waitpid(pid);
            check(command, output, "operand\n");
        } else {
            snprintf(command, sizeof(command), "tapb operand > %s", output);
            ios_system(command);
            ios_waitpid(pid);
            check(command, output, "operand\n");
        }
    }
    atomic_fetch_add(&finished, 1);
    return NULL;
}

static void timedOut(int signal) {
    fprintf(stderr, "concurrent-getopt: FAIL, %d of %d threads finished\n", atomic_load(&finished), THREADS);
    dumpStacksAndExit();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(120);
        initializeEnvironment();
        ios_switchSession("concurrent-getopt-probe");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"tapa", @"tapa_main", false);
        replaceCommand(@"tapb", @"tapb_main", false);
        replaceCommand(@"getopt-first", @"getopt_first_main", false);
        replaceCommand(@"getopt-second", @"getopt_second_main", false);
        joinMainThread = false;
        bool isolated = checkOrderedOverlap();
        snprintf(directory, sizeof(directory), "%s/concurrent-getopt-%d", getenv("TMPDIR") ?: "/tmp", getpid());
        mkdir(directory, 0700);
        pthread_t threads[THREADS];
        for (long t = 0; t < THREADS; t++) pthread_create(&threads[t], NULL, worker, (void *)t);
        for (int t = 0; t < THREADS; t++) pthread_join(threads[t], NULL);
        alarm(0);
        if (atomic_load(&wrong)) {
            fprintf(stderr, "concurrent-getopt: FAIL, %d of %d commands gave a wrong answer\n", atomic_load(&wrong), THREADS * ROUNDS);
            return 1;
        }
        fprintf(stderr, "concurrent-getopt: %d threads x %d commands PASS\n", THREADS, ROUNDS);
        return isolated ? 0 : 1;
    }
}
