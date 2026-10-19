#!/usr/bin/env node
// Regenerates the fee-receipt golden fixture from the platform's own source.
//
//   node scripts/generate-fee-receipt-fixtures.mjs <path-to-emperor-ai> [--check]
//
// A payment on a matter prints as the receipt an advocate's office issues. The web builds it in
// `src/components/projects/money/receipt.js` (`buildReceiptHtml`, and the helpers that say who it
// is from, to and about) with the rupee helpers of `money/inr.js` (`amountInWordsINR`,
// `rupeesFigure`, `financialYear`, `receiptNumber`). `FeeReceipt.swift` is a port of both, held
// to them here.
//
// Tests/EmperorCoreTests/Resources/fee-receipt/receipt.json records, from running that JavaScript:
//   - `words`, `figures` — amountInWordsINR / rupeesFigure for a spread of amounts in paise
//     (zero, paise alone, each Indian group's edges, crores of crores, the ceiling, a negative).
//   - `financialYears`, `receiptNumbers`, `caseNumbers`, `clients`, `advocates`, `matters`.
//   - `receipts` — the whole HTML document `buildReceiptHtml` returns for a set of payments,
//     with the wire-shaped project, people, user and entry each was built from.
//
// The modules are the same ones the web's own `ledger.selftest.mjs` runs under Node. `--check`
// writes nothing and exits 1 if the fixture differs.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const moneyDir = platform && path.join(platform, 'src/components/projects/money')
if (!platform || !fs.existsSync(path.join(moneyDir, 'receipt.js'))) {
  console.error('usage: generate-fee-receipt-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const outDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/fee-receipt')
const out = path.join(outDir, 'receipt.json')

// The platform's sources are ESM whatever its package.json says.
registerHooks({
  load(url, context, next) {
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

const R = await import(pathToFileURL(path.join(moneyDir, 'receipt.js')).href)
const I = await import(pathToFileURL(path.join(moneyDir, 'inr.js')).href)

const amounts = [0, 1, 50, 99, 100, 101, 1900, 2000, 2100, 9900, 10000, 10100, 99900, 100000, 100100,
  1000000, 9999900, 10000000, 12345678950, 100000000000, 120000000000, 1234567890123, 1e14, 1e14 + 1, -500, 29, 2500005, 500000, 500001]
const words = amounts.map(p => ({ paise: p, text: I.amountInWordsINR(p / 100) }))
const figures = amounts.map(p => ({ paise: p, text: I.rupeesFigure(p / 100) }))
const financialYears = ['2026-03-31', '2026-04-01', '1999-12-31', '2000-01-15', '', 'soon', '2026-10-19T10:00:00Z']
  .map(day => ({ day, text: I.financialYear(day) }))
const receiptNumbers = [
  { id: 'led_m3k9x2_ab12cd', entry_date: '2026-10-01' },
  { id: 'led-1', entry_date: '2026-03-31' },
  { id: '', entry_date: '2026-04-01' },
  { id: 'x_y-z', entry_date: '', created_at: '2025-06-01 10:00:00' },
  { id: 'abcdefghij', entry_date: null },
].map(entry => ({ entry, text: I.receiptNumber(entry) }))
const projects = [
  { name: 'Acme v. Beta', case_type: 'W.P.(C)', case_number: '1234', case_year: '2026', forum_name: 'High Court of Delhi', client: 'Acme Private Limited' },
  { name: 'Suit', case_type: 'CS(OS)', case_number: 'CS(OS) 55', case_year: '2018', forum_name: 'The Saket District Court', client: 'R. Sharma' },
  { name: 'Appeal', case_type: '', case_number: '77/2024', case_year: '2024', forum_name: '', client: '' },
  { name: '  Spaced   name  ', case_number: '', case_year: '2024', client: '  Mehta & Sons  ' },
  { name: '<b>Odd</b> "matter"', case_type: 'O.A.', case_number: '9', forum_name: 'NCLT <Mumbai>', client: 'Tom & Jerry' },
]
const caseNumbers = projects.map(project => ({ project, text: R.caseNumberOf(project) }))
const matters = projects.map(project => ({ project, matter: R.matterFromProject(project) }))
const people = [
  { role: 'client', name: 'acme private limited', address: '12, Nehru Place,\n New Delhi' },
  { role: 'client', name: 'Someone Else', address: 'Elsewhere' },
  { role: 'opposite', name: 'Beta Ltd', address: 'Gurugram' },
]
const clients = [
  { project: projects[0], people },
  { project: projects[2], people },
  { project: projects[2], people: [{ role: 'client', name: '  ', address: 'x' }, people[1]] },
  { project: projects[1], people: [] },
  { project: projects[1], people: null },
].map(c => ({ ...c, client: R.receiptClient(c.project, c.people) }))
const users = [
  { id: 1, name: 'Asha Rao', title: 'Advocate', organization: 'Rao Chambers', phone: '+919876543210', email: 'asha@example.test' },
  { id: 2, name: '', title: '', organization: '', phone: '12345', email: 'clerk@example.test' },
  { id: 3, name: ' Vikram  Seth ', title: 'Senior Advocate', organization: '', phone: '09876543210', email: '' },
  { id: 4 },
]
const advocates = users.map(user => ({ user, advocate: R.advocateFromProfile(user) }))

const entries = [
  { id: 'led_m3k9x2_ab12cd', kind: 'payment', title: '', amount: 25000, amount_paise: 2500000, entry_date: '2026-10-01', mode: 'upi', reference: '41290031', created_at: '2026-10-01 09:00:00' },
  { id: 'led_q1_zz9', kind: 'payment', title: 'Drafting of reply', amount: 4999.5, amount_paise: 499950, entry_date: '2026-03-31', mode: 'cheque', reference: '004512, HDFC Bank', created_at: '2026-04-02 09:00:00' },
  { id: 'led_cash', kind: 'payment', title: 'Appearance fee', amount: 5000, amount_paise: 500000, entry_date: '2026-04-01', mode: 'cash', reference: '', created_at: '' },
  { id: 'led_bank', kind: 'payment', title: '<script>x</script>', amount: 100000.01, amount_paise: 10000001, entry_date: '2026-11-15', mode: 'bank', reference: 'UTR<1>', created_at: '' },
  { id: 'led_card', kind: 'payment', amount: 1200000, entry_date: '', mode: 'card', reference: 'T9', created_at: '2027-01-05 10:00:00' },
  { id: 'led_other', kind: 'payment', title: 'Retainer', amount: 0.5, entry_date: '2026-02-30', mode: 'other', reference: 'note 7' },
  { id: 'led_none', kind: 'payment', title: 'Misc', amount_paise: 7500, entry_date: '2026-12-01' },
]
const receipts = [
  { name: 'upi-full', user: users[0], project: projects[0], people, entry: entries[0] },
  { name: 'cheque-paise-the-forum', user: users[0], project: projects[1], people: [], entry: entries[1] },
  { name: 'cash-at-the-stamp-line', user: users[2], project: projects[1], people: [], entry: entries[2] },
  { name: 'escaped-everything', user: users[1], project: projects[4], people: [{ role: 'client', name: 'Tom & Jerry', address: '"Flat" <3>' }], entry: entries[3] },
  { name: 'card-no-date', user: users[3], project: projects[2], people, entry: entries[4] },
  { name: 'other-mode-bad-date', user: users[0], project: projects[3], people: [], entry: entries[5] },
  { name: 'paise-only-no-mode', user: users[2], project: projects[0], people: [], entry: entries[6] },
].map(c => ({
  ...c,
  html: R.buildReceiptHtml({
    advocate: R.advocateFromProfile(c.user),
    client: R.receiptClient(c.project, c.people),
    matter: R.matterFromProject(c.project),
    entry: c.entry,
  }),
}))

const fixture = JSON.stringify({
  words, figures, financialYears, receiptNumbers, caseNumbers, matters, clients, advocates, receipts,
}, null, 1) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === fixture) {
  console.log(`receipt.json is current — ${receipts.length} receipts`)
} else {
  console.log(`${before === null ? 'new' : 'changed'}  receipt.json — ${receipts.length} receipts`)
  if (checkOnly) process.exit(1)
  fs.mkdirSync(outDir, { recursive: true })
  fs.writeFileSync(out, fixture)
}
