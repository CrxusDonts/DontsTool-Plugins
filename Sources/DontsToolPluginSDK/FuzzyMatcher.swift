import Foundation

public enum FuzzyMatcher {
    public struct PreparedCandidate: Sendable {
        public let normalized: String
        public let words: [String]

        public init(_ value: String) {
            normalized = FuzzyMatcher.normalize(value)
            words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
    }

    public static func score(query: String, candidate: String) -> Double? {
        let q = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return score(normalizedQuery: q, candidate: PreparedCandidate(candidate))
    }

    public static func score(normalizedQuery q: String, candidate: PreparedCandidate) -> Double? {
        let c = candidate.normalized
        guard !q.isEmpty, !c.isEmpty else { return nil }

        if q == c { return 1000 }
        if c.hasPrefix(q) { return 900 }
        if candidate.words.contains(where: { $0.hasPrefix(q) }) { return 800 }
        if let range = c.range(of: q) {
            let position = c.distance(from: c.startIndex, to: range.lowerBound)
            return max(700 - Double(position), 650)
        }
        if let density = subsequenceDensity(q, in: c) {
            return 300 + 300 * density
        }
        return nil
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func subsequenceDensity(_ query: String, in candidate: String) -> Double? {
        var queryIndex = query.startIndex
        var firstMatch: Int?
        var lastMatch = 0
        var candidateIndex = 0

        for character in candidate {
            if queryIndex < query.endIndex, character == query[queryIndex] {
                if firstMatch == nil { firstMatch = candidateIndex }
                lastMatch = candidateIndex
                queryIndex = query.index(after: queryIndex)
            }
            candidateIndex += 1
        }

        guard queryIndex == query.endIndex, let firstMatch else { return nil }
        let span = max(1, lastMatch - firstMatch + 1)
        return Double(query.count) / Double(span)
    }
}
