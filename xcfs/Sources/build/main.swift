// use it from root folder:
// `swift run --package-path xcfs build [all, awk, tar, ios_system, ...] [--ios-only]`

import FMake
import class Foundation.ProcessInfo

OutputLevel.default = .error

let args = ProcessInfo.processInfo.arguments.dropFirst()
let platforms: [Platform] = args.contains("--ios-only") ? [.iPhoneOS, .iPhoneSimulator] : [.iPhoneOS, .iPhoneSimulator, .Catalyst]

let allSchemes = [
    "ios_system",
    "awk",
    "curl_ios", 
    "files",
    "shell",
    "ssh_cmd",
    "ssh_cmdA",
    "ssh_agent",
    "sshd",
    "tar",
    "text",
    ]

let selection = args.first { $0 != "--ios-only" } ?? "all"
let schemes = selection == "all" ? allSchemes : selection.components(separatedBy: ",")
for scheme in schemes where !allSchemes.contains(scheme) {
    fatalError("Unknown scheme: \(scheme)")
}

var checksums: [[String?]] = []

for scheme in schemes {
    try xcxcf(
        dirPath: ".build",
        project: "ios_system",
        scheme: scheme,
        platforms: platforms.map { ($0, excludedArchs: []) }
    )

    try cd(".build") {
        let zip = "\(scheme).xcframework.zip"
        // Updating an existing ZIP can retain stale slices from a previous build.
        try sh("rm -f \(zip)")
        try sh("zip --symlinks -r \(zip) \(scheme).xcframework")
        let chksum = try sha(path: zip)
        checksums.append([zip, chksum])
        try sh("rm -rf \(scheme)")
        try sh("mkdir \(scheme)")
        try sh("mv \(scheme).xcframework \(scheme)")
    }
}

var releaseNotes =
"""
Release notes:

\( checksums.markdown(headers: "File", "SHA 256") )

"""

try write(content: releaseNotes, atPath: ".build/release.md")

