import SwiftUI

struct HomeView: View {
    let client: LibreTVClient
    @Binding var category: RecommendationCategory
    let onSelect: (RecommendationItem) -> Void
    let onSearch: () -> Void
    let onSessionExpired: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [RecommendationItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var retry = 0
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(RecommendationCategory.allCases) { option in
                            Button {
                                category = option
                            } label: {
                                HStack(spacing: 10) {
                                    if category == option { Image(systemName: "checkmark") }
                                    Text(option.title)
                                }
                                .font(.system(size: 26, weight: category == option ? .semibold : .regular))
                            }
                            .tint(category == option ? CinemaTheme.accent : CinemaTheme.secondary)
                            .accessibilityAddTraits(category == option ? .isSelected : [])
                            .id(option)
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 20)
                }
                .onAppear { proxy.scrollTo(category, anchor: .center) }
                .onChange(of: category) { _, value in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(category.title).font(.title2.bold()).foregroundStyle(CinemaTheme.text)
                Spacer()
                Text("选一部影片，查看可用片源")
                    .font(.caption).foregroundStyle(CinemaTheme.secondary)
            }
            .padding(.horizontal, 80)
            ScrollView {
                if isLoading {
                    ProgressView("正在加载\(category.title)…")
                        .frame(maxWidth: .infinity, minHeight: 330)
                } else if let error {
                    VStack(alignment: .leading, spacing: 26) {
                        Label("这个榜单暂时未能加载", systemImage: "exclamationmark.triangle")
                            .font(.title3).foregroundStyle(CinemaTheme.text)
                        Text(error).foregroundStyle(CinemaTheme.secondary)
                        Text("可以重试、切换其他榜单，或直接搜索片名。")
                            .foregroundStyle(CinemaTheme.secondary)
                        HStack(spacing: 30) {
                            Button("重试榜单") { retry += 1 }
                            Button("搜索影片", action: onSearch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 50)
                } else if items.isEmpty {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("这个榜单暂时没有影片。可以切换榜单或搜索片名。")
                            .foregroundStyle(CinemaTheme.secondary)
                        HStack(spacing: 30) {
                            Button("刷新榜单") { retry += 1 }
                            Button("搜索影片", action: onSearch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 50)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 36)],
                              alignment: .leading, spacing: 38) {
                        ForEach(items) { item in
                            let rating = displayRating(item.rating)
                            Button { onSelect(item) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    PosterView(client: client, address: item.cover, onSessionExpired: onSessionExpired)
                                        .overlay(alignment: .bottomTrailing) {
                                            if let rating {
                                                Label(rating, systemImage: "star.fill")
                                                    .font(.system(size: 23, weight: .semibold))
                                                    .foregroundStyle(CinemaTheme.text)
                                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                                    .background(.black.opacity(0.82), in: Capsule())
                                                    .padding(12)
                                            }
                                        }
                                    Text(item.title)
                                        .font(.system(size: 27, weight: .semibold))
                                        .lineLimit(2, reservesSpace: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12).padding(.bottom, 16)
                                }
                            }
                            .buttonStyle(CinemaCardStyle())
                            .accessibilityLabel(item.title + (rating.map { "，评分\($0)" } ?? ""))
                            .accessibilityHint("搜索这部影片的可用片源")
                        }
                    }
                    .padding(.vertical, 22)
                    .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 80)
            .task(id: category.id + "-" + String(retry)) { await load() }
        }
    }

    @MainActor private func load() async {
        let id = UUID()
        requestID = id
        let requestedCategory = category
        isLoading = true
        error = nil
        items = []
        defer { if requestID == id { isLoading = false } }
        do {
            let response = try await client.recommendations(for: requestedCategory)
            try Task.checkCancellation()
            guard requestID == id, category == requestedCategory else { return }
            items = response
        } catch is CancellationError {
        } catch LibreTVError.unauthorized {
            guard !Task.isCancelled, requestID == id, category == requestedCategory else { return }
            onSessionExpired()
        } catch {
            guard !Task.isCancelled, requestID == id, category == requestedCategory else { return }
            self.error = (error as? LibreTVError)?.localizedDescription ?? "请稍后重试。"
        }
    }
}

enum CinemaTheme {
    static let canvas = Color(red: 9 / 255, green: 19 / 255, blue: 33 / 255)
    static let card = Color(red: 23 / 255, green: 38 / 255, blue: 56 / 255)
    static let accent = Color(red: 70 / 255, green: 201 / 255, blue: 245 / 255)
    static let text = Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255)
    static let secondary = Color(red: 166 / 255, green: 180 / 255, blue: 200 / 255)
}

struct CinemaCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(CinemaTheme.text)
                .background(CinemaTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isFocused ? CinemaTheme.accent : .clear, lineWidth: 5)
                }
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.04 : 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

private func displayRating(_ raw: String?) -> String? {
    guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite, (0...10).contains(value) else { return nil }
    return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
}
