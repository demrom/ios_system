// Exercise the public command snapshot API with the real Simulator runtime.
#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

extern int ashell_owned_command_name(FILE *, char *, size_t);


static dispatch_semaphore_t started, finish;
static FILE *input, *output, *errors;
int term_state_fixture(int argc, char **argv) {
    // Commands may rewrite argv; the exported snapshot must remain stable.
    argv[0][0] = 'X';
    dispatch_semaphore_signal(started);
    dispatch_semaphore_wait(finish, DISPATCH_TIME_FOREVER);
    return 0;
}
static void *run(void *context) {
    @autoreleasepool {
        ios_switchSession(context);
        ios_setStreams(input, output, errors);
        thread_stdin = input;
        thread_stdout = output;
        thread_stderr = errors;
        pid_t pid = ios_fork();
        assert(ios_system("state-fixture") == 0);
        ios_waitpid(pid);
        ios_releaseThreadId(pid);
    }
    return NULL;
}
static void timeout_handler(int signal) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timeout_handler);
        alarm(10);
        initializeEnvironment();
        joinMainThread = true;
        input = tmpfile(); output = tmpfile(); errors = tmpfile();
        assert(input && output && errors);
        void *owner = NULL;
        assert(ashell_register_owned_streams(input, output, errors, &owner) == 0);
        char command[1024];
        assert(ashell_owned_command_name(NULL, command, sizeof(command)) == EINVAL);
        assert(ashell_owned_command_name(output, command, sizeof(command)) == EAGAIN);
        started = dispatch_semaphore_create(0);
        finish = dispatch_semaphore_create(0);
        pthread_t thread;
        assert(pthread_create(&thread, NULL, run, "term-state-test") == 0);
        if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            char message[4096];
            ssize_t count = pread(fileno(errors), message, sizeof(message), 0);
            if (count > 0) write(STDERR_FILENO, message, count);
            abort();
        }
        assert(ashell_owned_command_name(output, command, sizeof(command)) == 0);
        assert(strcmp(command, "state-fixture") == 0);
        assert(ashell_owned_command_name(output, command, 2) == ENOSPC);
        assert(ashell_owned_command_name(errors, command, sizeof(command)) == EAGAIN);
        dispatch_semaphore_signal(finish);
        pthread_join(thread, NULL);
        ashell_wait_owned_streams(owner);
        assert(ashell_owned_command_name(output, command, sizeof(command)) == EAGAIN);
        ashell_unregister_owned_streams(&owner);
        assert(ashell_owned_command_name(output, command, sizeof(command)) == EAGAIN);
        fclose(input); fclose(output); fclose(errors);
        puts("PASS: public ios_system command snapshot, stream isolation, bounds and cleanup");
    }
    return 0;
}
