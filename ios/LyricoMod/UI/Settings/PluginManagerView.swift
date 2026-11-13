// Settings → 插件管理 (Android PluginManagerScreen + PluginConfigScreen).
#if canImport(LyricoPlugins)
import SwiftUI
import UniformTypeIdentifiers
import LyricoPlugins

extension PluginSourceType {
    var localizedTitle: String {
        switch self {
        case .metadata: return L("plugin_type_metadata")
        case .lyrics: return L("plugin_type_lyrics")
        case .cover: return L("plugin_type_cover")
        }
    }

    var systemImage: String {
        switch self {
        case .metadata: return "text.badge.checkmark"
        case .lyrics: return "text.quote"
        case .cover: return "photo"
        }
    }
}

struct PluginIconView: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct PluginManagerView: View {
    @ObservedObject var manager: PluginManager
    @State private var type: PluginSourceType = .metadata
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var busy = false
    @State private var message: String?
    @State private var catalog: PluginCatalog?
    @State private var pendingDelete: InstalledPlugin?

    var body: some View {
        let list = manager.plugins(for: type)
        List {
            Section {
                Picker(L("plugin_type_with_value", type.localizedTitle), selection: $type) {
                    ForEach(PluginSourceType.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if list.isEmpty {
                    Text(manager.plugins.isEmpty ? L("plugin_empty") : L("plugin_type_empty", type.localizedTitle))
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { plugin in
                    NavigationLink {
                        PluginDetailView(manager: manager, pluginId: plugin.id)
                    } label: {
                        PluginRow(manager: manager, plugin: plugin, type: type)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = plugin } label: { Label(L("plugin_uninstall"), systemImage: "trash") }
                    }
                }
                .onMove { from, to in perform { try manager.move(type, fromOffsets: from, toOffset: to) } }
            }
        }
        .navigationTitle(L("plugin_manager_title"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !list.isEmpty { EditButton() }
                Menu {
                    Button { showFileImporter = true } label: { Label(L("ios_plugin_import_file"), systemImage: "doc.zipper") }
                    Button { urlText = ""; showURLPrompt = true } label: { Label(L("ios_plugin_install_url"), systemImage: "link") }
                } label: { Image(systemName: "plus") }
                .disabled(busy)
            }
        }
        .overlay {
            if busy {
                ProgressView(L("plugin_action_working")).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result { message = L("plugin_action_failed", error.localizedDescription) }
                return
            }
            Task { await importFiles(urls) }
        }
        .alert(L("ios_plugin_install_url"), isPresented: $showURLPrompt) {
            TextField("https://", text: $urlText)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button(L("cancel"), role: .cancel) {}
            Button(L("plugin_import_install")) { Task { await installURL(urlText) } }
        } message: { Text(L("ios_plugin_install_url_hint")) }
        .alert(L("plugin_manager_title"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("confirm"), role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog(L("plugin_uninstall"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { plugin in
            Button(L("plugin_uninstall"), role: .destructive) {
                perform { try manager.uninstall(plugin.id) }
                message = L("plugin_action_deleted")
            }
        } message: { plugin in Text(L("plugin_uninstall_confirm_message", manager.displayName(plugin))) }
        .sheet(item: Binding(get: { catalog.map(CatalogBox.init) }, set: { catalog = $0?.catalog })) { box in
            NavigationStack { PluginCatalogView(manager: manager, catalog: box.catalog) }
        }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { message = L("plugin_action_failed", String(describing: error)) }
    }

    private func importFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        var installed = 0
        var failures: [String] = []
        for url in urls {
            do {
                let result = try await manager.installZip(at: url)
                installed += result.installed.count
                failures += result.failed.map { "\($0.displayName): \($0.reason)" }
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        message = summary(installed: installed, failures: failures)
    }

    private func installURL(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await manager.installFromURL(trimmed) {
            case .archive(let result):
                message = summary(installed: result.installed.count, failures: result.failed.map { "\($0.displayName): \($0.reason)" })
            case .catalog(let c):
                catalog = c
            }
        } catch {
            message = L("plugin_action_failed", String(describing: error))
        }
    }

    private func summary(installed: Int, failures: [String]) -> String {
        if installed == 0 && failures.isEmpty { return L("plugin_action_none_installable") }
        return ([L("plugin_install_result", installed, failures.count)] + failures).joined(separator: "\n")
    }
}

private struct CatalogBox: Identifiable {
    let catalog: PluginCatalog
    var id: String { catalog.sourceUrl }
}

private struct PluginRow: View {
    @ObservedObject var manager: PluginManager
    let plugin: InstalledPlugin
    let type: PluginSourceType

    var body: some View {
        HStack(spacing: 12) {
            PluginIconView(url: manager.iconURL(of: plugin))
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.displayName(plugin)).lineLimit(1)
                Text([plugin.versionName, plugin.author].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(plugin.sourceTypes, id: \.self) { t in
                        Image(systemName: t.systemImage).font(.caption2)
                            .foregroundStyle(plugin.isEnabled(for: t) ? Color.accentColor : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { plugin.isEnabled(for: type) },
                set: { value in try? manager.setEnabled(plugin.id, type, value) }))
            .labelsHidden()
        }
    }
}

/// Releases of a catalog fetched from "install from link".
struct PluginCatalogView: View {
    @ObservedObject var manager: PluginManager
    let catalog: PluginCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var working: Set<String> = []
    @State private var errors: [String: String] = [:]

    var body: some View {
        List {
            Section(footer: Text(catalog.sourceUrl).font(.caption)) {
                ForEach(catalog.plugins) { release in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(release.name)
                                Text(L("plugin_version_with_value", release.versionName) + " · " + L("plugin_download_size", Format.fileSize(release.size)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            action(release)
                        }
                        if !release.changelog.isEmpty { Text(release.changelog).font(.caption).foregroundStyle(.secondary) }
                        if !release.compatible { Text(L("plugin_online_incompatible")).font(.caption).foregroundStyle(.orange) }
                        if let e = errors[release.id] { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle(L("plugin_catalog_plugins", catalog.plugins.count))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("action_done")) { dismiss() } } }
    }

    @ViewBuilder
    private func action(_ release: PluginRelease) -> some View {
        let installed = manager.plugin(release.id)
        if working.contains(release.id) {
            ProgressView()
        } else if let installed, installed.versionCode == release.versionCode {
            Text(L("plugin_task_installed")).font(.caption).foregroundStyle(.secondary)
        } else {
            let title: String = {
                guard let installed else { return L("plugin_import_install") }
                return installed.versionCode < release.versionCode ? L("plugin_update") : L("plugin_import_conflict_downgrade")
            }()
            Button(title) {
                Task {
                    working.insert(release.id)
                    errors[release.id] = nil
                    do { try await manager.install(release: release, from: catalog) } catch { errors[release.id] = String(describing: error) }
                    working.remove(release.id)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!release.compatible)
        }
    }
}

/// Plugin details, enabled types, custom name and config (Android PluginConfigScreen).
struct PluginDetailView: View {
    @ObservedObject var manager: PluginManager
    let pluginId: String
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var customName = ""
    @State private var errors: Set<String> = []
    @State private var loaded = false
    @State private var savedNotice = false
    @State private var confirmUninstall = false
    @State private var failure: String?

    var body: some View {
        if let plugin = manager.plugin(pluginId) {
            content(plugin)
        } else {
            Text(L("source_config_invalid_source")).foregroundStyle(.secondary)
        }
    }

    private func content(_ plugin: InstalledPlugin) -> some View {
        let fields = manager.configFields(pluginId)
        return Form {
            Section {
                HStack(spacing: 12) {
                    PluginIconView(url: manager.iconURL(of: plugin), size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.displayName(plugin)).font(.headline)
                        Text(plugin.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text(L("plugin_version_with_value", "\(plugin.versionName) (\(plugin.versionCode))"))
                if !plugin.author.isEmpty { Text(L("plugin_author_with_value", plugin.author)) }
                Text(L("plugin_api_versions_with_value", plugin.apiVersion, plugin.minHostApiVersion)).font(.caption).foregroundStyle(.secondary)
                let description = manager.localizedDescription(plugin)
                if !description.isEmpty { Text(description).font(.callout) }
                if let source = plugin.installSourceUrl { InfoRow(label: L("plugin_install_source"), value: source) }
                if let update = plugin.updateUrl { InfoRow(label: L("plugin_update_url"), value: update) }
            }
            Section(header: Text(L("plugin_custom_name")), footer: Text(L("plugin_custom_name_hint", manager.originalName(plugin)))) {
                TextField(manager.originalName(plugin), text: $customName)
                    .onSubmit { saveName() }
            }
            Section(footer: plugin.isEnabledAnywhere ? nil : Text(L("source_config_plugin_disabled_hint"))) {
                ForEach(plugin.sourceTypes, id: \.self) { t in
                    Toggle(isOn: Binding(get: { manager.plugin(pluginId)?.isEnabled(for: t) ?? false },
                                         set: { v in try? manager.setEnabled(pluginId, t, v) })) {
                        Label(t.localizedTitle, systemImage: t.systemImage)
                    }
                }
            }
            configSections(fields)
            Section {
                Button(L("plugin_uninstall"), role: .destructive) { confirmUninstall = true }
            }
        }
        .navigationTitle(L("plugin_config_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("source_config_save")) { save() } }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            values = manager.config(pluginId)
            customName = plugin.customName ?? ""
        }
        .alert(L("source_config_saved"), isPresented: $savedNotice) { Button(L("confirm"), role: .cancel) {} }
        .alert(L("plugin_config_title"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L("confirm"), role: .cancel) {}
        } message: { Text(failure ?? "") }
        .confirmationDialog(L("plugin_uninstall"), isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button(L("plugin_uninstall"), role: .destructive) {
                do { try manager.uninstall(pluginId); dismiss() } catch { failure = String(describing: error) }
            }
        } message: { Text(L("plugin_uninstall_confirm_message", manager.displayName(plugin))) }
    }

    @ViewBuilder
    private func configSections(_ fields: [PluginConfigField]) -> some View {
        if fields.isEmpty {
            Section { Text(L("source_config_empty")).foregroundStyle(.secondary) }
        } else {
            ForEach(groups(fields), id: \.key) { group in
                if group.fields.contains(where: { $0.dependency.isSatisfied(values) }) {
                    Section(group.title) {
                        ForEach(group.fields.filter { $0.dependency.isSatisfied(values) }) { field in
                            fieldView(field)
                        }
                    }
                }
            }
        }
    }

    private struct FieldGroup { let key: String; let title: String; let fields: [PluginConfigField] }

    private func groups(_ fields: [PluginConfigField]) -> [FieldGroup] {
        var order: [String] = []
        var map: [String: [PluginConfigField]] = [:]
        for f in fields {
            let key = f.group.trimmingCharacters(in: .whitespaces)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(f)
        }
        return order.map { key in
            let title = key.isEmpty ? L("source_config_basic") : (map[key]?.first?.groupTitle ?? key)
            return FieldGroup(key: key, title: title, fields: map[key] ?? [])
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0; errors.remove(key) })
    }

    @ViewBuilder
    private func fieldView(_ field: PluginConfigField) -> some View {
        let title = field.title + (field.required ? " *" : "")
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case .switch:
                Toggle(isOn: Binding(get: { (values[field.key] ?? "").lowercased() == "true" },
                                     set: { values[field.key] = $0 ? "true" : "false" })) {
                    Text(title)
                }
            case .dropdown:
                Picker(title, selection: binding(field.key)) {
                    if !field.options.contains(where: { $0.value == values[field.key] }) { Text("—").tag(values[field.key] ?? "") }
                    ForEach(field.options, id: \.value) { option in Text(option.label).tag(option.value) }
                }
                if let selected = field.options.first(where: { $0.value == values[field.key] }), !selected.summary.isEmpty {
                    Text(selected.summary).font(.caption).foregroundStyle(.secondary)
                }
            case .markdown:
                markdown(field.defaultValue.isEmpty ? (field.summary ?? "") : field.defaultValue)
            case .password:
                Text(title).font(.subheadline)
                SecureField(field.title, text: binding(field.key)).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .number:
                Text(title).font(.subheadline)
                TextField(field.title, text: binding(field.key)).keyboardType(.numbersAndPunctuation)
            case .textarea:
                Text(title).font(.subheadline)
                TextField(field.title, text: binding(field.key), axis: .vertical).lineLimit(3...10)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            case .text:
                Text(title).font(.subheadline)
                TextField(field.title, text: binding(field.key)).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if field.type != .markdown, let summary = field.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if errors.contains(field.key) {
                Text(L("source_config_required_error")).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed).font(.callout)
        }
        return Text(text).font(.callout)
    }

    private func saveName() {
        do { try manager.setCustomName(pluginId, customName) } catch { failure = String(describing: error) }
    }

    private func save() {
        saveName()
        let missing = manager.missingRequiredKeys(pluginId, values: values)
        guard missing.isEmpty else { errors = Set(missing); return }
        do {
            try manager.setConfig(pluginId, values)
            savedNotice = true
        } catch { failure = String(describing: error) }
    }
}
#endif
