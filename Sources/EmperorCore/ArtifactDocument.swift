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
    static func html(wrapping fragment: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 16px/1.55 -apple-system, "Times New Roman", serif;
            margin: 20px; word-wrap: break-word;
          }
          table { width: 100%; border-collapse: collapse; margin: 12px 0; }
          th, td { border: 1px solid currentColor; padding: 6px; }
          /* Wide tables of contents must scroll rather than force the page sideways. */
          .scroll { overflow-x: auto; }
        </style>
        </head><body><div class="scroll">\(fragment)</div></body></html>
        """
    }
}
