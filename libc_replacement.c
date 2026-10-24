//
//  libc_replacement.c
//  ios_system
//
//  Created by Nicolas Holzschuch on 30/04/2018.
//  Copyright © 2018 Nicolas Holzschuch. All rights reserved.
//
#include <stdlib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <wchar.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/param.h>
#include <stdatomic.h>
#include <dlfcn.h>  // for dlopen()/dlsym()/dlclose()

#include "ios_error.h"
#undef write
#undef fwrite
#undef puts
#undef fputs
#undef fputc
#undef putw
#undef putp
#undef fflush
#undef getenv
#undef setenv
#undef unsetenv

// in order to run webAssembly commands sequentially, we first stack them, then run them in command line order:
// At this point, this could just be a mutex.

_Atomic int preparingWebAssemblyCommands = 0;
_Atomic int orderOfWebAssemblyCommands = 0;
__thread int currentWebAssemblyCommandOrder = 0;
int startedPreparingWebAssemblyCommand(void) {
    preparingWebAssemblyCommands += 1;
    return atomic_fetch_add(&orderOfWebAssemblyCommands, 1) + 1;
}

int webAssemblyCommandOrder(void) {
    return currentWebAssemblyCommandOrder;
}

void finishedPreparingWebAssemblyCommand(void) {
    if (preparingWebAssemblyCommands > 0)
        preparingWebAssemblyCommands -= 1;
}

static void executeWebAssemblyCommandsInOrder(void) {
    void (*function)(void) = NULL;
    if (function == NULL) {
        function = dlsym(RTLD_MAIN_ONLY, "executeWebAssemblyCommands");
    }
    if (function == NULL) {
        // more extensive search, but more expensive too.
        function = dlsym(RTLD_DEFAULT, "executeWebAssemblyCommands");
    }
    if (function != NULL) {
        while (preparingWebAssemblyCommands > 0) {
            // Empty loops create problems in Release mode.
            if (thread_stdout != NULL) { fflush(thread_stdout); }
            if (thread_stderr != NULL) { fflush(thread_stderr); }
        }
        function();
    }
    orderOfWebAssemblyCommands = 0;
}


int printf (const char *format, ...) {
    va_list arg;
    int done;
    
    va_start (arg, format);
    done = vfprintf (thread_stdout, format, arg);
    va_end (arg);
    
    return done;
}

// #define debugPrint
int fprintf(FILE * restrict stream, const char * restrict format, ...) {
    va_list arg;
    int done;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (thread_stdout == NULL) thread_stdout = stdout;

    va_start (arg, format);
    if (fileno(stream) == STDOUT_FILENO) done = vfprintf (thread_stdout, format, arg);
#ifndef debugPrint
    else if (fileno(stream) == STDERR_FILENO) done = vfprintf (thread_stderr, format, arg);
#else
    // iOS, debug:
    else if ((fileno(stream) == STDERR_FILENO) || (fileno(stream) == fileno(thread_stderr))) done = vfprintf (stderr, format, arg);
#endif
    else done = vfprintf (stream, format, arg);
    va_end (arg);
    
    return done;
}
int scanf (const char *format, ...) {
    int             count;
    va_list ap;
    
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stdin == NULL) thread_stdin = stdin;

    fflush(thread_stdout);
    fflush(thread_stderr);
    va_start (ap, format);
    count = vfscanf (thread_stdin, format, ap);
    va_end (ap);
    return (count);
}
int ios_fflush(FILE *stream) {
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (stream == NULL) {
        // Do not flush streams owned by concurrently running commands.
        int output = fflush(thread_stdout);
        int error = thread_stderr == thread_stdout ? 0 : fflush(thread_stderr);
        return output || error ? EOF : 0;
    }

    if (fileno(stream) == STDOUT_FILENO) return fflush(thread_stdout);
    if (fileno(stream) == STDERR_FILENO) return fflush(thread_stderr);
    return fflush(stream);
}
ssize_t ios_write(int fildes, const void *buf, size_t nbyte) {
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fildes == STDOUT_FILENO) return write(fileno(thread_stdout), buf, nbyte);
    if (fildes == STDERR_FILENO) return write(fileno(thread_stderr), buf, nbyte);
    return write(fildes, buf, nbyte);
}
size_t ios_fwrite(const void *restrict ptr, size_t size, size_t nitems, FILE *restrict stream) {
#ifdef debugPrint
    return fwrite(ptr, size, nitems, stderr);
#endif
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fileno(stream) == STDOUT_FILENO) return fwrite(ptr, size, nitems, thread_stdout);
    if (fileno(stream) == STDERR_FILENO) return fwrite(ptr, size, nitems, thread_stderr);
    return fwrite(ptr, size, nitems, stream);
}
int ios_puts(const char *s) {
    if (thread_stdout == NULL) thread_stdout = stdout;
    // puts adds a newline at the end.
    int returnValue = fputs(s, thread_stdout);
    fputc('\n', thread_stdout);
    return returnValue;
}
int ios_fputs(const char* s, FILE *stream) {
#ifdef debugPrint
    return fputs(s, stderr);
#endif
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fileno(stream) == STDOUT_FILENO) return fputs(s, thread_stdout);
    if (fileno(stream) == STDERR_FILENO) return fputs(s, thread_stderr);
    return fputs(s, stream);
}
int ios_fputc(int c, FILE *stream) {
#ifdef debugPrint
    return fputc(c, stderr);
#endif
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fileno(stream) == STDOUT_FILENO) return fputc(c, thread_stdout);
    if (fileno(stream) == STDERR_FILENO) return fputc(c, thread_stderr);
    return fputc(c, stream);
}

#include <assert.h>

int ios_putw(int w, FILE *stream) {
    if (thread_stdout == NULL) thread_stdout = stdout;
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fileno(stream) == STDOUT_FILENO) return putw(w, thread_stdout);
    if (fileno(stream) == STDERR_FILENO) return putw(w, thread_stderr);
    return putw(w, stream);
}

// Fake process IDs to go with fake forking:
// You will still need to edit your code to make sure you go through both branches.
#define IOS_MAX_THREADS 128
static _Atomic(pthread_t) thread_ids[IOS_MAX_THREADS];
static _Atomic int command_status[IOS_MAX_THREADS];
static bool native_reservations[IOS_MAX_THREADS];
static pthread_mutex_t thread_completion_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t thread_completed = PTHREAD_COND_INITIALIZER;

static void unlockThreadCompletion(void *mutex) {
    pthread_mutex_unlock(mutex);
}

void ios_notifyThreadCompletion(void) {
    pthread_mutex_lock(&thread_completion_mutex);
    pthread_cond_broadcast(&thread_completed);
    pthread_mutex_unlock(&thread_completion_mutex);
}
// A session can have several children; its last status does not identify a PID.
void ios_storePidStatus(pid_t pid, int status) {
    if (pid > 0 && pid < IOS_MAX_THREADS)
        atomic_store(&command_status[pid], status & 0xff);
}

void ios_storeCommandStatus(int status) {
    pthread_t thread = pthread_self();
    for (int pid = 1; pid < IOS_MAX_THREADS; pid++) {
        if (atomic_load(&thread_ids[pid]) == thread) {
            ios_storePidStatus(pid, status);
            return;
        }
    }
}

int ios_pidStatus(pid_t pid) {
    return pid > 0 && pid < IOS_MAX_THREADS ? atomic_load(&command_status[pid]) : -1;
}

static int wait_status(pid_t pid) {
    return pid > 0 && pid < IOS_MAX_THREADS ?
        atomic_load(&command_status[pid]) : ios_getCommandStatus();
}

static int numVariablesSet[IOS_MAX_THREADS];
static char** environment[IOS_MAX_THREADS];
static char** copyEnvironment[IOS_MAX_THREADS];
static char previousDirectory[IOS_MAX_THREADS][MAXPATHLEN];
static int previousPid[IOS_MAX_THREADS];

static int pid_overflow = 0;
static pid_t current_pid = 0;
static __thread pid_t dispatched_pid;
static __thread pid_t native_pid = -1;
static __thread pid_t native_dispatch_parent = -1;
static __thread int legacy_dispatch_cancellation = -1;

pid_t ios_nativePid(void) { return native_pid; }
pid_t ios_dispatchedPid(void) { return dispatched_pid; }
void ios_bindNativePid(pid_t pid) { native_pid = pid; native_dispatch_parent = -1; }
pid_t ios_takeNativeDispatchParent(void) {
    pid_t parent = native_dispatch_parent;
    native_dispatch_parent = -1;
    return parent;
}
int ios_takeLegacyDispatchCancellation(void) {
    int state = legacy_dispatch_cancellation;
    legacy_dispatch_cancellation = -1;
    return state;
}
// We need to lock current_pid during operations
pthread_mutex_t pid_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pid_registered = PTHREAD_COND_INITIALIZER;
static pid_t legacy_registration_pid;
_Atomic(int) cleanup_counter = 0;
static pid_t last_allocated_pid = 0;

void ios_waitForPidRegistration(void) {
    pthread_mutex_lock(&pid_mtx);
    while (legacy_registration_pid) pthread_cond_wait(&pid_registered, &pid_mtx);
    pthread_mutex_unlock(&pid_mtx);
}

extern void ios_resetPidWorkerState(pid_t pid);

// The caller holds pid_mtx until every result has been copied.
int ios_consumePidStatusLocked(pid_t pid) {
    int status = wait_status(pid);
    native_reservations[pid] = false;
    ios_resetPidWorkerState(pid);
    return status;
}

static int consume_wait_status(pid_t pid) {
    if (pid <= 0 || pid >= IOS_MAX_THREADS) return wait_status(pid);
    pthread_mutex_lock(&pid_mtx);
    int status = ios_consumePidStatusLocked(pid);
    pthread_mutex_unlock(&pid_mtx);
    return status;
}

extern int ios_interruptpid(pid_t pid);

void ios_reapNativeChildren(pid_t parent) {
    for (pid_t child = 1; child < IOS_MAX_THREADS; child++) {
        pthread_mutex_lock(&pid_mtx);
        bool owned = native_reservations[child] && previousPid[child] == parent;
        // Worker proxies are not in the native command tree. Cancel them before
        // cleanup waits, while the reservation still identifies this parent's child.
        if (owned) ios_interruptpid(child);
        pthread_mutex_unlock(&pid_mtx);
        if (owned) ios_waitpid(child);
    }
}


void makeGlobal(void) {
    pid_t pid = ios_currentPid();
    copyEnvironment[pid] = environment[pid];
    environment[pid] = NULL; // makes it really global
}
void makeLocal(void) {
    pid_t pid = ios_currentPid();
    environment[pid] = copyEnvironment[pid];
    copyEnvironment[pid] = NULL;
}

inline pthread_t ios_getThreadId(pid_t pid) {
    // return ios_getLastThreadId(); // previous behaviour
    if (pid >= IOS_MAX_THREADS) { return -1; }
    return thread_ids[pid];
}

void newPreviousDirectory(void) {
    pid_t pid = ios_currentPid();
    // Called when a command calls "cd". Actually changes the directory for that command.
    getwd(previousDirectory[pid]);
}

// We do not recycle process ids too quickly to avoid collisions.
void storeEnvironment(char* envp[]);
static void storeEnvironmentForPid(char *const envp[], pid_t pid);
static inline pid_t ios_nextAvailablePid(bool native) {
    while (cleanup_counter > 0) { } // Don't start a command while another is ending.
    int cancellation = -1;
    if (!native) {
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cancellation);
        legacy_dispatch_cancellation = cancellation;
    }
    // fprintf(stderr, "Locking in ios_nextAvailablePid\n");
    pthread_mutex_lock(&pid_mtx);
    while (legacy_registration_pid) pthread_cond_wait(&pid_registered, &pid_mtx);
    char** currentEnvironment = environmentVariables(ios_currentPid());
    int previousPidId = ios_currentPid();
    pid_t allocatedPid;
    if (!pid_overflow && (last_allocated_pid < IOS_MAX_THREADS - 1)
        && (thread_ids[last_allocated_pid+1] == 0)
        && !native_reservations[last_allocated_pid+1]) {
        allocatedPid = last_allocated_pid + 1;
        last_allocated_pid = allocatedPid;
        native_reservations[allocatedPid] = native;
        command_status[allocatedPid] = 130; // Cancellation before a recorded exit.
        ios_resetPidWorkerState(allocatedPid);
        thread_ids[allocatedPid] = -1; // Not yet started
        numVariablesSet[allocatedPid] = 0;
        environment[allocatedPid] = NULL;
        storeEnvironmentForPid(currentEnvironment, allocatedPid); // duplicate the environment variables
        getwd(previousDirectory[allocatedPid]); // store current working directory
        previousPid[allocatedPid] = previousPidId;
        if (!native && native_pid < 0) {
            current_pid = allocatedPid;
            legacy_registration_pid = allocatedPid;
        }
        // fprintf(stderr, "Returning from ios_nextAvailablePid, pid= %d\n", current_pid);
        if (native_pid >= 0) {
            native_dispatch_parent = native_pid;
            native_pid = allocatedPid;
        }
        pthread_mutex_unlock(&pid_mtx);
        return allocatedPid;
    }
    // We've already started more than IOS_MAX_THREADS threads.
    pid_overflow = 1;
    int candidates = 0;
    while (1) {
        if (candidates++ >= IOS_MAX_THREADS - 1) {
            pthread_mutex_unlock(&pid_mtx);
            if (!native) {
                legacy_dispatch_cancellation = -1;
                pthread_setcancelstate(cancellation, NULL);
            }
            return -1;
        }
        allocatedPid = last_allocated_pid + 1;
        last_allocated_pid = allocatedPid;
        if (allocatedPid >= IOS_MAX_THREADS) {
            allocatedPid = 1;
            last_allocated_pid = 1;
        }
        pthread_t thread_pid = ios_getThreadId(allocatedPid);
        if (thread_pid == 0 && !native_reservations[allocatedPid]) { // We found a not-active pid
            native_reservations[allocatedPid] = native;
            command_status[allocatedPid] = 130; // Cancellation before a recorded exit.
            ios_resetPidWorkerState(allocatedPid);
            thread_ids[allocatedPid] = -1; // Not yet started
            numVariablesSet[allocatedPid] = 0;
            environment[allocatedPid] = NULL;
            storeEnvironmentForPid(currentEnvironment, allocatedPid); // duplicate the environment variables
            getwd(previousDirectory[allocatedPid]); // store current working directory
            previousPid[allocatedPid] = previousPidId;
            if (!native && native_pid < 0) {
                current_pid = allocatedPid;
                legacy_registration_pid = allocatedPid;
            }
            // fprintf(stderr, "Returning from ios_nextAvailablePid, pid= %d\n", current_pid);
            if (native_pid >= 0) {
                native_dispatch_parent = native_pid;
                native_pid = allocatedPid;
            }
            pthread_mutex_unlock(&pid_mtx);
            return allocatedPid;
        }
        // Dangerous: if the process is already killed, this wil crash
        /*
        if (pthread_kill(thread_pid, 0) != 0) {
            thread_ids[current_pid] = 0;
            return current_pid; // not running anymore
        }
        */
    }
}

void ios_storeThreadIdForPid(pid_t pid, pthread_t thread) {
    pthread_mutex_lock(&pid_mtx);
    // To avoid issues when a command starts a command without forking,
    // we only store thread IDs for the first thread of the "process".
    // fprintf(stderr, "Unlocking pid %d, storing thread %x current value: %x\n", current_pid, thread,  thread_ids[pid]);
    if (thread_ids[pid] == -1) {
        if (thread) dispatched_pid = pid;
        thread_ids[pid] = thread;
        if (!thread) ios_notifyThreadCompletion();
    }
    if (legacy_registration_pid == pid) {
        legacy_registration_pid = 0;
        pthread_cond_broadcast(&pid_registered);
    }
    pthread_mutex_unlock(&pid_mtx);
}

inline void ios_storeThreadId(pthread_t thread) {
    ios_storeThreadIdForPid(ios_currentPid(), thread);
}


char* libc_getenv(const char* variableName) {
    pid_t pid = ios_currentPid();
    if (environment[pid] != NULL) {
        if (variableName == NULL) { return NULL; }
        // fprintf(stderr, "libc_getenv: %s\n", variableName); fflush(stderr);
        char** envp = environment[pid];
        unsigned long varNameLen = strlen(variableName);
        if (varNameLen == 0) { return NULL; }
        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (envp[i] == NULL) { continue; }
            if (strlen(envp[i]) < varNameLen) { continue; }
            if (strncmp(variableName, envp[i], varNameLen) == 0) {
                if (strlen(envp[i]) > varNameLen) {
                    if (envp[i][varNameLen] == '=') {
                        return envp[i] + varNameLen + 1;
                    }
                }
            }
            /*
            char* position = strchr(envp[i],'=');
            if (strncmp(variableName, envp[i], position - envp[i]) == 0) {
                char* value = position + 1;
                return value;
            }
             */
        }
        return NULL;
    } else {
        return getenv(variableName);
    }
}

extern void set_session_errno(int n);
int ios_setenv_pid(const char* variableName, const char* value, int overwrite, int pid) {
    if (environment[pid] != NULL) {
        if (variableName == NULL) {
            set_session_errno(EINVAL);
            return -1;
        }
        if (strlen(variableName) == 0) {
            set_session_errno(EINVAL);
            return -1;
        }
        char* position = strchr(variableName,'=');
        if (position != NULL) {
            set_session_errno(EINVAL);
            return -1;
        }
        char** envp = environment[pid];
        unsigned long varNameLen = strlen(variableName);
        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (envp[i] == NULL) { continue; }
            if (strncmp(variableName, envp[i], varNameLen) == 0) {
                if (strlen(envp[i]) > varNameLen) {
                    if (envp[i][varNameLen] == '=') {
                        // This variable is defined in the current environment:
                        if (overwrite == 0) { return 0; }
                        envp[i] = realloc(envp[i], strlen(variableName) + strlen(value) + 2);
                        sprintf(envp[i], "%s=%s", variableName, value);
                        return 0;
                    }
                }
            }
        }
        // Not found so far, add it to the list:
        int pos = numVariablesSet[pid];
        environment[pid] = realloc(envp, (numVariablesSet[pid] + 2) * sizeof(char*));
        environment[pid][pos] = malloc(strlen(variableName) + strlen(value) + 2);
        environment[pid][pos + 1] = NULL;
        sprintf(environment[pid][pos], "%s=%s", variableName, value);
        numVariablesSet[pid] += 1;
        return 0;
    } else {
        return setenv(variableName, value, overwrite);
    }
}

int ios_setenv_parent(const char* variableName, const char* value, int overwrite) {
    pid_t pid = ios_currentPid();
    return ios_setenv_pid(variableName, value, overwrite, previousPid[pid]);
}

int ios_setenv(const char* variableName, const char* value, int overwrite) {
    pid_t pid = ios_currentPid();
    return ios_setenv_pid(variableName, value, overwrite, pid);
}

int ios_putenv(char* string) {
    pid_t pid = ios_currentPid();
    if (environment[pid] != NULL) {
        unsigned length;
        char     *temp;

        /*  Find the length of the "NAME="  */
        temp = strchr(string,'=');
        if ( temp == 0 ) {
            set_session_errno(EINVAL);
            return( -1 );
        }
        length = (unsigned) (temp - string + 1);

        /*  Scan through the environment looking for "NAME="  */
        char** envp = environment[pid];

        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (envp[i] == NULL) { continue; }
            if ( strncmp( string, envp[i], length ) == 0 ) {
                // Found it. Copy in place.
                envp[i] = realloc(envp[i], strlen(string) + 1);
                memcpy(envp[i], string, strlen(string) + 1);
                return 0;
            }
        }
        // Not found so far, add it to the list:
        int pos = numVariablesSet[pid];
        environment[pid] = realloc(envp, (numVariablesSet[pid] + 2) * sizeof(char*));
        environment[pid][pos] = malloc(strlen(string) + 1);
        environment[pid][pos + 1] = NULL;
        memcpy(environment[pid][pos], string, strlen(string) + 1);
        numVariablesSet[pid] += 1;
        return 0;
    } else {
        return putenv(string);
    }
}

int ios_unsetenv_pid(const char* variableName, int pid) {
    // Someone calls unsetenv once the process has been terminated.
    // Best thing to do is erase the environment and return
    if (environment[pid] != NULL) {
        if (variableName == NULL) {
            set_session_errno(EINVAL);
            return -1;
        }
        if (strlen(variableName) == 0) {
            set_session_errno(EINVAL);
            return -1;
        }
        char* position = strchr(variableName,'=');
        if (position != NULL) {
            set_session_errno(EINVAL);
            return -1;
        }
        char** envp = environment[pid];
        unsigned long varNameLen = strlen(variableName);
        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (envp[i] == NULL) { continue; }
            if (strncmp(variableName, envp[i], varNameLen) == 0) {
                if (strlen(envp[i]) > varNameLen) {
                    if (envp[i][varNameLen] == '=') {
                        // This variable is defined in the current environment:
                        free(envp[i]);
                        envp[i] = NULL;
                        if (i < numVariablesSet[pid] - 1) {
                            for (int j = i; j < numVariablesSet[pid] - 1; j++) {
                                envp[j] = envp[j+1];
                            }
                            envp[numVariablesSet[pid] - 1] = NULL;
                        }
                        numVariablesSet[pid] -= 1;
                        environment[pid] = realloc(envp, (numVariablesSet[pid] + 1) * sizeof(char*));
                        return 0;
                    }
                }
            }
        }
        /*
         for (int i = 0; i < numVariablesSet[pid]; i++) {
         char* position = strstr(envp[i],"=");
         if (strncmp(variableName, envp[i], position - envp[i]) == 0) {
         }
         } */
        // Not found:
        return 0;
    } else {
        return unsetenv(variableName);
    }
}

int ios_unsetenv_parent(const char* variableName) {
    pid_t pid = ios_currentPid();
    return ios_unsetenv_pid(variableName, previousPid[pid]);
}

int ios_unsetenv(const char* variableName) {
    pid_t pid = ios_currentPid();
    return ios_unsetenv_pid(variableName, pid);
}


// store environment variables (called from execve)
// Copy the entire environment:
extern char** environ;
void resetEnvironment(pid_t pid);
static void storeEnvironmentForPid(char *const envp[], pid_t pid) {
    if (environment[pid] != NULL) {
        // We already allocated one environment. Let's clean it:
        resetEnvironment(pid);
    }
    int i = 0;
    while (envp[i] != NULL) {
        i++;
    }
    numVariablesSet[pid] = i;
    environment[pid] = malloc((numVariablesSet[pid] + 1) * sizeof(char*));
    for (int i = 0; i < numVariablesSet[pid]; i++) {
        if (envp[i] != NULL)
            environment[pid][i] = strdup(envp[i]);
        else
            environment[pid][i] = NULL;
    }
    // Keep NULL-termination:
    environment[pid][numVariablesSet[pid]] = NULL;
}

void storeEnvironment(char* envp[]) {
    storeEnvironmentForPid(envp, ios_currentPid());
}

// when the command is terminated, release the environment variables that were added.
void resetEnvironment(pid_t pid) {
    if (environment[pid] != NULL) {
        // Free the variables allocated:
        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (environment[pid][i] == NULL) { continue; }
            free(environment[pid][i]);
            environment[pid][i] = NULL;
        }
        free(environment[pid]);
        environment[pid] = NULL;
        numVariablesSet[pid] = 0;
    }
}

// Used by "env -i": clear all environment variables, but don't clear the environment itself
void clearEnvironment(pid_t pid) {
    if (environment[pid] != NULL) {
        // Free the variables allocated:
        for (int i = 0; i < numVariablesSet[pid]; i++) {
            if (environment[pid][i] == NULL) { continue; }
            free(environment[pid][i]);
            environment[pid][i] = NULL;
        }
        numVariablesSet[pid] = 0;
    }
}


char** environmentVariables(pid_t pid) {
    if (environment[pid] != NULL) {
        return environment[pid];
    } else {
        return environ;
    }
}

extern int chdir_nolock(const char* path); // defined in ios_system.m
void ios_releaseThread(pthread_t thread) {
    if (thread == NULL) {
        return;
    }
    // TODO: this is inefficient. Replace with NSMutableArray?
    for (int p = 0; p < IOS_MAX_THREADS; p++) {
        if (thread_ids[p] == thread) {
            // fprintf(stderr, "Found Id %d\n", p);
            // Don't reset the environment; sometimes, commands try to change the environment while it is being erased.
            // resetEnvironment(p);
            // fprintf(stderr, "Reset current directory to %s because process %d terminates\n", previousDirectory[p], p);
            // Restore cwd before publishing completion to ios_waitpid callers.
            chdir_nolock(previousDirectory[p]);
            if (native_pid < 0) current_pid = previousPid[p];
            thread_ids[p] = NULL;
            ios_notifyThreadCompletion();
            return;
        }
    }
    // fprintf(stderr, "Not found\n");
}

void ios_releaseBackgroundThread(pthread_t thread) {
    // Same as ios_releaseThread, but do not reset the directory.
    for (int p = 0; p < IOS_MAX_THREADS; p++) {
        if (thread_ids[p] == thread) {
            // fprintf(stderr, "Found Id %d\n", p);
            if (native_pid < 0) current_pid = previousPid[p];
            thread_ids[p] = NULL;
            ios_notifyThreadCompletion();
            return;
        }
    }
    // fprintf(stderr, "Not found\n");
}

void ios_releaseBackgroundThreadId(pid_t pid) {
    pthread_mutex_lock(&pid_mtx);
    if (thread_ids[pid] != 0) {
        if (!native_reservations[pid] && current_pid == pid) current_pid = previousPid[pid];
        thread_ids[pid] = 0;
        ios_notifyThreadCompletion();
    }
    pthread_mutex_unlock(&pid_mtx);
}

void ios_releaseThreadId(pid_t pid) {
    // Don't reset the environment; sometimes, commands try to change the environment while it is being erased.
    // resetEnvironment(pid);
    if (thread_ids[pid] != 0) {
        // fprintf(stderr, "Locking for pid %d in ios_releaseThreadId\n", pid);
        // fprintf(stderr, "Reset current directory to %s because process %d terminates\n", previousDirectory[pid], pid);
        chdir_nolock(previousDirectory[pid]);
        if (native_pid < 0) current_pid = previousPid[pid];
        thread_ids[pid] = 0;
        ios_notifyThreadCompletion();
        // fprintf(stderr, "Unlocking for pid %d in ios_releaseThreadId\n", pid);
    } else {
        // fprintf(stderr, "ios_releaseThreadId: pid %d was already terminated.\n", pid);
    }
}

pid_t ios_currentPid(void) {
    return native_pid >= 0 ? native_pid : current_pid;
}

// Note to self: do not redefine getpid() unless you have a way to make it consistent even when a "process" starts a new thread.
// 0MQ and asyncio rely on this.
pid_t fork(void) { return ios_nextAvailablePid(false); } // increases current_pid by 1.
pid_t ios_forkNative(void) { return ios_nextAvailablePid(true); }
pid_t ios_fork(void) { return ios_nextAvailablePid(false); } // increases current_pid by 1.
pid_t vfork(void) { return ios_nextAvailablePid(false); }



// simple replacement of waitpid for swift programs
// We use "optnone" to prevent optimization, otherwise the while loops never end.
__attribute__ ((optnone)) void ios_waitForPidCompletion(pid_t pid) {
    
    executeWebAssemblyCommandsInOrder();
    
    // Old system: no explicit pid, just store last thread Id.
    if ((pid == -1) || (pid == 0)) {
        pthread_mutex_lock(&thread_completion_mutex);
        pthread_cleanup_push(unlockThreadCompletion, &thread_completion_mutex);
        while (ios_getLastThreadId() != 0)
            pthread_cond_wait(&thread_completed, &thread_completion_mutex);
        pthread_cleanup_pop(1);
        return;
    }
    // New system: thread Id is store with pid:
    if (pid < 0 || pid >= IOS_MAX_THREADS) return;
    // ios_system detaches command threads, so pthread_join cannot wait for them.
    // Include the allocated-but-not-started (-1) state and recheck under the
    // notification mutex to avoid losing an exit between the check and wait.
    // pthread_cond_wait is a cancellation point and reacquires the mutex before
    // the cancellation cleanup handlers run: the handler releases it, so a
    // cancelled caller does not leave every ending command blocked in
    // notify_thread_completion.
    pthread_mutex_lock(&thread_completion_mutex);
    pthread_cleanup_push(unlockThreadCompletion, &thread_completion_mutex);
    while (atomic_load(&thread_ids[pid]) != 0)
        pthread_cond_wait(&thread_completed, &thread_completion_mutex);
    pthread_cleanup_pop(1);
    // fprintf(stderr, "Returning from ios_waitpid for %d \n", pid);
    return;
}

void ios_waitpid(pid_t pid) {
    ios_waitForPidCompletion(pid);
    consume_wait_status(pid);
}

__attribute__ ((optnone)) pid_t waitpid(pid_t pid, int *stat_loc, int options) {
    // pthread_join won't work,  because the thread might have been detached.
    // (and you can't re-join a detached thread).
    // -1 = the call waits for any child process (not good yet)
    //  0 = the call waits for any child process in the process group of the caller
    
    if (options && WNOHANG) {
        executeWebAssemblyCommandsInOrder(); // start executing webAssembly commands
        // WNOHANG: just check that the process is still running:
        pthread_t threadToWaitFor;
        if ((pid == -1) || (pid == 0)) threadToWaitFor = ios_getLastThreadId();
        else threadToWaitFor = ios_getThreadId(pid);
        if (threadToWaitFor != 0) // the process is still running
            return 0;
        else {
            int status = consume_wait_status(pid);
        if (stat_loc) *stat_loc = W_EXITCODE(status, 0);
            fflush(thread_stdout);
            fflush(thread_stderr);
            return pid; // was "-1". See man page and https://github.com/holzschu/ios_system/issues/89
        }
    } else {
        // Wait until the process is terminated:
        ios_waitForPidCompletion(pid);
        int status = consume_wait_status(pid);
        if (stat_loc) *stat_loc = W_EXITCODE(status, 0);
        return pid;
    }
}

// The previous function is designed to override the standard version of waitpid.
// With Python 3.13, it doesn't work and the standard version is called instead.
// When that happens, we explicitly call this function (a copy of the previous one).
// Also useful in Swift calls
__attribute__ ((optnone)) pid_t ios_full_waitpid(pid_t pid, int *stat_loc, int options) {
    // pthread_join won't work,  because the thread might have been detached.
    // (and you can't re-join a detached thread).
    // -1 = the call waits for any child process (not good yet)
    //  0 = the call waits for any child process in the process group of the caller
    
    if (options && WNOHANG) {
        executeWebAssemblyCommandsInOrder(); // start executing webAssembly commands
        // WNOHANG: just check that the process is still running:
        pthread_t threadToWaitFor;
        if ((pid == -1) || (pid == 0)) threadToWaitFor = ios_getLastThreadId();
        else threadToWaitFor = ios_getThreadId(pid);
        if (threadToWaitFor != 0) // the process is still running
            return 0;
        else {
            int status = consume_wait_status(pid);
        if (stat_loc) *stat_loc = W_EXITCODE(status, 0);
            fflush(thread_stdout);
            fflush(thread_stderr);
            return pid; // was "-1". See man page and https://github.com/holzschu/ios_system/issues/89
        }
    } else {
        // Wait until the process is terminated:
        ios_waitForPidCompletion(pid);
        int status = consume_wait_status(pid);
        if (stat_loc) *stat_loc = W_EXITCODE(status, 0);
        return pid;
    }
}



//
void vwarn(const char *fmt, va_list args)
{
    if (thread_stderr == NULL) thread_stderr = stderr;
    fputs(ios_progname(), thread_stderr);
    if (fmt != NULL)
    {
        fputs(": ", thread_stderr);
        vfprintf(thread_stderr, fmt, args);
    }
    fputs(": ", thread_stderr);
    fputs(strerror(errno), thread_stderr);
    putc('\n', thread_stderr);
}

void vwarnx(const char *fmt, va_list args)
{
    if (thread_stderr == NULL) thread_stderr = stderr;
    fputs(ios_progname(), thread_stderr);
    fputs(": ", thread_stderr);
    if (fmt != NULL)
        vfprintf(thread_stderr, fmt, args);
    putc('\n', thread_stderr);
}
// void err(int eval, const char *fmt, ...);
void err(int eval, const char *fmt, ...) {
    if (fmt != NULL) {
        va_list argptr;
        va_start(argptr, fmt);
        vwarn(fmt, argptr);
        va_end(argptr);
    }
    ios_exit(eval);
}
// void errc(int eval, int errorcode, const char *fmt, ...);
void errc(int eval, int errorcode, const char *fmt, ...) {
    if (thread_stderr == NULL) thread_stderr = stderr;
    if (fmt != NULL) {
        va_list argptr;
        va_start(argptr, fmt);
        fputs(ios_progname(), thread_stderr);
        fputs(": ", thread_stderr);
        vfprintf(thread_stderr, fmt, argptr);
        fputs(": ", thread_stderr);
        fputs(strerror(errorcode), thread_stderr);
        putc('\n', thread_stderr);
        va_end(argptr);
    }
    ios_exit(eval);
}
//     void errx(int eval, const char *fmt, ...);
void errx(int eval, const char *fmt, ...) {
    if (fmt != NULL) {
        va_list argptr;
        va_start(argptr, fmt);
        vwarnx(fmt, argptr);
        va_end(argptr);
    }
    ios_exit(eval);
}
//   void warn(const char *fmt, ...);
void warn(const char *fmt, ...) {
    if (fmt != NULL) {
        va_list argptr;
        va_start(argptr, fmt);
        vwarn(fmt, argptr);
        va_end(argptr);
    }
}
//   void warnx(const char *fmt, ...);
void warnx(const char *fmt, ...) {
    if (fmt != NULL) {
        va_list argptr;
        va_start(argptr, fmt);
        vwarnx(fmt, argptr);
        va_end(argptr);
    }
}
// void warnc(int code, const char *fmt, ...);
void warnc(int code, const char *fmt, ...) {
    if (thread_stderr == NULL) thread_stderr = stderr;
    fputs(ios_progname(), thread_stderr);
    if (fmt != NULL)
    {
        va_list argptr;
        va_start(argptr, fmt);
        fputs(": ", thread_stderr);
        vfprintf(thread_stderr, fmt, argptr);
        vwarn(fmt, argptr);
        va_end(argptr);
    }
    fputs(": ", thread_stderr);
    fputs(strerror(code), thread_stderr);
    putc('\n', thread_stderr);
}
