import SwiftUI
import AppKit
import QuickLookUI

// MARK: - Store

@MainActor
final class ADBFileExplorerStore: ObservableObject {
    @Published private(set) var items: [ADBFileItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String? = nil
    @Published private(set) var currentPath: String = "/"
    @Published private(set) var history: [String] = ["/"]
    @Published private(set) var historyIndex: Int = 0
    @Published private(set) var isPulling = false
    @Published var pullingFileName: String? = nil
    @Published var selectedIDs: Set<String> = []
    @Published var lastSelectedID: String? = nil
    @Published var renamingItem: ADBFileItem? = nil
    @Published var infoItem: ADBFileItem? = nil

    let deviceID: String
    let deviceName: String
    private let provider: ADBProviding

    init(deviceID: String, deviceName: String, provider: ADBProviding = ADBProvider.shared) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.provider = provider
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var selectedItems: [ADBFileItem] { items.filter { selectedIDs.contains($0.id) } }

    var pathComponents: [(label: String, path: String)] {
        var components: [(String, String)] = [("/", "/")]
        var accumulated = ""
        for part in currentPath.split(separator: "/") {
            accumulated += "/\(part)"
            components.append((String(part), accumulated))
        }
        return components
    }

    func loadCurrentPath() {
        isLoading = true
        errorMessage = nil
        selectedIDs.removeAll()
        let path = currentPath
        let deviceID = self.deviceID
        let provider = self.provider

        Task.detached { [weak self] in
            do {
                let result = try provider.listFiles(path: path, deviceID: deviceID)
                await MainActor.run { [weak self] in
                    self?.items = result
                    self?.isLoading = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.items = []
                    self?.isLoading = false
                }
            }
        }
    }

    func navigate(to path: String) {
        guard path != currentPath else { return }
        let truncated = Array(history.prefix(historyIndex + 1))
        history = truncated + [path]
        historyIndex = history.count - 1
        currentPath = path
        loadCurrentPath()
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = history[historyIndex]
        loadCurrentPath()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = history[historyIndex]
        loadCurrentPath()
    }

    func refresh() { loadCurrentPath() }

    // MARK: - Local cache

    static var localCacheRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AIPhone/DeviceFiles", isDirectory: true)
    }

    func localPath(for remotePath: String) -> URL {
        let sanitizedDevice = deviceName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let relativePath = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
        return Self.localCacheRoot
            .appendingPathComponent(sanitizedDevice, isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    nonisolated func pullToLocalSync(item: ADBFileItem, destination: URL, provider: ADBProviding, deviceID: String) throws -> URL {
        try provider.pullFile(remotePath: item.path, localPath: destination.path, deviceID: deviceID)
        return destination
    }

    nonisolated func pullItemsToLocalSync(_ items: [ADBFileItem], destinations: [(ADBFileItem, URL)], provider: ADBProviding, deviceID: String) throws -> [URL] {
        var urls: [URL] = []
        for (item, dest) in destinations {
            try provider.pullFile(remotePath: item.path, localPath: dest.path, deviceID: deviceID)
            urls.append(dest)
        }
        return urls
    }

    // MARK: - Actions

    func openItems(_ items: [ADBFileItem]) {
        guard !isPulling else { return }
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        isPulling = true
        pullingFileName = files.count == 1 ? files[0].name : "\(files.count) files"

        let pairs = files.map { ($0, localPath(for: $0.path)) }
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            for (file, dest) in pairs {
                do {
                    try provider.pullFile(remotePath: file.path, localPath: dest.path, deviceID: deviceID)
                    await MainActor.run { NSWorkspace.shared.open(dest) }
                } catch {
                    await MainActor.run { self?.errorMessage = "Failed to open \(file.name): \(error.localizedDescription)" }
                }
            }
            await MainActor.run {
                self?.isPulling = false
                self?.pullingFileName = nil
            }
        }
    }

    func pullAndOpen(item: ADBFileItem) { openItems([item]) }

    func deleteItems(_ items: [ADBFileItem]) {
        let toDelete = items
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            for item in toDelete {
                do {
                    try provider.deleteFile(remotePath: item.path, recursive: item.isDirectory, deviceID: deviceID)
                } catch {
                    await MainActor.run { self?.errorMessage = "Failed to delete \(item.name): \(error.localizedDescription)" }
                    return
                }
            }
            await MainActor.run { self?.refresh() }
        }
    }

    func renameItem(_ item: ADBFileItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let parentPath = (item.path as NSString).deletingLastPathComponent
        let newPath = (parentPath as NSString).appendingPathComponent(trimmed)
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            do {
                try provider.renameFile(oldPath: item.path, newPath: newPath, deviceID: deviceID)
                await MainActor.run { self?.refresh() }
            } catch {
                await MainActor.run { self?.errorMessage = "Failed to rename: \(error.localizedDescription)" }
            }
        }
    }

    func copyItemsToClipboard(_ items: [ADBFileItem]) {
        guard !isPulling else { return }
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        isPulling = true
        pullingFileName = files.count == 1 ? files[0].name : "\(files.count) files"

        let pairs = files.map { ($0, localPath(for: $0.path)) }
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            do {
                var urls: [URL] = []
                for (file, dest) in pairs {
                    try provider.pullFile(remotePath: file.path, localPath: dest.path, deviceID: deviceID)
                    urls.append(dest)
                }
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls.map { $0 as NSURL } as [NSPasteboardWriting])
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Copy failed: \(error.localizedDescription)" }
            }
            await MainActor.run {
                self?.isPulling = false
                self?.pullingFileName = nil
            }
        }
    }

    func quickLookItems(_ items: [ADBFileItem]) {
        guard !isPulling else { return }
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        isPulling = true
        pullingFileName = files.count == 1 ? files[0].name : "\(files.count) files"

        let pairs = files.map { ($0, localPath(for: $0.path)) }
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            do {
                var urls: [URL] = []
                for (file, dest) in pairs {
                    try provider.pullFile(remotePath: file.path, localPath: dest.path, deviceID: deviceID)
                    urls.append(dest)
                }
                await MainActor.run {
                    FileQuickLookCoordinator.shared.present(urls: urls)
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Quick Look failed: \(error.localizedDescription)" }
            }
            await MainActor.run {
                self?.isPulling = false
                self?.pullingFileName = nil
            }
        }
    }

    func showInfo(for item: ADBFileItem) { infoItem = item }

    // MARK: - Import (push)

    func importFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isPulling = true
        pullingFileName = "Uploading \(urls.count) item(s)"

        let targetPath = self.currentPath
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            for url in urls {
                let remotePath = (targetPath as NSString).appendingPathComponent(url.lastPathComponent)
                do {
                    try provider.pushFile(localPath: url.path, remotePath: remotePath, deviceID: deviceID)
                } catch {
                    await MainActor.run { self?.errorMessage = "Upload failed for \(url.lastPathComponent): \(error.localizedDescription)" }
                }
            }
            await MainActor.run {
                self?.isPulling = false
                self?.pullingFileName = nil
                self?.refresh()
            }
        }
    }

    func importToFolder(urls: [URL], folderPath: String) {
        guard !urls.isEmpty else { return }
        let provider = self.provider
        let deviceID = self.deviceID

        Task.detached { [weak self] in
            for url in urls {
                let remotePath = (folderPath as NSString).appendingPathComponent(url.lastPathComponent)
                do {
                    try provider.pushFile(localPath: url.path, remotePath: remotePath, deviceID: deviceID)
                } catch {
                    await MainActor.run { self?.errorMessage = "Upload failed: \(error.localizedDescription)" }
                }
            }
            await MainActor.run { self?.refresh() }
        }
    }
}

// MARK: - Quick Look Coordinator

@MainActor
final class FileQuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FileQuickLookCoordinator()

    private var urls: [URL] = []

    func present(urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

// MARK: - Main View

struct ADBFileExplorerView: View {
    let deviceID: String
    let deviceName: String

    @StateObject private var store: ADBFileExplorerStore

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        _store = StateObject(wrappedValue: ADBFileExplorerStore(deviceID: deviceID, deviceName: deviceName))
    }

    var body: some View {
        VStack(spacing: 0) {
            FileExplorerToolbar(store: store)

            Divider()

            ZStack {
                if store.isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.items.isEmpty && store.errorMessage == nil {
                    FileExplorerEmptyView()
                } else {
                    FileExplorerList(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay(alignment: .top) {
                if let error = store.errorMessage {
                    FileExplorerToast(message: error) {
                        store.errorMessage = nil
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: store.errorMessage)
                }
            }

            Divider()

            FileExplorerPathBar(store: store)

            if store.isPulling, let fileName = store.pullingFileName {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .focusable()
        .ifAvailable_onKeyPressHandlers(store: store)
        .onAppear {
            store.loadCurrentPath()
        }
        .sheet(item: $store.infoItem) { item in
            FileInfoSheet(item: item)
        }
        .sheet(item: $store.renamingItem) { item in
            FileRenameSheet(item: item) { newName in
                store.renameItem(item, newName: newName)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    defer { group.leave() }
                    let resolved: URL? = {
                        if let url = item as? URL { return url }
                        if let nsURL = item as? NSURL { return nsURL as URL }
                        if let data = item as? Data {
                            if let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) { return url }
                            if let str = String(data: data, encoding: .utf8), let url = URL(string: str) { return url }
                        }
                        return nil
                    }()
                    if let url = resolved {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            store.importFiles(urls: urls)
        }
    }
}

// MARK: - Error Toast

private struct FileExplorerToast: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - Toolbar

private struct FileExplorerToolbar: View {
    @ObservedObject var store: ADBFileExplorerStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Button {
                    store.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark
                                    ? Color.white.opacity(0.05)
                                    : Color.black.opacity(0.04))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canGoBack)

                Button {
                    store.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark
                                    ? Color.white.opacity(0.05)
                                    : Color.black.opacity(0.04))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canGoForward)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5, height: 16)
                .padding(.horizontal, 4)

            Text(store.currentPath == "/" ? "Root" : URL(fileURLWithPath: store.currentPath).lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if store.selectedIDs.count > 1 {
                Text("\(store.selectedIDs.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.10))
                    )
            }

            if !store.isLoading {
                Text("\(store.items.count) \(store.items.count == 1 ? "item" : "items")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.black.opacity(0.04))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
        .padding(.horizontal, 10)
    }
}

// MARK: - File List

private struct FileExplorerList: View {
    @ObservedObject var store: ADBFileExplorerStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                FileExplorerHeaderRow()

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)

                ForEach(store.items) { item in
                    FileExplorerRow(
                        item: item,
                        isSelected: store.selectedIDs.contains(item.id),
                        store: store
                    )
                }
            }
        }
        .onTapGesture {
            store.selectedIDs.removeAll()
        }
    }
}

private struct FileExplorerHeaderRow: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Size")
                .frame(width: 80, alignment: .trailing)

            Text("Date Modified")
                .frame(width: 150, alignment: .trailing)

            Text("Permissions")
                .frame(width: 120, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.3)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Row

private struct FileExplorerRow: View {
    let item: ADBFileItem
    let isSelected: Bool
    let store: ADBFileExplorerStore

    @State private var isHovered = false
    @State private var isDragTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20, alignment: .center)

                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if item.isSymlink {
                    Image(systemName: "arrow.triangle.turn.up.right.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.formattedSize)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)

            Text(item.modifiedDate ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 150, alignment: .trailing)

            Text(item.permissions ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected ? Color.accentColor.opacity(0.14) :
                    isDragTargeted ? Color.accentColor.opacity(0.08) :
                    isHovered ? Color.primary.opacity(0.04) : Color.clear
                )
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                store.navigate(to: item.path)
            } else {
                store.pullAndOpen(item: item)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded {
                    if NSEvent.modifierFlags.contains(.command) {
                        // Cmd+Click: toggle individual item
                        if store.selectedIDs.contains(item.id) {
                            store.selectedIDs.remove(item.id)
                        } else {
                            store.selectedIDs.insert(item.id)
                        }
                        store.lastSelectedID = item.id
                    } else if NSEvent.modifierFlags.contains(.shift) {
                        // Shift+Click: select range from anchor to clicked item
                        if let anchorID = store.lastSelectedID,
                           let anchorIndex = store.items.firstIndex(where: { $0.id == anchorID }),
                           let clickIndex = store.items.firstIndex(where: { $0.id == item.id }) {
                            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
                            let rangeIDs = Set(store.items[range].map(\.id))
                            store.selectedIDs.formUnion(rangeIDs)
                        } else {
                            store.selectedIDs = [item.id]
                            store.lastSelectedID = item.id
                        }
                    } else {
                        // Plain click: select only this item
                        store.selectedIDs = [item.id]
                        store.lastSelectedID = item.id
                    }
                }
        )
        .onHover { isHovered = $0 }
        .contextMenu { fileContextMenu }
        .onDrag {
            let provider = NSItemProvider()
            if !item.isDirectory {
                let destURL = store.localPath(for: item.path)
                let deviceID = store.deviceID
                provider.suggestedName = item.name
                provider.registerFileRepresentation(
                    forTypeIdentifier: "public.data",
                    fileOptions: [],
                    visibility: .all
                ) { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let parentDir = destURL.deletingLastPathComponent().path
                            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                            try ADBProvider.shared.pullFile(remotePath: item.path, localPath: destURL.path, deviceID: deviceID)
                            completion(destURL, false, nil)
                        } catch {
                            completion(nil, false, error)
                        }
                    }
                    return Progress(totalUnitCount: 1)
                }
            }
            return provider
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            if item.isDirectory {
                handleDropOnFolder(providers: providers, folderPath: item.path)
            } else {
                // Dropped on a file row → import into the current directory
                handleDropOnFolder(providers: providers, folderPath: store.currentPath)
            }
            return true
        }
        .help(item.isDirectory ? "Double-click to open folder" : "Double-click to download & open")
    }

    @ViewBuilder
    private var fileContextMenu: some View {
        Button {
            if item.isDirectory {
                store.navigate(to: item.path)
            } else {
                store.openItems(effectiveItems)
            }
        } label: {
            Label("Open", systemImage: "doc.text")
        }

        Divider()

        Button {
            store.quickLookItems(effectiveItems)
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        .disabled(effectiveItems.allSatisfy(\.isDirectory))

        Button {
            store.showInfo(for: item)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Divider()

        Button {
            store.copyItemsToClipboard(effectiveItems)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(effectiveItems.allSatisfy(\.isDirectory))

        Button {
            store.renamingItem = item
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            store.deleteItems(effectiveItems)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var effectiveItems: [ADBFileItem] {
        if store.selectedIDs.contains(item.id) && store.selectedIDs.count > 1 {
            return store.selectedItems
        }
        return [item]
    }

    private func handleDropOnFolder(providers: [NSItemProvider], folderPath: String) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    defer { group.leave() }
                    let resolved: URL? = {
                        if let url = item as? URL { return url }
                        if let nsURL = item as? NSURL { return nsURL as URL }
                        if let data = item as? Data {
                            if let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) { return url }
                            if let str = String(data: data, encoding: .utf8), let url = URL(string: str) { return url }
                        }
                        return nil
                    }()
                    if let url = resolved {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            store.importToFolder(urls: urls, folderPath: folderPath)
        }
    }
}

// MARK: - Path Bar

private struct FileExplorerPathBar: View {
    @ObservedObject var store: ADBFileExplorerStore
    @Environment(\.colorScheme) private var colorScheme

    private func chipFill(isCurrent: Bool) -> Color {
        guard isCurrent else { return Color.clear }
        return colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(store.pathComponents.enumerated()), id: \.offset) { index, component in
                    PathBarSegment(
                        index: index,
                        label: component.label,
                        isCurrent: component.path == store.currentPath,
                        chipFill: chipFill(isCurrent: component.path == store.currentPath)
                    ) {
                        store.navigate(to: component.path)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
    }
}

private struct PathBarSegment: View {
    let index: Int
    let label: String
    let isCurrent: Bool
    let chipFill: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if index > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 3)
            }

            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: index == 0 ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.50))

                    Text(label)
                        .font(.system(size: 11, weight: isCurrent ? .medium : .regular))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary.opacity(0.50))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(chipFill)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Get Info Sheet

private struct FileInfoSheet: View {
    let item: ADBFileItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: item.iconName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(item.isDirectory ? "Folder" : fileKind)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            infoRow("Path", item.path)
            infoRow("Size", item.formattedSize)
            infoRow("Permissions", item.permissions ?? "--")
            infoRow("Modified", item.modifiedDate ?? "--")

            if item.isSymlink {
                infoRow("Type", "Symbolic Link")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                            )
                    )
            }
        }
        .padding(20)
        .frame(width: 360, height: 340)
    }

    private var fileKind: String {
        let ext = (item.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) File"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)

            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Rename Sheet

private struct FileRenameSheet: View {
    let item: ADBFileItem
    let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var newName: String

    init(item: ADBFileItem, onRename: @escaping (String) -> Void) {
        self.item = item
        self.onRename = onRename
        _newName = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)

                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.black.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.08),
                                lineWidth: 0.5
                            )
                    )
                    .onSubmit { doRename() }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.06)
                                : Color.black.opacity(0.04))
                    )

                Button("Rename") { doRename() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                            )
                    )
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func doRename() {
        onRename(newName)
        dismiss()
    }
}

// MARK: - Empty / Error Views

private struct FileExplorerEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.quaternary)

            Text("Empty Folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)

            Text("Drag files here to upload them to the device")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ADBFileItem helpers

extension ADBFileItem {
    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic":
            return "photo.fill"
        case "mp4", "mkv", "avi", "mov", "webm", "3gp":
            return "video.fill"
        case "mp3", "ogg", "wav", "flac", "aac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "log", "md":
            return "doc.text.fill"
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return "archivebox.fill"
        case "apk":
            return "app.badge.fill"
        case "db", "sqlite":
            return "cylinder.fill"
        default:
            return "doc.fill"
        }
    }

    var formattedSize: String {
        guard let bytes = size, !isDirectory else { return "--" }
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", gb)
    }
}

// MARK: - Availability helpers

private extension View {
    @ViewBuilder
    func ifAvailable_onKeyPressHandlers(store: ADBFileExplorerStore) -> some View {
        if #available(macOS 14.0, *) {
            self
                // Space → Quick Look
                .onKeyPress(.space) {
                    let selected = store.selectedItems
                    guard !selected.isEmpty else { return .ignored }
                    store.quickLookItems(selected)
                    return .handled
                }
                // Delete / Backspace → Delete
                .onKeyPress(.delete) {
                    let selected = store.selectedItems
                    guard !selected.isEmpty else { return .ignored }
                    store.deleteItems(selected)
                    return .handled
                }
                // Enter → Rename (single selection)
                .onKeyPress(.return) {
                    let selected = store.selectedItems
                    guard selected.count == 1 else { return .ignored }
                    store.renamingItem = selected[0]
                    return .handled
                }
                // Cmd+C → Copy
                .onKeyPress(characters: CharacterSet(charactersIn: "c"), phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command) else { return .ignored }
                    let selected = store.selectedItems
                    guard !selected.isEmpty else { return .ignored }
                    store.copyItemsToClipboard(selected)
                    return .handled
                }
        } else {
            self
        }
    }
}
