import SwiftUI
import ImageIO

struct PosterView: View {
    let client: LibreTVClient
    let address: String?
    let onSessionExpired: () -> Void
    @State private var image: CGImage?
    @State private var requestID = UUID()

    var body: some View {
        Rectangle()
            .fill(CinemaTheme.card)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "film").font(.system(size: 50, weight: .light))
                        Text("暂无海报").font(.system(size: 22))
                    }
                    .foregroundStyle(CinemaTheme.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: address) {
                let id = UUID()
                requestID = id
                image = nil
                guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    let data = try await client.coverData(for: address)
                    try Task.checkCancellation()
                    guard requestID == id,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 600,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { return }
                    image = thumbnail
                } catch is CancellationError {
                } catch LibreTVError.unauthorized {
                    guard !Task.isCancelled, requestID == id else { return }
                    onSessionExpired()
                } catch {
                    // A missing or unreadable cover must never block selecting the film.
                }
            }
    }
}
