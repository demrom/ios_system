#import <Foundation/Foundation.h>
#import "ios_system.h"
#include <signal.h>
#include <unistd.h>
static void timedOut(int number) { _Exit(124); }
int main(void) {
    @autoreleasepool {
        signal(SIGALRM, timedOut); alarm(10);
        initializeEnvironment(); ios_switchSession("native-images");
        ios_setStreams(stdin, stdout, stderr); joinMainThread = true;
        for (int iteration = 0; iteration < 3; iteration++) {
            int result = ios_system("image-job parent");
            dprintf(2, "parent/child mutable image state, reuse%d: result=%d\n", iteration + 1, result);
            if (result) return 1;
        }
        dprintf(2, "independent command images and sequential reuse: PASS\n");
        return 0;
    }
}
