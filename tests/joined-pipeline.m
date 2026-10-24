#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <poll.h>
#include <signal.h>
#include <unistd.h>

static int consumerDone[2];
int joined_producer(int argc, char **argv) {
    fputs("input\n", thread_stdout);
    return 0;
}
int joined_consumer(int argc, char **argv) {
    while (fgetc(thread_stdin) != EOF) {}
    usleep(250000);
    write(consumerDone[1], "D", 1);
    return 37;
}
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        if (pipe(consumerDone)) return 2;
        initializeEnvironment(); ios_switchSession("joined-pipeline");
        ios_setStreams(stdin, stdout, stderr);
        replaceCommand(@"joined-producer", @"joined_producer", false);
        replaceCommand(@"joined-consumer", @"joined_consumer", false);
        joinMainThread = true;
        int status = ios_system("joined-producer | joined-consumer");
        struct pollfd completion = {consumerDone[0], POLLIN, 0};
        int completed = poll(&completion, 1, 0);
        bool passed = completed == 1 && status == 37;
        dprintf(2, "joined pipeline returns after last stage: completed=%d status=%d %s\n", completed, status, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
