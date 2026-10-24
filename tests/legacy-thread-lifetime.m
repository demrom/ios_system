#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <dispatch/dispatch.h>
#include <sys/wait.h>
#include <unistd.h>
int lifetime_child(int argc, char **argv) { return 7; }
int lifetime_parent(int argc, char **argv) {
    for (int iteration = 0; iteration < 32; iteration++) {
        pid_t child = ios_fork();
        if (child < 0) return 90;
        ios_system("lifetime-child");
        int status;
        if (ios_full_waitpid(child, &status, 0) != child ||
            !WIFEXITED(status) || WEXITSTATUS(status) != 7) return 91;
    }
    return 0;
}
int main(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _Exit(124); });
        initializeEnvironment();
        replaceCommand(@"lifetime-child", @"lifetime_child", false);
        replaceCommand(@"lifetime-parent", @"lifetime_parent", false);
        for (int joined = 0; joined < 2; joined++) {
            ios_switchSession(joined ? "legacy-thread-lifetime-joined" : "legacy-thread-lifetime-detached");
            ios_setStreams(stdin, stdout, stderr);
            joinMainThread = joined;
            pid_t parent = ios_fork();
            if (parent < 0) return 92;
            ios_system("lifetime-parent");
            int status;
            if (ios_full_waitpid(parent, &status, 0) != parent ||
                !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 93;
            dprintf(2, "LEGACY_THREAD_LIFETIME joined=%d PASS\n", joined);
        }
        return 0;
    }
}
