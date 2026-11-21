import Foundation

public enum PathDisplay {
    public static func abbreviated(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    public static func parentDirectory(of url: URL) -> String {
        abbreviated(url.deletingLastPathComponent().path)
    }
}
