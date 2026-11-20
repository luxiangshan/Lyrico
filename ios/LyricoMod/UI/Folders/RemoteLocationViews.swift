import SwiftUI
import CoreImage.CIFilterBuiltins
import WebKit

// Remote location screens (Android RemoteLocationScreen / RemoteFolderBrowser / Cloud115 login):
// connection form -> test connection -> pick folders -> add to library and scan.

/// Add or edit a remote location.
struct RemoteLocationEditorView: View {
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    private let isEditing: Bool
    @State private var location: RemoteLocation
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var browser: BrowserTarget?
    @State private var loginMethod: Cloud115Method = .qr

    enum Cloud115Method: Hashable { case qr, web, cookie }

    struct BrowserTarget: Identifiable {
        let id = UUID()
        let client: RemoteStorageClient
        let location: RemoteLocation
    }

    init(kind: RemoteKind) {
        isEditing = false
        let name: String
        switch kind {
        case .cloud115: name = L("remote_type_115")
        default: name = kind.label
        }
        _location = State(initialValue: RemoteLocation(id: Self.newId(), type: kind, displayName: name))
    }

    init(existing: RemoteLocation) {
        isEditing = true
        _location = State(initialValue: existing)
    }

    static func newId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    var body: some View {
        Form {
            Section {
                TextField(L("remote_field_name"), text: $location.displayName)
            }
            switch location.type {
            case .webdav, .openlist:
                Section {
                    TextField(location.type == .webdav ? L("remote_field_url_webdav") : L("remote_field_url_openlist"), text: $location.baseUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(location.type == .openlist ? L("remote_field_username_openlist") : L("remote_field_username"), text: $location.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(isEditing ? L("remote_field_password_keep") : L("remote_field_password"), text: $password)
                }
            case .smb:
                Section {
                    TextField(L("remote_field_host_smb"), text: $location.baseUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("remote_field_share"), text: $location.share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("remote_field_username"), text: $location.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(isEditing ? L("remote_field_password_keep") : L("remote_field_password"), text: $password)
                    TextField(L("remote_field_domain"), text: $location.domain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            case .cloud115:
                cloud115Section
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text(connecting ? L("remote_connecting") : L("remote_connect"))
                        Spacer()
                        if connecting { ProgressView() }
                    }
                }
                .disabled(connecting || !canConnect)
            }
        }
        .navigationTitle(isEditing ? L("remote_edit_title", location.displayName) : L("remote_add_title", location.type == .cloud115 ? L("remote_type_115") : location.type.label))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
        }
        .navigationDestination(isPresented: Binding(get: { browser != nil }, set: { if !$0 { browser = nil } })) {
            if let target = browser {
                RemoteFolderBrowserView(client: target.client, initiallySelected: Set(isEditing ? existingFolders : [])) { paths in
                    library.saveRemoteLocation(target.location, paths: paths)
                    dismiss()
                }
            }
        }
    }

    private var existingFolders: [String] {
        library.folders.filter { $0.kind == .remote && $0.sourceId == location.id }.map(\.path)
    }

    private var canConnect: Bool {
        switch location.type {
        case .webdav, .openlist: return !location.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty
        case .smb: return !location.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty && !location.share.trimmingCharacters(in: .whitespaces).isEmpty
        case .cloud115: return !location.secret.isEmpty
        }
    }

    @ViewBuilder private var cloud115Section: some View {
        if !location.secret.isEmpty {
            Section {
                Label(L("remote_115_signed_in"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
        Section {
            Picker("", selection: $loginMethod) {
                Text(L("remote_115_method_qr")).tag(Cloud115Method.qr)
                Text(L("remote_115_method_web")).tag(Cloud115Method.web)
                Text("Cookie").tag(Cloud115Method.cookie)
            }
            .pickerStyle(.segmented)
            switch loginMethod {
            case .qr:
                Cloud115QRLoginView { cookie in location.secret = cookie; error = nil }
            case .web:
                Cloud115WebLoginLauncher { cookie in location.secret = cookie; error = nil }
            case .cookie:
                Cloud115CookieField { cookie in location.secret = cookie; error = nil }
            }
        }
    }

    private func connect() async {
        var loc = location
        loc.baseUrl = loc.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        loc.share = loc.share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ").union(.whitespacesAndNewlines))
        loc.username = loc.username.trimmingCharacters(in: .whitespacesAndNewlines)
        loc.domain = loc.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if loc.displayName.trimmingCharacters(in: .whitespaces).isEmpty { loc.displayName = loc.type.label }
        if loc.type != .cloud115, !password.isEmpty || !isEditing { loc.secret = password }
        connecting = true
        error = nil
        defer { connecting = false }
        do {
            let client = try RemoteIntegration.makeClient(loc)
            try await client.testConnection()
            browser = BrowserTarget(client: client, location: loc)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension RemoteLocationEditorView.BrowserTarget: Hashable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Browses folders of a connected location and lets the user pick several (Android RemoteFolderBrowser).
struct RemoteFolderBrowserView: View {
    let client: RemoteStorageClient
    let onDone: ([String]) -> Void

    @State private var path = "/"
    @State private var entries: [LibraryEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: Set<String>

    init(client: RemoteStorageClient, initiallySelected: Set<String>, onDone: @escaping ([String]) -> Void) {
        self.client = client
        self.onDone = onDone
        _selected = State(initialValue: initiallySelected)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "folder")
                    Text(path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                }
                Button {
                    toggle(path)
                } label: {
                    Label(L("remote_browse_select_current"), systemImage: selected.contains(path) ? "checkmark.circle.fill" : "circle")
                }
                if path != "/" {
                    Button { open(parent(of: path)) } label: { Label(L("remote_browse_up"), systemImage: "arrow.turn.left.up") }
                }
            }
            Section {
                if loading {
                    HStack { ProgressView(); Text(L("remote_browse_loading")).foregroundStyle(.secondary) }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button(L("ios_retry")) { load() }
                } else if entries.isEmpty {
                    Text(L("remote_browse_empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.path) { e in
                        HStack {
                            Button { toggle(e.path) } label: {
                                Image(systemName: selected.contains(e.path) ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.large)
                            }
                            .buttonStyle(.borderless)
                            Button { open(e.path) } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    Text(e.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !selected.isEmpty {
                Section(L("remote_browse_selected", selected.count)) {
                    ForEach(selected.sorted(), id: \.self) { p in
                        HStack {
                            Text(p).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { selected.remove(p) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("remote_add_folder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("remote_save")) { onDone(selected.sorted()) }.disabled(selected.isEmpty)
            }
        }
        .task { load() }
    }

    private func toggle(_ p: String) {
        if selected.contains(p) { selected.remove(p) } else { selected.insert(p) }
    }

    private func open(_ p: String) {
        path = p
        load()
    }

    private func parent(of p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func load() {
        let target = path
        loading = true
        error = nil
        Task {
            do {
                let list = try await client.list(target)
                guard target == path else { return }
                entries = list.filter { $0.isDirectory && !AudioFormats.skippedDirectories.contains($0.name) && !$0.name.hasPrefix(".") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                guard target == path else { return }
                entries = []
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - 115 login

/// QR login: shows the code, polls until confirmed, then hands the cookie back.
struct Cloud115QRLoginView: View {
    let onCookie: (String) -> Void

    @State private var flow = Cloud115QRLoginFlow()
    @State private var code: Cloud115QRLoginFlow.Code?
    @State private var image: UIImage?
    @State private var status: Cloud115QRLoginFlow.Status = .waiting
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var share: ShareItems?
    @State private var done = false

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .opacity(status == .expired || status == .cancelled ? 0.3 : 1)
            } else if error == nil {
                ProgressView().frame(height: 120)
            }
            Text(statusText).font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
            HStack {
                Button(L("remote_qr_refresh")) { start() }.buttonStyle(.bordered)
                if let image {
                    Button(L("remote_qr_share")) { share = ShareItems(items: [image]) }.buttonStyle(.bordered)
                    Button(L("remote_qr_save")) {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    }.buttonStyle(.bordered)
                }
            }
            .font(.footnote)
            Text(L("remote_qr_album_hint")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear { if code == nil { start() } }
        .onDisappear { task?.cancel() }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
    }

    private var statusText: String {
        if let error { return error }
        if done { return L("remote_115_signed_in") }
        switch status {
        case .waiting: return L("remote_qr_hint")
        case .scanned: return L("remote_qr_scanned")
        case .confirmed: return L("remote_qr_confirmed")
        case .expired: return L("remote_qr_expired")
        case .cancelled: return L("remote_qr_cancelled")
        }
    }

    private func start() {
        task?.cancel()
        error = nil
        status = .waiting
        image = nil
        done = false
        task = Task { @MainActor in
            do {
                let c = try await flow.start()
                code = c
                image = Self.qrImage(c.content)
                let cookie = try await flow.awaitCookie(c) { s in status = s }
                if Task.isCancelled { return }
                if let cookie {
                    done = true
                    onCookie(cookie)
                } else if status != .cancelled {
                    status = .expired
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Manual cookie entry (advanced).
struct Cloud115CookieField: View {
    let onCookie: (String) -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("remote_115_cookie_hint")).font(.caption).foregroundStyle(.secondary)
            TextField(L("remote_115_cookie_field"), text: $text, axis: .vertical)
                .lineLimit(3...6)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button(L("remote_115_cookie_connect")) {
                if let c = Cloud115QRLoginFlow.normalizeCookie(text) {
                    error = nil
                    ok = true
                    onCookie(c)
                } else {
                    ok = false
                    error = L("remote_115_cookie_invalid")
                }
            }
            .buttonStyle(.bordered)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if ok { Label(L("remote_115_signed_in"), systemImage: "checkmark").font(.caption).foregroundStyle(.green) }
        }
        .padding(.vertical, 4)
    }
}

/// Account/password login on 115's own web page (desktop UA), reading the session cookie from the web view.
struct Cloud115WebLoginLauncher: View {
    let onCookie: (String) -> Void
    @State private var show = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("remote_115_web_hint")).font(.caption).foregroundStyle(.secondary)
            Text(L("remote_115_web_slot_note")).font(.caption).foregroundStyle(.orange)
            Button(L("remote_115_web_open")) { show = true }.buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $show) {
            NavigationStack {
                Cloud115WebLoginView { cookie in
                    show = false
                    onCookie(cookie)
                }
            }
        }
    }
}

struct Cloud115WebLoginView: View {
    let onCookie: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = Cloud115WebLoginModel()

    var body: some View {
        Cloud115WebView(model: model)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                if let s = model.status {
                    Text(s).font(.footnote).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
            .navigationTitle(L("remote_115_method_web"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onAppear { model.onCookie = onCookie }
            .onDisappear { model.stop() }
    }
}

@MainActor
final class Cloud115WebLoginModel: NSObject, ObservableObject, WKNavigationDelegate {
    static let loginURL = URL(string: "https://115.com/?mode=login")!
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @Published var status: String?
    var onCookie: ((String) -> Void)?
    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // Non-persistent store: 115 cookies never outlive this login screen.
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: config)
        v.customUserAgent = Self.desktopUA
        v.navigationDelegate = self
        v.load(URLRequest(url: Self.loginURL))
        return v
    }()
    private var finished = false
    private var timer: Timer?

    func reload() {
        webView.load(URLRequest(url: Self.loginURL))
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCookies() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.checkCookies() }
    }

    private func checkCookies() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            var map: [String: String] = [:]
            for c in cookies where c.domain.hasSuffix("115.com") {
                let k = c.name.uppercased()
                if ["UID", "CID", "SEID", "KID"].contains(k), !c.value.isEmpty, map[k] == nil { map[k] = c.value }
            }
            let raw = ["UID", "CID", "SEID", "KID"].compactMap { k in map[k].map { "\(k)=\($0)" } }.joined(separator: "; ")
            guard let cookie = Cloud115QRLoginFlow.normalizeCookie(raw) else { return }
            Task { @MainActor in
                guard !self.finished else { return }
                self.finished = true
                self.stop()
                self.status = L("remote_115_web_checking")
                self.onCookie?(cookie)
            }
        }
    }
}

struct Cloud115WebView: UIViewRepresentable {
    let model: Cloud115WebLoginModel

    func makeUIView(context: Context) -> WKWebView {
        model.startPolling()
        return model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.stopLoading()
    }
}
