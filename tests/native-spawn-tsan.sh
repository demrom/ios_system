#!/bin/bash
# Check auxiliary thread reclamation through the existing public PID waits.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
logs=${1:-"$root/.build/native-spawn-ci"}
mkdir -p "$logs"
work=$(mktemp -d "$logs/tsan.XXXXXX")
work=$(cd "$work" && pwd)
arch=$(uname -m)
cc=(xcrun --sdk iphonesimulator clang -target "$arch-apple-ios16.0-simulator")
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
runtime_library=$("${cc[@]}" -print-file-name=libclang_rt.tsan_iossim_dynamic.dylib)
cp "$runtime_library" "$frameworks/"
"${cc[@]}" -fsanitize=thread -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -I"$root/ios_system" -I"$root" -F"$frameworks" -framework ios_system -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks -Wl,-export_dynamic \
    "$root/tests/legacy-thread-lifetime.m" -o "$work/legacy-thread-lifetime"
codesign --force --sign - "$frameworks/ios_system.framework"
codesign --force --sign - "$frameworks/libclang_rt.tsan_iossim_dynamic.dylib"
codesign --force --sign - "$work/legacy-thread-lifetime"
model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -er --arg model "$model" --arg arch "$arch" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier')
device=$(xcrun simctl create ios-system-native-spawn-tsan "$model" "$runtime")
trap 'xcrun simctl shutdown "$device" || true; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
status=0
log="$work/legacy-thread-lifetime.log"
SIMCTL_CHILD_TSAN_OPTIONS=halt_on_error=1 \
    /usr/bin/time -p xcrun simctl spawn "$device" "$work/legacy-thread-lifetime" > "$log" 2>&1 || status=$?
printf 'exit=%s\n' "$status" >> "$log"
if [[ $status != 0 ]] || grep -q 'WARNING: ThreadSanitizer' "$log"; then
    tail -50 "$log" >&2
    exit 1
fi
grep -Fx 'LEGACY_THREAD_LIFETIME joined=0 PASS' "$log"
grep -Fx 'LEGACY_THREAD_LIFETIME joined=1 PASS' "$log"
