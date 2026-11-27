// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DabaiPet",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DabaiPet", targets: ["DabaiPetApp"]),
    ],
    targets: [
        .target(
            name: "DabaiPetCore",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(name: "DabaiPetUI", dependencies: ["DabaiPetCore"]),
        .target(name: "CredentialIPC"),
        .executableTarget(name: "DabaiPetApp", dependencies: ["DabaiPetCore", "DabaiPetUI", "CredentialIPC"]),
        .testTarget(name: "DabaiPetCoreTests", dependencies: ["DabaiPetCore"], path: "Tests"),
    ],
    swiftLanguageModes: [.v6]
)
