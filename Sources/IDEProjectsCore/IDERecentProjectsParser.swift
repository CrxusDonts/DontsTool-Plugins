import Foundation

public enum IDERecentProjectsParser {
    public static let maximumDocumentSize = 4 * 1024 * 1024

    public static func parse(_ data: Data, homeDirectory: URL) throws -> [IDERecentProject] {
        guard data.count <= maximumDocumentSize else { throw ParseError.invalidDocument }
        // JetBrains history has no DTD. Refusing declarations also prevents internal entity expansion.
        guard let document = String(data: data, encoding: .utf8), !document.contains("\0") else {
            throw ParseError.invalidDocument
        }
        guard !document.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !document.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ParseError.invalidDocument
        }
        let delegate = RecentProjectsDelegate(homeDirectory: homeDirectory)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidDocument }
        return delegate.projects.values.sorted {
            if $0.lastOpenedTimestamp != $1.lastOpenedTimestamp {
                return $0.lastOpenedTimestamp > $1.lastOpenedTimestamp
            }
            return $0.url.path < $1.url.path
        }
    }

    public static func localURL(_ path: String, homeDirectory: URL) -> URL? {
        RecentProjectsDelegate.localURL(path, homeDirectory: homeDirectory)
    }

    public enum ParseError: Error, Equatable {
        case invalidDocument
    }
}

private final class RecentProjectsDelegate: NSObject, XMLParserDelegate {
    let homeDirectory: URL
    var projects: [String: IDERecentProject] = [:]
    private var stack: [String] = []
    private var componentDepth: Int?
    private var additionalInfoDepth: Int?
    private var entryDepth: Int?
    private var metadataDepth: Int?
    private var path: String?
    private var customName: String?
    private var timestamp: Int64 = 0
    private var hidden = false

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        stack.append(elementName)
        if elementName == "component", attributes["name"] == "RecentProjectsManager" {
            componentDepth = stack.count
        }
        if elementName == "option", attributes["name"] == "additionalInfo", componentDepth != nil, additionalInfoDepth == nil {
            additionalInfoDepth = stack.count
        }
        if elementName == "entry", additionalInfoDepth != nil, entryDepth == nil, stack.dropLast().last == "map" {
            entryDepth = stack.count
            path = attributes["key"]
            customName = nil
            timestamp = 0
            hidden = false
        }
        if elementName == "RecentProjectMetaInfo", entryDepth != nil {
            metadataDepth = stack.count
            hidden = attributes["hidden"] == "true"
        }
        if elementName == "option", metadataDepth != nil, let value = attributes["value"] {
            switch attributes["name"] {
            case "activationTimestamp", "projectOpenTimestamp":
                timestamp = max(timestamp, Int64(value) ?? 0)
            case "customProjectName":
                customName = value
            default:
                break
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if entryDepth == stack.count {
            if !hidden, let path, let url = Self.localURL(path, homeDirectory: homeDirectory) {
                let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let project = IDERecentProject(
                    url: url,
                    name: name?.isEmpty == false ? name! : url.lastPathComponent,
                    lastOpenedTimestamp: timestamp
                )
                if projects[url.path].map({ $0.lastOpenedTimestamp < timestamp }) ?? true {
                    projects[url.path] = project
                }
            }
            entryDepth = nil
            path = nil
        }
        if metadataDepth == stack.count { metadataDepth = nil }
        if additionalInfoDepth == stack.count { additionalInfoDepth = nil }
        if componentDepth == stack.count { componentDepth = nil }
        stack.removeLast()
    }

    static func localURL(_ path: String, homeDirectory: URL) -> URL? {
        let expanded: String
        if path == "$USER_HOME$" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("$USER_HOME$/") {
            expanded = homeDirectory.path + path.dropFirst("$USER_HOME$".count)
        } else if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.path + path.dropFirst()
        } else {
            expanded = path
        }
        guard expanded.hasPrefix("/"),
              !expanded.hasPrefix("//"),
              !expanded.contains("$"),
              !expanded.contains("\0") else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}
