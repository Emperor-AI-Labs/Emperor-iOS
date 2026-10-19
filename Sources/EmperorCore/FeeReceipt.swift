import Foundation

// The printable fee receipt for one payment on a matter.
//
// A port of the web's `src/components/projects/money/receipt.js` (`buildReceiptHtml` and the
// helpers that say who it is from, to and about) and of the rupee helpers in `money/inr.js` and
// `money/dates.js` it prints with. Held to the web's own output, byte for byte, by
// `scripts/generate-fee-receipt-fixtures.mjs`.
//
// It is the form an Indian advocate's office has always issued: the advocate at the head, a
// numbered and dated "Received with thanks from … the sum of ₹… (Rupees … Only) … towards
// professional fees in the matter of …", the figure in a box, and a signature — with a box for a
// revenue stamp when the amount is above ₹5,000. The box is only a place for one; whether one is
// needed is the advocate's call.

/// Rupees on paper: in words, as a figure, and the receipt's number.
///
/// Everything is in whole paise, as on the web — the API sends rupees as a float beside the exact
/// integer, and a float is never added up or printed from.
enum RupeeText {
    /// Above this an amount is a typing accident rather than a fee (`MAX_RUPEES`).
    static let maxPaise: Int64 = 100_000_000_000_000

    private static let ones = [
        "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten",
        "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen",
        "Nineteen",
    ]
    private static let tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]

    private static func under100(_ n: Int64) -> String {
        if n < 20 { return ones[Int(n)] }
        return tens[Int(n / 10)] + (n % 10 != 0 ? " \(ones[Int(n % 10)])" : "")
    }

    private static func under1000(_ n: Int64) -> String {
        [n >= 100 ? "\(ones[Int(n / 100)]) Hundred" : "", n % 100 != 0 ? under100(n % 100) : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Crore, lakh, thousand, hundred — a count of crores past 99 is itself written in Indian
    /// words ("One Thousand Two Hundred Crore"), as a cheque writes it.
    private static func indianWords(_ n: Int64) -> String {
        if n == 0 { return "Zero" }
        let crore = n / 10_000_000
        let lakh = (n % 10_000_000) / 100_000
        let thousand = (n % 100_000) / 1000
        let rest = n % 1000
        return [
            crore != 0 ? "\(indianWords(crore)) Crore" : "",
            lakh != 0 ? "\(under100(lakh)) Lakh" : "",
            thousand != 0 ? "\(under100(thousand)) Thousand" : "",
            rest != 0 ? under1000(rest) : "",
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Rupees Twelve Lakh … and Fifty Paise Only"; "Fifty Paise Only" under a rupee; empty for
    /// a negative or absurd amount, so the receipt shows a blank rather than nonsense
    /// (`amountInWordsINR`).
    static func words(paise: Int64) -> String {
        guard paise >= 0, paise <= maxPaise else { return "" }
        let rupees = paise / 100
        let p = paise % 100
        if rupees == 0 && p != 0 { return "\(under100(p)) Paise Only" }
        return "Rupees \(indianWords(rupees))\(p != 0 ? " and \(under100(p)) Paise" : "") Only"
    }

    /// "₹25,000/-" for whole rupees, "₹25,000.50" with paise (`rupeesFigure`).
    static func figure(paise: Int64) -> String {
        guard paise >= 0 else { return "" }
        let rupees = indianGrouped(paise / 100)
        let p = paise % 100
        return p != 0 ? "₹\(rupees).\(String(format: "%02d", Int(p)))" : "₹\(rupees)/-"
    }

    /// `1,25,000` — the last three digits, then pairs, as `toLocaleString('en-IN')` writes it.
    static func indianGrouped(_ value: Int64) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var head = String(digits.dropLast(3))
        let tail = String(digits.suffix(3))
        var groups: [String] = []
        while head.count > 2 {
            groups.insert(String(head.suffix(2)), at: 0)
            head = String(head.dropLast(2))
        }
        if !head.isEmpty { groups.insert(head, at: 0) }
        return (groups + [tail]).joined(separator: ",")
    }

    /// The Indian financial year a day falls in, "2026-27" (`financialYear`); empty without a
    /// date at the start of the text.
    static func financialYear(_ raw: String?) -> String {
        let text = raw ?? ""
        guard text.count >= 10 else { return "" }
        let chars = Array(text.prefix(10))
        let shape = chars.enumerated().allSatisfy { index, c in
            index == 4 || index == 7 ? c == "-" : c.isASCII && c.isNumber
        }
        guard shape, let year = Int(String(chars[0..<4])), let month = Int(String(chars[5..<7]))
        else { return "" }
        let start = month >= 4 ? year : year - 1
        return "\(start)-\(String(format: "%02d", (start + 1) % 100))"
    }

    /// The receipt number: the financial year of the payment and the last six letters and
    /// digits of the entry's id (`receiptNumber`). Never a running serial, so a reprint matches
    /// the copy the client holds.
    static func receiptNumber(id: String?, entryDate: String?, createdAt: String?) -> String {
        let fy = financialYear(entryDate?.nilIfEmpty ?? createdAt)
        let alnum = (id ?? "").unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        let tail = String(String.UnicodeScalarView(alnum.suffix(6))).uppercased()
        return [fy, tail.isEmpty ? "000000" : tail].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// "01 Oct 2026" for a real calendar day at the start of the text, else empty (`fmtDay` in
    /// `money/dates.js` — a typed-in day that does not exist is not rolled into the next month).
    static func shortDay(_ raw: String?) -> String {
        guard let raw, raw.count >= 10 else { return "" }
        let key = String(raw.prefix(10))
        guard let day = CivilDay(key: key) else { return "" }
        let c = day.components
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%02d", c.day) + " \(months[c.month - 1]) " + String(format: "%04d", c.year)
    }
}

enum FeeReceipt {
    /// Who the receipt is from — the signed-in profile (`advocateFromProfile`).
    struct Advocate: Equatable, Sendable {
        var name = ""
        var designation = ""
        var chambers = ""
        var phone = ""
        var email = ""
    }

    /// Who it is made out to (`receiptClient`).
    struct Client: Equatable, Sendable {
        var name = ""
        var address = ""
    }

    /// What it is about (`matterFromProject`).
    struct Matter: Equatable, Sendable {
        var title = ""
        var caseNo = ""
        var forum = ""
    }

    /// Above this, the revenue-stamp box is drawn (Indian Stamp Act, 1899, Sch. I, Art. 53).
    static let stampAbovePaise: Int64 = 5000 * 100

    /// Whitespace runs to one space, trimmed — the web's `clean`.
    static func clean(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The five characters the web escapes, so user text can never become markup.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// "CS(OS) 55/2018": the type only when the number does not already carry it, the year only
    /// when the number does not already end with it (`caseNumberOf`).
    static func caseNumber(of project: Project) -> String {
        let number = clean(project.caseNumber)
        guard !number.isEmpty else { return "" }
        let type = clean(project.caseType)
        let typed = !type.isEmpty && !number.lowercased().hasPrefix(type.lowercased()) ? "\(type) \(number)" : number
        let year = clean(project.caseYear)
        return !year.isEmpty && !typed.hasSuffix("/\(year)") ? "\(typed)/\(year)" : typed
    }

    /// The matter's client, with the address from People when that record is the same person. A
    /// person under another name is never silently swapped in for the named client.
    static func client(project: Project, people: [ProjectPerson]) -> Client {
        let named = clean(project.client)
        let clients = people.filter { $0.role == "client" && !clean($0.name).isEmpty }
        let same = named.isEmpty
            ? clients.first
            : clients.first { clean($0.name).lowercased() == named.lowercased() }
        return Client(name: named.isEmpty ? clean(same?.name) : named, address: clean(same?.address))
    }

    static func advocate(from user: User?) -> Advocate {
        let phone = clean(user?.phone)
        return Advocate(
            name: clean(user?.name),
            designation: clean(user?.title),
            chambers: clean(user?.organization),
            // `formatIndianPhone` for a valid mobile: "+91 98765 43210".
            phone: !phone.isEmpty && IndianMobile.isValid(phone) ? "+91 \(IndianMobile.local(phone))" : phone,
            email: clean(user?.email))
    }

    static func matter(from project: Project) -> Matter {
        Matter(title: clean(project.name), caseNo: caseNumber(of: project), forum: clean(project.forumName))
    }

    /// The entry's amount in paise: the exact integer when it came, else the rupees rounded to
    /// the nearest paisa (`paiseOf`).
    static func paise(of entry: LedgerEntry) -> Int64 {
        if let exact = entry.amountPaise { return Int64(exact) }
        guard let rupees = entry.amount, rupees.isFinite else { return 0 }
        return Int64((rupees * 100).rounded(.toNearestOrAwayFromZero))
    }

    /// How the money came, in the receipt's own words: "by cheque no. 004512, HDFC Bank".
    static func paidBy(mode: String?, reference: String?) -> String {
        let ref = clean(reference)
        switch mode {
        case "cash": return "in cash"
        case "upi": return "by UPI" + (ref.isEmpty ? "" : " (ref. \(ref))")
        case "bank": return "by bank transfer" + (ref.isEmpty ? "" : " (UTR \(ref))")
        case "cheque": return "by cheque" + (ref.isEmpty ? "" : " no. \(ref)")
        case "card": return "by card" + (ref.isEmpty ? "" : " (txn \(ref))")
        default: return ref.isEmpty ? "" : "(ref. \(ref))"
        }
    }

    static func number(of entry: LedgerEntry) -> String {
        RupeeText.receiptNumber(id: entry.id, entryDate: entry.entryDateRaw, createdAt: entry.createdAtRaw)
    }

    /// A file name for the shared PDF: "Receipt 2026-27-AB12CD.pdf".
    static func fileName(for entry: LedgerEntry) -> String {
        "Receipt \(number(of: entry).replacingOccurrences(of: "/", with: "-")).pdf"
    }

    /// The receipt as one HTML document — exactly the web's `buildReceiptHtml`.
    static func html(advocate: Advocate, client: Client, matter: Matter, entry: LedgerEntry) -> String {
        let blank = "<span class=\"blank\"></span>"
        let paise = paise(of: entry)
        let number = number(of: entry)
        let figure = RupeeText.figure(paise: paise)
        let words = RupeeText.words(paise: paise)
        let date = RupeeText.shortDay(entry.entryDateRaw)
        let towards = clean(entry.title).nilIfEmpty ?? "professional fees"
        let by = paidBy(mode: entry.mode, reference: entry.reference)
        let forum: String
        if matter.forum.isEmpty {
            forum = ""
        } else {
            let hasThe = matter.forum.range(of: #"^the\s"#, options: [.regularExpression, .caseInsensitive]) != nil
            forum = "before \(hasThe ? "" : "the ")\(escape(matter.forum))"
        }
        let matterText = ["<b>\(escape(matter.title).nilIfEmpty ?? blank)</b>",
                          matter.caseNo.isEmpty ? "" : escape(matter.caseNo), forum]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let contacts = [advocate.phone, advocate.email].filter { !$0.isEmpty }.map(escape)
            .joined(separator: " &middot; ")
        let signer = advocate.name.nilIfEmpty ?? advocate.email
        let docTitle = "Receipt \(number)" + (client.name.isEmpty ? "" : " — \(client.name)")

        let designationLine = advocate.designation.isEmpty ? "" : "<div class=\"sub\">\(escape(advocate.designation))</div>"
        let chambersLine = advocate.chambers.isEmpty ? "" : "<div class=\"sub\">\(escape(advocate.chambers))</div>"
        let contactsLine = contacts.isEmpty ? "" : "<div class=\"sub\">\(contacts)</div>"
        let address = client.address.isEmpty ? "" : ", \(escape(client.address)),"
        let byText = by.isEmpty ? "" : " \(escape(by))"
        let stamp = paise > stampAbovePaise ? "<div class=\"stamp\">Revenue<br>stamp</div>" : ""
        let signerLine = signer.isEmpty ? "" : "<b>\(escape(signer))</b><br>"

        return """
            <!doctype html>
            <html lang="en-IN">
            <head>
            <meta charset="utf-8">
            <title>\(escape(docTitle))</title>
            <style>
            \(style)
            </style>
            </head>
            <body>
            <div class="bar"><button type="button" id="receipt-print">Print</button><span>To keep a copy, choose “Save as PDF” in the print dialog.</span></div>
            <main class="sheet">
              <header class="head">
                <div class="who">\(escape(advocate.name).nilIfEmpty ?? "&nbsp;")</div>
                \(designationLine)
                \(chambersLine)
                \(contactsLine)
              </header>
              <div class="title">RECEIPT</div>
              <div class="meta"><span>Receipt No. <b class="no">\(escape(number))</b></span><span>Date: <b>\(escape(date).nilIfEmpty ?? blank)</b></span></div>
              <p class="text">Received with thanks from <b>\(escape(client.name).nilIfEmpty ?? blank)</b>\(address)
                the sum of <b>\(escape(figure))</b> (<b>\(escape(words))</b>)\(byText) towards \(escape(towards)) in the
                matter of \(matterText).</p>
              <div class="foot">
                <div class="figure">\(escape(figure))</div>
                <div class="sign">
                  \(stamp)
                  <div class="sig"><div class="rule"></div>\(signerLine)\(escape(advocate.designation.nilIfEmpty ?? "Advocate"))</div>
                </div>
              </div>
            </main>
            </body>
            </html>
            """
    }

    /// The same document laid out for paper, for the PDF this client shares: the web's
    /// `@media print` rules applied outright and its on-screen Print bar left out, because a
    /// print formatter is not a browser and is not relied on to pick the print rules.
    static func printableHTML(advocate: Advocate, client: Client, matter: Matter, entry: LedgerEntry) -> String {
        html(advocate: advocate, client: client, matter: matter, entry: entry)
            .replacingOccurrences(of: printBar + "\n", with: "")
            .replacingOccurrences(of: "</style>\n</head>", with: """
                  body { background: #fff; }
                  .sheet { width: auto; margin: 0; padding: 0; box-shadow: none; }
                </style>
                </head>
                """)
    }

    static let printBar = "<div class=\"bar\"><button type=\"button\" id=\"receipt-print\">Print</button><span>To keep a copy, choose “Save as PDF” in the print dialog.</span></div>"

    // The web's stylesheet, verbatim.
    private static let style = """
          @page { size: A4; margin: 16mm 18mm; }
          * { box-sizing: border-box; }
          html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          /* Times New Roman, the face Indian courts ask for, and lining figures: Georgia's old-style
             digits dip below the line, which is wrong on a column of amounts and case numbers. */
          body { margin: 0; background: #ECEEF5; color: #0F1424; font: 16px/1.6 'Times New Roman', Times, 'Liberation Serif', serif;
            font-variant-numeric: lining-nums; }
          .bar { display: flex; align-items: center; justify-content: center; gap: 14px; padding: 12px; background: #F7F8FC;
            border-bottom: 1px solid #E8EAF2; font: 13px/1.4 system-ui, -apple-system, 'Segoe UI', sans-serif; color: #454B63; }
          .bar button { height: 34px; padding: 0 18px; border: 0; border-radius: 4px; cursor: pointer; color: #fff;
            font: 600 13px/1 system-ui, -apple-system, 'Segoe UI', sans-serif; background: linear-gradient(135deg, #464E85 0%, #547592 100%); }
          .sheet { width: 190mm; margin: 24px auto; padding: 16mm 15mm 14mm; background: #fff;
            box-shadow: 0 1px 2px rgba(15, 20, 36, .08), 0 10px 28px -14px rgba(15, 20, 36, .22); }
          .head { text-align: center; padding-bottom: 12px; border-bottom: 2px solid #0F1424; }
          .who { font-size: 21px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; }
          .sub { font-size: 13.5px; color: #454B63; }
          .title { margin: 22px 0 0; text-align: center; font-size: 15px; font-weight: 700; letter-spacing: .32em; }
          .meta { display: flex; justify-content: space-between; gap: 16px; margin: 18px 0 20px; font-size: 14px; }
          .meta .no { font-family: ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace; font-size: 13.5px; }
          .text { margin: 0; text-align: justify; }
          .blank { display: inline-block; min-width: 46mm; border-bottom: 1px solid #0F1424; }
          .foot { display: flex; justify-content: space-between; align-items: flex-end; gap: 18px; margin-top: 30px; }
          .figure { padding: 8px 16px; border: 1.5px solid #0F1424; font-size: 18px; font-weight: 700; white-space: nowrap; }
          .sign { display: flex; align-items: flex-end; gap: 16px; }
          .stamp { display: grid; place-items: center; width: 24mm; height: 28mm; border: 1px dashed #8C93B0;
            font: 10.5px/1.3 system-ui, sans-serif; color: #8C93B0; text-align: center; }
          .sig { min-width: 62mm; text-align: center; font-size: 13.5px; line-height: 1.45; }
          .sig .rule { height: 16mm; border-bottom: 1px solid #0F1424; margin-bottom: 6px; }
          @media print {
            body { background: #fff; }
            .bar { display: none; }
            .sheet { width: auto; margin: 0; padding: 0; box-shadow: none; }
          }
        """

    /// The name of a receipt file attached to an entry — its last path part (`receiptFileName`).
    static func attachedFileName(_ path: String?) -> String? {
        let normal = (path ?? "").replacingOccurrences(of: "\\", with: "/")
        let name = normal.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }
}
