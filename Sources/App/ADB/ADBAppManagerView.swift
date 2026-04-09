import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Info Model

struct ADBAppInfo: Identifiable, Hashable, Sendable {
    let packageName: String
    let displayName: String
    var iconData: Data?

    var id: String { packageName }

    var icon: NSImage? {
        guard let iconData, !iconData.isEmpty else { return nil }
        return NSImage(data: iconData)
    }
}

// MARK: - Icon Cache

private enum AppIconCache {
    private static var cacheDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AIPhone/IconCache", isDirectory: true)
    }

    private static func cacheFile(deviceID: String, packageName: String) -> URL {
        let safeDevice = deviceID.replacingOccurrences(of: ":", with: "_")
        return cacheDir
            .appendingPathComponent(safeDevice, isDirectory: true)
            .appendingPathComponent(packageName + ".png")
    }

    static func read(deviceID: String, packageName: String) -> Data? {
        let url = cacheFile(deviceID: deviceID, packageName: packageName)
        return try? Data(contentsOf: url)
    }

    static func write(deviceID: String, packageName: String, data: Data) {
        let url = cacheFile(deviceID: deviceID, packageName: packageName)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func remove(deviceID: String, packageName: String) {
        let url = cacheFile(deviceID: deviceID, packageName: packageName)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - App Manager Store

@MainActor
final class ADBAppManagerStore: ObservableObject {
    @Published var apps: [ADBAppInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    @Published var isInstalling = false
    @Published var installMessage: String?

    private let provider: any ADBProviding = ADBProvider.shared

    func loadApps(deviceID: String) {
        isLoading = true
        errorMessage = nil
        statusMessage = "Loading packages…"

        Task.detached(priority: .userInitiated) { [provider] in
            let packages: [String]
            do {
                let output = try provider.shell("pm list packages -3", deviceID: deviceID)
                packages =
                    output
                    .components(separatedBy: "\n")
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "package:", with: "")
                        return trimmed.isEmpty ? nil : trimmed
                    }
            } catch {
                await MainActor.run {
                    self.apps = []
                    self.isLoading = false
                    self.errorMessage = "Failed to list packages: \(error.localizedDescription)"
                    self.statusMessage = nil
                }
                return
            }

            guard !packages.isEmpty else {
                await MainActor.run {
                    self.apps = []
                    self.isLoading = false
                    self.errorMessage = "No packages found on this device."
                    self.statusMessage = nil
                }
                return
            }

            var appInfos: [ADBAppInfo] = packages.map { pkg in
                let name = ADBAppCatalog.appName(for: pkg) ?? Self.readableAppName(from: pkg)
                let cached = AppIconCache.read(deviceID: deviceID, packageName: pkg)
                return ADBAppInfo(packageName: pkg, displayName: name, iconData: cached)
            }
            appInfos.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            let totalCount = appInfos.count

            await MainActor.run {
                self.apps = appInfos
                self.statusMessage = "\(totalCount) packages loaded. Fetching icons…"
            }

            // Fetch icons in batches
            let batchSize = 10
            for batchStart in stride(from: 0, to: appInfos.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, appInfos.count)
                let batch = Array(appInfos[batchStart..<batchEnd])

                var updates: [(String, Data)] = []
                for app in batch {
                    if let iconData = Self.fetchAppIcon(
                        packageName: app.packageName, deviceID: deviceID, provider: provider)
                    {
                        AppIconCache.write(deviceID: deviceID, packageName: app.packageName, data: iconData)
                        updates.append((app.packageName, iconData))
                    }
                }

                if !updates.isEmpty {
                    await MainActor.run {
                        for (pkg, data) in updates {
                            if let idx = self.apps.firstIndex(where: { $0.packageName == pkg }) {
                                self.apps[idx].iconData = data
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                self.isLoading = false
                self.statusMessage = "\(totalCount) apps"
            }
        }
    }

    func refreshAppDetails(packageName: String, deviceID: String) {
        statusMessage = "Refreshing \(packageName)…"
        Task.detached(priority: .userInitiated) { [provider] in
            if let iconData = Self.fetchAppIcon(
                packageName: packageName, deviceID: deviceID, provider: provider)
            {
                AppIconCache.write(deviceID: deviceID, packageName: packageName, data: iconData)
                await MainActor.run {
                    if let idx = self.apps.firstIndex(where: { $0.packageName == packageName }) {
                        self.apps[idx].iconData = iconData
                    }
                    self.statusMessage = "Refreshed \(packageName)"
                }
            } else {
                await MainActor.run {
                    self.statusMessage = "Refreshed \(packageName) (no icon)"
                }
            }
        }
    }

    func openApp(
        packageName: String, deviceInfo: ADBDeviceInfo, settings: AISettingsStore,
        profile: ADBDeviceProfile, scrcpyStore: ScrcpyLaunchStore
    ) {
        let executable = settings.scrcpyLaunchConfiguration(
            deviceID: deviceInfo.deviceID, profile: profile
        ).executable
        let args = ["--serial", deviceInfo.deviceID, "--start-app=\(packageName)"]
        statusMessage = "Opening \(packageName) via scrcpy…"

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            do {
                try process.run()
                await MainActor.run {
                    self.statusMessage = "Launched scrcpy for \(packageName)"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage =
                        "Failed to open \(packageName): \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteApp(packageName: String, deviceID: String) {
        statusMessage = "Uninstalling \(packageName)…"

        Task.detached(priority: .userInitiated) { [provider] in
            do {
                let result = try provider.shell("pm uninstall \(packageName)", deviceID: deviceID)
                let success = result.lowercased().contains("success")
                if success {
                    AppIconCache.remove(deviceID: deviceID, packageName: packageName)
                }
                await MainActor.run {
                    if success {
                        self.apps.removeAll { $0.packageName == packageName }
                        self.statusMessage = "Uninstalled \(packageName)"
                    } else {
                        self.statusMessage = "Uninstall result: \(result)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to uninstall: \(error.localizedDescription)"
                }
            }
        }
    }

    func pullApp(packageName: String, deviceID: String) {
        statusMessage = "Locating APK for \(packageName)…"

        Task.detached(priority: .userInitiated) { [provider] in
            do {
                let pathOutput = try provider.shell("pm path \(packageName)", deviceID: deviceID)
                let apkPaths =
                    pathOutput
                    .components(separatedBy: "\n")
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("package:") else { return nil }
                        return String(trimmed.dropFirst("package:".count))
                    }

                guard let primaryAPK = apkPaths.first else {
                    await MainActor.run {
                        self.statusMessage = "Could not find APK path for \(packageName)"
                    }
                    return
                }

                let suggestedName = "\(packageName).apk"

                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.title = "Save APK — \(packageName)"
                    panel.nameFieldStringValue = suggestedName
                    panel.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]
                    panel.canCreateDirectories = true

                    guard panel.runModal() == .OK, let saveURL = panel.url else {
                        self.statusMessage = "Pull cancelled."
                        return
                    }

                    self.statusMessage = "Pulling \(packageName)…"

                    Task.detached(priority: .userInitiated) {
                        do {
                            try provider.pullFile(
                                remotePath: primaryAPK, localPath: saveURL.path, deviceID: deviceID)

                            // If there are split APKs, pull them alongside
                            if apkPaths.count > 1 {
                                let parentDir = saveURL.deletingLastPathComponent()
                                for (index, splitPath) in apkPaths.dropFirst().enumerated() {
                                    let splitName = "\(packageName)_split\(index + 1).apk"
                                    let splitURL = parentDir.appendingPathComponent(splitName)
                                    try? provider.pullFile(
                                        remotePath: splitPath, localPath: splitURL.path,
                                        deviceID: deviceID)
                                }
                            }

                            await MainActor.run {
                                self.statusMessage = "Saved APK to \(saveURL.lastPathComponent)"
                                NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                            }
                        } catch {
                            await MainActor.run {
                                self.statusMessage =
                                    "Failed to pull APK: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to locate APK: \(error.localizedDescription)"
                }
            }
        }
    }

    func installAPK(localPath: String, deviceID: String) {
        isInstalling = true
        installMessage = "Installing \(URL(fileURLWithPath: localPath).lastPathComponent)…"

        Task.detached(priority: .userInitiated) { [provider] in
            do {
                let result = try provider.shell("pm install -r -t '\(localPath)'", deviceID: deviceID)
                // Fallback: use adb install directly if pm install didn't work
                let succeeded = result.lowercased().contains("success")
                await MainActor.run {
                    self.isInstalling = false
                    if succeeded {
                        self.installMessage = nil
                        self.statusMessage = "App installed successfully"
                        self.loadApps(deviceID: deviceID)
                    } else {
                        self.installMessage = nil
                        self.statusMessage = "Install result: \(result)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.installMessage = nil
                    self.statusMessage = "Install failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func installLocalAPK(url: URL, deviceID: String) {
        isInstalling = true
        installMessage = "Installing \(url.lastPathComponent)…"

        Task.detached(priority: .userInitiated) {
            let provider = ADBProvider.shared
            do {
                // Push APK to device then install
                let remotePath = "/data/local/tmp/\(url.lastPathComponent)"
                try provider.pushFile(localPath: url.path, remotePath: remotePath, deviceID: deviceID)
                let result = try provider.shell("pm install -r -t '\(remotePath)'", deviceID: deviceID)
                let _ = try? provider.shell("rm -f '\(remotePath)'", deviceID: deviceID)
                let succeeded = result.lowercased().contains("success")
                await MainActor.run {
                    self.isInstalling = false
                    self.installMessage = nil
                    if succeeded {
                        self.statusMessage = "App installed successfully"
                        self.loadApps(deviceID: deviceID)
                    } else {
                        self.statusMessage = "Install result: \(result)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.installMessage = nil
                    self.statusMessage = "Install failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func readableAppName(from packageName: String) -> String {
        let parts = packageName.components(separatedBy: ".")
        guard let last = parts.last, !last.isEmpty else { return packageName }
        // Capitalize the last component
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private nonisolated static func fetchAppIcon(
        packageName: String, deviceID: String, provider: any ADBProviding
    ) -> Data? {
        // 1. Get APK path
        guard let pathOutput = try? provider.shell("pm path \(packageName)", deviceID: deviceID)
        else { return nil }
        guard let apkPath = pathOutput
            .components(separatedBy: "\n")
            .compactMap({ line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("package:") else { return nil }
                return String(trimmed.dropFirst("package:".count))
            })
            .first, !apkPath.isEmpty
        else { return nil }

        // 2. List all potential icon entries inside the APK
        guard let listOutput = try? provider.shell(
            "unzip -l '\(apkPath)' 2>/dev/null",
            deviceID: deviceID),
            !listOutput.isEmpty
        else { return nil }

        // Parse all file entries from unzip output
        let allEntries = listOutput.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { return nil }
            return parts.last
        }

        // 3. Try multiple icon patterns in priority order
        let iconPatterns: [(String) -> Bool] = [
            // Prefer ic_launcher PNG (non-round, non-foreground/background)
            { $0.hasSuffix(".png") && $0.contains("ic_launcher") && !$0.contains("round") && !$0.contains("foreground") && !$0.contains("background") },
            // ic_launcher round PNG
            { $0.hasSuffix(".png") && $0.contains("ic_launcher") && !$0.contains("foreground") && !$0.contains("background") },
            // ic_launcher WEBP
            { $0.hasSuffix(".webp") && $0.contains("ic_launcher") && !$0.contains("foreground") && !$0.contains("background") },
            // Any launcher PNG
            { $0.hasSuffix(".png") && $0.contains("launcher") },
            // Any launcher WEBP
            { $0.hasSuffix(".webp") && $0.contains("launcher") },
            // Any icon PNG in mipmap or drawable
            { $0.hasSuffix(".png") && ($0.contains("mipmap") || $0.contains("drawable")) && $0.contains("icon") },
            // Foreground as last resort
            { ($0.hasSuffix(".png") || $0.hasSuffix(".webp")) && $0.contains("ic_launcher") && $0.contains("foreground") },
        ]

        let resolutionOrder = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"]

        var iconEntry: String?
        for pattern in iconPatterns {
            let candidates = allEntries.filter(pattern)
            guard !candidates.isEmpty else { continue }
            // Pick best resolution
            for res in resolutionOrder {
                if let entry = candidates.first(where: { $0.contains(res) }) {
                    iconEntry = entry
                    break
                }
            }
            if iconEntry == nil { iconEntry = candidates.first }
            break
        }

        guard let iconEntry else { return nil }

        // 4. Extract icon to a temp file on device and pull it
        let remoteTmp = "/data/local/tmp/.aiphone_icon_\(packageName).png"
        let _ = try? provider.shell(
            "unzip -p '\(apkPath)' '\(iconEntry)' > '\(remoteTmp)' 2>/dev/null",
            deviceID: deviceID)

        let localTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        defer {
            try? FileManager.default.removeItem(at: localTmp)
            let _ = try? provider.shell("rm -f '\(remoteTmp)'", deviceID: deviceID)
        }

        do {
            try provider.pullFile(
                remotePath: remoteTmp, localPath: localTmp.path, deviceID: deviceID)
            let data = try Data(contentsOf: localTmp)
            guard !data.isEmpty, NSImage(data: data) != nil else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

// MARK: - App Manager View

struct ADBAppManagerView: View {
    let deviceID: String
    let deviceInfo: ADBDeviceInfo

    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore
    @EnvironmentObject private var scrcpyLaunchStore: ScrcpyLaunchStore

    @StateObject private var store = ADBAppManagerStore()
    @State private var searchText = ""
    @State private var confirmDeletePackage: String?
    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    private var filteredApps: [ADBAppInfo] {
        guard !searchText.isEmpty else { return store.apps }
        let query = searchText.lowercased()
        return store.apps.filter {
            $0.displayName.lowercased().contains(query)
                || $0.packageName.lowercased().contains(query)
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    TextField("Search apps…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.06), lineWidth: 0.5)
                )

                Spacer()

                Button {
                    store.loadApps(deviceID: deviceID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.isLoading)
            }
            .padding(.bottom, 10)

            // Content
            if store.isLoading && store.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading installed apps…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.apps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "No apps found." : "No matches for \"\(searchText)\"")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredApps) { app in
                            AppGridTile(app: app)
                                .onTapGesture(count: 2) {
                                    store.openApp(
                                        packageName: app.packageName,
                                        deviceInfo: deviceInfo,
                                        settings: aiSettings,
                                        profile: profileStore.profile(for: deviceID),
                                        scrcpyStore: scrcpyLaunchStore
                                    )
                                }
                                .contextMenu {
                                    Button {
                                        store.openApp(
                                            packageName: app.packageName,
                                            deviceInfo: deviceInfo,
                                            settings: aiSettings,
                                            profile: profileStore.profile(for: deviceID),
                                            scrcpyStore: scrcpyLaunchStore
                                        )
                                    } label: {
                                        Label("Open", systemImage: "play.fill")
                                    }

                                    Button(role: .destructive) {
                                        confirmDeletePackage = app.packageName
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Divider()

                                    Button {
                                        store.refreshAppDetails(
                                            packageName: app.packageName, deviceID: deviceID)
                                    } label: {
                                        Label("Refresh Details", systemImage: "arrow.clockwise")
                                    }

                                    Button {
                                        store.pullApp(
                                            packageName: app.packageName, deviceID: deviceID)
                                    } label: {
                                        Label("Pull the APP", systemImage: "square.and.arrow.down")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onAppear {
            if store.apps.isEmpty {
                store.loadApps(deviceID: deviceID)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "apk" else { return }
                    DispatchQueue.main.async {
                        store.installLocalAPK(url: url, deviceID: deviceID)
                    }
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Drop APK to install")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if store.isInstalling {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(store.installMessage ?? "Installing…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .alert(
            "Uninstall App",
            isPresented: Binding(
                get: { confirmDeletePackage != nil },
                set: { if !$0 { confirmDeletePackage = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                confirmDeletePackage = nil
            }
            Button("Uninstall", role: .destructive) {
                if let pkg = confirmDeletePackage {
                    store.deleteApp(packageName: pkg, deviceID: deviceID)
                }
                confirmDeletePackage = nil
            }
        } message: {
            Text(
                "Are you sure you want to uninstall \(confirmDeletePackage ?? "this app")? This cannot be undone."
            )
        }
    }
}

// MARK: - App Grid Tile

private struct AppGridTile: View {
    let app: ADBAppInfo
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.03)
                    )
                    .frame(width: 52, height: 52)

                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            colorScheme == .dark
                                ? Color.white.opacity(0.15)
                                : Color.black.opacity(0.10))
                }
            }

            VStack(spacing: 1) {
                Text(app.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 26, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.03)
                        : Color.white.opacity(0.40))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04),
                    lineWidth: 0.5
                )
        )
        .help(app.packageName)
    }
}
