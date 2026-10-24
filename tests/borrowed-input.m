#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

static FILE *input, *output, *errors;
static dispatch_semaphore_t entered, leave, finished;
static int commandStatus;

int borrowed_noop(int argc, char **argv) {
    dispatch_semaphore_signal(entered);
    dispatch_semaphore_wait(leave, DISPATCH_TIME_FOREVER);
    dprintf(2, "COMMAND_BODY_RETURN\n");
    return 0;
}

static void *readInput(void *unused) {
    int byte = fgetc(input);
    dprintf(2, "READER_RETURN byte=%d\n", byte);
    return NULL;
}

static void *runCommand(void *unused) {
    @autoreleasepool {
        ios_switchSession("borrowed-input");
        ios_setStreams(input, output, errors);
        commandStatus = ios_system("borrowed-noop");
        dispatch_semaphore_signal(finished);
    }
    return NULL;
}

static void timedOut(int number) { _Exit(124); }

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGALRM, timedOut);
        alarm(30);
        int descriptors[2];
        if (pipe(descriptors)) return 2;
        input = fdopen(descriptors[0], "r");
        output = tmpfile();
        errors = tmpfile();
        if (!input || !output || !errors) return 3;
        initializeEnvironment();
        replaceCommand(@"borrowed-noop", @"borrowed_noop", false);
        void *registration = NULL;
        if (argc == 1 && ashell_register_owned_streams(input, output, errors, &registration)) return 4;
        entered = dispatch_semaphore_create(0);
        leave = dispatch_semaphore_create(0);
        finished = dispatch_semaphore_create(0);
        joinMainThread = true;
        pthread_t command, reader;
        if (pthread_create(&command, NULL, runCommand, NULL)) return 5;
        if (dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC))) return 6;
        if (pthread_create(&reader, NULL, readInput, NULL)) return 7;
        bool locked = false;
        for (int i = 0; i < 1000; i++) {
            if (ftrylockfile(input)) { locked = true; break; }
            funlockfile(input);
            usleep(1000);
        }
        if (!locked) return 8;
        dprintf(2, "SHARED_INPUT_READER_BLOCKED\n");
        dispatch_semaphore_signal(leave);
        bool completed = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0;
        dprintf(2, "COMMAND_COMPLETED_BEFORE_INPUT=%d\n", completed);
        if (write(descriptors[1], "x", 1) != 1) return 9;
        pthread_join(reader, NULL);
        pthread_join(command, NULL);
        ashell_unregister_owned_streams(&registration);
        fclose(input); fclose(output); fclose(errors); close(descriptors[1]);
        dprintf(2, "BORROWED_INPUT status=%d %s\n", commandStatus, completed && commandStatus == 0 ? "PASS" : "FAIL");
        return completed && commandStatus == 0 ? 0 : 1;
    }
}
