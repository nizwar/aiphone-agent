import Foundation

enum ADBAppCatalog {
    private static let fallbackMappings: [String: String] = [
        "Settings": "com.android.settings",
        "AndroidSystemSettings": "com.android.settings",
        "Chrome": "com.android.chrome",
        "Google Chrome": "com.android.chrome",
        "WeChat": "com.tencent.mm", 
        "QQ": "com.tencent.mobileqq", 
        "TikTok": "com.zhiliaoapp.musically",
        "Tiktok": "com.zhiliaoapp.musically",
        "Gmail": "com.google.android.gm",
        "Google Maps": "com.google.android.apps.maps",
        "PermataMobile X": "net.myinfosys.PermataMobileX",
        "Honor of Kings": "com.levelinfinite.sgameGlobal",
        "Tokopedia": "com.tokopedia.tkpd",
        "AdGuard": "com.adguard.android",
        "Royal Kingdom": "com.dreamgames.royalkingdom",
        "GetContact": "app.source.getcontact",
        "Google News": "com.google.android.apps.magazines",
        "GitHub": "com.github.android",
        "Livin' by Mandiri": "id.bmri.livin",
        "Suno AI": "com.suno.android",
        "Kredivo": "com.finaccel.android",
        "Washtby Merchant": "com.washtby.app.merchant",
        "Google TV": "com.google.android.videos",
        "Google Bard (Gemini)": "com.google.android.apps.bard",
        "ANetCapture (Mock Capture)": "com.anetcapture.mock",
        "Google Play Console": "com.google.android.apps.playconsole", 
        "Termux": "com.termux",
        "WhatsApp Business": "com.whatsapp.w4b",
        "Google Sheets": "com.google.android.apps.docs.editors.sheets",
        "Mobile Legends: Bang Bang": "com.mobile.legends",
        "SuruhKami Merchant": "id.suruhkami.app.merchant",
        "Steam": "com.valvesoftware.android.steam.community",
        "Yump": "com.alloapp.yump",
        "Grab": "com.grabtaxi.passenger",
        "MyRepublic": "id.net.myrepublic",
        "Netflix": "com.netflix.mediaclient",
        "iQIYI": "com.iqiyi.i18n",
        "Agoda": "com.agoda.mobile.consumer",
        "Pegadaian Digital": "com.pegadaiandigital",
        "Traveloka": "com.traveloka.android",
        "Gboard": "com.google.android.inputmethod.latin",
        "WhatsApp": "com.whatsapp",
        "Google Docs": "com.google.android.apps.docs",
        "Washtby Customer": "com.washtby.app.customer",
        "DANA": "id.dana",
        "MyTelkomsel": "com.telkomsel.telkomselcm",
        "WiZ Connected": "com.wizconnected.wiz2",
        "Firebase App Distribution": "dev.firebase.appdistribution",
        "Transsion HealthLife": "com.transsion.healthlife",
        "UC Browser": "com.UCMobile.intl",
        "Facebook": "com.facebook.katana",
        "Gojek": "com.gojek.app",
        "WebAPK (Chrome PWA)": "org.chromium.webapk.a14e4562579cd39ae_v2",
        "Cermati": "com.cermati.app",
        "MANGA Plus": "jp.co.shueisha.mangaplus",
        "Bank Jago": "com.jago.digitalBanking",
        "Cloudflare 1.1.1.1": "com.cloudflare.onedotonedotonedotone",
        "Unknown (Suspicious / Unverified)": "com.ygjszsea.google",
        "Google Authenticator": "com.google.android.apps.authenticator2",
        "WebAPK (Chrome PWA) Alt": "org.chromium.webapk.a8295264289c21105_v2",
        "Unknown (Unverified)": "com.gof.global",
        "Perplexity Comet": "ai.perplexity.comet",
        "WebAPK (Chrome PWA) Alt 2": "org.chromium.webapk.afd56b082147bae6c_v2",
        "OVO": "ovo.id",
        "FlutterShark": "com.fluttershark.fluttersharkapp",
        "McDonald's": "com.mcdonalds.mobileapp",
        "Instagram": "com.instagram.android"
    ]

    static let packageMappings: [String: String] = {
        var merged = fallbackMappings
        if let repoMappings = loadMappingsFromOpenAutoGLM() {
            merged.merge(repoMappings) { _, new in new }
        }
        return merged
    }()

    static func packageName(for appNameOrPackage: String) -> String? {
        if appNameOrPackage.contains(".") {
            return appNameOrPackage
        }
        return packageMappings[appNameOrPackage]
    }

    static func appName(for packageName: String) -> String? {
        packageMappings.first(where: { $0.value == packageName })?.key
    }

    static func supportedApps() -> [String] {
        Array(packageMappings.keys).sorted()
    }

    static func candidatePackages(for appNameOrPackage: String) -> [String] {
        let trimmed = appNameOrPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalizedQuery = normalizedLookupKey(trimmed)
        var candidates: [String] = []

        if trimmed.contains(".") {
            candidates.append(trimmed)
        }

        if let exact = packageMappings[trimmed] {
            candidates.append(exact)
        }

        if let caseInsensitive = packageMappings.first(where: { normalizedLookupKey($0.key) == normalizedQuery })?.value {
            candidates.append(caseInsensitive)
        }

        for (name, package) in packageMappings {
            let normalizedName = normalizedLookupKey(name)
            if normalizedName.contains(normalizedQuery) || normalizedQuery.contains(normalizedName) {
                candidates.append(package)
            }
        }

        var unique: [String] = []
        for package in candidates where !unique.contains(package) {
            unique.append(package)
        }
        return unique
    }

    static func installedAppHints(from installedPackages: [String], limit: Int = 30) -> [String] {
        let knownApps = installedPackages.compactMap { package -> String? in
            guard let appName = appName(for: package) else { return nil }
            return "\(appName) (\(package))"
        }

        if !knownApps.isEmpty {
            return Array(knownApps.sorted().prefix(limit))
        }

        return Array(installedPackages.sorted().prefix(limit))
    }

    private static func normalizedLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private static func loadMappingsFromOpenAutoGLM() -> [String: String]? {
        for url in candidateConfigURLs() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let parsed = parseMappings(from: source)
            if !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    private static func parseMappings(from source: String) -> [String: String] {
        let pattern = #"[\"']([^\"']+)[\"']\s*:\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var mappings: [String: String] = [:]
        for match in matches where match.numberOfRanges == 3 {
            let key = nsSource.substring(with: match.range(at: 1))
            let value = nsSource.substring(with: match.range(at: 2))
            mappings[key] = value
        }
        return mappings
    }

    private static func candidateConfigURLs() -> [URL] {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)

        let bases = [
            currentDirectory,
            currentDirectory.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ]

        let relatives = [
            "autoglm/phone_agent/config/apps.py",
            "../autoglm/phone_agent/config/apps.py",
            "../../autoglm/phone_agent/config/apps.py",
            "../../../autoglm/phone_agent/config/apps.py"
        ]

        return bases.flatMap { base in
            relatives.map { relative in
                base.appendingPathComponent(relative).standardizedFileURL
            }
        }
    }
}
