#!/bin/bash
# Run the existing concurrent-fork consumer against an instrumented runtime.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
logs=${1:?Pass a directory for the build and test logs}
mkdir -p "$logs"
work=$(mktemp -d "$logs/run.XXXXXX")
work=$(cd "$work" && pwd)
arch=$(uname -m)
cc=(xcrun --sdk iphonesimulator clang -target "$arch-apple-ios16.0-simulator")
# Debug command tracing drowned out the concurrent workload on hosted Intel.
# Keep the original fixture's command count and alarm, with TSan on Release.
if ! xcodebuild -project "$root/ios_system.xcodeproj" -scheme ios_system -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/build" \
    ARCHS="$arch" CODE_SIGNING_ALLOWED=NO ENABLE_THREAD_SANITIZER=YES build > "$work/build.log" 2>&1; then
    tail -60 "$work/build.log" >&2
    exit 1
fi
frameworks="$work/Frameworks"
mkdir "$frameworks"
cp -R "$work/build/Build/Products/Release-iphonesimulator/ios_system.framework" "$frameworks/"
cp "$root/Resources/commandDictionary.plist" "$work/"
cp "$root/tests/tsan.supp" "$work/"
runtime_library=$("${cc[@]}" -print-file-name=libclang_rt.tsan_iossim_dynamic.dylib)
cp "$runtime_library" "$frameworks/"
"${cc[@]}" -fsanitize=thread -fobjc-arc -I"$root/ios_system" -I"$root" -F"$frameworks" \
    -framework ios_system -framework Foundation -Wl,-rpath,@executable_path/Frameworks \
    -Wl,-export_dynamic "$root/tests/concurrent-fork.m" -o "$work/concurrent-fork"
codesign --force --sign - "$frameworks/ios_system.framework"
codesign --force --sign - "$frameworks/libclang_rt.tsan_iossim_dynamic.dylib"
codesign --force --sign - "$work/concurrent-fork"

model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -er --arg model "$model" --arg arch "$arch" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier')
device=$(xcrun simctl create ios-system-tsan "$model" "$runtime")
trap 'xcrun simctl shutdown "$device" || true; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
status=0
SIMCTL_CHILD_TSAN_OPTIONS="suppressions=$work/tsan.supp:exitcode=66" \
    xcrun simctl spawn "$device" "$work/concurrent-fork" > "$work/concurrent-fork.log" 2>&1 || status=$?
printf 'TSAN_CONCURRENT_FORK_EXIT=%s\n' "$status" | tee -a "$work/concurrent-fork.log"
if [[ $status != 0 ]] || grep -q 'WARNING: ThreadSanitizer' "$work/concurrent-fork.log"; then
    grep -E 'WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer' "$work/concurrent-fork.log" >&2 || true
    tail -30 "$work/concurrent-fork.log" >&2
    exit 1
fi
grep -E '^concurrent-fork: [0-9]+ threads x [0-9]+ commands PASS$' "$work/concurrent-fork.log"
