#!/bin/bash
# Run the standalone tests from tests/README.md against the current build products.
set -euo pipefail
products=$(cd "${1:?Pass the xcframework build directory}" && pwd)
logs=${2:?Pass a directory for the test logs}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$logs"
work=$(mktemp -d "$logs/run.XXXXXX")
work=$(cd "$work" && pwd)
mkdir "$work/Frameworks"
slice=ios-arm64_x86_64-simulator
for name in ios_system files text; do
    cp -R "$products/$name/$name.xcframework/$slice/$name.framework" "$work/Frameworks/"
    codesign --force --sign - "$work/Frameworks/$name.framework"
done

arch=$(uname -m)
target="$arch-apple-ios16.0-simulator"
cc=(xcrun --sdk iphonesimulator clang -target "$target")
compile() {
    local name=$1 dir="$work/$1"
    shift
    mkdir -p "$dir"
    cp "$root/Resources/commandDictionary.plist" "$dir/"
    "${cc[@]}" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -I"$root" -I"$root/ios_system" \
        -F"$work/Frameworks" -framework ios_system -framework Foundation \
        -Wl,-rpath,@executable_path/../Frameworks -Wl,-export_dynamic \
        "$root/tests/$name.m" "$@" -o "$dir/$name"
    codesign --force --sign - "$dir/$name"
}
for name in window-size signal-handlers cwd-order session-streams native-tty owned-streams owned-cancellation \
    input-lease wasm-stdin-close wasm-command-order waitpid-idle cleanup-wait cleanup-cancel concurrent-fork \
    concurrent-getopt getopt-legacy pid-admission thread-create-failure child-wait-status command-streams \
    direct-cancellation alias-redirection less-capture; do
    compile "$name"
done

mkdir "$work/Frameworks/SignalHandler.framework"
signal_handler="$work/Frameworks/SignalHandler.framework/SignalHandler"
"${cc[@]}" -dynamiclib -install_name @rpath/SignalHandler.framework/SignalHandler \
    "$root/tests/signal-handler-command.c" -o "$signal_handler"
codesign --force --sign - "$signal_handler"
plutil -insert signal-handler -json '["@rpath/SignalHandler.framework/SignalHandler","signal_handler_main","","none"]' \
    "$work/signal-handlers/commandDictionary.plist"

mkdir "$work/main-thread-winch"
slowcreate="$work/main-thread-winch/libslowcreate.dylib"
"${cc[@]}" -dynamiclib -install_name @loader_path/libslowcreate.dylib \
    "$root/tests/main-thread-winch-slowcreate.c" -o "$slowcreate"
codesign --force --sign - "$slowcreate"
compile main-thread-winch "$slowcreate"

thread_hook="$work/thread-create-failure/thread-create-failure-hook.dylib"
"${cc[@]}" -dynamiclib "$root/tests/thread-create-failure-hook.c" -o "$thread_hook"
codesign --force --sign - "$thread_hook"

mkdir "$work/direct-cancellation/bin"
touch "$work/direct-cancellation/bin/direct-cancel"
chmod 755 "$work/direct-cancellation/bin/direct-cancel"
plutil -insert direct-cancel -json '["SELF","direct_cancel_main","","none"]' \
    "$work/direct-cancellation/commandDictionary.plist"
plutil -replace less -json '["files.framework/files","less_main","","no"]' \
    "$work/less-capture/commandDictionary.plist"

model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -r --arg model "$model" --arg arch "$arch" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
if [[ -z $runtime ]]; then
    echo 'No available iOS runtime supports iPhone 17' >&2
    exit 1
fi
device=$(xcrun simctl create ios-system-tests "$model" "$runtime")
trap 'xcrun simctl shutdown "$device" || true; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b

failed=0
run() {
    local label=$1 name=$2 log="$work/$1.log" status=0
    shift 2
    /usr/bin/time -p xcrun simctl spawn "$device" "$work/$name/$name" "$@" > "$log" 2>&1 || status=$?
    printf 'exit=%s\n' "$status" >> "$log"
    if [[ $status == 0 ]]; then
        printf '%s: PASS\n' "$label"
        grep -E 'PASS|^real ' "$log" | tail -8 || true
    else
        printf '%s: FAIL (exit %s)\n' "$label" "$status" >&2
        tail -30 "$log" >&2
        failed=1
    fi
}
for name in window-size signal-handlers session-streams native-tty owned-streams input-lease wasm-stdin-close \
    wasm-command-order waitpid-idle cleanup-wait cleanup-cancel concurrent-fork concurrent-getopt getopt-legacy \
    main-thread-winch pid-admission child-wait-status less-capture; do
    run "$name" "$name"
done
run signal-handlers-staggered signal-handlers --staggered
mkdir "$work/cwd-order/result" "$work/owned-cancellation/result" "$work/alias-redirection/result"
run cwd-order cwd-order "$work/cwd-order/result"
run owned-cancellation owned-cancellation "$work/owned-cancellation/result"
run alias-redirection alias-redirection "$work/alias-redirection/result"
run input-lease-cancel input-lease cancel
run direct-cancellation direct-cancellation "$work/direct-cancellation/bin"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$thread_hook" SIMCTL_CHILD_MallocScribble=1 SIMCTL_CHILD_MallocPreScribble=1 \
    run thread-create-failure thread-create-failure
run wc-bytes command-streams 'wc -c' $'      14\n'
run wc-lines command-streams 'wc -l' $'       2\n'
run wc-words command-streams 'wc -w' $'       3\n'
run wc-characters command-streams 'wc -m' $'      14\n'
run wc-default command-streams wc $'       2       3      14\n'
for name in grep egrep fgrep; do run "$name" command-streams "$name three" $'three\n'; done
run cksum command-streams cksum $'112545809 14\n'
run sum command-streams sum $'63079 1\n'
printf -v basename '%0253d' 0
input="$work/command-streams/$basename"
printf 'fixture\n' > "$input"
quoted=${input//\'/\'\\\'\'}
SIMCTL_CHILD_LC_ALL=C run gzip-open-error command-streams "gzip '$quoted'" '' 1 'File name too long'
if ! printf 'fixture\n' | cmp - "$input"; then failed=1; fi
exit "$failed"
