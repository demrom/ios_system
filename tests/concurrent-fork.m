// Several threads start short commands behind ios_fork while other commands end. A command that
// ends must not move current_pid under a thread that has just forked: the new command's slot would
// stay "not started" for ever and its ios_waitpid would never return.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "ios_system.h"
#include "hang-dump.h"
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define THREADS 8
#define ROUNDS 400
#ifndef CONCURRENT_FORK_WATCHDOG_SECONDS
#define CONCURRENT_FORK_WATCHDOG_SECONDS 120
#endif

int tick_main(int argc, char **argv) {
    return 0;
}

static dispatch_semaphore_t ready[2], finish[2];

int held_tick_main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "older") && strcmp(argv[1], "newer"))) return 2;
    int slot = !strcmp(argv[1], "newer");
    dispatch_semaphore_signal(ready[slot]);
    dispatch_semaphore_wait(finish[slot], DISPATCH_TIME_FOREVER);
    return slot ? 23 : 17;
}

static int verifyReservation(void) {
    const char *sessions[] = {"pid-reservation-older", "pid-reservation-newer"};
    const char *commands[] = {"held-tick older", "held-tick newer"};
    pid_t pids[2];
    replaceCommand(@"held-tick", @"held_tick_main", false);
    for (int slot = 0; slot < 2; slot++) {
        ready[slot] = dispatch_semaphore_create(0);
        finish[slot] = dispatch_semaphore_create(0);
        ios_switchSession(sessions[slot]);
        ios_setStreams(stdin, stdout, stderr);
        pids[slot] = ios_fork();
        ios_system(commands[slot]);
        if (dispatch_semaphore_wait(ready[slot], dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            fprintf(stderr, "PID_RESERVATION command %d did not start\n", slot);
            return 2;
        }
    }
    pid_t before = ios_currentPid();
    int older_status, newer_status;
    dispatch_semaphore_signal(finish[0]);
    ios_full_waitpid(pids[0], &older_status, 0);
    pid_t after = ios_currentPid();
    int delivered = WIFEXITED(older_status) ? WEXITSTATUS(older_status) : -1;
    int still_running = ios_full_waitpid(pids[1], &newer_status, WNOHANG) == 0;
    dispatch_semaphore_signal(finish[1]);
    ios_full_waitpid(pids[1], &newer_status, 0);
    int next_status = WIFEXITED(newer_status) ? WEXITSTATUS(newer_status) : -1;
    bool pass = before == pids[1] && after == pids[1] && still_running && delivered == 17 && next_status == 23;
    fprintf(stderr, "PID_RESERVATION newer=%d before=%d after=%d running=%d statuses=%d/%d %s\n",
        pids[1], before, after, still_running, delivered, next_status, pass ? "PASS" : "FAIL");
    return !pass;
}

static atomic_int finished;
static volatile sig_atomic_t checkingReservation;

static void *worker(void *unused) {
    for (int i = 0; i < ROUNDS; i++) {
        pid_t pid = ios_fork();
        ios_system("tick");
        ios_waitpid(pid);
    }
    atomic_fetch_add(&finished, 1);
    return NULL;
}

static void timedOut(int signal) {
    if (checkingReservation) fputs("PID_RESERVATION timed out waiting for command completion\n", stderr);
    else fprintf(stderr, "concurrent-fork: FAIL, %d of %d threads finished, ios_waitpid never returned\n", atomic_load(&finished), THREADS);
    dumpStacksAndExit();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(CONCURRENT_FORK_WATCHDOG_SECONDS);
        initializeEnvironment();
        ios_switchSession("concurrent-fork-probe");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"tick", @"tick_main", false);
        joinMainThread = false;
        if (argc == 2 && !strcmp(argv[1], "--reservation")) {
            checkingReservation = 1;
            alarm(20);
            int status = verifyReservation();
            alarm(0);
            return status;
        }
        pthread_t threads[THREADS];
        for (int t = 0; t < THREADS; t++) pthread_create(&threads[t], NULL, worker, NULL);
        for (int t = 0; t < THREADS; t++) pthread_join(threads[t], NULL);
        alarm(0);
        fprintf(stderr, "concurrent-fork: %d threads x %d commands PASS\n", THREADS, ROUNDS);
        return 0;
    }
}
