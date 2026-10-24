#import <Foundation/Foundation.h>
#import "ios_system.h"
#include "ios_spawn.h"
#include <signal.h>
#include <unistd.h>
static const char *modulePath, *scriptPath, *privatePath;
int interpreter_parent(int argc, char **argv) {
    for (int script = 0; script < 2; script++) {
        FILE *output = tmpfile();
        if (!output) return 2;
        ios_spawn_options options = {fileno(thread_stdin), fileno(output), fileno(thread_stderr), NULL, 0};
        char *direct[] = {"wasm", (char *)modulePath, NULL};
        char *indirect[] = {(char *)scriptPath, NULL};
        char *environment[] = {(char *)privatePath, NULL};
        pid_t child;
        int status = -1;
        int error = ios_spawn(&child, script ? indirect[0] : direct[0], &options, script ? indirect : direct, environment);
        if (!error && ios_full_waitpid(child, &status, 0) != child) return 3;
        rewind(output);
        char bytes[64] = {0}; size_t count = fread(bytes, 1, sizeof(bytes) - 1, output); fclose(output);
        bool passed = !error && !status && count == 13 && !memcmp(bytes, "PRIVATE_WASM\n", 13);
        dprintf(2, "INTERPRETER_PATH mode=%s launch=%d status=%d bytes=%zu %s\n", script ? "shebang" : "direct", error, status, count, passed ? "PASS" : "FAIL");
        if (!passed) return 1;
    }
    return 0;
}
static void timedOut(int number) { _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        signal(SIGALRM, timedOut); alarm(10);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]) return 3;
        NSString *module = [directory stringByAppendingPathComponent:@"path-interpreter"];
        NSString *script = [directory stringByAppendingPathComponent:@"script"];
        NSString *dictionary = [directory stringByAppendingPathComponent:@"commands.plist"];
        if (![manager copyItemAtPath:[NSString stringWithUTF8String:argv[1]] toPath:module error:NULL]) return 4;
        if (![@"#!/usr/bin/env path-interpreter\n" writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return 5;
        if (![@{@"wasm": @[@"shell.framework/shell", @"wasm3", @"", @"file"]} writeToFile:dictionary atomically:YES]) return 6;
        modulePath = module.UTF8String; scriptPath = script.UTF8String;
        privatePath = [@"PATH=" stringByAppendingString:directory].UTF8String;
        initializeEnvironment(); ios_switchSession("interpreter-path"); ios_setStreams(stdin, stdout, stderr);
        if (addCommandList(dictionary)) return 7;
        replaceCommand(@"interpreter-parent", @"interpreter_parent", false); joinMainThread = true;
        int result = ios_system("interpreter-parent");
        [manager removeItemAtPath:directory error:NULL];
        return result ? 1 : 0;
    }
}
