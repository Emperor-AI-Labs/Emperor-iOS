import Foundation

/// One piece of an enhanced prompt: either fixed prose or a blank the user fills in.
enum PromptSegment: Equatable, Sendable {
    case text(String)
    /// A `{{...}}` token. `label` is what the model said is missing, already trimmed.
    case placeholder(label: String)
}

/// An enhanced prompt, split at its `{{PLACEHOLDER}}` tokens.
///
/// The enhancer is told to insert `{{WHICH MATTER OR CASE NUMBER}}` rather than invent a
/// plausible value — a guardrail added after a model turned a document's own draft date into
/// a filing deadline and stated it as fact. That only pays off if the client actually offers
/// the blanks to be filled; pasting the raw text into the composer sends the braces to the
/// model verbatim.
///
/// `{{ }}` was chosen over `[ ]` because square brackets appear in real legal text — exhibit
/// numbers, `[Section 138]` — and would produce false positives.
struct PromptTemplate: Equatable, Sendable {
    var segments: [PromptSegment]

    /// The labels needing input, in the order they appear, without duplicates.
    ///
    /// A model that needs the same fact twice writes the same label twice, and asking for it
    /// twice would be absurd — so one field drives every occurrence.
    var labels: [String] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard case .placeholder(let label) = segment, seen.insert(label).inserted else {
                return nil
            }
            return label
        }
    }

    var hasPlaceholders: Bool { !labels.isEmpty }

    /// Splits `text` into alternating prose and placeholders.
    ///
    /// Hand-scanned rather than regex-matched so the rules are visible: a token is
    /// `{{`, at least one non-`}` character, `}}`. Anything else — an unclosed `{{`, a bare
    /// `{`, a `{{}}` — stays prose, because prompts about JSON or curly-brace templates are
    /// entirely plausible from this audience and mangling them would be worse than missing a
    /// blank.
    ///
    /// - Note: the **server never parses these**. It only instructs the model to emit them
    ///   (`ENHANCER_SYSTEM_PROMPT`, `sync-server.js:4573`) and streams the result through
    ///   untouched. The only parser is the web client's
    ///   `PLACEHOLDER_RE = /\{\{([^}]+)\}\}/g` (`src/lib/parseEnhancedTemplate.js:10`), which
    ///   is what this mirrors — so the contract lives in a peer client, not in the backend, and
    ///   nothing on the server will tell us if it changes.
    static func parse(_ text: String) -> PromptTemplate {
        var segments: [PromptSegment] = []
        var prose = ""
        var index = text.startIndex

        func flushProse() {
            if !prose.isEmpty {
                segments.append(.text(prose))
                prose = ""
            }
        }

        while index < text.endIndex {
            guard text[index] == "{",
                  let afterOpen = openerEnd(in: text, at: index),
                  let closeStart = text.range(of: "}}", range: afterOpen..<text.endIndex)?.lowerBound
            else {
                prose.append(text[index])
                index = text.index(after: index)
                continue
            }

            let body = text[afterOpen..<closeStart]
            // `[^}]+` in the web client's regex: a lone `}` inside means this is not a token.
            // The trimmed-empty case is ours — a blank with no label is unfillable on a phone,
            // since there is nothing to tell the user what to type.
            let label = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !body.contains("}"), !label.isEmpty else {
                prose.append(text[index])
                index = text.index(after: index)
                continue
            }

            flushProse()
            segments.append(.placeholder(label: label))
            index = text.index(closeStart, offsetBy: 2)
        }

        flushProse()
        return PromptTemplate(segments: segments)
    }

    /// The index just past a `{{`, or nil if this is not one.
    private static func openerEnd(in text: String, at index: String.Index) -> String.Index? {
        let second = text.index(after: index)
        guard second < text.endIndex, text[second] == "{" else { return nil }
        return text.index(after: second)
    }

    /// The prompt as it would be sent, given what the user has filled in.
    ///
    /// - Important: an unfilled blank goes back as `{{LABEL}}` rather than vanishing. The
    ///   assistant is then explicitly told what was left unspecified and can ask, which is
    ///   the whole point of the placeholder. Dropping it instead produces a fluent sentence
    ///   with a hole in the middle of it — exactly the fabrication risk the guardrail exists
    ///   to remove.
    func filled(with values: [String: String]) -> String {
        segments.reduce(into: "") { result, segment in
            switch segment {
            case .text(let value):
                result += value
            case .placeholder(let label):
                let entered = values[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
                result += (entered?.isEmpty ?? true) ? "{{\(label)}}" : entered!
            }
        }
    }

    /// The text as it stands with nothing filled in.
    ///
    /// `parse` then `raw` round-trips exactly, with one deliberate exception: a padded label
    /// loses its padding, because the label is trimmed on the way in and re-emitted trimmed.
    /// `{{ CASE NUMBER }}` comes back as `{{CASE NUMBER}}`. That matches the web client, whose
    /// serialiser also re-emits the trimmed label (`EnhancedPromptFields.jsx:37`), so both
    /// clients send the assistant the same token for the same blank.
    var raw: String { filled(with: [:]) }
}
