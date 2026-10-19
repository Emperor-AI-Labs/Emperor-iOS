#!/usr/bin/env node
// Regenerates the Corporate Calendar's statutory-schedule golden fixture from the platform.
//
//   node scripts/generate-compliance-schedule-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web generates a company's statutory deadlines in the browser, from
// `src/lib/complianceSchedule.js` (`generateComplianceEvents`), for whichever company profile the
// user has described. `ComplianceSchedule.swift` is a port of that module, held to it here.
//
// Tests/EmperorCoreTests/Resources/compliance-schedule/schedule.json records, from running it:
//   - `obligations` — `COMPLIANCE_OBLIGATIONS` without the `applies` functions (their effect is
//     pinned by the cases below), `categoryOrder`, `ptStates`, `indianStates`, `newCompany('')`.
//   - `cases` — `generateComplianceEvents({from, to, profile})` for a spread of profiles (nothing
//     on, each switch on alone, everything on, AGM dates that cross a year end, a missing AGM
//     date) and windows (the page's own −60/+366 days around a day, a leap year, a year end).
//     Each event is kept as its id (`stat:<obligation>:<YYYY-MM-DD>`) and, where the month
//     overrides the usual day, its note; everything else on an event is its obligation's.
//     `summary` is `profileSummary(profile)`.
//
// The module builds dates from local Y/M/D parts, so the zone is fixed to UTC to keep the run
// reproducible. `--check` writes nothing and exits 1 if the fixture differs.

process.env.TZ = 'UTC'

import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const modulePath = platform && path.join(platform, 'src/lib/complianceSchedule.js')
if (!platform || !fs.existsSync(modulePath)) {
  console.error('usage: generate-compliance-schedule-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const outDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/compliance-schedule')
const out = path.join(outDir, 'schedule.json')

// The module imports nothing, so it is loaded as a data: URL of its own source — the platform's
// package.json is not needed to say it is ESM.
const source = fs.readFileSync(modulePath, 'utf8')
const S = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'))

const day = (key) => { const [y, m, d] = key.split('-').map(Number); return new Date(y, m - 1, d) }
const addDays = (key, n) => { const x = day(key); x.setDate(x.getDate() + n); return x }
const keyOf = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

const base = S.newCompany('Acme Private Limited')
const profiles = [
  { name: 'nothing-on', profile: base },
  { name: 'listed', profile: { ...base, listed: true } },
  { name: 'employees-pt-state', profile: { ...base, hasEmployees: true, state: 'Maharashtra' } },
  { name: 'employees-no-pt-state', profile: { ...base, hasEmployees: true, state: 'Delhi' } },
  { name: 'employees-no-state', profile: { ...base, hasEmployees: true } },
  { name: 'gst', profile: { ...base, gstRegistered: true } },
  { name: 'foreign', profile: { ...base, foreignDealings: true } },
  { name: 'tax-audit', profile: { ...base, taxAudit: true } },
  { name: 'csr', profile: { ...base, csr: true } },
  { name: 'everything', profile: { ...base, listed: true, hasEmployees: true, gstRegistered: true, foreignDealings: true, taxAudit: true, csr: true, state: 'Karnataka' } },
  { name: 'agm-year-end', profile: { ...base, gstRegistered: true, agmMonth: 12, agmDay: 31 } },
  { name: 'agm-january', profile: { ...base, csr: true, agmMonth: 1, agmDay: 31 } },
  { name: 'agm-missing', profile: { ...base, agmMonth: 0, agmDay: 0 } },
  { name: 'default-profile', profile: S.DEFAULT_PROFILE },
]
// The page's own window is India's today −60 to +366 days (`ComplianceCalendar.jsx`).
const windows = [
  { name: 'page-window-2026-10-19', from: keyOf(addDays('2026-10-19', -60)), to: keyOf(addDays('2026-10-19', 366)) },
  { name: 'leap-year-2024', from: '2024-01-01', to: '2024-12-31' },
  { name: 'year-end-2027', from: '2027-12-15', to: '2028-03-05' },
  { name: 'one-day', from: '2026-10-31', to: '2026-10-31' },
]

const cases = []
for (const w of windows) {
  for (const p of profiles) {
    // Every profile over the page window; the other windows over a few that exercise them.
    if (w.name !== 'page-window-2026-10-19' && !['nothing-on', 'everything', 'agm-year-end', 'agm-january', 'agm-missing'].includes(p.name)) continue
    const events = S.generateComplianceEvents({ from: day(w.from), to: day(w.to), profile: p.profile })
    cases.push({
      name: `${w.name}/${p.name}`,
      from: w.from,
      to: w.to,
      profile: p.profile,
      summary: S.profileSummary(p.profile),
      events: events.map(e => e.overrideNote ? { id: e.id, overrideNote: e.overrideNote } : { id: e.id }),
    })
  }
}

const fixture = JSON.stringify({
  categoryOrder: S.CATEGORY_ORDER,
  categoryLabels: Object.fromEntries(S.CATEGORY_ORDER.map(k => [k, S.CATEGORY_META[k].label])),
  ptStates: S.PT_STATES,
  indianStates: S.INDIAN_STATES,
  newCompany: S.newCompany(''),
  obligations: S.COMPLIANCE_OBLIGATIONS.map(({ applies, ...ob }) => ({ ...ob, conditional: !!applies })),
  cases,
}, null, 1) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === fixture) {
  console.log(`schedule.json is current — ${S.COMPLIANCE_OBLIGATIONS.length} obligations, ${cases.length} cases`)
} else {
  console.log(`${before === null ? 'new' : 'changed'}  schedule.json — ${cases.length} cases`)
  if (checkOnly) process.exit(1)
  fs.mkdirSync(outDir, { recursive: true })
  fs.writeFileSync(out, fixture)
}
