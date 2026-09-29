import Foundation

/// Adelaide Metro publishes alert bodies as raw HTML — nested `<div>`s, `<p>`, bullet lists, tables and
/// entities — which was being rendered literally in the Alerts tab.
///
/// Deliberately a plain-text flattener, not an HTML renderer: `NSAttributedString`'s HTML importer pulls in
/// WebKit, must run on the main actor, and takes milliseconds per string, which is untenable for a list that
/// re-renders on every realtime frame. Structure that survives is what a rider needs — line breaks and bullets.
enum HTMLText {
    private static let blockBreaks = ["</p>", "</div>", "</tr>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>"]
    private static let lineBreaks = ["<br>", "<br/>", "<br />"]

    private static let entities: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&#39;": "'", "&ndash;": "–", "&mdash;": "—",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&hellip;": "…", "&bull;": "•", "&middot;": "·", "&deg;": "°", "&trade;": "™",
        "&copy;": "©", "&reg;": "®", "&eacute;": "é",
    ]

    static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }

        var text = html
        for tag in lineBreaks { text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive) }
        for tag in blockBreaks { text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive) }
        // `<li>` opens the line; `</li>` must not also break, or every bullet gets a blank line after it.
        text = text.replacingOccurrences(of: "<li>", with: "\n• ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</li>", with: "", options: .caseInsensitive)
        // Table cells collapse onto one line per row — a real grid can't survive in plain text anyway.
        text = text.replacingOccurrences(of: "</td>", with: " — ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</th>", with: " — ", options: .caseInsensitive)

        text = text.replacing(/<[^>]+>/, with: "")
        text = decodeEntities(text)
        return tidy(text)
    }

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // `&amp;` last, and outside the dictionary: iteration order is random per launch, so "&amp;lt;"
        // (a literal "&lt;") decoded to "<" on some launches and not others.
        if text.contains("&#") {
            text = text.replacing(/&#(x?)([0-9A-Fa-f]+);/) { match in
            let digits = String(match.output.2)
            let radix = match.output.1.isEmpty ? 10 : 16
            guard let value = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(value) else {
                return String(match.output.0)
            }
            return String(Character(scalar))
            }
        }
        return text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    /// Nested block tags leave runs of blank lines behind; collapse them so alerts don't render as a ladder.
    private static func tidy(_ input: String) -> String {
        let lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                // The cell separator is emitted per `</td>`, including the row's last one — trim the dangler.
                line.replacing(/[ \t]+/, with: " ")
                    .trimmingCharacters(in: .whitespaces)
                    .replacing(/\s*—$/, with: "")
            }

        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue } // no leading or doubled blanks
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
