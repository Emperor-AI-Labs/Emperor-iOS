#!/usr/bin/env node
// Regenerates the golden data for the day's cause list as it is downloaded.
//
//   node scripts/generate-cause-list-export-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web's Download menu on the cause list (`src/lib/causeList.js`) groups the day's listings by
// court in the judicial hierarchy, orders each court's rows by court number then item, and writes
// them out as PDF, Word or CSV with one column set. `CauseListExport.swift` is held to that
// file's own answers: the groups, every cell of every row, the date line, and the CSV byte for
// byte. `downloadCauseListCsv` hands its text to the browser as a Blob, so the few DOM calls it
// makes are stood in for here and the Blob's text is what is recorded.
//
// The listings are shaped like `GET /cause-list` entries, as in generate-cause-list-fixtures.mjs.
//
// Output: `Tests/EmperorCoreTests/CauseListExportGolden.swift`. `--check` writes nothing and exits
// 1 if the file would change.

import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/lib/causeList.js'))) {
  console.error('usage: generate-cause-list-export-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const lib = await import(pathToFileURL(path.resolve(platform, 'src/lib/causeList.js')).href)
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/CauseListExportGolden.swift')

const base = {
  date: '2026-10-19', caseId: 'case_1', teamId: 'team_1', title: 'Menon vs. Union of India',
  parties: null, caseType: null, category: null, diaryNumber: null,
  courtName: 'Delhi High Court', courtType: 'hc', caseNumber: '1234', caseYear: '2024',
  cnr: null, judge: null, coram: null, ndoh: null,
}
const hearing = (extra) => ({
  ...base, purpose: null, bench: null, courtNo: null, itemNo: null, listType: null, time: null,
  scraped: false, advocates: null, stage: null, remarks: null, source: 'hearing', ...extra,
})
const scraped = (extra) => hearing({ scraped: true, ...extra })

// One day's list, across the tiers, with the shapes that decide an order or a cell.
const entries = [
  scraped({ caseId: 'd1', courtNo: 'COURT NO. 12', itemNo: '7', coram: "HON'BLE MR. JUSTICE PRATEEK JALAN",
    caseType: 'W.P.(C)', caseNumber: '4412', caseYear: '2025', parties: 'RAMESH KUMAR vs. UNION OF INDIA',
    category: '4101- SERVICE MATTERS', advocates: 'A. Sharma, B. Rao', listType: 'Supplementary List', time: '10:30 AM',
    purpose: 'For admission' }),
  scraped({ caseId: 'd2', courtNo: 'COURT NO. 3', itemNo: '12', coram: 'Justice Navin Chawla',
    caseType: 'CS(OS)', caseNumber: '55/2018', caseYear: '2018', title: 'Bhalla v. Kumari [Court 3]',
    listType: 'Advance List', stage: 'Arguments' }),
  scraped({ caseId: 'd3', courtNo: 'COURT NO. 3', itemNo: '2.1', caseType: 'CRL.A.', caseNumber: '9', caseYear: '2024',
    title: 'State vs. Mohan - Next hearing 2026-11-01' }),
  hearing({ caseId: 'd4', courtName: 'Delhi High Court', title: 'No room yet', purpose: 'Fixed Date by Court' }),
  hearing({ caseId: 's1', courtName: 'Supreme Court of India', courtType: 'sc', caseType: 'Supreme Court Matter (Diary lookup)',
    caseNumber: '12852/2024', caseYear: '2024', diaryNumber: '12852/2024', title: 'XYZ Ltd. vs. ABC Ltd.',
    courtNo: 'Court No. 4', itemNo: '301.1', remarks: 'regular hearing matter' }),
  hearing({ caseId: 's2', courtName: 'Supreme Court of India', courtType: 'sc', caseType: 'SLP(C) No.', caseNumber: '881',
    caseYear: '2025', title: 'P vs. Q', courtNo: 'Registrar Court 1', itemNo: '5' }),
  hearing({ caseId: 's3', courtName: 'Supreme Court of India', courtType: 'sc', caseType: 'C.A.', caseNumber: '10',
    caseYear: '2023', title: 'R vs. S', courtNo: 'Court No. 4', itemNo: '3010' }),
  hearing({ caseId: 'b1', courtName: 'Bombay High Court', courtType: 'hc', caseType: 'WP-134', caseNumber: '77', caseYear: null,
    title: 'Tata vs. Mistry', courtNo: 'Court Room 7' }),
  hearing({ caseId: 'n1', courtName: 'NCLT New Delhi Bench-III', courtType: 'nclt', caseType: null, caseNumber: null,
    caseYear: null, cnr: 'CP(IB)-112/ND/2025', title: 'Insolvency of Foo Ltd.', bench: 'Court 2', stage: 'Pending' }),
  hearing({ caseId: 'n2', courtName: 'National Company Law Appellate Tribunal', courtType: 'nclat', caseType: null,
    caseNumber: null, caseYear: null, diaryNumber: '998/2025', title: 'Bar vs. Baz', purpose: 'Hearing - 2' }),
  hearing({ caseId: 't1', courtName: 'Income Tax Appellate Tribunal, Delhi', courtType: 'tribunal', title: 'CIT vs. Assessee',
    category: '3600', advocates: null, stage: 'Part heard matters' }),
  hearing({ caseId: 'x1', courtName: 'Saket District Court', courtType: 'district', caseType: 'CS(COMM)-12', caseNumber: '5',
    caseYear: '2026', title: 'Quote "test", comma, and more', listType: 'Daily' }),
  hearing({ caseId: 'f1', courtName: 'District Consumer Disputes Redressal Commission', courtType: 'forum', title: 'Consumer vs. Shop',
    caseNumber: null, caseYear: null, cnr: null, purpose: 'supplementary hearing' }),
  hearing({ caseId: 'o1', courtName: 'Arbitral Tribunal of Mr. X', courtType: 'other', title: 'Claimant vs. Respondent',
    caseNumber: null, caseYear: null }),
  hearing({ caseId: 'o2', courtName: 'Lok Adalat', courtType: '', title: 'Settlement', caseNumber: null, caseYear: null }),
]
const day = '2026-10-19'

// downloadCauseListCsv hands its text to the browser; record it instead.
let csv = null
globalThis.document = {
  createElement: () => ({ click() {} }),
  body: { appendChild() {}, removeChild() {} },
}
globalThis.URL.createObjectURL = (blob) => { csv = blob; return 'blob:fixture' }
globalThis.URL.revokeObjectURL = () => {}
lib.downloadCauseListCsv(day, entries)
const csvText = await csv.text()

const groups = lib.groupEntriesByCourtHierarchy(entries).map(g => ({
  courtName: g.courtName,
  rows: g.entries.map(e => {
    const ct = lib.formatCauseTitle(e)
    return {
      caseId: e.caseId,
      courtNo: lib.extractCourtNo(e),
      item: lib.extractItemNo(e),
      parties: ct.parties,
      appealOrCaseNo: ct.appealOrCaseNo,
      category: ct.category,
      coram: lib.extractCoram(e),
      advocates: lib.extractAdvocates(e),
      suppl: lib.extractSuppl(e),
      time: lib.extractTime(e),
      note: lib.extractListingNote(e),
    }
  }),
}))

const golden = { day, longDay: lib.fmtLong(day), entries, groups, csv: csvText }
const json = JSON.stringify(golden, null, 2)
if (json.includes('"""#')) throw new Error('fixture would terminate the Swift raw string early')

const swift = `// Generated by scripts/generate-cause-list-export-fixtures.mjs from the platform's
// src/lib/causeList.js. Do not edit by hand — regenerate it.
//
// One day's \`/cause-list\` entries, the court groups and cells the web's export writes for
// them, and the CSV it downloads.

enum CauseListExportGolden {
    static let json = #"""
${json}
"""#
}
`

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === swift) {
  console.log('cause-list export fixtures: up to date')
  process.exit(0)
}
if (checkOnly) {
  console.error('cause-list export fixtures: out of date — rerun without --check')
  process.exit(1)
}
fs.writeFileSync(out, swift)
console.log(`cause-list export fixtures: wrote ${entries.length} entries in ${groups.length} courts`)
