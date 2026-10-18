import Foundation

/// Your own spellings, put in place after recognition with no model involved. One term per line in
/// `vocabulary.txt`, `#` starts a comment, and how it gets misheard may follow after `|`: `Cursor | 咳嗽`.
///
/// Only spans that are certainly the term are replaced:
/// - the term spelled out letter by letter or split into words ("c f" → CF, "k a y" → Kay, "open AI" → OpenAI);
/// - the term with its digits read out, when at least two of its letters stand alone ("e to b" → E2B; in English
///   "m to" is usually just "m to");
/// - an alias, written exactly as you wrote it.
/// A change of case alone ("cursor") is not one: DeepSeek sees whether it is the name.
///
/// Nothing here reaches the speech service or DeepSeek. Hot words pulled unrelated speech towards the list
/// (记录同步，yeah became Claude Code, 1.7.1), and so did terms shown to DeepSeek as candidates for what sounded
/// close, measured 2026-10-18 on 55 of Max's dictations: 同意 and 统一 became 通义 eight times and Mac mini became
/// Gemini, against four names it got right (asr-lexicon eval/kay/VOCABULARY.md).
///
/// Main thread only, like the dictation path and Settings.
struct Vocabulary: Equatable {
    struct Term: Equatable {
        let text: String
        let aliases: [String]
    }

    /// A place in a dictation that is one of the terms.
    struct Match: Equatable {
        let range: Range<String.Index>
        let heard: String
        let term: String
    }

    private(set) var terms: [Term] = []
    private var forms: [Form] = []

    static var url: URL { AppFiles.directory.appendingPathComponent("vocabulary.txt") }

    init(terms: [Term] = []) {
        self.terms = terms
        forms = Self.forms(of: terms)
    }

    init(parsing text: String) {
        var terms: [Term] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let term = fields.first else { continue }
            // A term on two lines keeps the aliases of both.
            if let index = terms.firstIndex(where: { $0.text == term }) {
                terms[index] = Term(text: term, aliases: terms[index].aliases + fields.dropFirst())
            } else {
                terms.append(Term(text: term, aliases: Array(fields.dropFirst())))
            }
        }
        self.init(terms: terms)
    }

    static func == (a: Vocabulary, b: Vocabulary) -> Bool { a.terms == b.terms }

    // MARK: - Matching

    /// The spans to replace, left to right, none overlapping; the longer span wins where two would.
    func replacements(in text: String) -> [Match] {
        guard !forms.isEmpty else { return [] }
        var found: [Match] = []
        for segment in Self.segments(text) {
            for form in forms {
                found += Self.find(form, in: segment, of: text)
            }
        }
        found.sort { text.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
            > text.distance(from: $1.range.lowerBound, to: $1.range.upperBound) }
        var kept: [Match] = []
        for match in found where !kept.contains(where: { $0.range.overlaps(match.range) }) {
            kept.append(match)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func apply(to text: String) -> String {
        var result = text
        for match in replacements(in: text).reversed() {
            result.replaceSubrange(match.range, with: match.term)
        }
        return result
    }

    // MARK: - Forms

    /// One way a term can be heard.
    private struct Form {
        enum Kind { case term, reading, alias }
        let term: String
        let units: [Unit]
        let kind: Kind
    }

    private static let digitWords: [[Character: String]] = [
        ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
         "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine"],
        // How a recognizer writes a digit it heard as a word.
        ["2": "to", "4": "for"],
        ["0": "零", "1": "一", "2": "二", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"],
    ]

    private static func forms(of terms: [Term]) -> [Form] {
        var forms: [Form] = []
        for term in terms {
            var heard: [(String, Form.Kind)] = [(term.text, .term)]
            for words in digitWords where term.text.contains(where: { words[$0] != nil }) {
                heard.append((term.text.map { c in words[c].map { " \($0) " } ?? String(c) }.joined(), .reading))
            }
            heard += term.aliases.map { ($0, .alias) }
            for (text, kind) in heard {
                let units = segments(text).flatMap(\.self)
                if !units.isEmpty { forms.append(Form(term: term.text, units: units, kind: kind)) }
            }
        }
        return forms
    }

    // MARK: - Units

    /// What is compared: a Latin letter or digit, lower-cased, or any other character as it is.
    private struct Unit {
        let value: Character
        let isLatin: Bool
        /// A match starts at a word's first unit and ends at a word's last: inside "pcfx" there is no CF. Every
        /// Chinese character is a word of its own.
        var starts = false
        var ends = false
        let range: Range<String.Index>
    }

    /// The units of each run of text between punctuation: a match never crosses a comma.
    private static func segments(_ text: String) -> [[Unit]] {
        var segments: [[Unit]] = []
        var current: [Unit] = []
        var latin: [(Character, Range<String.Index>)] = []

        func flushLatin() {
            // A word also splits where letters meet digits and where lower case meets upper (OpenAI → Open AI),
            // so E2B is three words and lines up with "e to b".
            var word: [Unit] = []
            func flushWord() {
                guard !word.isEmpty else { return }
                word[0].starts = true
                word[word.count - 1].ends = true
                current += word
                word = []
            }
            var previous: Character?
            for (c, range) in latin {
                if let p = previous, p.isNumber != c.isNumber || (p.isLowercase && c.isUppercase) { flushWord() }
                word.append(Unit(value: Character(c.lowercased()), isLatin: true, range: range))
                previous = c
            }
            flushWord()
            latin = []
        }
        func flushSegment() {
            flushLatin()
            if !current.isEmpty { segments.append(current) }
            current = []
        }

        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let c = text[index]
            if c.isASCII && (c.isLetter || c.isNumber) {
                latin.append((c, index..<next))
            } else if c == "'" || c == "’", !latin.isEmpty, next < text.endIndex, text[next].isASCII, text[next].isLetter {
                // Inside a word ("I'm"): neither a unit nor a break.
            } else if c.isWhitespace {
                flushLatin()
            } else if c.isLetter {
                flushLatin()
                current.append(Unit(value: c, isLatin: false, starts: true, ends: true, range: index..<next))
            } else {
                flushSegment()
            }
            index = next
        }
        flushSegment()
        return segments
    }

    /// Every place `form` occurs in `segment` unit for unit, starting and ending on word boundaries.
    private static func find(_ form: Form, in segment: [Unit], of text: String) -> [Match] {
        let p = form.units
        guard p.count <= segment.count else { return [] }
        var found: [Match] = []
        for start in 0...(segment.count - p.count) where segment[start].starts {
            let end = start + p.count
            guard segment[end - 1].ends,
                  zip(p, segment[start..<end]).allSatisfy({ $0.value == $1.value }) else { continue }
            let span = segment[start..<end]
            let range = span.first!.range.lowerBound..<span.last!.range.upperBound
            let heard = String(text[range])
            let replaces: Bool
            switch form.kind {
            case .term:
                replaces = span.allSatisfy(\.isLatin) && heard.lowercased() != form.term.lowercased()
            case .reading:
                replaces = span.filter { $0.isLatin && $0.starts && $0.ends && $0.value.isLetter }.count >= 2
            case .alias:
                replaces = heard != form.term
            }
            if replaces { found.append(Match(range: range, heard: heard, term: form.term)) }
        }
        return found
    }

    // MARK: - The file

    private static var cached: (date: Date?, vocabulary: Vocabulary)?

    /// The list as the file has it now. Read again only when the file changed, so a dictation costs a stat.
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
            cached = nil
            return true
        } catch {
            return false
        }
    }
}
