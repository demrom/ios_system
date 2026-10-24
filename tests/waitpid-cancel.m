// A thread cancelled while it waits in ios_waitpid must end at once and must not keep thread_completion_mutex: the
// command it waits for publishes its end under the same mutex, so one cancelled caller would hang every later
// ios_waitpid and command end. The test cancels a thread blocked in ios_waitpid, expects it to be cancelled well before
// the command ends, then waits for the command from the main thread. A watchdog exits 124 when the wait never ends.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

int nap_main(int argc, char **argv) {
    usleep(1500000);
    return 0;
}

static pid_t napPid;

static void *waiter(void *arg) {
    ios_waitpid(napPid);
    return NULL;
}

static void timedOut(int signal) {
    static const char message[] = "waitpid-cancel: FAIL, no end after 20 s\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _Exit(124);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(20);
        initializeEnvironment();
        ios_switchSession("waitpid-cancel-probe");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"nap", @"nap_main", false);
        joinMainThread = false;
        napPid = ios_fork();
        ios_system("nap");
        pthread_t thread;
        pthread_create(&thread, NULL, waiter, NULL);
        usleep(600 * 1000); // the waiter is in ios_waitpid by now
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        pthread_cancel(thread);
        void *result = NULL;
        pthread_join(thread, &result); // the command runs for another 0.9 s
        clock_gettime(CLOCK_MONOTONIC, &end);
        double joined = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
        ios_waitpid(napPid); // hangs here when the cancelled waiter kept the mutex
        BOOL passed = (result == PTHREAD_CANCELED) && joined < 0.5;
        fprintf(stderr, "waitpid-cancel: cancelled=%d joined after %.2fs %s\n", result == PTHREAD_CANCELED, joined, passed ? "PASS" : "FAIL");
        alarm(0);
        return passed ? 0 : 1;
    }
}
