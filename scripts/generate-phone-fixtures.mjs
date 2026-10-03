#!/usr/bin/env node
// Regenerates Tests/EmperorCoreTests/Resources/phone.json from the platform's own phone rules.
//
//   node scripts/generate-phone-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The app normalises a mobile number before sending it, and the server validates it with
// `src/lib/phone.js`. The two must agree on every shape a person types, so the expectations come
// from running that file — never from anyone's reading of it.
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const source = platform && path.join(platform, 'src/lib/phone.js')
if (!source || !fs.existsSync(source)) {
  console.error('usage: generate-phone-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const phone = await import(pathToFileURL(source).href)
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/phone.json')

const inputs = [
  '', ' ', 'abc', '9876543210', '98765 43210', '+91 98765 43210', '+91-98765-43210',
  '+919876543210', '919876543210', '91 98765 43210', '098765 43210', '09876543210',
  '0091 98765 43210', '+91 098765 43210', '+91 91234 56789', '9123456789', '91234 56789',
  '9198765432', '987654321', '98765', '9876', '5876543210', '1234567890', '7000000000',
  '6000000000', '98765abc43210', '₹9,876,543,210', '(987) 654-3210', '+1 415 555 0100',
  '９８７６５４３２１０', '९८७६५४३२१०', '98765432101234', '  +91 98765 43210  ',
  '+91', '91', '0', '00', '+', '+9', '+91 9', '9 8 7 6 5 4 3 2 1 0',
]
const cases = inputs.map(input => ({
  input,
  normalized: phone.normalizeIndianPhone(input),
  valid: phone.isValidIndianMobile(input),
  api: phone.phoneForApi(input),
  local: phone.formatIndianPhoneLocal(input),
}))
const text = JSON.stringify(cases, null, 1) + '\n'
const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === text) { console.log(`${cases.length} cases, unchanged`); process.exit(0) }
if (checkOnly) { console.log('phone.json differs from the platform'); process.exit(1) }
fs.writeFileSync(out, text)
console.log(`${cases.length} cases written`)
