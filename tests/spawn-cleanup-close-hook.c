#include <stdio.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
extern int closing[2], releaseClose[2];
extern struct stat selectedInput;
extern atomic_bool pauseClose;

// Interpose the OS boundary so stream cleanup has a deterministic observation window.
static int paused_fclose(FILE *stream) {
    struct stat state;
    bool expected = true;
    if (!fstat(fileno(stream), &state) && state.st_dev == selectedInput.st_dev &&
        state.st_ino == selectedInput.st_ino &&
        atomic_compare_exchange_strong(&pauseClose, &expected, false)) {
        char byte;
        if (write(closing[1], "C", 1) != 1 || read(releaseClose[0], &byte, 1) != 1) _Exit(2);
    }
    return fclose(stream);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } closeInterpose = {
    (const void *)paused_fclose, (const void *)fclose
};
