import Foundation

/// The newest release an update feed (a Sparkle appcast) offers, read just far enough to know
/// whether it's newer than what's installed. Sparkle checks everything else, signatures included,
/// once the app takes over.
public struct UpdateFeedItem: Equatable, Sendable {
    /// The build number, as in `CFBundleVersion`.
    public var version: String
    /// The version people see, as in `CFBundleShortVersionString`.
    public var displayVersion: String?
    public var minimumSystemVersion: String?

    public init(version: String, displayVersion: String? = nil, minimumSystemVersion: String? = nil) {
        self.version = version
        self.displayVersion = displayVersion
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// Whether this item is newer than a build number, comparing number by number.
    public func isNewer(than installedVersion: String) -> Bool {
        installedVersion.compare(version, options: .numeric) == .orderedAscending
    }

    /// Whether this Mac's system is recent enough for the item.
    public func runs(on system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard let minimumSystemVersion else { return true }
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return minimumSystemVersion.compare(current, options: .numeric) != .orderedDescending
    }
}

public enum UpdateFeed {
    /// The newest item in an appcast, or `nil` when it has none.
    public static func newestItem(in data: Data) -> UpdateFeedItem? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.items.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [UpdateFeedItem] = []
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { current = [:] }
            // Older appcasts put the version on the enclosure.
            if name == "enclosure", var item = current, item["sparkle:version"] == nil, let version = attributes["sparkle:version"] {
                item["sparkle:version"] = version
                if item["sparkle:shortVersionString"] == nil {
                    item["sparkle:shortVersionString"] = attributes["sparkle:shortVersionString"]
                }
                current = item
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion"].contains(name), !value.isEmpty {
                current?[name] = value
            }
            if name == "item", let item = current {
                if let version = item["sparkle:version"] {
                    items.append(UpdateFeedItem(
                        version: version,
                        displayVersion: item["sparkle:shortVersionString"],
                        minimumSystemVersion: item["sparkle:minimumSystemVersion"]))
                }
                current = nil
            }
            text = ""
        }
    }
}

/// When the helper last looked for an update, and which one it last brought to the user's attention.
public struct UpdateCheckState: Codable, Equatable, Sendable {
    public var lastCheck: Date?
    public var announcedVersion: String?
    public var announcedAt: Date?

    public init(lastCheck: Date? = nil, announcedVersion: String? = nil, announcedAt: Date? = nil) {
        self.lastCheck = lastCheck
        self.announcedVersion = announcedVersion
        self.announcedAt = announcedAt
    }
}
