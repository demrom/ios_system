#!/bin/bash
# Execute the documented native spawn fixtures with their real runtime on iOS Simulator.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
products=$(cd "${1:?Pass the Release-iphonesimulator products directory}" && pwd)
logs=${2:-"$root/.build/native-spawn-ci"}
mkdir -p "$logs"
work=$(mktemp -d "$logs/run.XXXXXX")
work=$(cd "$work" && pwd)
device=
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
    local status=$1
    if [[ -n $device ]]; then
        xcrun simctl shutdown "$device" || true
        if ! xcrun simctl delete "$device"; then
            printf 'Could not delete Simulator %s\n' "$device" >&2
            if [[ $status == 0 ]]; then status=1; fi
        fi
    fi
    exit "$status"
}
trap 'cleanup "$?"' EXIT
arch=$(uname -m)
model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -r --arg model "$model" --arg arch "$arch" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
if [[ -z $runtime ]]; then
    printf 'No available iOS runtime supports iPhone 17 on %s\n' "$arch" >&2
    exit 1
fi
frameworks="$work/Frameworks"
mkdir "$frameworks"
for name in ios_system shell; do
    cp -R "$products/$name.framework" "$frameworks/"
    codesign --force --sign - "$frameworks/$name.framework"
done
cp "$root/Resources/commandDictionary.plist" "$work/"
cc=(xcrun --sdk iphonesimulator clang -target "$arch-apple-ios16.0-simulator" -I"$root" -I"$root/ios_system" -F"$frameworks")
standalone=(arguments environment streams directory inherited-directory inherited-directory-stability session-directory session-reaping
    unload-streams status-retention cancellation legacy-cancellation parent-exit legacy-pid session-thread fork-cancellation
    helper-context helper-cleanup images unforked-session restore-status helper-cooperative legacy-environment-return
    cd-backpressure worker-admission)
others=(waitpid-cancel joined-pipeline borrowed-input descriptor-limits environment-snapshot owned-command-snapshot)
compile() {
    local name=$1
    "${cc[@]}" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework ios_system -framework Foundation \
        -Wl,-rpath,@executable_path/Frameworks -Wl,-export_dynamic "$root/tests/$name.m" -o "$work/$name"
    codesign --force --sign - "$work/$name"
}
for name in "${standalone[@]}"; do compile "spawn-$name"; done
for name in "${others[@]}" spawn-buffered-return spawn-background-parent spawn-stopping-parent spawn-nested-system \
    spawn-cleanup-serialization spawn-log-cancellation spawn-interpreter-path; do
    compile "$name"
done
build_framework() {
    local name=$1 source=$2 output="$frameworks/$1.framework/$1"
    mkdir -p "$(dirname "$output")"
    "${cc[@]}" -dynamiclib -framework ios_system -install_name "@rpath/$name.framework/$name" \
        "$root/tests/$source" -o "$output"
    codesign --force --sign - "$output"
}
for name in ImageA ImageB; do build_framework "$name" spawn-image-command.c; done
build_framework Unload spawn-unload-command.c
plutil -insert image-job -json '["@rpath/ImageA.framework/ImageA","image_main","","no",["@rpath/ImageB.framework/ImageB"]]' "$work/commandDictionary.plist"
plutil -insert unload-job -json '["@rpath/Unload.framework/Unload","unload_main","","no",[]]' "$work/commandDictionary.plist"
plutil -insert state-fixture -json '["MAIN","term_state_fixture","","no"]' "$work/commandDictionary.plist"
for name in spawn-cleanup-close-hook log-writev-hook; do
    "${cc[@]}" -dynamiclib -Wl,-undefined,dynamic_lookup "$root/tests/$name.c" -o "$work/$name.dylib"
    codesign --force --sign - "$work/$name.dylib"
done
npx --yes --package wabt@1.0.39 -- wat2wasm "$root/tests/path-interpreter.wat" -o "$work/path-interpreter.wasm"

device=$(xcrun simctl create ios-system-native-spawn "$model" "$runtime")
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
failed=0
run() {
    local label=$1 executable=$2 status=0 log="$work/$1.log"
    shift 2
    /usr/bin/time -p xcrun simctl spawn "$device" "$work/$executable" "$@" > "$log" 2>&1 || status=$?
    printf 'exit=%s\n' "$status" >> "$log"
    if [[ $status == 0 ]]; then
        printf '%s: PASS\n' "$label"
        grep -E 'PASS|^real ' "$log" | tail -8 || true
    else
        printf '%s: FAIL (exit %s)\n' "$label" "$status" >&2
        tail -35 "$log" >&2
        failed=1
    fi
}
for name in "${standalone[@]}"; do run "spawn-$name" "spawn-$name"; done
for name in waitpid-cancel joined-pipeline borrowed-input owned-command-snapshot spawn-stopping-parent spawn-nested-system; do run "$name" "$name"; done
for mode in startup startup-maximum maximum pipeline spawn; do run "descriptor-limits-$mode" descriptor-limits "$mode"; done
for mode in normal full contended; do run "spawn-buffered-$mode" spawn-buffered-return "$mode"; done
run borrowed-input-unregistered borrowed-input unregistered
run spawn-stopping-parent-system spawn-stopping-parent system
run spawn-nested-system-cancel spawn-nested-system cancel
SIMCTL_CHILD_MallocScribble=1 run environment-snapshot environment-snapshot
SIMCTL_CHILD_MallocScribble=1 run spawn-background-parent spawn-background-parent
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$work/spawn-cleanup-close-hook.dylib" run spawn-cleanup-serialization spawn-cleanup-serialization
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$work/log-writev-hook.dylib" run spawn-log-cancellation spawn-log-cancellation
run spawn-interpreter-path spawn-interpreter-path "$work/path-interpreter.wasm"
exit "$failed"
