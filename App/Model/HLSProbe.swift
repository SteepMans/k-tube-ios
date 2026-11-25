#if DEBUG
import AVFoundation
import Foundation

/// CI check of the local HLS server (debug builds only, -ktubeScreen hlsprobe): plays Apple's public test streams
/// through 127.0.0.1 exactly like a YouTube video and logs the player's state and error log.
@MainActor
enum HLSProbe {
    static let streams = [
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8",
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
    ]
    private static var players: [AVPlayer] = []

    static func run(_ app: AppModel) {
        let server = app.gateway.server
        for (i, s) in streams.enumerated() {
            guard let url = server.masterURL(s, quality: 0, fps: 0, audio: nil, av1: false) else { continue }
            let p = AVPlayer(url: url)
            p.isMuted = true
            p.play()
            players.append(p)
            Task { @MainActor in
                for t in 0..<20 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let item = p.currentItem
                    var line = "KTPROBE \(i) t=\(t) status=\(item?.status.rawValue ?? -1) time=\(String(format: "%.1f", p.currentTime().seconds))"
                    if let e = item?.error as NSError? {
                        line += " error=\(e.domain) \(e.code) \(e.localizedDescription)"
                        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { line += " under=\(u.domain) \(u.code)" }
                    }
                    for ev in item?.errorLog()?.events.suffix(3) ?? [] {
                        line += " | log \(ev.errorDomain) \(ev.errorStatusCode) \(ev.errorComment ?? "") \(ev.uri?.prefix(80) ?? "")"
                    }
                    if let a = item?.accessLog()?.events.last { line += " bytes=\(a.numberOfBytesTransferred)" }
                    NSLog("%@", line)
                }
            }
        }
    }
}
#endif
