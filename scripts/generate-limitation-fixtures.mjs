#!/usr/bin/env node
// Regenerates the Limitation Radar golden fixture from the platform's own source.
//
//   node scripts/generate-limitation-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The Radar's arithmetic runs on the server, in `src/features/limitation-radar/audit.js`; the web
// page imports the same module for its suit types, so the articles, periods and "time runs from"
// text it offers cannot drift from what the audit applies. This client offers the same list, and
// it must not drift either — so the list is read from that module here, never retyped.
//
// Tests/EmperorCoreTests/Resources/limitation-radar.json records, from running that JavaScript:
//   - `profiles` — `PROFILES`, in the order the web's picker lists them, and `defaultKey`
//     (`DEFAULT_PROFILE`).
//   - `cases` — `auditLimitation(input)` for a spread of timelines: in time, barred, in time only
//     with the mediation exclusion, a capped mediation, mediation begun after expiry, and a
//     mediation with no end date. `computed_at` is a clock reading and is dropped.
//     Each case also carries `display`: the lines the web's result card draws from that output
//     (`src/pages/LimitationRadarPage.jsx`). Its `days` and `longDate` helpers are cut out of the
//     page by name and evaluated, so the pluralisation and the date wording are the platform's;
//     only the choice between the page's sentences is restated here, beside the JSX it mirrors.
//
// `--check` writes nothing and exits 1 if the fixture differs.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const auditPath = platform && path.join(platform, 'src/features/limitation-radar/audit.js')
const pagePath = platform && path.join(platform, 'src/pages/LimitationRadarPage.jsx')
if (!platform || !fs.existsSync(auditPath) || !fs.existsSync(pagePath)) {
  console.error('usage: generate-limitation-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/limitation-radar.json')

// The platform's sources are ESM whatever its package.json says.
registerHooks({
  load(url, context, next) {
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

const { PROFILES, DEFAULT_PROFILE, auditLimitation } = await import(pathToFileURL(auditPath).href)

// The page's two formatting helpers, cut by name. A renamed helper fails here, loudly.
const page = fs.readFileSync(pagePath, 'utf8')
function cut(name) {
  const m = page.match(new RegExp(`const\\s+${name}\\s*=\\s*([\\s\\S]*?)\\n(?=const|function|export)`))
  if (!m) {
    console.error(`${name} not found in src/pages/LimitationRadarPage.jsx`)
    process.exit(1)
  }
  return new Function(`return ${m[1].trim()}`)()
}
const days = cut('days')
const longDate = cut('longDate')

// Mirrors the result card: the line beside the status chip, and the "Statutory framework" rows.
function display(result) {
  const med = result.mediation
  return {
    days: result.relies_on_mediation_exclusion
      ? `${days(result.days_overdue)} late without the exclusion · ${days(-result.adjusted_days_overdue)} remaining with it`
      : result.days_overdue > 0
        ? `${days(result.days_overdue)} past the last day to file`
        : `${days(-result.days_overdue)} remaining`,
    lastDay: longDate(result.bare_deadline),
    mediationExcluded: med
      ? (med.began_after_expiry
        ? 'None — it began after the period had expired'
        : `${days(med.excluded_days)} (${longDate(med.start)} to ${longDate(med.end)}${med.capped ? ', capped at five months' : med.end_assumed ? ', end date assumed' : ''})`)
      : null,
    withExclusion: med && med.excluded_days > 0 ? longDate(result.adjusted_deadline) : null,
  }
}

const inputs = [
  // In time, filed on the very last day: zero days remaining.
  { name: 'safe-on-the-last-day', input: { profile: 'contract_compensation', cause_of_action: '2023-01-15', intended_filing: '2026-01-15' } },
  // A leap-day accrual: three years on is 28 February, and a day after is one day late.
  { name: 'barred-by-one-day', input: { profile: 'specific_performance', cause_of_action: '2020-02-29', intended_filing: '2023-03-01' } },
  // Barred, and the mediation exclusion does not save it.
  { name: 'barred-despite-mediation', input: { profile: 'contract_compensation', cause_of_action: '2021-01-01', intended_filing: '2024-06-01', mediation_start: '2023-10-01', mediation_end: '2023-11-01' } },
  // In time only with the Section 12A exclusion.
  { name: 'mediation-only', input: { profile: 'contract_compensation', cause_of_action: '2022-01-10', intended_filing: '2025-03-01', mediation_start: '2024-11-01', mediation_end: '2025-02-15' } },
  // Mediation longer than five months is capped.
  { name: 'capped-mediation', input: { profile: 'contract_compensation', cause_of_action: '2022-01-10', intended_filing: '2025-05-01', mediation_start: '2024-06-01', mediation_end: '2025-03-01' } },
  // Mediation begun after the period expired excludes nothing.
  { name: 'began-after-expiry', input: { profile: 'residuary', cause_of_action: '2020-01-01', intended_filing: '2023-05-01', mediation_start: '2023-03-01', mediation_end: '2023-04-01' } },
  // No end date: taken to run to the filing date or the cap.
  { name: 'end-assumed', input: { profile: 'contract_compensation', cause_of_action: '2022-01-10', intended_filing: '2025-02-01', mediation_start: '2024-12-01' } },
  // In time without the exclusion; it is mentioned but not needed. No profile: the default.
  { name: 'safe-exclusion-not-needed', input: { cause_of_action: '2023-06-01', intended_filing: '2024-06-01', mediation_start: '2024-01-01', mediation_end: '2024-02-01' } },
]

const cases = inputs.map(({ name, input }) => {
  const { computed_at, ...output } = auditLimitation(input)
  return { name, input, output, display: display(output) }
})

const fixture = JSON.stringify({
  profiles: Object.values(PROFILES).map(({ key, label, article, years, runsFrom }) => ({ key, label, article, years, runsFrom })),
  defaultKey: DEFAULT_PROFILE,
  cases,
}, null, 2) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === fixture) {
  console.log(`limitation-radar.json is current — ${Object.keys(PROFILES).length} profiles, ${cases.length} cases`)
} else {
  console.log(`${before === null ? 'new' : 'changed'}  limitation-radar.json`)
  if (checkOnly) process.exit(1)
  fs.writeFileSync(out, fixture)
}
