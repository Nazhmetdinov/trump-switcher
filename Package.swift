// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrumpSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrumpSwitcher", targets: ["TrumpSwitcher"])],
    targets: [
        .target(name: "LocalSafety", publicHeadersPath: "include"),
        .target(name: "Hunspell", publicHeadersPath: "include",
            cxxSettings: [.define("HUNSPELL_STATIC"), .define("BUILDING_LIBHUNSPELL")]),
        .target(name: "SwitcherCore", dependencies: ["Hunspell"],
            resources: [.copy("Resources/Dictionaries")],
            linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "TrumpSwitcher", dependencies: ["SwitcherCore", "LocalSafety"],
            exclude: ["ChromeInputChecks.swift", "InputPipelineChecks.swift"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "InputFixture", dependencies: ["LocalSafety"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]),
        .executableTarget(name: "CoreChecks", dependencies: ["SwitcherCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx11
)
