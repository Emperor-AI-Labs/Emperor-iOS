#!/usr/bin/env node
// Regenerates the role-card deck and its golden fixtures from the platform's own source.
//
//   node scripts/generate-role-card-fixtures.mjs <path-to-emperor-ai> [--check]
//
// Every role but Litigator opens on a deck of cards (`src/roles/*Cards.js`), and each card resolves
// to a synthetic tool through a prefix in `src/tools/registry.js` (`getTool`): `scdoc-` Senior
// Counsel, `adoc-` Arbitrators & Judges, `cdoc-` Corporate Counsel, `sdoc-` Student, `pdoc-`
// Paralegal, `ndoc-` Legal Aid, `dadv-` Devil's Advocate. This script writes three things, and all
// of them come from running that JavaScript rather than reading it:
//
//   - Sources/EmperorCore/Tools/RoleCards.swift — the data: every card, each grid's filter (mode,
//     tag, level or context) and each grouped grid's section order. The resolvers in
//     `RoleCardTools.swift` are hand-ported code; this is what they read.
//   - Tests/EmperorCoreTests/Resources/cards/<toolId>_{empty,filled}.txt — each card's prompt on an
//     empty form and on a filled one (the filled rule is `RoleCardGoldenTests.filled`: the first
//     option for a select, "test <key>" otherwise).
//   - Tests/EmperorCoreTests/Resources/cards/guardrail_devil_<mode>.txt — the Devil's Advocate
//     guardrail the web appends to every tool prompt while that role is active (`devilLine` in
//     `src/tools/ToolWorkspace.jsx`). ToolWorkspace is a React component and cannot be imported
//     here, so the one expression is cut out of it by name and evaluated with the store values it
//     reads; nothing in it is retyped.
//
// The modules are imported for real, under Node, with the stand-in `generate-tool-fixtures.mjs`
// uses: `lucide-react` is the web's icon set, and each icon name resolves to a placeholder string,
// because no prompt reads an icon.
//
// `--check` writes nothing and exits 1 if any output differs — the way to ask "has the platform
// moved since these were made?" without touching the tree.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/tools/registry.js'))) {
  console.error('usage: generate-role-card-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const out = path.join(root, 'Tests/EmperorCoreTests/Resources/cards')
const swiftFile = path.join(root, 'Sources/EmperorCore/Tools/RoleCards.swift')

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
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

// Pinned clock, as the other generators: 2026-09-03 12:00 IST. No card reads it.
const FIXED = Date.UTC(2026, 8, 3, 6, 30, 0)
const RealDate = Date
globalThis.Date = class extends RealDate {
  constructor(...args) { if (args.length === 0) super(FIXED); else super(...args) }
  static now() { return FIXED }
}

const mod = (rel) => import(pathToFileURL(path.join(src, rel)).href)
const { getTool } = await mod('tools/registry.js')
const counsel = await mod('roles/counselCards.js')
const adjudicator = await mod('roles/adjudicatorCards.js')
const corporate = await mod('roles/corporateCards.js')
const student = await mod('roles/studentCards.js')
const paralegal = await mod('roles/paralegalCards.js')
const ngo = await mod('roles/ngoCards.js')
const devil = await mod('roles/devilCards.js')

// The decks in the order RoleCards.swift has always listed them; Devil's Advocate is last.
// `capabilities` marks a deck whose `kind: 'capability'` cards this app routes to its own screen
// (`RoleCard.capability`). Devil's Advocate's Limitation card opens the Limitation Radar. Corporate
// Counsel's one capability card (`compliance-calendar`) is not routed that way yet, so its entry
// stays a plain card, as it always has been here.
const DECKS = [
  { swift: 'seniorCounsel', prefix: 'scdoc-', m: counsel },
  { swift: 'adjudicator', prefix: 'adoc-', m: adjudicator, filters: adjudicator.MODES, sections: adjudicator.SECTIONS },
  { swift: 'corporateCounsel', prefix: 'cdoc-', m: corporate, filters: corporate.TAGS, sections: corporate.SECTIONS },
  { swift: 'student', prefix: 'sdoc-', m: student, filters: student.LEVELS },
  { swift: 'paralegal', prefix: 'pdoc-', m: paralegal, filters: paralegal.CONTEXTS },
  { swift: 'legalAid', prefix: 'ndoc-', m: ngo, filters: ngo.MODES, sections: ngo.SECTIONS },
  { swift: 'devilsAdvocate', prefix: 'dadv-', m: devil, filters: devil.MODES, sections: devil.SECTIONS,
    capabilities: true },
]

const outputs = []   // [file, text]
const fixtureNames = new Set()

// ── Prompts ──────────────────────────────────────────────────────────────────────────────────
for (const deck of DECKS) {
  for (const card of deck.m.CARDS) {
    const id = `${deck.prefix}${card.id}`
    const tool = getTool(id)
    if (!tool) throw new Error(`getTool('${id}') resolved nothing`)
    const filled = {}
    for (const field of tool.inputs || []) {
      if (Array.isArray(field.options) && field.options.length) {
        const first = field.options[0]
        filled[field.key] = typeof first === 'object' ? (first.value ?? first.label) : first
      } else filled[field.key] = `test ${field.key}`
    }
    fixture(`${id}_empty`, tool.buildPrompt({}))
    fixture(`${id}_filled`, tool.buildPrompt(filled))
  }
}

// ── The Devil's Advocate guardrail ──────────────────────────────────────────────────────────
const workspace = fs.readFileSync(path.join(src, 'tools/ToolWorkspace.jsx'), 'utf8')
const devilExpr = cutExpression(workspace, 'const devilLine =')
const devilLine = new Function('st', 'DEVIL_MODE_LABEL', `return (${devilExpr})`)
fixture('guardrail_devil_opposition', devilLine({ uiRole: 'devil', devilMode: 'opposition' }, devil.MODE_LABEL))
fixture('guardrail_devil_our-side', devilLine({ uiRole: 'devil', devilMode: 'our-side' }, devil.MODE_LABEL))
// The store's default before a mode is ever chosen.
fixture('guardrail_devil_unset', devilLine({ uiRole: 'devil' }, devil.MODE_LABEL))
// Any other role: nothing.
if (devilLine({ uiRole: 'litigator' }, devil.MODE_LABEL) !== '') throw new Error('devilLine fires outside the role')

// ── The Swift data ───────────────────────────────────────────────────────────────────────────
outputs.push([swiftFile, renderSwift()])

let changed = 0
for (const [file, text] of outputs) {
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null
  if (before === text) continue
  changed++
  console.log(`${before === null ? 'new' : 'changed'}  ${path.relative(root, file)}`)
  if (!checkOnly) fs.writeFileSync(file, text)
}
const stale = fs.readdirSync(out).filter(f => f.endsWith('.txt') && !fixtureNames.has(f.slice(0, -4)))
for (const f of stale) console.log(`not produced by the platform any more  ${f}`)
console.log(`${outputs.length} outputs, ${changed} ${checkOnly ? 'differ' : 'written'}`)
if (checkOnly && (changed || stale.length)) process.exit(1)

// ── Helpers ──────────────────────────────────────────────────────────────────────────────────

function fixture(name, text) {
  if (typeof text !== 'string') throw new Error(`${name} is not a string`)
  fixtureNames.add(name)
  outputs.push([path.join(out, `${name}.txt`), text])
}

function renderSwift() {
  const str = (v) => JSON.stringify(v)   // a JSON string literal is a valid Swift one for this text
  const opt = (v) => (v === undefined || v === null) ? 'nil' : str(v)
  const list = (a) => `[${(a || []).map(str).join(', ')}]`
  const lines = []
  lines.push(`// Generated from the platform's own card modules — do not edit by hand.
//
// Produced by evaluating src/roles/*Cards.js and src/tools/registry.js under Node, the
// same way the twenty-nine tool prompts were pinned. If a card changes on the platform,
// regenerate this file and its fixtures rather than editing either to match: the
// fixture is the contract and this is the copy.

import Foundation

let ROLE_CARDS: [RoleCard] = [`)
  for (const deck of DECKS) {
    for (const c of deck.m.CARDS) {
      const filters = c.modes || c.tags || c.levels || c.contexts || []
      const capability = deck.capabilities && c.kind === 'capability'
      const entry = [
        `    RoleCard(`,
        `        id: ${str(c.id)}, role: .${deck.swift},`,
        `        title: ${str(c.title)},`,
        `        subtitle: ${opt(c.subtitle)},`,
        `        section: ${opt(c.section)},`,
        `        output: .${c.output || 'document'},`,
        `        isSafetyFirst: ${c.safety ? 'true' : 'false'},`,
        `        filters: ${list(filters)},`,
        `        dropdown: ${list(c.dropdown)},`,
        `        note: ${str(c.note || '')}${capability ? ',' : ''}`,
      ]
      // A card that opens one of the app's own screens rather than a prompt.
      if (capability) entry.push(`        capability: ${str(c.tool)}`)
      entry.push(`    ),`)
      lines.push(...entry)
    }
  }
  lines.push(`]

/// The filter each role's card grid offers, in the platform's order.
let ROLE_CARD_FILTERS: [PractitionerRole: [RoleCardFilter]] = [`)
  for (const deck of DECKS.filter(d => d.filters)) {
    lines.push(`    .${deck.swift}: [`)
    for (const f of deck.filters) lines.push(`        RoleCardFilter(id: ${str(f.id)}, label: ${str(f.label)}),`)
    lines.push(`    ],`)
  }
  lines.push(`]

/// Section order for the roles whose grids are grouped.
let ROLE_CARD_SECTIONS: [PractitionerRole: [String]] = [`)
  for (const deck of DECKS.filter(d => d.sections)) lines.push(`    .${deck.swift}: ${list(deck.sections)},`)
  lines.push(`]`)
  return lines.join('\n') + '\n'
}

// The source of `<marker> <expression>` up to the statement's end. Brackets, strings and template
// literals (with their `${…}` holes) are matched, so a `?:` spread over several lines comes out
// whole.
function cutExpression(text, marker) {
  const at = text.indexOf(marker)
  if (at < 0) throw new Error(`${marker} not found`)
  const start = at + marker.length
  const stack = []   // '(' '[' '{' for brackets, '`' inside a template, '${' inside a hole
  let i = start
  for (; i < text.length; i++) {
    const ch = text[i]
    const top = stack[stack.length - 1]
    if (top === '`') {
      if (ch === '\\') i++
      else if (ch === '`') stack.pop()
      else if (ch === '$' && text[i + 1] === '{') { stack.push('${'); i++ }
      continue
    }
    if (ch === "'" || ch === '"') {
      for (i++; i < text.length && text[i] !== ch; i++) if (text[i] === '\\') i++
      continue
    }
    if (ch === '`') stack.push('`')
    else if (ch === '(' || ch === '[' || ch === '{') stack.push(ch)
    else if (ch === ')' || ch === ']' || ch === '}') stack.pop()
    else if (ch === '\n' && stack.length === 0) {
      // A statement ends at a newline whose next line does not continue the expression.
      if (!/^[?:+]/.test(text.slice(i + 1).trimStart())) break
    }
  }
  return text.slice(start, i).trim()
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) { if (entry.name !== 'node_modules') yield* walk(p) }
    else if (/\.(jsx?|mjs)$/.test(entry.name)) yield p
  }
}
