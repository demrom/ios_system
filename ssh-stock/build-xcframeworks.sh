#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <new-output-directory>" >&2
    exit 64
fi

recipe=$(cd "$(dirname "$0")" && pwd)
mkdir "$1"
work=$(cd "$1" && pwd)
inputs="$work/inputs"
dist="$work/dist"
mkdir "$inputs" "$dist"

download() {
    curl --fail --silent --show-error --location --proto '=https' --retry 3 \
        --output "$inputs/$1" "$2"
}

download openssh-10.6p1.tar.gz \
    https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p1.tar.gz

# Match the runtime and crypto releases the a-Shell mini consumer embeds.
download ios_system.xcframework.zip \
    https://github.com/demrom/ios_system/releases/download/ios-system-preview-2c560334ecca/ios_system.xcframework.zip
download openssl-dynamic.xcframework.zip \
    https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip
(
    cd "$inputs"
    shasum -a 256 -c "$recipe/sources.sha256"
    shasum -a 256 -c <<'CHECKSUMS'
bac0689c792901cbf410899162c06ab22a950b032adfb5f94b5c3ab6a661e883  ios_system.xcframework.zip
329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80  openssl-dynamic.xcframework.zip
CHECKSUMS
    ditto -x -k ios_system.xcframework.zip "$inputs"
    ditto -x -k openssl-dynamic.xcframework.zip "$inputs"
)

for slice in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
    sdk=${slice%:*}
    arch=${slice#*:}
    dependency_slice=ios-arm64
    if [ "$sdk" = iphonesimulator ]; then
        dependency_slice=ios-arm64_x86_64-simulator
    fi
    dependencies="$work/dependencies-$sdk-$arch"
    mkdir "$dependencies"
    for framework in ios_system openssl; do
        dependency="$inputs/$framework.xcframework/$dependency_slice/$framework.framework"
        xcrun lipo "$dependency/$framework" -verify_arch "$arch"
        ln -s "$dependency" "$dependencies/$framework.framework"
    done
    output="$work/$sdk-$arch"
    bash "$recipe/build.sh" "$sdk" "$inputs" "$output" "$dependencies" "$arch"
    cp "$output/recipe.txt" "$dist/$sdk-$arch.recipe.txt"
done

for name in SSHStock SCPStock SFTPStock SSHKeygenStock; do
    simulator="$work/iphonesimulator-arm64/sdk/$name.framework"
    xcrun lipo -create \
        "$simulator/$name" "$work/iphonesimulator-x86_64/sdk/$name.framework/$name" \
        -output "$work/$name-simulator"
    mv "$work/$name-simulator" "$simulator/$name"
    xcframework="$work/$name.xcframework"
    xcodebuild -create-xcframework \
        -framework "$work/iphoneos-arm64/sdk/$name.framework" \
        -framework "$simulator" -output "$xcframework"
    bash "$recipe/audit-xcframework.sh" "$xcframework" > "$dist/$name.audit.txt"
    ditto -c -k --norsrc --keepParent "$xcframework" "$dist/$name.xcframework.zip"
done

(cd "$dist" && shasum -a 256 ./*.xcframework.zip | tee checksums.txt)
