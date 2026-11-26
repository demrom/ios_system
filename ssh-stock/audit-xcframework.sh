#!/bin/bash
set -euo pipefail

fail() {
    echo "$name: $*" >&2
    exit 1
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <Stock-client.xcframework> <build-root>" >&2
    exit 64
fi

root=$1; work=$2
recipe=$(cd "$(dirname "$0")" && pwd)
name=$(basename "$root" .xcframework)
case "$name" in
    SSHStock) entry=_ashell_ssh_main ;;
    SCPStock) entry=_ashell_scp_main ;;
    SFTPStock) entry=_ashell_sftp_main ;;
    SSHKeygenStock) entry=_ashell_ssh_keygen_main ;;
    *) fail "Unknown stock client" ;;
esac

plutil -extract AvailableLibraries json -o - "$root/Info.plist" |
    jq -e --arg framework "$name.framework" '
        sort_by(.LibraryIdentifier) | length == 2 and
        (.[0] | .LibraryIdentifier == "ios-arm64" and .LibraryPath == $framework and
            .SupportedPlatform == "ios" and .SupportedPlatformVariant == null and
            .SupportedArchitectures == ["arm64"]) and
        (.[1] | .LibraryIdentifier == "ios-arm64_x86_64-simulator" and .LibraryPath == $framework and
            .SupportedPlatform == "ios" and .SupportedPlatformVariant == "simulator" and
            (.SupportedArchitectures | sort) == ["arm64", "x86_64"])
    ' >/dev/null || fail "unexpected XCFramework library manifest"

for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    binary="$root/$slice/$name.framework/$name"
    archs=(arm64)
    sdk=iphoneos
    platform=IOS
    if [ "$slice" = ios-arm64_x86_64-simulator ]; then
        archs+=(x86_64)
        sdk=iphonesimulator
        platform=IOSSIMULATOR
    fi

    actual_archs=$(xcrun lipo -archs "$binary")
    case "$slice:$actual_archs" in
        'ios-arm64:arm64'|'ios-arm64_x86_64-simulator:arm64 x86_64'|'ios-arm64_x86_64-simulator:x86_64 arm64') ;;
        *) fail "$slice: unexpected architectures: $actual_archs" ;;
    esac
    printf '%s: %s\n' "$slice" "$actual_archs"

    for arch in "${archs[@]}"; do
        printf '\n%s %s\n' "$slice" "$arch"
        build=$(xcrun vtool -arch "$arch" -show-build "$binary")
        printf '%s\n' "$build"
        [ "$(awk '$1 == "platform" {print $2}' <<< "$build")" = "$platform" ] ||
            fail "$slice/$arch: wrong Mach-O platform"
        [ "$(awk '$1 == "minos" {print $2}' <<< "$build")" = 15.0 ] ||
            fail "$slice/$arch: expected minimum iOS 15.0"

        header=$(xcrun otool -arch "$arch" -hv "$binary")
        printf '%s\n' "$header"
        awk '$5 == "DYLIB" {found=1} END {exit !found}' <<< "$header" ||
            fail "$slice/$arch: not a dynamic library"
        id="@rpath/$name.framework/$name"
        [ "$(xcrun otool -arch "$arch" -D "$binary" | awk 'NR == 2')" = "$id" ] ||
            fail "$slice/$arch: wrong install name"

        links=$(xcrun otool -arch "$arch" -L "$binary")
        printf '%s\n' "$links"
        libs=$(awk 'NR > 1 {print $1}' <<< "$links")
        grep -Fx '@rpath/ios_system.framework/ios_system' <<< "$libs" >/dev/null ||
            fail "$slice/$arch: missing dependency ios_system"
        # SCP and SFTP link ssherr-nolibcrypto and delegate the SSH transport.
        if [ "$name" = SSHStock ] || [ "$name" = SSHKeygenStock ]; then
            grep -Fx '@rpath/openssl.framework/openssl' <<< "$libs" >/dev/null ||
                fail "$slice/$arch: missing dependency openssl"
        fi
        while IFS= read -r lib; do
            case "$lib" in
                "$id"|@rpath/ios_system.framework/ios_system|@rpath/openssl.framework/openssl|/usr/lib/*|/System/Library/Frameworks/*) ;;
                *) fail "$slice/$arch: unexpected dependency $lib" ;;
            esac
        done <<< "$libs"

        xcrun nm -arch "$arch" -gUj "$binary" | grep -Fx "$entry" ||
            fail "$slice/$arch: missing entry point $entry"
        bash "$recipe/audit-symbols.sh" "$sdk" "$arch" "$binary" "$work/dependencies-$sdk-$arch"
    done
done
