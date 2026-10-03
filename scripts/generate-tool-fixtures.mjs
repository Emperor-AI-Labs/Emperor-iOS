#!/usr/bin/env node
// Regenerates the tool-prompt golden fixtures from the platform's own source.
//
//   node scripts/generate-tool-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The fixtures in Tests/EmperorCoreTests/Resources/tools/ are the contract the Swift port is held
// to, character for character. They have to come from the platform's JavaScript, not from anyone's
// reading of it: these prompts are tens of thousands of characters of procedural checklist, and a
// dropped clause is a tool that silently stops covering the objection it exists to catch.
//
// The registry is imported for real, under Node, with two stand-ins and nothing else:
//   - `lucide-react` is the web's icon set. A prompt never reads an icon, so each name the
//     platform imports resolves to a placeholder string.
//   - the clock is pinned to 3 September 2026, noon in India, because Caseflow writes today's
//     date into its prompt and the fixtures must not change daily. `ToolGoldenTests.today` is the
//     same day.
//
// `--check` writes nothing and exits 1 if any fixture differs — the way to ask "has the platform
// moved since these were made?" without touching the tree.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/tools/registry.js'))) {
  console.error('usage: generate-tool-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/tools')

// Every icon name the platform imports from lucide-react, so the stand-in can export each one.
const iconNames = new Set()
for (const file of walk(src)) {
  const text = fs.readFileSync(file, 'utf8')
  for (const m of text.matchAll(/import\s*\{([^}]*)\}\s*from\s*['"]lucide-react['"]/g)) {
    for (const part of m[1].split(',')) {
      const name = part.trim().split(/\s+as\s+/)[0].trim()
      if (/^[A-Za-z_$][\w$]*$/.test(name)) iconNames.add(name)
    }
  }
}
const lucideStub = [...iconNames].map(n => `export const ${n} = '${n}';`).join('\n')

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'lucide-react') return { url: 'emperor-stub:lucide', shortCircuit: true }
    let target = null
    if (specifier.startsWith('@/')) target = path.join(src, specifier.slice(2))
    else if (specifier.startsWith('.') && context.parentURL?.startsWith('file:')) {
      target = path.resolve(path.dirname(fileURLToPath(context.parentURL)), specifier)
    }
    if (target) {
      for (const candidate of [target, `${target}.js`, `${target}.jsx`, path.join(target, 'index.js')]) {
        if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
          return { url: pathToFileURL(candidate).href, shortCircuit: true }
        }
      }
    }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (url === 'emperor-stub:lucide') return { format: 'module', source: lucideStub, shortCircuit: true }
    // The platform's package.json may not declare "type": "module"; its sources are ESM regardless.
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

// Pinned clock: 2026-09-03 12:00 IST.
const FIXED = Date.UTC(2026, 8, 3, 6, 30, 0)
const RealDate = Date
globalThis.Date = class extends RealDate {
  constructor(...args) { if (args.length === 0) super(FIXED); else super(...args) }
  static now() { return FIXED }
}

const { TOOLS } = await import(pathToFileURL(path.join(src, 'tools/registry.js')).href)
const { ANALYSIS_TOOLS } = await import(pathToFileURL(path.join(src, 'tools/definitions/index.js')).href)

const fixtures = {}

// The registry tools: an empty form, and a filled one built by the rule `ToolGoldenTests.filled`
// uses — first option for a select, "test <key>" otherwise, Hindi for a language field.
for (const [id, tool] of Object.entries(TOOLS)) {
  if (ANALYSIS_TOOLS[id]) continue
  if (typeof tool.buildPrompt !== 'function') continue
  fixtures[`${id}_empty`] = tool.buildPrompt({})
  const filled = {}
  for (const field of tool.inputs || []) {
    if (field.key === 'lang') filled[field.key] = 'Hindi'
    else if (Array.isArray(field.options) && field.options.length) {
      const first = field.options[0]
      filled[field.key] = typeof first === 'object' ? (first.value ?? first.label) : first
    } else filled[field.key] = `test ${field.key}`
  }
  fixtures[`${id}_filled`] = tool.buildPrompt(filled)
}

// The five analysis tools take their own input shapes, so their cases are the specific answers
// `ToolGoldenTests` asks with.
const A = ANALYSIS_TOOLS
fixtures['list-of-dates_full'] = A['list-of-dates'].buildPrompt({
  format: 'Limitation Chronology', forum: 'NCLT', party: 'the Petitioner', focus: 'The 2019 invoices only.',
})
fixtures['list-of-dates_empty'] = A['list-of-dates'].buildPrompt({})
fixtures['blind-spots_litigation'] = A['blind-spots'].buildPrompt({
  docKind: 'Writ Petition', side: 'the Petitioner', material: 'Para 1. The impugned order.', worry: 'Limitation.',
})
fixtures['blind-spots_contract'] = A['blind-spots'].buildPrompt({ docKind: 'Contract / Agreement', side: 'the Buyer' })
fixtures['blind-spots_empty'] = A['blind-spots'].buildPrompt({})
fixtures['highlighter_empty'] = A.highlighter.buildPrompt({})
fixtures['highlighter_scoped'] = A.highlighter.buildPrompt({
  extract: 'Caps, Indemnity Limits & Carve-outs', party: 'the Buyer', hunt: 'the liability cap',
  source: 'Clause 9.2 caps liability at INR 5,00,00,000.',
})
fixtures['highlighter_custom'] = A.highlighter.buildPrompt({ extract: 'Something I typed myself' })
fixtures['doc-index_empty'] = A['doc-index'].buildPrompt({})
fixtures['doc-index_full'] = A['doc-index'].buildPrompt({
  deliverable: 'Contradictions & discrepancies', recordType: 'Title deeds & property chain',
  matter: 'Sterling v NHAI', focus: 'The principal amount.', source: 'D1 text',
})
fixtures['caseflow_ason'] = A.caseflow.buildPrompt({
  deliverable: 'Client Status Note', party: 'Appellant', asOn: '08.12.2026', context: 'Order sheet attached.',
})
fixtures['caseflow_today'] = A.caseflow.buildPrompt({})

let changed = 0
for (const [name, text] of Object.entries(fixtures).sort()) {
  const file = path.join(out, `${name}.txt`)
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null
  if (before === text) continue
  changed++
  console.log(`${before === null ? 'new' : 'changed'}  ${name}`)
  if (!checkOnly) fs.writeFileSync(file, text)
}
const stale = fs.readdirSync(out).filter(f => f.endsWith('.txt') && !(f.slice(0, -4) in fixtures))
for (const f of stale) console.log(`not produced by the platform any more  ${f}`)
console.log(`${Object.keys(fixtures).length} fixtures, ${changed} ${checkOnly ? 'differ' : 'written'}`)
if (checkOnly && (changed || stale.length)) process.exit(1)

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) yield* walk(p)
    else if (/\.(js|jsx|mjs)$/.test(entry.name)) yield p
  }
}
