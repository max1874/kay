import Foundation

/// Words the speech service should lean towards: names it would otherwise mishear (Raycast as "Request",
/// Cursor as "咳嗽", 2026-10-11). One term per line in `vocabulary.txt`, `#` starts a comment, and a leading
/// `!` marks a term to pull hard. On Max's Mac the file is a symlink into the asr-lexicon repository
/// (hotwords.d/kay.txt), so the list is kept in Git; writes go to the file the link points at.
///
/// Qwen takes weighted hot words: the first 50 `!` terms get its "super" weight 50, everything else 5, at
/// most 2000 in all (its documented limits). Doubao takes the whole list as context hot words, unweighted.
/// tools/eval.py reads the same format with the same rules.
struct Vocabulary: Equatable {
    struct Term: Equatable {
        let text: String
        let strong: Bool
    }

    var terms: [Term] = []

    static let qwenMaxTerms = 2000
    static let qwenMaxStrong = 50
    static let qwenStrongWeight = 50
    static let qwenWeight = 5

    static var url: URL { AppFiles.directory.appendingPathComponent("vocabulary.txt") }

    init(terms: [Term] = []) { self.terms = terms }

    init(parsing text: String) {
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            line = line.trimmingCharacters(in: .whitespaces)
            let strong = line.hasPrefix("!")
            let term = line.drop { $0 == "!" }.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(Term(text: term, strong: strong))
        }
    }

    var strongCount: Int { terms.filter(\.strong).count }

    /// Qwen's `vocabulary` parameter: term → weight.
    var qwen: [String: Int] {
        let strong = terms.filter(\.strong).prefix(Self.qwenMaxStrong).map(\.text)
        var weights: [String: Int] = [:]
        var order: [String] = []
        for term in strong { weights[term] = Self.qwenStrongWeight; order.append(term) }
        for term in terms where weights[term.text] == nil {
            weights[term.text] = Self.qwenWeight
            order.append(term.text)
        }
        let kept = Set(order.prefix(Self.qwenMaxTerms))
        return weights.filter { kept.contains($0.key) }
    }

    /// Doubao's context hot words.
    var doubao: [String] { terms.map(\.text) }

    // MARK: - The file

    /// Main thread only, like every caller (key presses, Settings, the key test).
    private static var cached: (date: Date?, vocabulary: Vocabulary)?

    /// The list as the file has it now. Read again only when the file changed, so a key press costs a stat.
    static func current() -> Vocabulary {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        if let cached, cached.date == date { return cached.vocabulary }
        let vocabulary = (try? String(contentsOf: url, encoding: .utf8)).map(Vocabulary.init(parsing:)) ?? Vocabulary()
        cached = (date, vocabulary)
        return vocabulary
    }

    static func text() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Writes through a symlink rather than replacing it.
    @discardableResult
    static func save(_ text: String) -> Bool {
        let target = url.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
