#!/usr/bin/env node
// Regenerates the matter-record golden fixture — the chronology merge, the "List of Dates &
// Events" export and the Overview timeline — from the platform's own source.
//
//   node scripts/generate-matter-record-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web reads a matter's record in `src/lib/projectRecord.js`: `chronologyEntries` merges the
// user's own entries with the linked case's hearings and orders, `sortChronology` orders them,
// `eventText` words each for a synopsis, `listOfDatesHtml` lays out the List of Dates & Events
// that the Chronology section exports to Word and to print, and `nextHearing` picks the next
// date. `MatterRecord.swift`, `ChronologyExport.swift` and `OverviewTimeline.swift` port them,
// held to them here.
//
// Tests/EmperorCoreTests/Resources/matter-record/record.json records, from running it:
//   - `entries` — chronologyEntries(updates, courtHistory) for one matter's record, each with
//     its eventText, and the keys in sortChronology's order oldest-first and newest-first.
//   - `exports` — listOfDatesHtml for several projects and selections of those entries.
//   - `nextHearings` — nextHearing for several project / linked-case date pairs.
//   - `plainCourtText`, `orderTitle`, `fmtDots` — the small text helpers.
//   - `timeline` — the Overview's vertical timeline for a day. The rows are what the Timeline
//     component in `src/components/projects/sections/OverviewSection.jsx` draws: its
//     `entryText`, `kindSub` and `awayText` are cut out of the page by name and evaluated, so
//     the wording is the platform's; how it filters, orders, inserts a year marker and
//     alternates sides is restated below beside the JSX it mirrors.
//
// `--check` writes nothing and exits 1 if the fixture differs.

process.env.TZ = 'UTC'

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const recordPath = platform && path.join(platform, 'src/lib/projectRecord.js')
const overviewPath = platform && path.join(platform, 'src/components/projects/sections/OverviewSection.jsx')
if (!platform || !fs.existsSync(recordPath) || !fs.existsSync(overviewPath)) {
  console.error('usage: generate-matter-record-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const outDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/matter-record')
const out = path.join(outDir, 'record.json')

// `@/…` is the platform's alias for src/; the icons are only ever compared, never drawn here.
const ICONS = 'data:text/javascript,' + encodeURIComponent(
  ['CalendarDays', 'Gavel', 'ScrollText', 'Upload', 'Flag', 'CheckCircle2', 'StickyNote']
    .map(n => `export const ${n} = '${n}'`).join('\n'))
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'lucide-react') return { url: ICONS, shortCircuit: true }
    if (specifier.startsWith('@/')) {
      return { url: pathToFileURL(path.join(src, specifier.slice(2) + '.js')).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

const R = await import(pathToFileURL(recordPath).href)

// The Overview's wording helpers, cut by name. A renamed helper fails here, loudly.
const page = fs.readFileSync(overviewPath, 'utf8')
function cut(pattern, name) {
  const m = page.match(pattern)
  if (!m) { console.error(`${name} not found in OverviewSection.jsx`); process.exit(1) }
  return m[0]
}
const helpers = new Function('plainCourtText', 'kindMeta', [
  cut(/function entryText\(e\) \{[\s\S]*?\n\}\n/, 'entryText'),
  cut(/const kindSub = .*\n/, 'kindSub'),
  cut(/const awayText = .*\n/, 'awayText'),
  'return { entryText, kindSub, awayText }',
].join('\n'))(R.plainCourtText, R.kindMeta)

// ── One matter's record ──────────────────────────────────────────────────────
const updates = [
  { id: 'u1', kind: 'event', title: 'Agreement to sell executed', body: 'Sale consideration ₹1.2 crore; ₹20 lakh paid as advance.', event_date: '2023-01-15', created_at: '2026-09-01 10:00:00', source: 'manual', source_ref: null },
  { id: 'u2', kind: 'event', title: 'Legal notice sent', body: '', event_date: '2024-03-02', created_at: '2026-09-01 10:01:00', source: 'ai', source_ref: 'Notice.pdf, p. 1' },
  { id: 'u3', kind: 'filing', title: 'Suit filed:', body: 'Plaint with documents.', event_date: '2024-06-10', created_at: '2026-09-01 10:02:00', source: 'manual' },
  { id: 'u4', kind: 'note', title: 'Call client before the hearing', body: '', event_date: '2026-08-11', created_at: '2026-09-01 10:03:00', source: 'manual' },
  { id: 'u5', kind: 'task', title: 'Draft rejoinder', body: '', event_date: '2026-08-20', created_at: '2026-09-01 10:04:00', source: 'manual' },
  { id: 'u6', kind: 'hearing', title: 'Listed — FOR ARGUMENTS', body: '', event_date: '2026-08-12', created_at: '2026-08-12 06:00:00', source: 'court' },
  { id: 'u7', kind: 'milestone', title: '', body: 'Issues framed by the court', event_date: '2025-02-20', created_at: '2026-09-01 10:05:00', source: 'manual' },
  { id: 'u8', kind: 'event', title: 'Undated thought', body: 'No date yet', event_date: null, created_at: null, source: 'manual' },
  { id: 'u9', kind: 'order', title: 'Interim order noted', body: 'Status quo', event_date: '2026-08-12T18:30:00Z', created_at: '2026-08-13 09:00:00', source: 'manual' },
  { id: 'u10', kind: 'event', title: 'Rejoinder due', body: '', event_date: '2026-11-02', created_at: '2026-09-01 10:06:00', source: 'manual' },
  { id: 'u11', kind: 'event', title: 'Earlier note', body: '', event_date: null, created_at: '2026-01-05 20:00:00', source: 'manual' },
]
const courtHistory = [
  { id: 'c1', section: 'hearings', title: 'FOR ARGUMENTS', subtitle: null, item_date: '2026-08-12', status: null, source: 'scrape', data: { courtNo: 'COURT NO. 4', itemNo: 12, coram: "HON'BLE MR. JUSTICE A. KUMAR", time: '10:30 AM' } },
  { id: 'c2', section: 'hearings', title: 'Listing', subtitle: 'Justice B', item_date: '2025-11-03', status: null, source: 'scrape', data: { courtNo: 'Registrar Court 1', remarks: 'Adjourned' } },
  { id: 'c3', section: 'orders', title: 'O', subtitle: null, item_date: '2025-11-03', status: null, source: 'scrape', data: { type: 'Interim Order', url: 'https://example.test/o1.pdf' } },
  { id: 'c4', section: 'orders', title: 'Order dated 12.08.2026', subtitle: null, item_date: '2026-08-12', status: null, source: 'scrape', data: { type: 'order' } },
  { id: 'c5', section: 'hearings', title: 'TO BE LISTED IN COURT NO.42)', subtitle: null, item_date: '2026-10-28', status: null, source: 'scrape', data: null },
  { id: 'c6', section: 'documents', title: 'Vakalatnama', item_date: '2024-06-10', data: {} },
  { id: 'c7', section: 'orders', title: '', subtitle: null, item_date: '2024-09-09', status: null, source: 'scrape', data: '{"title":"J"}' },
  { id: 'c8', section: 'hearings', title: 'Mention', item_date: null, data: {} },
  { id: 'c9', section: 'hearings', title: 'listing', subtitle: null, item_date: '2024-09-09', source: 'scrape', data: { bench: 'DB-II', purpose: 'For orders', itemNo: '0' } },
]
const entries = R.chronologyEntries(updates, courtHistory)
const strip = (e) => ({ key: e.key, id: e.id, src: e.src, own: e.own, kind: e.kind, day: e.day, title: e.title, body: e.body, sourceRef: e.sourceRef, created: e.created, eventText: R.eventText(e) })

// ── List of Dates & Events ───────────────────────────────────────────────────
const linkedCase = { id: 'lc1', court_name: 'High Court of Delhi', case_type: 'CS(OS)', case_number: '512', case_year: '2024', next_hearing_date: '2026-10-28' }
const projects = [
  { name: 'Acme v. Beta', client: 'Acme Private Limited', opposite_party: 'Beta Builders LLP', our_side: 'plaintiff', forum_name: 'High Court of Delhi at New Delhi', case_type: 'CS(OS)', case_number: '512', case_year: '2024' },
  { name: 'Beta matter', client: 'Beta & Sons', opposite_party: 'State <of> "Delhi"', our_side: 'Respondent', forum_name: '', case_type: 'W.P.(C)', case_number: 'W.P.(C) 1234', case_year: '2026' },
  { name: '', client: 'Only client', opposite_party: '', our_side: 'petitioner', forum_name: 'NCLT', case_number: '' },
  { name: 'Odd side', client: 'A', opposite_party: 'B', our_side: 'other', case_number: 'IA No. 77/2025' },
]
// The web's default selection (`EXPORT_GROUPS`): the user's entries, the AI's, the court's
// orders — not every listing, not notes and tasks.
const defaultPick = entries.filter(e => e.day && !(e.own && (e.kind === 'note' || e.kind === 'task')) && !(e.src === 'court' && e.kind === 'hearing'))
const exports = [
  { name: 'default-selection', project: projects[0], linkedCase, pick: defaultPick },
  { name: 'everything', project: projects[0], linkedCase, pick: entries },
  { name: 'respondent-escaped', project: projects[1], linkedCase: null, pick: defaultPick },
  { name: 'no-forum-falls-to-case', project: projects[2], linkedCase, pick: entries.filter(e => e.src === 'court') },
  { name: 'unknown-side', project: projects[3], linkedCase: null, pick: [] },
].map(x => ({ name: x.name, project: x.project, linkedCase: x.linkedCase, keys: x.pick.map(e => e.key), html: R.listOfDatesHtml({ project: x.project, linkedCase: x.linkedCase, entries: x.pick }) }))

// ── Next hearing ─────────────────────────────────────────────────────────────
const today = '2026-10-19'
const nextHearings = [
  { project: { next_hearing_date: '2026-10-25' }, linkedCase: { next_hearing_date: '2026-10-28' } },
  { project: { next_hearing_date: '2026-10-30' }, linkedCase: { next_hearing_date: '2026-10-28' } },
  { project: { next_hearing_date: '2026-10-19' }, linkedCase: null },
  { project: { next_hearing_date: '2026-09-01' }, linkedCase: { next_hearing_date: '2026-08-12' } },
  { project: { next_hearing_date: '2026-10-28' }, linkedCase: { next_hearing_date: '2026-10-28' } },
  { project: {}, linkedCase: {} },
].map(x => {
  const n = R.nextHearing({ project: x.project, linkedCase: x.linkedCase, courtHistory }, today)
  return { ...x, next: n && { day: n.day, from: n.from, days: n.days, listing: n.listing?.id ?? null, latest: n.latest?.id ?? null } }
})

// ── The Overview timeline (vertical) ─────────────────────────────────────────
// Mirrors `Timeline` in OverviewSection.jsx: the record's dated entries up to today, tasks left
// out, newest first; the next hearing on top when it is today or later; a year marker wherever
// the year changes; the side flips on every row's index, year markers counted.
function timeline(project, lc, day) {
  const next = R.nextHearing({ project, linkedCase: lc, courtHistory }, day)
  const list = R.sortChronology(entries.filter(e => e.day && e.kind !== 'task' && e.day <= day), true)
  const upcoming = next && next.days >= 0 ? next : null
  const rows = []
  if (upcoming) rows.push({ next: true, i: 0, date: R.fmtDay(upcoming.day), title: 'Next hearing', sub: helpers.awayText(upcoming.days) })
  let year = null
  const marked = []
  list.forEach((e) => {
    const y = e.day.slice(0, 4)
    if (y !== year) { marked.push({ year: y }); year = y }
    marked.push({ e })
  })
  marked.forEach((r, idx) => {
    if (r.year) { rows.push({ year: r.year }); return }
    const title = helpers.entryText(r.e)
    rows.push({ key: r.e.key, i: idx + (upcoming ? 1 : 0), kind: r.e.kind, src: r.e.src,
      date: R.fmtDay(r.e.day).replace(/ \d{4}$/, ''), title, sub: helpers.kindSub(r.e, title) })
  })
  return rows
}

const fixture = JSON.stringify({
  today,
  updates,
  courtHistory,
  entries: entries.map(strip),
  oldestFirst: R.sortChronology(entries, false).map(e => e.key),
  newestFirst: R.sortChronology(entries, true).map(e => e.key),
  exports,
  nextHearings,
  timeline: [
    { name: 'with-next-hearing', day: today, project: { next_hearing_date: '2026-10-25' }, linkedCase, rows: timeline({ next_hearing_date: '2026-10-25' }, linkedCase, today) },
    { name: 'next-hearing-passed', day: '2026-11-05', project: {}, linkedCase, rows: timeline({}, linkedCase, '2026-11-05') },
    { name: 'early-day', day: '2024-12-31', project: {}, linkedCase: null, rows: timeline({}, null, '2024-12-31') },
  ],
  plainCourtText: ['TO BE LISTED IN COURT NO.42)', 'For arguments', 'LISTED IN COURT NO 7', 'AB', '  mixed   Case court no. 3 '].map(t => ({ in: t, out: R.plainCourtText(t) })),
  orderTitle: ['O', 'j', 'OJ', ' Judgment  dated ', ''].map(t => ({ in: t, out: R.orderTitle(t) })),
  fmtDots: ['2026-08-12', '2026-08-12T20:00:00Z', '2026-08-12 20:00:00', '', 'soon'].map(t => ({ in: t, out: R.fmtDots(t) })),
}, null, 1) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === fixture) {
  console.log(`record.json is current — ${entries.length} entries, ${exports.length} exports`)
} else {
  console.log(`${before === null ? 'new' : 'changed'}  record.json — ${entries.length} entries, ${exports.length} exports`)
  if (checkOnly) process.exit(1)
  fs.mkdirSync(outDir, { recursive: true })
  fs.writeFileSync(out, fixture)
}
