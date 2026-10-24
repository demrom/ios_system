#include <stdlib.h>
#include "ios_error.h"
static void report_cleanup(void) { fputs("IMAGE_CLEANUP\n", thread_stderr); }
int unload_main(int argc, char **argv) { return atexit(report_cleanup); }
