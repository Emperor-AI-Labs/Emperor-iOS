import Foundation

/// Preparing a model-authored artifact for display.
enum ArtifactDocument {

    /// Wraps a drafted HTML fragment in a minimal page.
    ///
    /// Drafts arrive as inline-styled fragments — centred headings, underlined court names,
    /// bordered tables of contents — with no CSS classes and no document shell of their own,
    /// so the typography has to be supplied here.
    ///
    /// - Important: the fragment is model-authored and **never sanitised upstream** — the
    ///   platform's web renderer uses `rehype-raw` with no `rehype-sanitize`. The safety of
    ///   showing it rests entirely on the web view's configuration (JavaScript disabled, nil
    ///   base URL, navigation refused), not on anything done to the markup here.
    /// The size a fragment is set at when nothing scales it — what export uses.
    ///
    /// Export must not move with a reader's text-size setting. A filed PDF is a fixed artefact,
    /// and the registry's copy should not run to a different number of pages because of a
    /// preference on somebody's phone.
    static let basePointSize: Double = 17

    /// How wide the text column may get, in characters.
    ///
    /// A measure, not a width. Line length is what decides whether a long document can actually
    /// be read: past roughly ninety characters the eye starts losing its place on the way back
    /// to the left margin. So on a 13-inch iPad the column is capped and centred rather than run
    /// edge to edge. Because the cap is in `ch` it grows with the type, so scaling up genuinely
    /// enlarges the page instead of only reflowing it.
    private static let measureInCharacters = 84

    /// Wide enough that only a tablet reaches it. An A4 page is 595pt and never does, which is
    /// what keeps an exported PDF identical whatever this rule does on screen.
    private static let tabletBreakpointPx = 820

    static func html(wrapping fragment: String, pointSize: Double = basePointSize) -> String {
        // A floor rather than trust: this comes from a system metric, and type below about
        // eleven points is not a document anyone reads on a phone.
        let size = max(11, pointSize)
        // Larger type on a tablet, not merely a longer line — a 13-inch screen is held further
        // away than a phone.
        let wide = (size * 1.18 * 100).rounded() / 100
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, "Times New Roman", serif;
            font-size: \(size)px;
            line-height: 1.6;
            /* Centred, so the cap above reads as a page rather than as text held to one edge. */
            margin: 0 auto;
            /* Scales between a phone's gutter and a tablet's margin without a list of devices. */
            padding: clamp(16px, 4vw, 44px);
            max-width: \(measureInCharacters)ch;
            word-wrap: break-word;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.3; }
          /* One title over one document — where a court's own heading sits. */
          h1 { text-align: center; }
          table { width: 100%; border-collapse: collapse; margin: 1em 0; }
          th, td { border: 1px solid currentColor; padding: 0.5em; vertical-align: top; }
          /* A List of Dates: the platform asks the model for these two classes by name
             (listOfDates.js), and its own stylesheet is what gives them meaning. A date sits on
             the optical centre of the event it belongs to, and the notes under the table read
             as apparatus to it rather than as a second section of equal weight. */
          table.ex-loe { font-size: 0.85em; line-height: 1.4; }
          table.ex-loe th, table.ex-loe td { vertical-align: middle; padding: 0.35em 0.6em; }
          table.ex-loe th:first-child, table.ex-loe td:first-child {
            text-align: center; white-space: nowrap;
          }
          .ex-loe-notes {
            margin-top: 0.9em; padding-top: 0.5em;
            border-top: 0.5px solid currentColor;
            font-size: 0.68em; line-height: 1.35; opacity: 0.78;
          }
          .ex-loe-notes h2, .ex-loe-notes h3 {
            font-size: 1em; font-weight: 600; letter-spacing: 0.06em;
            text-transform: uppercase; margin: 0 0 0.35em;
          }
          .ex-loe-notes p { margin: 0 0 0.3em; text-align: left; }
          /* Wide tables of contents must scroll rather than force the page sideways. */
          .scroll { overflow-x: auto; }
          @media (min-width: \(tabletBreakpointPx)px) {
            body { font-size: \(wide)px; padding: 48px; }
          }
        </style>
        </head><body><div class="scroll">\(fragment)</div></body></html>
        """
    }
}
