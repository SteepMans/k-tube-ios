// swift-tools-version:5.9
// Логика без интерфейса: клиент Innertube, потоки HLS, шлюз, библиотека, импорт и экспорт. Те же исходники входят в
// приложение (project.yml), а пакет нужен для тестов: `swift test` идёт на macOS и на Linux в Docker.
import PackageDescription

let package = Package(
    name: "KTubeCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "KTubeCore", targets: ["KTubeCore"]),
    ],
    targets: [
        .target(name: "KTubeCore", path: "Sources/KTubeCore"),
        .testTarget(name: "KTubeCoreTests", dependencies: ["KTubeCore"], path: "Tests/KTubeCoreTests"),
    ]
)
