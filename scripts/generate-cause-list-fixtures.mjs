#!/usr/bin/env node
// Regenerates the golden data for how a cause-list row names its court, item, coram and note.
//
//   node scripts/generate-cause-list-fixtures.mjs <path-to-emperor-ai> [--check]
//
// Those four are read off each listing by the platform's own `src/lib/causeList.js`
// (`extractCourtNo`, `extractItemNo`, `extractCoram`, `extractTime`, `extractListingNote`), which
// is what the web's Home card and Case Management list print. The Swift port in
// `CauseListingDisplay.swift` is held to that file's answers rather than to anyone's reading of
// its regular expressions — the rules are a dozen patterns deep, and the one that matters most
// (a court-published row states its own room and item, or has none) is a single early return
// that a retyped port would be easy to get subtly wrong.
//
// The inputs below are shaped like `GET /cause-list` entries (sync-server.js, the `pushEntry`
// calls): only keys that route actually sends. `causeList.js` has no static imports, so it is
// imported as it is — no stand-ins needed.
//
// Output: `Tests/EmperorCoreTests/CauseListDisplayGolden.swift`, a Swift source file rather than
// a resource, so it needs no change to Package.swift or project.yml. `--check` writes nothing and
// exits 1 if the file would change.

import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/lib/causeList.js'))) {
  console.error('usage: generate-cause-list-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const lib = await import(pathToFileURL(path.resolve(platform, 'src/lib/causeList.js')).href)
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/CauseListDisplayGolden.swift')

// Every key a `/cause-list` entry can carry, with the defaults `pushEntry` writes. Each case
// overrides what it is about; nothing outside this list is ever sent, so nothing outside it is
// worth feeding the extractors.
const base = {
  date: '2026-09-14', caseId: 'case_1', teamId: 'team_1', title: 'Menon vs. Union of India',
  parties: null, caseType: null, category: null, diaryNumber: null,
  courtName: 'Delhi High Court', courtType: 'hc', caseNumber: '1234', caseYear: '2024',
  cnr: null, judge: null, coram: null, ndoh: null,
}
const hearing = (extra) => ({
  ...base, purpose: null, bench: null, courtNo: null, itemNo: null, listType: null, time: null,
  scraped: false, advocates: null, stage: null, remarks: null, source: 'hearing', ...extra,
})
const scraped = (extra) => hearing({ scraped: true, ...extra })
const next = (extra) => ({
  ...base, purpose: 'Next hearing', stage: null, source: 'next', courtNo: null, itemNo: null,
  advocates: null, ...extra,
})

const cases = {
  // A court-published row states its own room and item. Its bench text is a roster code and its
  // purpose a roster line — neither may be read as where the matter is heard.
  scraped_states_its_own_room: scraped({
    courtNo: 'COURT NO.270', itemNo: '12', bench: 'Court 236',
    purpose: 'TO BE LISTED IN COURT NO.270', coram: "HON'BLE MR. JUSTICE PRATEEK JALAN",
  }),
  scraped_with_no_room_or_item_stays_blank: scraped({
    bench: 'Court 47', purpose: 'Court No. 5 at item 7', stage: 'Item 9',
    coram: "HON'BLE MS. JUSTICE JYOTI SINGH",
  }),
  scraped_item_is_trimmed: scraped({ itemNo: '  7 ', courtNo: 'Court Hall 5' }),
  scraped_blank_item_is_none: scraped({ itemNo: '   ', courtNo: '4' }),
  scraped_registrar_court_keeps_its_prefix: scraped({ courtNo: 'Registrar Court No. 1', itemNo: '3' }),
  scraped_principal_registrar: scraped({ courtNo: 'Principal Registrar Court 2', itemNo: '3A' }),
  scraped_roman_room: scraped({ courtNo: 'Court-II', itemNo: '101' }),
  scraped_bare_roman_room: scraped({ courtNo: 'iv', itemNo: '5' }),
  scraped_unrecognised_room_kept_verbatim: scraped({ courtNo: 'Old  Building,  Room A', itemNo: '2' }),
  scraped_dash_room_is_none: scraped({ courtNo: '—', itemNo: '6' }),
  scraped_time: scraped({ courtNo: 'Court No. 4', itemNo: '9', time: ' 10:30 AM ' }),

  // A hand-entered row keeps the older reading of its own text.
  hand_entered_room_and_item_from_purpose: hearing({
    purpose: 'TO BE LISTED IN COURT NO. 1 AT ITEM NO. 15',
    bench: "Hon'ble Dr. Justice D.Y. Chandrachud & Hon'ble Justice P.S. Narasimha",
    coram: "Hon'ble Dr. Justice D.Y. Chandrachud & Hon'ble Justice P.S. Narasimha",
  }),
  hand_entered_bench_is_a_room: hearing({ bench: 'Court 47', purpose: 'For admission' }),
  hand_entered_item_from_serial: hearing({ purpose: 'Sr. No. 3 — for directions' }),
  hand_entered_item_in_brackets: hearing({ remarks: 'Listed (Item 9) after lunch' }),
  hand_entered_item_no_in_court: hearing({ purpose: 'Listed at No. 4 in Court' }),
  hand_entered_item_from_title: hearing({ title: 'Menon vs. Union of India [Item 5]' }),
  hand_entered_explicit_wins: hearing({ itemNo: '21', purpose: 'Item 3', courtNo: 'Court No. 11' }),
  hand_entered_room_from_remarks: hearing({ remarks: 'Court Room 6, after the board' }),
  hand_entered_nothing: hearing({ purpose: 'For final disposal' }),

  // Coram: never a courtroom, never the forum's own name, and a "Court 14 - " prefix is dropped.
  coram_with_room_prefix: hearing({ coram: 'Court 14 - Justice Yashwant Varma' }),
  coram_that_is_only_rooms: hearing({ coram: 'Court 255, Court 259', judge: 'Justice Amit Bansal' }),
  coram_that_is_the_forum: hearing({
    courtName: 'District Consumer Disputes Redressal Commission',
    coram: 'District Consumer Disputes Redressal Commission',
    bench: 'District Consumer Disputes Redressal Commission',
  }),
  coram_from_purpose_text: hearing({ purpose: "Before Hon'ble Mr. Justice Sanjeev Narula, for orders" }),
  coram_from_purpose_coram_label: hearing({ purpose: 'Coram: Justice C. Hari Shankar; for hearing' }),
  coram_from_stage_bench_label: hearing({ stage: 'Bench - Division Bench II' }),
  coram_none: hearing({ purpose: 'For admission' }),

  // The next-hearing entry carries what the server read off the case, and nothing more.
  next_with_server_item: next({ itemNo: '12', stage: 'Item 12', coram: 'Justice Manmeet Pritam Singh Arora' }),
  next_with_server_room: next({ courtNo: 'Court 30', judge: 'Justice Navin Chawla', coram: 'Justice Navin Chawla' }),
  next_bare: next({}),
  next_stage_note: next({ stage: 'Part heard matters' }),

  // The note line: purpose and stage, minus placeholders, roster lines, bare numbers and repeats.
  note_purpose_and_stage: hearing({ purpose: 'Fixed Date by Court', stage: 'Part heard matters' }),
  note_placeholder_dropped: hearing({ purpose: 'Next listing', stage: 'Arguments' }),
  note_roster_line_dropped: scraped({ purpose: 'TO BE LISTED IN COURT NO.270', stage: 'Admission' }),
  note_repeat_dropped: hearing({ purpose: 'Arguments', stage: 'arguments' }),
  note_bare_number_dropped: hearing({ purpose: '12', stage: 'For orders' }),
  note_brackets_trimmed: hearing({ purpose: '[For Final Hearing]' }),
  note_hearing_n_dropped: hearing({ purpose: 'Hearing - 2', stage: 'Pending' }),
  note_long_is_clipped: hearing({
    purpose: 'For framing of issues and directions as to the further course of the proceedings, '
      + 'including the filing of affidavits of admission and denial of documents by both sides',
    stage: 'Completion of pleadings and admission or denial of documents',
  }),
  note_devanagari_is_clipped_by_utf16: hearing({
    purpose: 'साक्ष्य हेतु '.repeat(14).trim(),
  }),
  note_whitespace_collapsed: hearing({ purpose: '  For\n  orders   on   IA  ' }),

  // JavaScript's \d and \b are ASCII-only; ICU's are not. Devanagari digits are not a "bare
  // number" to the web, and a Devanagari letter is not a word character beside "Sr".
  devanagari_digits_are_not_a_bare_number: hearing({ purpose: 'For orders', stage: '१२' }),
  devanagari_letter_before_serial: hearing({ purpose: 'सूचीsr 4' }),
  devanagari_letter_after_serial: hearing({ purpose: 'Sr 4अ' }),
}

const dash = (v) => (v === '—' || v === '' ? null : v)
const golden = Object.entries(cases).map(([name, listing]) => ({
  name,
  listing,
  expected: {
    courtNo: dash(lib.extractCourtNo(listing)),
    itemNo: dash(lib.extractItemNo(listing)),
    coram: dash(lib.extractCoram(listing)),
    time: dash(lib.extractTime(listing)),
    note: dash(lib.extractListingNote(listing)),
  },
}))

const json = JSON.stringify(golden, null, 2)
if (json.includes('"""#')) throw new Error('fixture would terminate the Swift raw string early')

const swift = `// Generated by scripts/generate-cause-list-fixtures.mjs from the platform's
// src/lib/causeList.js. Do not edit by hand — regenerate it.
//
// Each case is a \`/cause-list\` entry and what the web's extractors print for it. \`null\` is the
// web's "—": nothing to show.

enum CauseListDisplayGolden {
    static let json = #"""
${json}
"""#
}
`

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === swift) {
  console.log('cause-list fixtures: up to date')
  process.exit(0)
}
if (checkOnly) {
  console.error('cause-list fixtures: out of date — rerun without --check')
  process.exit(1)
}
fs.writeFileSync(out, swift)
console.log(`cause-list fixtures: wrote ${golden.length} cases`)
