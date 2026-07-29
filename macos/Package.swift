// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DataTrack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "datatrack", targets: ["datatrack"]),
        .executable(name: "DataTrackMenuBar", targets: ["DataTrackMenuBar"]),
        .executable(name: "datatrack-tests", targets: ["datatrack-tests"]),
        .library(name: "DataTrackCore", targets: ["DataTrackCore"]),
    ],
    targets: [
        .target(
            name: "DataTrackCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "datatrack",
            dependencies: ["DataTrackCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DataTrackMenuBar",
            dependencies: ["DataTrackCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Test runner as a plain executable. See Sources/datatrack-tests/Harness.swift
        // for why neither swift-testing nor XCTest is usable here.
        .executableTarget(
            name: "datatrack-tests",
            dependencies: ["DataTrackCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
