import SwiftUI

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var path: [SearchItem] = []
    @State private var isShowingSearch = false
    @State private var category: RecommendationCategory = .movieWeekly

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 18) {
                header.padding(.horizontal, 80).padding(.top, 40)
                if model.isAuthenticated, let client = model.client {
                    if isShowingSearch {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                searchContent(client: client)
                                operationStatus
                            }
                            .padding(.horizontal, 80).padding(.vertical, 24)
                        }
                    } else {
                        HomeView(client: client, category: $category, onSelect: { item in
                            model.query = item.title
                            isShowingSearch = true
                            model.search()
                        }, onSearch: { isShowingSearch = true }, onSessionExpired: sessionExpired)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            connectionContent
                            operationStatus
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 80).padding(.vertical, 36)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CinemaTheme.canvas.ignoresSafeArea())
            .navigationDestination(for: SearchItem.self) { item in
                if let client = model.client {
                    DetailView(item: item, client: client, onSessionExpired: sessionExpired)
                }
            }
            .onChange(of: model.isAuthenticated) { _, authenticated in
                if !authenticated { path = []; isShowingSearch = false }
            }
        }
        .tint(CinemaTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 28) {
            HStack(spacing: 16) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 90, height: 54)
                    .accessibilityHidden(true)
                Text("LibreTV").font(.system(size: 43, weight: .bold)).foregroundStyle(CinemaTheme.text)
            }
            Spacer()
            if model.isAuthenticated {
                if isShowingSearch {
                    Button { model.cancel(); isShowingSearch = false } label: {
                        Label("返回首页", systemImage: "house")
                    }
                } else {
                    Button { isShowingSearch = true } label: {
                        Label("搜索影片", systemImage: "magnifyingglass")
                    }
                }
                Button("断开连接") {
                    path = []
                    isShowingSearch = false
                    model.disconnect()
                }
            }
        }
    }

    @ViewBuilder private var operationStatus: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if model.isBusy {
            HStack(spacing: 28) {
                ProgressView()
                Text(model.progressText).foregroundStyle(CinemaTheme.text)
                Button("取消") { model.cancel() }
            }
        }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("连接家里的 LibreTV，发现想看的电影和剧集。")
                .foregroundStyle(CinemaTheme.secondary)
            if model.status == nil {
                Text("LibreTV 地址").font(.headline).foregroundStyle(CinemaTheme.text)
                TextField("http://libretv.local:8899", text: $model.address)
                    .autocorrectionDisabled()
                    .onSubmit { model.connect() }
                    .disabled(model.isBusy)
                Button("连接服务器") { model.connect() }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            } else {
                Text(model.address).foregroundStyle(CinemaTheme.secondary)
                if model.status?.passwordRequired == true {
                    SecureField("LibreTV 访问密码", text: $model.password)
                        .onSubmit { model.login() }.disabled(model.isBusy)
                    HStack(spacing: 30) {
                        Button("登录") { model.login() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || model.password.isEmpty)
                        Button("更换地址") { model.disconnect() }.disabled(model.isBusy)
                    }
                    Text("密码只用于本次连接，不会保存。关闭 App 或断开连接后需要重新登录。")
                        .font(.caption).foregroundStyle(CinemaTheme.secondary)
                } else {
                    Text(LibreTVError.passwordNotConfigured.localizedDescription)
                        .foregroundStyle(.orange)
                    Button("重新连接") { model.connect() }.disabled(model.isBusy)
                    Button("更换地址") { model.disconnect() }.disabled(model.isBusy)
                }
            }
        }
        .frame(maxWidth: 1150, alignment: .leading)
    }

    private func searchContent(client: LibreTVClient) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("搜索影片").font(.title2.bold()).foregroundStyle(CinemaTheme.text)
            HStack(spacing: 30) {
                TextField("输入电影或电视剧名称", text: $model.query)
                    .onSubmit { model.search() }.disabled(model.isBusy)
                Button("搜索") { model.search() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.sources.isEmpty {
                Text(LibreTVError.noSources.localizedDescription).foregroundStyle(CinemaTheme.text)
                Button("重新读取片源") { model.refreshSources() }.disabled(model.isBusy)
            }
            if !model.failedSources.isEmpty {
                Label("这些片源暂未返回结果：" + model.failedSources.joined(separator: "、") + "。仍可观看其他片源。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.hasSearched && !model.isBusy && model.results.isEmpty {
                Text(model.failedSources.isEmpty ? "没有找到影片，试试更短的片名。" : "本次没有可用结果，请重试或更换片名。")
                    .foregroundStyle(CinemaTheme.secondary)
            } else if !model.hasSearched && !model.isBusy {
                Text("输入片名开始搜索，再选择想看的版本和片源。")
                    .foregroundStyle(CinemaTheme.secondary)
            }
            if !model.results.isEmpty {
                Text("选择片源 · \(model.results.count) 个结果")
                    .font(.headline).foregroundStyle(CinemaTheme.text)
                Text("请核对片名和年份，选择想看的版本。")
                    .font(.caption).foregroundStyle(CinemaTheme.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 36), GridItem(.flexible(), spacing: 36)], spacing: 32) {
                ForEach(model.results) { item in
                    NavigationLink(value: item) {
                        HStack(alignment: .top, spacing: 24) {
                            PosterView(client: client, address: item.pic, onSessionExpired: sessionExpired)
                                .frame(width: 145)
                            VStack(alignment: .leading, spacing: 16) {
                                Text(item.name).font(.headline).lineLimit(2)
                                Text(item.sourceName).font(.subheadline).foregroundStyle(CinemaTheme.accent)
                                Text([item.year, item.typeName, item.remarks].compactMap { $0 }
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(CinemaCardStyle())
                    .accessibilityLabel([item.name, item.sourceName, item.year, item.remarks].compactMap { $0 }.joined(separator: "，"))
                    .accessibilityHint("查看简介和剧集")
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func sessionExpired() {
        path = []
        isShowingSearch = false
        model.sessionExpired()
    }
}

@MainActor private final class LibraryModel: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "LibreTV.serverURL") ?? ""
    @Published var password = ""
    @Published var query = ""
    @Published private(set) var status: ServerStatus?
    @Published private(set) var client: LibreTVClient?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isBusy = false
    @Published private(set) var progressText = ""
    @Published private(set) var results: [SearchItem] = []
    @Published private(set) var failedSources: [String] = []
    @Published private(set) var hasSearched = false
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    var sources: [SourceConfig] { client?.sources ?? [] }

    func connect() {
        run("正在连接服务器…") { [self] in
            let server = try ServerAddress(address)
            client?.disconnect()
            let newClient = LibreTVClient(server: server)
            client = newClient
            status = nil
            address = server.url.absoluteString
            UserDefaults.standard.set(address, forKey: "LibreTV.serverURL")
            let response = try await newClient.status()
            try Task.checkCancellation()
            status = response
            isAuthenticated = response.verified
        }
    }

    func login() {
        guard let client else { return }
        run("正在登录…") { [self] in
            try await client.login(password: password)
            try Task.checkCancellation()
            password = ""
            let response = try await client.status()
            try Task.checkCancellation()
            guard response.verified else { throw LibreTVError.unauthorized }
            status = response
            isAuthenticated = true
        }
    }

    func refreshSources() {
        guard let client else { return }
        run("正在读取片源…") { [self] in
            let response = try await client.status()
            try Task.checkCancellation()
            guard response.verified else { throw LibreTVError.unauthorized }
            status = response
        }
    }

    func search() {
        guard let client else { return }
        let requestedQuery = query
        run("正在搜索各片源…") { [self] in
            results = []
            failedSources = []
            hasSearched = false
            let response = try await client.search(query: requestedQuery)
            try Task.checkCancellation()
            results = response.list
            failedSources = response.failures.map { failure in
                (client.sources.first { $0.key == failure.sourceKey }?.name ?? "某个片源") +
                (failure.timedOut == true ? "（超时）" : "")
            }
            hasSearched = true
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        operationID = UUID()
        isBusy = false
    }

    func disconnect() {
        cancel()
        client?.disconnect()
        client = nil
        status = nil
        isAuthenticated = false
        password = ""
        results = []
        failedSources = []
        hasSearched = false
        error = nil
    }

    func sessionExpired() {
        cancel()
        isAuthenticated = false
        password = ""
        results = []
        failedSources = []
        hasSearched = false
        error = LibreTVError.unauthorized.localizedDescription
    }

    private func run(_ text: String, action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        let id = UUID()
        operationID = id
        error = nil
        isBusy = true
        progressText = text
        operation = Task { [weak self] in
            defer {
                if self?.operationID == id { self?.isBusy = false; self?.operation = nil }
            }
            do { try Task.checkCancellation(); try await action() }
            catch is CancellationError {}
            catch LibreTVError.unauthorized {
                guard !Task.isCancelled, self?.operationID == id else { return }
                self?.sessionExpired()
            }
            catch {
                guard !Task.isCancelled, self?.operationID == id else { return }
                self?.error = (error as? LibreTVError)?.localizedDescription ?? "请求失败，请稍后重试。"
            }
        }
    }
}

private struct DetailView: View {
    let item: SearchItem
    let client: LibreTVClient
    let onSessionExpired: () -> Void
    @State private var detail: VideoDetail?
    @State private var error: String?
    @State private var isLoading = true
    @State private var retry = 0
    @State private var requestID = UUID()
    @State private var selectedEpisode: EpisodeSelection?
    @State private var isShowingSynopsis = false

    private var synopsis: String { plainSynopsis(detail?.videoInfo.desc) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .top, spacing: 50) {
                    PosterView(client: client, address: detail?.videoInfo.cover ?? item.pic,
                               onSessionExpired: onSessionExpired)
                        .frame(width: 240).clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 20) {
                        Text(detail?.videoInfo.title ?? item.name).font(.largeTitle.bold()).foregroundStyle(CinemaTheme.text)
                        Text("片源：\(item.sourceName)").foregroundStyle(CinemaTheme.accent)
                        if isLoading { ProgressView("正在读取简介和剧集…") }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Button("重新读取") { retry += 1 }
                        }
                        if let info = detail?.videoInfo {
                            Text([info.year ?? item.year, info.area ?? item.area, info.typeName, info.remarks]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(CinemaTheme.secondary)
                            if let director = info.director, !director.isEmpty {
                                Text("导演：" + plainSynopsis(director)).font(.caption).foregroundStyle(CinemaTheme.text)
                            }
                            if let actor = info.actor, !actor.isEmpty {
                                Text("主演：" + plainSynopsis(actor)).font(.caption).foregroundStyle(CinemaTheme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(synopsis.isEmpty ? "这个片源暂未提供简介。" : synopsis)
                                .font(.body).lineLimit(3)
                                .foregroundStyle(CinemaTheme.secondary)
                            if !synopsis.isEmpty {
                                Button("阅读完整简介") { isShowingSynopsis = true }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusSection()
                if let detail {
                    if detail.episodes.isEmpty {
                        Text("这个片源没有可播放的剧集，请返回选择其他片源。").foregroundStyle(CinemaTheme.text)
                    } else {
                        Text("选择剧集 · 共 \(detail.episodes.count) 集").font(.title2.bold()).foregroundStyle(CinemaTheme.text)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], spacing: 28) {
                            ForEach(detail.episodes.indices, id: \.self) { index in
                                Button("第 \(index + 1) 集") {
                                    selectedEpisode = EpisodeSelection(index: index, url: detail.episodes[index])
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .focusSection()
                    }
                }
                Text("按遥控器返回键回到片源列表。")
                    .font(.caption).foregroundStyle(CinemaTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 80).padding(.vertical, 50)
        }
        .background(CinemaTheme.canvas.ignoresSafeArea())
        .task(id: retry) {
            let id = UUID()
            requestID = id
            isLoading = true
            error = nil
            defer { if requestID == id { isLoading = false } }
            do {
                let response = try await client.detail(for: item)
                try Task.checkCancellation()
                guard requestID == id else { return }
                detail = response
            } catch is CancellationError {
            } catch LibreTVError.unauthorized {
                guard !Task.isCancelled, requestID == id else { return }
                onSessionExpired()
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = (error as? LibreTVError)?.localizedDescription ?? "无法读取剧集，请重试。"
            }
        }
        .fullScreenCover(isPresented: $isShowingSynopsis) {
            SynopsisView(title: detail?.videoInfo.title ?? item.name, synopsis: synopsis)
        }
        .fullScreenCover(item: $selectedEpisode) { episode in
            PlayerView(client: client, episode: episode.url,
                       title: "\(item.name) · 第 \(episode.index + 1) 集", onSessionExpired: onSessionExpired)
        }
    }
}

private struct SynopsisView: View {
    let title: String
    let synopsis: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text(title + " · 完整简介").font(.title2.bold()).foregroundStyle(CinemaTheme.text)
                Spacer()
                Button("返回选集") { dismiss() }
            }
            Text("上下滑动遥控器阅读，按返回键回到选集。")
                .font(.caption).foregroundStyle(CinemaTheme.secondary)
            SynopsisTextView(text: synopsis)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 80).padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CinemaTheme.canvas.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }
}

private struct SynopsisTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.isScrollEnabled = true
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.backgroundColor = .clear
        view.textColor = UIColor(CinemaTheme.text)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 30, right: 20)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

private struct EpisodeSelection: Identifiable {
    let id = UUID()
    let index: Int
    let url: String
}

func plainSynopsis(_ raw: String?) -> String {
    guard let raw else { return "" }
    var text = raw
        .replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])\\s*>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, value) in [("&nbsp;", " "), ("&#160;", " "), ("&quot;", "\""), ("&#34;", "\""),
                            ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&middot;", "·"), ("&amp;", "&")] {
        text = text.replacingOccurrences(of: entity, with: value)
    }
    return text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\n[ \\t]*\\n(?:[ \\t]*\\n)+", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
