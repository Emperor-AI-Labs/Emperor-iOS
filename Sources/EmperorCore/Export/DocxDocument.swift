import Foundation

/// A drafted document as a real Word file.
///
/// **Not HTML with a `.docx` on the end.** The platform tried that and abandoned it — its own
/// note records that "several Office builds opened read-only or refused as corrupt" — so this
/// writes genuine OOXML into a ZIP, which is what a `.docx` is.
///
/// The typography mirrors `htmlToDocx.js` so a document exported from the phone and the same
/// document exported from the web are the same artefact: Bookman Old Style throughout, headings
/// at 16/14/13pt against a 13pt body, H1 centred.
///
/// Pagination is left to Word, set up the way the platform sets it up:
/// - headings carry `keepNext` and `keepLines`, so a heading never sits alone at the foot of a
///   page, orphaned from the text it introduces;
/// - a table's header row is marked `tblHeader`, so it repeats at the top of every page a long
///   table spills onto;
/// - every row is `cantSplit`, so a row is never sliced across a page break — which is what once
///   cut a date in half.
enum DocxDocument {

    /// Half-points, as OOXML counts type. 26 is the 13pt body the platform sets.
    private enum Size {
        static let body = 26
        static let heading1 = 32
        static let heading2 = 28
        static let heading3 = 26
    }

    private static let font = "Bookman Old Style"

    /// The finished `.docx` for a drafted HTML fragment.
    static func make(fromHTML fragment: String) -> Data {
        var pictures: [Picture] = []
        let body = paragraphs(from: HTMLFragment.parse(fragment), pictures: &pictures)
        return archive(documentBody: body.isEmpty ? emptyParagraph : body, pictures: pictures)
    }

    /// A picture on its way into the package: its bytes, and the relationship the document
    /// refers to it by.
    struct Picture {
        let image: EmbeddedImage
        let index: Int

        /// Images start after the two fixed parts, which hold `rId1` and `rId2`.
        var relationshipID: String { "rId\(index + 2)" }
        var path: String { "media/image\(index).\(image.format.fileExtension)" }
    }

    // MARK: - Assembling the package

    private static func archive(documentBody: String, pictures: [Picture]) -> Data {
        var zip = ZipArchive()
        // `[Content_Types].xml` must be the first entry. Word will not open a package whose
        // content types it cannot find before the parts they describe.
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", packageRelationships)
        zip.add("word/_rels/document.xml.rels", documentRelationships(pictures))
        zip.add("word/styles.xml", styles)
        zip.add("word/numbering.xml", numbering)
        for picture in pictures {
            zip.add("word/\(picture.path)", picture.image.data)
        }
        zip.add("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipNamespace)"><w:body>\(documentBody)\(sectionProperties)\
            </w:body></w:document>
            """)
        return zip.data()
    }

    private static let wordNamespace =
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipNamespace =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="gif" ContentType="image/gif"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        </Types>
        """

    private static let packageRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """

    private static func documentRelationships(_ pictures: [Picture]) -> String {
        var out = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationshipNamespace)/styles" Target="styles.xml"/>\
            <Relationship Id="rId2" Type="\(relationshipNamespace)/numbering" Target="numbering.xml"/>
            """
        for picture in pictures {
            out += """
                <Relationship Id="\(picture.relationshipID)" \
                Type="\(relationshipNamespace)/image" Target="\(picture.path)"/>
                """
        }
        return out + "</Relationships>"
    }

    /// A4 with the margins a registry expects, in twentieths of a point.
    private static let sectionProperties = """
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1418" w:gutter="0"/></w:sectPr>
        """

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(wordNamespace)">\
        <w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="\(font)" w:hAnsi="\(font)"/><w:sz w:val="\(Size.body)"/>\
        </w:rPr></w:rPrDefault></w:docDefaults>\
        </w:styles>
        """

    /// Bullets and numbers as Word understands them.
    ///
    /// Typed-in markers print, but Word will not renumber them: insert an item at the top of a
    /// list of twenty and every number below it is wrong, with nothing to say so. A numbering
    /// part costs one more relationship and makes the list an actual list.
    ///
    /// Nine levels each, because that is what Word expects to find and a missing level leaves a
    /// nested item unformatted.
    private static let numbering: String = {
        func levels(format: String, text: (Int) -> String) -> String {
            (0..<9).map { level in
                """
                <w:lvl w:ilvl="\(level)"><w:start w:val="1"/>\
                <w:numFmt w:val="\(format)"/><w:lvlText w:val="\(text(level))"/>\
                <w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\(720 * (level + 1))" \
                w:hanging="360"/></w:pPr></w:lvl>
                """
            }.joined()
        }
        // Disc, circle, square repeating — the convention a word processor uses by depth.
        let bullets = ["•", "◦", "▪"]
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="\(wordNamespace)">\
            <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\
            \(levels(format: "bullet", text: { bullets[$0 % bullets.count] }))</w:abstractNum>\
            <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\
            \(levels(format: "decimal", text: { "%\($0 + 1)." }))</w:abstractNum>\
            <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
            <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>\
            </w:numbering>
            """
    }()

    /// The `w:numId` each kind of list refers to, as declared above.
    private enum NumberingID {
        static let bullet = 1
        static let ordered = 2
    }

    private static let emptyParagraph = "<w:p/>"

    /// A4 less the margins declared in `sectionProperties`, in twips — what a table has to fit.
    private static let usableWidthTwips = 11906 - 1418 - 1134

    // MARK: - Blocks

    private static func paragraphs(
        from nodes: [HTMLNode], depth: Int = 0, pictures: inout [Picture]
    ) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let value):
                // Loose text between blocks is still content — a fragment often opens with it.
                if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += paragraph(runs: [Run(text: value)], style: nil, alignment: nil)
                }
            case .element(let tag, let attributes, let children):
                out += block(
                    tag: tag, attributes: attributes, children: children, depth: depth,
                    pictures: &pictures)
            }
        }
        return out
    }

    private static func block(
        tag: String, attributes: [String: String], children: [HTMLNode], depth: Int,
        pictures: inout [Picture]
    ) -> String {
        let align = alignment(attributes)
        switch tag {
        case "p":
            return paragraph(runs: runs(children, Format(), pictures: &pictures), style: nil, alignment: align)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = min(3, Int(String(tag.dropFirst())) ?? 1)
            // H1 is centred unless the markup says otherwise — a cause title, in practice.
            return paragraph(
                runs: runs(children, Format(), pictures: &pictures), style: "Heading\(level)",
                alignment: align ?? (level == 1 ? "center" : nil), keepWithNext: true)
        case "br":
            return paragraph(runs: [], style: nil, alignment: nil)
        case "hr":
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"auto\"/></w:pBdr></w:pPr></w:p>"
        case "ul", "ol":
            return list(children, ordered: tag == "ol", depth: depth, pictures: &pictures)
        case "li":
            // A stray `li` outside a list still has to print.
            return paragraph(runs: runs(children, Format(), pictures: &pictures), style: nil, alignment: align)
        case "blockquote":
            return paragraph(
                runs: runs(children, Format(), pictures: &pictures), style: nil, alignment: align, indent: 720)
        case "table":
            return table(children, pictures: &pictures)
        case "img":
            let picture = runs([.element(tag: "img", attributes: attributes, children: [])],
                               Format(), pictures: &pictures)
            return picture.isEmpty ? "" : paragraph(
                runs: picture, style: nil, alignment: align ?? "center")
        case "figure", "script", "style":
            return ""
        default:
            // Any other wrapper — div, section, span used as a block, something unknown. Descend:
            // the text inside is the document and the tag is packaging.
            if childrenHoldBlocks(children) {
                return paragraphs(from: children, depth: depth, pictures: &pictures)
            }
            let inline = runs(children, Format(), pictures: &pictures)
            return inline.isEmpty ? "" : paragraph(runs: inline, style: nil, alignment: align)
        }
    }

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "blockquote",
        "section", "article", "header", "footer", "main", "hr", "pre",
    ]

    private static func isList(_ node: HTMLNode) -> Bool {
        if case .element(let tag, _, _) = node { return tag == "ul" || tag == "ol" }
        return false
    }

    private static func childrenHoldBlocks(_ children: [HTMLNode]) -> Bool {
        children.contains { node in
            if case .element(let tag, _, _) = node { return blockTags.contains(tag) }
            return false
        }
    }

    private static func list(
        _ children: [HTMLNode], ordered: Bool, depth: Int, pictures: inout [Picture]
    ) -> String {
        var out = ""
        for child in children {
            guard case .element(let tag, let attributes, let grandchildren) = child,
                  tag == "li"
            else { continue }
            // A real list, referring to `numbering.xml`, rather than a marker typed into the
            // text. Typed markers print but Word will not renumber them: insert an item at the
            // top of a list of twenty and every number below it is silently wrong.
            //
            // Only the item's own inline content — a nested list is walked separately below, or
            // its text would appear twice, once here and once as its own items.
            let items = runs(grandchildren.filter { !isList($0) }, Format(), pictures: &pictures)
            out += paragraph(
                runs: items, style: nil, alignment: alignment(attributes),
                numbering: (ordered ? NumberingID.ordered : NumberingID.bullet, depth))
            // A nested list inside the item.
            for grandchild in grandchildren {
                if case .element(let inner, _, let innerChildren) = grandchild,
                   inner == "ul" || inner == "ol" {
                    out += list(innerChildren, ordered: inner == "ol", depth: depth + 1, pictures: &pictures)
                }
            }
        }
        return out
    }

    private static func table(_ children: [HTMLNode], pictures: inout [Picture]) -> String {
        let rows = flattenRows(children)
        guard !rows.isEmpty else { return "" }
        // A grid is not optional. Without `w:tblGrid` declaring the columns, a reader has nothing
        // to lay the cells against — LibreOffice dropped every column but the first, silently, and
        // the XML was still well-formed. Widths are shared equally across the usable page.
        let columns = max(1, rows.map(\.cells.count).max() ?? 1)
        let columnWidth = usableWidthTwips / columns
        var out = """
            <w:tbl><w:tblPr><w:tblW w:w="\(usableWidthTwips)" w:type="dxa"/>\
            <w:tblBorders>\
            <w:top w:val="single" w:sz="4" w:color="auto"/>\
            <w:left w:val="single" w:sz="4" w:color="auto"/>\
            <w:bottom w:val="single" w:sz="4" w:color="auto"/>\
            <w:right w:val="single" w:sz="4" w:color="auto"/>\
            <w:insideH w:val="single" w:sz="4" w:color="auto"/>\
            <w:insideV w:val="single" w:sz="4" w:color="auto"/>\
            </w:tblBorders></w:tblPr>
            """
        let gridColumn = "<w:gridCol w:w=\"\(columnWidth)\"/>"
        out += "<w:tblGrid>" + String(repeating: gridColumn, count: columns) + "</w:tblGrid>"
        for (index, row) in rows.enumerated() {
            let isHeader = index == 0 && row.isHeader
            // `cantSplit` on every row, `tblHeader` on the first: a long chronology then breaks
            // between whole rows with its heading repeated, rather than slicing a date in two.
            out += "<w:tr><w:trPr><w:cantSplit/>"
            out += isHeader ? "<w:tblHeader/>" : ""
            out += "</w:trPr>"
            for cell in row.cells {
                let content = runs(cell.children, Format(bold: cell.isHeader), pictures: &pictures)
                out += "<w:tc><w:tcPr><w:tcW w:w=\"\(columnWidth)\" w:type=\"dxa\"/></w:tcPr>"
                out += paragraph(
                    runs: content.isEmpty ? [Run(text: "")] : content,
                    style: nil, alignment: alignment(cell.attributes))
                out += "</w:tc>"
            }
            out += "</w:tr>"
        }
        return out + "</w:tbl>"
    }

    private struct Cell {
        let children: [HTMLNode]
        let attributes: [String: String]
        let isHeader: Bool
    }

    private struct Row {
        let cells: [Cell]
        var isHeader: Bool { cells.allSatisfy(\.isHeader) && !cells.isEmpty }
    }

    /// Rows, reached through `thead`/`tbody`/`tfoot` if they are there and directly if they are
    /// not — both shapes arrive.
    private static func flattenRows(_ nodes: [HTMLNode]) -> [Row] {
        var rows: [Row] = []
        for node in nodes {
            guard case .element(let tag, _, let children) = node else { continue }
            switch tag {
            case "thead", "tbody", "tfoot":
                rows += flattenRows(children)
            case "tr":
                var cells: [Cell] = []
                for cellNode in children {
                    guard case .element(let cellTag, let attributes, let cellChildren) = cellNode,
                          cellTag == "td" || cellTag == "th"
                    else { continue }
                    cells.append(Cell(
                        children: cellChildren, attributes: attributes, isHeader: cellTag == "th"))
                }
                if !cells.isEmpty { rows.append(Row(cells: cells)) }
            default:
                continue
            }
        }
        return rows
    }

    // MARK: - Runs

    private struct Format {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var superscript = false
        var subscriptText = false
    }

    private struct Run {
        var text: String
        var format = Format()
        /// A picture, already rendered as OOXML. When set, the run is the picture.
        var drawing: String?
    }

    private static func runs(
        _ nodes: [HTMLNode], _ format: Format, pictures: inout [Picture]
    ) -> [Run] {
        var out: [Run] = []
        for node in nodes {
            switch node {
            case .text(let value):
                if !value.isEmpty { out.append(Run(text: value, format: format)) }
            case .element(let tag, let attributes, let children):
                if tag == "br" { out.append(Run(text: "\n", format: format)); continue }
                if tag == "img" {
                    guard let source = attributes["src"],
                          let image = EmbeddedImage.parse(dataURI: source)
                    else {
                        // A remote picture is not fetched — an export must not depend on the
                        // network or on a credential. Say so in the document rather than
                        // leaving a silent hole where a seal or a signature was.
                        out.append(Run(text: "[image not embedded]", format: format))
                        continue
                    }
                    let picture = Picture(image: image, index: pictures.count + 1)
                    pictures.append(picture)
                    out.append(Run(text: "", format: format, drawing: drawing(for: picture)))
                    continue
                }
                if tag == "script" || tag == "style" { continue }
                var inner = format
                switch tag {
                case "b", "strong": inner.bold = true
                case "i", "em", "cite": inner.italic = true
                case "u", "ins": inner.underline = true
                case "s", "strike", "del": inner.strike = true
                case "sup": inner.superscript = true
                case "sub": inner.subscriptText = true
                default: break
                }
                // The editor writes weight and style as inline CSS as often as as tags, and
                // `htmlToDocx.js` reads both. Reading only the tags would lose an emphasis that
                // is plainly visible on screen.
                let style = (attributes["style"] ?? "").lowercased()
                if style.contains("font-weight:bold") || style.contains("font-weight: bold")
                    || style.contains("font-weight:700") || style.contains("font-weight: 700") {
                    inner.bold = true
                }
                if style.contains("font-style:italic") || style.contains("font-style: italic") {
                    inner.italic = true
                }
                if style.contains("underline") { inner.underline = true }
                if style.contains("line-through") { inner.strike = true }
                out += runs(children, inner, pictures: &pictures)
            }
        }
        return out
    }

    private static func paragraph(
        runs: [Run], style: String?, alignment: String?,
        keepWithNext: Bool = false, indent: Int = 0,
        numbering: (id: Int, level: Int)? = nil
    ) -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if keepWithNext { properties += "<w:keepNext/><w:keepLines/>" }
        if let numbering {
            properties += """
                <w:numPr><w:ilvl w:val="\(min(8, numbering.level))"/>\
                <w:numId w:val="\(numbering.id)"/></w:numPr>
                """
        }
        if indent > 0 { properties += "<w:ind w:left=\"\(indent)\"/>" }
        if let alignment { properties += "<w:jc w:val=\"\(alignment)\"/>" }

        var body = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        for run in runs {
            body += self.run(run, style: style)
        }
        return "<w:p>\(body)</w:p>"
    }

    private static func run(_ run: Run, style: String?) -> String {
        var properties = ""
        // Heading weight and size are carried on the run, because `styles.xml` here declares only
        // the defaults — spelling them out is what makes the heading a heading in every reader.
        switch style {
        case "Heading1": properties += "<w:b/><w:sz w:val=\"\(Size.heading1)\"/>"
        case "Heading2": properties += "<w:b/><w:sz w:val=\"\(Size.heading2)\"/>"
        case "Heading3": properties += "<w:b/><w:sz w:val=\"\(Size.heading3)\"/>"
        default:
            if run.format.bold { properties += "<w:b/>" }
        }
        if run.format.italic { properties += "<w:i/>" }
        if run.format.underline { properties += "<w:u w:val=\"single\"/>" }
        if run.format.strike { properties += "<w:strike/>" }
        if run.format.superscript { properties += "<w:vertAlign w:val=\"superscript\"/>" }
        if run.format.subscriptText { properties += "<w:vertAlign w:val=\"subscript\"/>" }

        let wrapped = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        if let drawing = run.drawing { return "<w:r>\(wrapped)\(drawing)</w:r>" }
        // A `<br>` became a newline in the run text; OOXML needs it as an element.
        let pieces = run.text.components(separatedBy: "\n")
        var text = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 { text += "<w:br/>" }
            if !piece.isEmpty {
                text += "<w:t xml:space=\"preserve\">\(escape(piece))</w:t>"
            }
        }
        return "<w:r>\(wrapped)\(text)</w:r>"
    }

    /// An inline picture, scaled to fit the page.
    ///
    /// OOXML measures in EMUs — 914400 to the inch — and a pixel at 96dpi is 9525 of them. A
    /// screenshot of a court order is routinely wider than the text column, so anything over the
    /// usable width is scaled down keeping its aspect ratio rather than running into the margin.
    private static func drawing(for picture: Picture) -> String {
        let perPixel = 9525
        var width = picture.image.width * perPixel
        var height = picture.image.height * perPixel
        // 1 twip is 635 EMU.
        let maxWidth = usableWidthTwips * 635
        if width > maxWidth, width > 0 {
            height = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
            width = maxWidth
        }
        let id = picture.index
        return """
            <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
            <wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(id)" name="Picture \(id)"/>\
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:nvPicPr><pic:cNvPr id="\(id)" name="Picture \(id)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(picture.relationshipID)"/>\
            <a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """
    }

    private static func alignment(_ attributes: [String: String]) -> String? {
        let style = (attributes["style"] ?? "").lowercased()
        let align = (attributes["align"] ?? "").lowercased()
        if style.contains("text-align:center") || style.contains("text-align: center")
            || align == "center" { return "center" }
        if style.contains("text-align:right") || style.contains("text-align: right")
            || align == "right" { return "right" }
        if style.contains("text-align:justify") || style.contains("text-align: justify")
            || align == "justify" { return "both" }
        if style.contains("text-align:left") || style.contains("text-align: left")
            || align == "left" { return "left" }
        return nil
    }

    /// XML escaping. Without it a single `&` in a party's name makes the package unopenable.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
