import Foundation

struct LyricWord: Hashable {
    let time: Double
    let text: String
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
    /// Populated only for "enhanced LRC" files that carry `<mm:ss.xx>` word tags.
    let words: [LyricWord]
    /// Start of the next line — used to pace the sweep on plain LRC.
    var end: Double

    var duration: Double { max(0.2, end - time) }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Which word is being sung at `position`, and how far through it we are.
    /// nil before the line starts, or when the line carries no word breakdown.
    func wordState(at position: Double) -> (index: Int, fraction: Double)? {
        guard !words.isEmpty, position >= time else { return nil }
        guard position < end else { return (words.count - 1, 1) }

        for index in words.indices.reversed() where position >= words[index].time {
            let wordEnd = index + 1 < words.count ? words[index + 1].time : end
            let fraction = (position - words[index].time) / max(0.05, wordEnd - words[index].time)
            return (index, min(1, max(0, fraction)))
        }
        return (0, 0)
    }

    /// 0...1 sweep across the line at the given playback position.
    func progress(at position: Double) -> Double {
        guard position > time else { return 0 }
        guard position < end else { return 1 }

        if words.count > 1 {
            // Word-timed: find the word we're inside and interpolate across it,
            // then convert to a fraction of the line's character count.
            let totalChars = max(1, words.reduce(0) { $0 + $1.text.count })
            var consumed = 0
            for (index, word) in words.enumerated() {
                let wordEnd = index + 1 < words.count ? words[index + 1].time : end
                if position < word.time { break }
                if position < wordEnd {
                    let within = (position - word.time) / max(0.05, wordEnd - word.time)
                    return Double(consumed) / Double(totalChars)
                        + within * Double(word.text.count) / Double(totalChars)
                }
                consumed += word.text.count
            }
            return Double(consumed) / Double(totalChars)
        }

        return (position - time) / duration
    }
}

enum LRCParser {

    private static let timeTag = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTag = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: [.caseInsensitive])

    static func parse(_ lrc: String) -> [LyricLine] {
        var offsetSeconds: Double = 0
        var collected: [(time: Double, text: String, words: [LyricWord])] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)

            // [offset:+250] shifts the whole file. Positive means "show lyrics earlier".
            if let match = offsetTag.firstMatch(in: line, range: whole),
               let ms = Double(ns.substring(with: match.range(at: 1))) {
                offsetSeconds = ms / 1000
                continue
            }

            // A line may carry several timestamps: [00:12.00][01:45.00] same words.
            // Only leading, back-to-back tags count as timestamps.
            var times: [Double] = []
            var cursor = 0
            for match in timeTag.matches(in: line, range: whole) {
                guard match.range.location == cursor else { break }
                cursor = match.range.location + match.range.length
                times.append(seconds(
                    minutes: ns.substring(with: match.range(at: 1)),
                    seconds: ns.substring(with: match.range(at: 2))))
            }
            guard !times.isEmpty else { continue }  // metadata tag like [ar:...]

            let body = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            let (text, words) = extractWords(from: body)
            for time in times {
                collected.append((time, text, words))
            }
        }

        collected.sort { $0.time < $1.time }

        var lines: [LyricLine] = []
        lines.reserveCapacity(collected.count)
        for (index, item) in collected.enumerated() {
            let start = max(0, item.time - offsetSeconds)
            let next = index + 1 < collected.count
                ? max(0, collected[index + 1].time - offsetSeconds)
                : start + 6
            let lineEnd = max(start + 0.2, next)
            let tagged = item.words.map {
                LyricWord(time: max(0, $0.time - offsetSeconds), text: $0.text)
            }
            lines.append(LyricLine(
                id: index,
                time: start,
                text: item.text,
                // Enhanced LRC gives us real word onsets. Everything else gets
                // estimated ones, so the highlight still advances word by word.
                words: tagged.isEmpty
                    ? estimateWords(text: item.text, from: start, to: lineEnd)
                    : tagged,
                end: lineEnd))
        }
        return lines
    }

    /// Splits `body` into plain text plus word timings, if the file uses `<mm:ss.xx>` tags.
    private static func extractWords(from body: String) -> (String, [LyricWord]) {
        let ns = body as NSString
        let matches = wordTag.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body, []) }

        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            let time = seconds(
                minutes: ns.substring(with: match.range(at: 1)),
                seconds: ns.substring(with: match.range(at: 2)))
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard textEnd > textStart else { continue }
            let chunk = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            words.append(LyricWord(time: time, text: chunk))
        }

        let plain = wordTag
            .stringByReplacingMatches(in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return (plain, words)
    }

    /// Spreads a line's duration across its words, weighted by syllable count.
    ///
    /// Line-timed LRC — which is most of LRCLIB — only says when a line starts.
    /// Sweeping it at a constant rate puts the highlight mid-line exactly halfway
    /// through, which is almost never where the singer is. Weighting by syllables
    /// makes the highlight linger on "shine" and skip through "in the", which is
    /// much closer to how the line is actually sung.
    ///
    /// It is an estimate. Held notes and rests still drift, and the sync trim
    /// remains the fix for a line that runs consistently early or late.
    static func estimateWords(text: String, from start: Double, to end: Double) -> [LyricWord] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count > 1 else {
            return tokens.isEmpty ? [] : [LyricWord(time: start, text: tokens[0])]
        }

        let weights = tokens.map { Double(syllables(in: $0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        let span = max(0.2, end - start)
        var words: [LyricWord] = []
        words.reserveCapacity(tokens.count)
        var consumed = 0.0
        for (index, token) in tokens.enumerated() {
            words.append(LyricWord(time: start + span * (consumed / total), text: token))
            consumed += weights[index]
        }
        return words
    }

    /// Vowel-group count, which is a decent proxy for how long a word is held.
    private static func syllables(in word: String) -> Int {
        let vowels = Set("aeiouyAEIOUY")
        var count = 0
        var previousWasVowel = false
        for character in word {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        // Trailing silent "e": "shine" is one beat, not two.
        if count > 1, word.count > 2, word.lowercased().hasSuffix("e") { count -= 1 }
        return max(1, count)
    }

    private static func seconds(minutes: String, seconds secondsField: String) -> Double {
        // Some files use [01:23:45] with a colon before the fraction.
        let normalized = secondsField.replacingOccurrences(of: ":", with: ".")
        return (Double(minutes) ?? 0) * 60 + (Double(normalized) ?? 0)
    }
}
