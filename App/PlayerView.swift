import SwiftUI
import AVKit

struct PlayerView: View {
    let client: LibreTVClient
    let episode: String
    let title: String
    let onSessionExpired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = PlaybackController()
    @State private var retry = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: playback.player)
                .ignoresSafeArea()
                .allowsHitTesting(playback.failure == nil)
            if playback.isLoading && playback.failure == nil {
                VStack(spacing: 24) {
                    ProgressView()
                    Text("正在准备播放…")
                }
                .padding(36).background(.black.opacity(0.8)).cornerRadius(16)
                .allowsHitTesting(false)
            }
            if let failure = playback.failure {
                VStack(spacing: 30) {
                    Text(title).font(.title2)
                    Text(failure).multilineTextAlignment(.center)
                    HStack(spacing: 40) {
                        Button("重试播放") { retry += 1 }
                        Button("返回选集") { dismiss() }
                    }
                }
                .padding(60).frame(maxWidth: 1200).background(.black.opacity(0.95))
            }
        }
        .task(id: retry) {
            playback.prepare()
            do {
                let status = try await client.status()
                guard status.verified else { throw LibreTVError.unauthorized }
                let request = try client.playbackRequest(for: episode)
                try Task.checkCancellation()
                playback.start(request)
            } catch is CancellationError {
            } catch LibreTVError.unauthorized {
                dismiss()
                onSessionExpired()
            } catch {
                playback.fail((error as? LibreTVError)?.localizedDescription ?? "无法开始播放，请重试或返回选集。")
            }
        }
        .onExitCommand { dismiss() }
        .onDisappear { playback.stop() }
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}

@MainActor private final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = true
    private var observations: [NSKeyValueObservation] = []
    private var failureObserver: NSObjectProtocol?
    private var timeout: Task<Void, Never>?

    func prepare() {
        stop()
        failure = nil
        isLoading = true
    }

    func start(_ request: PlaybackRequest) {
        let asset = AVURLAsset(url: request.url, options: [AVURLAssetHTTPCookiesKey: request.cookies])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player.currentItem === item else { return }
                    if item.status == .failed { self.fail() }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.failure == nil else { return }
                    self.isLoading = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    if self.isLoading { self.armTimeout() } else { self.timeout?.cancel() }
                }
            }
        ]
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.fail()
            }
        }
        armTimeout()
        player.play()
    }

    func fail(_ message: String = "这个片源暂时无法播放。可以重试，或返回选择其他片源。") {
        stop()
        failure = message
        isLoading = false
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        for observation in observations { observation.invalidate() }
        observations = []
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) }
            catch { return }
            self?.fail("等待片源超过 45 秒，请重试或返回选择其他片源。")
        }
    }
}
