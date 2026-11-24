import AVFoundation
import Foundation
import SwiftUI

/// Downloads for offline viewing: Apple's HLS download (AVAssetDownloadURLSession) of one quality, fetched through the
/// local server and the gateway. The app has to stay open while a download runs: the local server lives in the app.
@MainActor
final class Downloads: NSObject, ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        enum State: String, Codable { case queued, running, done, failed }
        var id: String { video.id }
        var video: VideoItem
        var quality: String
        var audioOnly: Bool
        var state: State
        var progress: Double
        /// path relative to the home folder (the system moves the app container between versions)
        var path: String?
        var error: String?
        var addedAt: Int
    }

    unowned let app: AppModel
    @Published var entries: [Entry] = []
    private var session: AVAssetDownloadURLSession!
    private var tasks: [String: AVAggregateAssetDownloadTask] = [:]
    private var taskIds: [Int: String] = [:]
    private let file: URL

    init(app: AppModel) {
        self.app = app
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        file = base.appendingPathComponent("downloads.json")
        super.init()
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        // a download cut off by closing the app cannot be resumed through a new local port
        for i in entries.indices where entries[i].state == .running || entries[i].state == .queued {
            entries[i].state = .failed
            entries[i].error = "Прервано: приложение было закрыто"
        }
        let config = URLSessionConfiguration.background(withIdentifier: "ru.steepmans.ktube.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = false
        session = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: file, options: .atomic) }
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    func localURL(_ e: Entry) -> URL? {
        guard let p = e.path else { return nil }
        let u = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func start(_ video: VideoItem, quality: Variant?, audioOnly: Bool) {
        if let e = entry(video.id), e.state == .running { return }
        entries.removeAll { $0.id == video.id }
        entries.insert(Entry(video: video, quality: audioOnly ? "звук" : (quality?.label ?? "лучшее"), audioOnly: audioOnly, state: .queued, progress: 0, addedAt: Format.now()), at: 0)
        save()
        app.show("Загрузка началась. Не закрывайте приложение, пока она идёт")
        Task {
            do {
                let info = try await app.streams.resolve(video.id, client: app.store.settings.playbackClient)
                guard let hls = info.hlsURL else { throw KTubeError("Нет потока") }
                let server = app.gateway.server
                let url: URL?
                if audioOnly, let a = info.audioTracks.first(where: \.isOriginal) ?? info.audioTracks.first, !a.url.isEmpty {
                    url = URL(string: server.mediaURL(HLS.resolve(a.url, base: hls), name: "index.m3u8"))
                } else {
                    let v = quality ?? info.variants.filter { HLS.playable($0.codecs, av1: false) }.first { $0.qualityClass <= 1080 }
                    url = server.masterURL(hls, quality: v?.qualityClass ?? 0, fps: v?.fps ?? 0, audio: nil, av1: false)
                }
                guard let url else { throw KTubeError("Нет потока") }
                let asset = AVURLAsset(url: url)
                let selections = try await asset.load(.preferredMediaSelection)
                guard let task = session.aggregateAssetDownloadTask(with: asset, mediaSelections: [selections], assetTitle: video.title, assetArtworkData: nil, options: nil) else {
                    throw KTubeError("Загрузка недоступна")
                }
                tasks[video.id] = task
                taskIds[task.taskIdentifier] = video.id
                update(video.id) { $0.state = .running }
                task.resume()
            } catch {
                update(video.id) {
                    $0.state = .failed
                    $0.error = error.localizedDescription
                }
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        remove(id)
    }

    func remove(_ id: String) {
        if let e = entry(id), let u = localURL(e) { try? FileManager.default.removeItem(at: u) }
        entries.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: String, _ f: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        f(&entries[i])
        save()
    }
}

extension Downloads: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, willDownloadTo location: URL) {
        let rel = location.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "")
        let tid = aggregateAssetDownloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskIds[tid] else { return }
            self.update(id) { $0.path = rel }
        }
    }

    nonisolated func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, didLoad timeRange: CMTimeRange,
                                totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection) {
        let total = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        let tid = aggregateAssetDownloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskIds[tid], total > 0 else { return }
            if let i = self.entries.firstIndex(where: { $0.id == id }) { self.entries[i].progress = min(1, loaded / total) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        let msg = error?.localizedDescription
        Task { @MainActor in
            guard let id = self.taskIds[tid] else { return }
            self.taskIds[tid] = nil
            self.tasks[id] = nil
            self.update(id) {
                if let msg {
                    $0.state = .failed
                    $0.error = msg
                } else {
                    $0.state = .done
                    $0.progress = 1
                }
            }
            if msg == nil { self.app.show("Загрузка завершена") }
        }
    }
}
