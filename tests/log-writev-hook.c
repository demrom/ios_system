#include <sys/uio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
extern int logReady[2], logGate[2];
extern atomic_bool holdLog;
// Hold the Foundation stderr write while its logging lock is owned.
static ssize_t held_writev(int fd, const struct iovec *vectors, int count) {
    for (int i = 0; i < count; i++) {
        bool expected = true;
        if (strnstr(vectors[i].iov_base, "Could not find function stopInteractive", vectors[i].iov_len) &&
            atomic_compare_exchange_strong(&holdLog, &expected, false)) {
            char byte;
            if (write(logReady[1], "R", 1) != 1 || read(logGate[0], &byte, 1) != 1) _Exit(2);
            break;
        }
    }
    return writev(fd, vectors, count);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } logInterpose = {
    (const void *)held_writev, (const void *)writev
};
