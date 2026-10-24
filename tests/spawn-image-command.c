#include "ios_spawn.h"
#include "ios_error.h"
#include <string.h>
#include <errno.h>
#include <sys/wait.h>
static int commandState;
int image_main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "child")) {
        int result = commandState != 0;
        commandState = 23;
        pid_t unavailable;
        char *nested[] = {"image-job", "child", NULL};
        if (ios_spawn(&unavailable, nested[0], NULL, nested, NULL) != EAGAIN) return 8;
        return result ? 7 : 0;
    }
    if (commandState) return 3;
    commandState = 7;
    pid_t child;
    char *arguments[] = {"image-job", "child", NULL};
    int error = ios_spawn(&child, arguments[0], NULL, arguments, NULL);
    if (error) return error;
    int status;
    if (ios_full_waitpid(child, &status, 0) != child || !WIFEXITED(status)) return 4;
    if (commandState != 7) return 23;
    return WEXITSTATUS(status);
}
