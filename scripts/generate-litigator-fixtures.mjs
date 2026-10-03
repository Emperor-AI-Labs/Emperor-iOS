#!/usr/bin/env node
// Regenerates the Litigator drafting taxonomy and its golden fixtures from the platform's own source.
//
//   node scripts/generate-litigator-fixtures.mjs <path-to-emperor-ai> [--check]
//
// Litigator is the one role whose workspace is not a card deck. The web drives it from a drafting
// taxonomy — `src/roles/litigatorDrafting.js` (matters, proceedings, sections, documents),
// `src/roles/litigatorForms.js` (each section's own fields and drafting instruction) — and two
// resolvers in `src/tools/registry.js` turn an id into a form and a prompt: `ldoc-<matter>-<item>`
// for one document, `lsec-<matter>-<section>` for a section's heading card, whose first field
// picks the document. Two hundred and twenty-two ids, every one of them a prompt that an advocate
// files from.
//
// This script writes two things, and both come from running that JavaScript rather than reading it:
//
//   - Sources/EmperorCore/Tools/LitigatorTaxonomy.swift — the data: matters, proceedings,
//     sections, documents, notes, templates and section forms. The Swift resolvers in
//     `LitigatorDrafting.swift` are hand-ported code; this is what they read. The forum list and
//     the forum formats are not rewritten here — the core already holds both, shared with
//     `draft-pleading` — but every one of the eight formats is pinned by a case in cases.json.
//   - Tests/EmperorCoreTests/Resources/litigator/*.json — what the platform produces from that
//     data: for every id, the resolved tool's title, short, blurb and inputs, and its prompt on an
//     empty form and on a filled one (the filled rule is `ToolGoldenTests.filled`); `sectionsFor`
//     for every matter and proceeding; and the heading card's one-line summary.
//
// The modules are imported for real, under Node, with the same stand-in
// `generate-tool-fixtures.mjs` uses: `lucide-react` is the web's icon set, and each icon name the
// platform imports resolves to a placeholder string, because no prompt reads an icon.
//
// Three values are private to a file and are cut out of it by name, brace-matched, and evaluated —
// the technique `generate-file-tool-fixtures.mjs` uses for functions inside `.jsx` pages. Cutting
// by name means a renamed or deleted value fails this script loudly rather than leaving stale data:
//   - `GENERIC_SECTION_FIELDS` (registry.js) — the fields a section without its own form gets.
//   - `sectionDesc` (pages/home/RoleCards.jsx) — the summary on a heading card.
//   - `META` (pages/LitigatorMatter.jsx) — the one-line description of Civil and of Criminal.
//
// `--check` writes nothing and exits 1 if anything differs — the way to ask "has the platform
// moved since these were made?" without touching the tree.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/roles/litigatorDrafting.js'))) {
  console.error('usage: generate-litigator-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const fixtureDir = path.join(root, 'Tests/EmperorCoreTests/Resources/litigator')
const swiftFile = path.join(root, 'Sources/EmperorCore/Tools/LitigatorTaxonomy.swift')

// ── Module loading ───────────────────────────────────────────────────────────────────────────
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

const load = (file) => import(pathToFileURL(path.join(src, file)).href)
const { ROLES, COMMON_TOOLS } = await load('roles/roleConfig.js')
const drafting = await load('roles/litigatorDrafting.js')
const { SECTION_FORMS } = await load('roles/litigatorForms.js')
const { getTool, FORUMS, FORUM_FORMATS } = await load('tools/registry.js')
const { PROCEEDINGS, DRAFT_SECTIONS, AREAS, sectionsFor, draftToolId, sectionToolId,
  getDraftItem, getDraftSection } = drafting

const GENERIC_SECTION_FIELDS = evaluate(cut('tools/registry.js', /const GENERIC_SECTION_FIELDS =/), 'GENERIC_SECTION_FIELDS')
const sectionDesc = evaluate(cut('pages/home/RoleCards.jsx', /function sectionDesc\(/), 'sectionDesc')
const META = evaluate(cut('pages/LitigatorMatter.jsx', /const META =/), 'META', [...iconNames])

// The home's Dashboard carries its own copy of `sectionDesc`. RoleCards.jsx is the live one (the
// Guided home renders it); if the two ever disagree, which one the phone should follow is a
// question for a person, not for this script.
const dashboardDesc = cut('pages/Dashboard.jsx', /function sectionDesc\(/)
if (dashboardDesc !== cut('pages/home/RoleCards.jsx', /function sectionDesc\(/)) {
  throw new Error('sectionDesc differs between Dashboard.jsx and home/RoleCards.jsx — decide which is live first')
}

const litigator = ROLES.find(r => r.id === 'litigator')
if (!litigator?.matters?.length) throw new Error('roleConfig.js: the litigator role has no matters')
const matters = litigator.matters.map(m => m.id)
for (const id of matters) {
  if (!AREAS[id] && !PROCEEDINGS[id]) throw new Error(`matter ${id} is neither Civil/Criminal nor an area`)
}

// ── Fixtures ─────────────────────────────────────────────────────────────────────────────────
// The filled rule `ToolGoldenTests.filled` uses: first option for a select, "test <key>"
// otherwise, Hindi for a language field. No litigator form has a language field; the branch is
// kept so the two rules cannot drift apart.
function filledValues(tool) {
  const filled = {}
  for (const field of tool.inputs || []) {
    if (field.key === 'lang') filled[field.key] = 'Hindi'
    else if (Array.isArray(field.options) && field.options.length) {
      const first = field.options[0]
      filled[field.key] = typeof first === 'object' ? (first.value ?? first.label) : first
    } else filled[field.key] = `test ${field.key}`
  }
  return filled
}

const describeInput = (f) => ({
  key: f.key, label: f.label, type: f.type, required: !!f.required,
  placeholder: f.placeholder ?? null, options: f.options ?? [], big: !!f.big,
})

function describeTool(id) {
  const tool = getTool(id)
  if (!tool) throw new Error(`getTool(${id}) returned nothing`)
  return {
    id, title: tool.title, short: tool.short, blurb: tool.blurb, output: tool.outputType,
    inputs: (tool.inputs || []).map(describeInput),
    empty: tool.buildPrompt({}),
    filled: tool.buildPrompt(filledValues(tool)),
  }
}

const documents = []
const sections = []
const summaries = []
const sectionLists = []
for (const matter of matters) {
  const proceedings = [null, ...(PROCEEDINGS[matter] || [])]
  for (const proceeding of proceedings) {
    sectionLists.push({
      matter, proceeding,
      sections: sectionsFor(matter, proceeding ?? undefined).map(s => ({ key: s.key, items: s.items.map(it => it.id) })),
    })
  }
  for (const section of sectionsFor(matter)) {
    const sid = sectionToolId(matter, section.key)
    if (!getDraftSection(sid)) throw new Error(`${sid} is offered but getDraftSection cannot read it`)
    sections.push(describeTool(sid))
    summaries.push({ id: sid, summary: sectionDesc(section) })
    for (const item of section.items) {
      const did = draftToolId(matter, item.id)
      if (!getDraftItem(did)) throw new Error(`${did} is offered but getDraftItem cannot read it`)
      documents.push(describeTool(did))
    }
  }
}

// Cases the empty and filled forms do not reach.
const prompt = (id, values) => ({ id, values, prompt: getTool(id).buildPrompt(values) })
const cases = [
  // Every forum, on a document and on a heading card: the forum names the court in the opening
  // sentence and appends that forum's formatting rules, and the filled form only ever picks the
  // first one.
  ...FORUMS.map(forum => prompt('ldoc-civil-plaint', { forum })),
  ...FORUMS.map(forum => prompt('lsec-criminal-bail', { forum })),
  // A forum typed in rather than chosen: named, but with no formatting rules to add.
  prompt('ldoc-criminal-quashing', { forum: 'Family Court' }),
  // Assembly: a value is trimmed, a blank one reads "(not provided)", and the heading card's
  // document type is what the opening sentence asks for — but never a section of its own.
  prompt('ldoc-civil-plaint', { parties: '  A v. B  ', factsCauseOfAction: '   ', reliefSought: 'Decree.\n' }),
  prompt('lsec-civil-common', { subhead: 'Caveat (s.148A CPC)', particulars: 'Rs 5,00,000' }),
  prompt('lsec-tax-gst', { subhead: 'Writ against GST action' }),
  // A template the platform left empty is no template at all.
  prompt('ldoc-labour-id-claim', { forum: 'Other Tribunal' }),
  // The code note: criminal, civil, and a practice area's own — and a matter that is none of
  // them, which the platform treats as civil.
  prompt('ldoc-criminal-vakalatnama', {}),
  prompt('ldoc-civil-vakalatnama', {}),
  prompt('ldoc-cyber-it-65b', {}),
  prompt('ldoc-unknown-plaint', {}),
]

// Ids the platform answers that the workspace never offers: a document read against the other
// branch's sections, and ids that name nothing. Pinned so the Swift lookup is exactly as
// permissive as `getTool`, no more and no less.
const lookups = [
  'ldoc-civil-bail-reply', 'ldoc-criminal-plaint', 'ldoc-civil-arb-s34', 'ldoc-tax-plaint',
  'ldoc-civil-nothing', 'ldoc-civil', 'ldoc-', 'lsec-civil-bail', 'lsec-criminal-issues',
  'lsec-criminal-complaints', 'lsec-tax-gst', 'lsec-tax-initiating', 'lsec-civil', 'lsec-',
  'ldoc-unknown-plaint', 'lsec-unknown-common', 'ldoc-company-nclt-252', 'LDOC-civil-plaint',
].map(id => {
  const tool = getTool(id)
  return { id, resolves: !!tool, title: tool?.title ?? null, blurb: tool?.blurb ?? null }
})

const fixtures = {
  taxonomy: {
    matters: litigator.matters.map(m => ({ id: m.id, label: m.label, short: m.short ?? null })),
    // The role's own toolkit, which sits beside the workspace rather than in it — pinned here
    // because it is the same roleConfig.js entry, and `PractitionerRole.toolIDs` is typed by hand.
    toolkit: [...litigator.tools, ...COMMON_TOOLS],
    proceedings: PROCEEDINGS,
    sectionsFor: sectionLists,
    summaries,
  },
  documents: { tools: documents },
  sections: { tools: sections },
  cases: { cases, lookups },
}

// ── The Swift data ───────────────────────────────────────────────────────────────────────────
const swift = renderSwift()

// ── Write ────────────────────────────────────────────────────────────────────────────────────
fs.mkdirSync(fixtureDir, { recursive: true })
let changed = 0
const outputs = Object.entries(fixtures).sort()
  .map(([name, value]) => [path.join(fixtureDir, `${name}.json`), render(value)])
outputs.push([swiftFile, swift])
for (const [file, text] of outputs) {
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null
  if (before === text) continue
  changed++
  console.log(`${before === null ? 'new' : 'changed'}  ${path.relative(root, file)}`)
  if (!checkOnly) fs.writeFileSync(file, text)
}
const stale = fs.readdirSync(fixtureDir).filter(f => f.endsWith('.json') && !(f.slice(0, -5) in fixtures))
for (const f of stale) console.log(`not produced by the platform any more  ${f}`)
console.log(`${documents.length} documents, ${sections.length} sections, ${outputs.length} files, ${changed} ${checkOnly ? 'differ' : 'written'}`)
if (checkOnly && (changed || stale.length)) process.exit(1)

// One entry per line, so a platform change shows up as the ids it touched.
function render(value) {
  const lines = Object.entries(value).map(([key, v]) => {
    const body = Array.isArray(v) && v.length && typeof v[0] === 'object'
      ? `[\n${v.map(item => `  ${JSON.stringify(item)}`).join(',\n')}\n ]`
      : JSON.stringify(v)
    return ` ${JSON.stringify(key)}: ${body}`
  })
  return `{\n${lines.join(',\n')}\n}\n`
}

function renderSwift() {
  const s = (v) => (v === undefined || v === null) ? 'nil' : swiftString(v)
  const list = (values) => `[${values.map(swiftString).join(', ')}]`
  const branch = { c: '.civil', cr: '.criminal', both: '.both' }
  const item = (it, indent) => {
    if (it.b !== undefined && !(it.b in branch)) throw new Error(`item ${it.id}: unknown branch ${it.b}`)
    const parts = [`id: ${s(it.id)}`, `label: ${s(it.label)}`]
    if (it.b !== undefined) parts.push(`branch: ${branch[it.b]}`)
    if (it.note !== undefined) parts.push(`note: ${s(it.note)}`)
    if (it.template !== undefined) parts.push(`template: ${s(it.template)}`)
    return `${indent}LitigatorItem(${parts.join(', ')}),`
  }
  const section = (sec, indent) => {
    if (sec.gate !== undefined && !['issues', 'trial'].includes(sec.gate)) {
      throw new Error(`section ${sec.key}: unknown gate ${sec.gate}`)
    }
    const head = [`key: ${s(sec.key)}`, `title: ${s(sec.title)}`]
    if (sec.template !== undefined) head.push(`template: ${s(sec.template)}`)
    if (sec.gate !== undefined) head.push(`gate: .${sec.gate}`)
    const lines = [`${indent}LitigatorSection(`, `${indent}    ${head.join(', ')},`]
    if (sec.draftInstruction !== undefined) {
      lines.push(`${indent}    draftInstruction: ${s(sec.draftInstruction)},`)
    }
    lines.push(`${indent}    items: [`)
    for (const it of sec.items) lines.push(item(it, `${indent}        `))
    lines.push(`${indent}    ]),`)
    return lines.join('\n')
  }
  const field = (f, indent) => {
    const kinds = ['text', 'textarea', 'select', 'forum']
    if (!kinds.includes(f.type)) throw new Error(`field ${f.key}: unknown type ${f.type}`)
    const parts = [`key: ${s(f.key)}`, `label: ${s(f.label)}`, `type: .${f.type}`]
    if (f.required) parts.push('required: true')
    if (f.placeholder !== undefined) parts.push(`placeholder: ${s(f.placeholder)}`)
    if (f.options !== undefined) parts.push(`options: ${list(f.options)}`)
    if (f.big) parts.push('big: true')
    return `${indent}LitigatorFormField(${parts.join(', ')}),`
  }

  const out = []
  out.push(`// Generated by scripts/generate-litigator-fixtures.mjs from the platform's own modules — do not
// edit by hand.
//
// Produced by evaluating src/roles/roleConfig.js, src/roles/litigatorDrafting.js,
// src/roles/litigatorForms.js and src/tools/registry.js under Node. If the taxonomy changes on the
// platform, regenerate this file and its fixtures rather than editing either to match: the fixture
// is the contract and this is the copy. The resolvers that read it are hand-ported, in
// LitigatorDrafting.swift.

import Foundation

/// The matters the Litigator workspace offers, in the platform's order — Civil, Criminal, then the
/// practice areas (\`roleConfig.js\`, the litigator entry's \`matters\`). The one-line summaries are
/// \`LitigatorMatter.jsx\`'s \`META\`, which describes Civil and Criminal only.
let LITIGATOR_MATTERS: [LitigatorMatter] = [`)
  for (const m of litigator.matters) {
    const parts = [`id: ${s(m.id)}`, `label: ${s(m.label)}`]
    if (m.short !== undefined) parts.push(`short: ${s(m.short)}`)
    if (META[m.id]?.desc !== undefined) parts.push(`summary: ${s(META[m.id].desc)}`)
    out.push(`    LitigatorMatter(${parts.join(', ')}),`)
  }
  out.push(`]

/// The proceeding (case type) a Civil or Criminal matter can be narrowed to — \`PROCEEDINGS\`.
/// It gates the Issues section and the two trial sections; the practice areas have none.
let LITIGATOR_PROCEEDINGS: [String: [String]] = [`)
  for (const [matter, list_] of Object.entries(PROCEEDINGS)) {
    out.push(`    ${s(matter)}: ${list(list_)},`)
  }
  out.push(`]

/// Civil and Criminal's sections — \`DRAFT_SECTIONS\`. One list for both: each document carries
/// the branch it belongs to, and a section shows for a matter if any of its documents does.
let LITIGATOR_DRAFT_SECTIONS: [LitigatorSection] = [`)
  for (const sec of DRAFT_SECTIONS) out.push(section(sec, '    '))
  out.push(`]

/// The practice areas — \`AREAS\` — each with its own sections, documents and governing-law note.
/// Keyed by matter id.
let LITIGATOR_AREAS: [String: LitigatorArea] = [`)
  for (const [matter, area] of Object.entries(AREAS)) {
    out.push(`    ${s(matter)}: LitigatorArea(`)
    out.push(`        label: ${s(area.label)},`)
    out.push(`        codeNote: ${s(area.codeNote)},`)
    out.push(`        sections: [`)
    for (const sec of area.sections) out.push(section(sec, '            '))
    out.push(`        ]),`)
  }
  out.push(`]

/// Each Civil and Criminal section's own fields and drafting instruction — \`SECTION_FORMS\`.
/// A section with no entry here uses \`LITIGATOR_GENERIC_SECTION_FIELDS\` and its own instruction.
let LITIGATOR_SECTION_FORMS: [String: LitigatorSectionForm] = [`)
  for (const [key, form] of Object.entries(SECTION_FORMS)) {
    out.push(`    ${s(key)}: LitigatorSectionForm(`)
    out.push(`        inputs: [`)
    for (const f of form.inputs) out.push(field(f, '            '))
    out.push(`        ],`)
    out.push(`        draftInstruction: ${s(form.draftInstruction)}),`)
  }
  out.push(`]

/// The fields a section without a form of its own is given — \`GENERIC_SECTION_FIELDS\`.
let LITIGATOR_GENERIC_SECTION_FIELDS: [LitigatorFormField] = [`)
  for (const f of GENERIC_SECTION_FIELDS) out.push(field(f, '    '))
  out.push(']')
  // `FORUMS` and `FORUM_FORMATS` are not written here: both already exist in the core, shared with
  // `draft-pleading` (ToolSpec.swift, RegistryTools.swift). The inputs in the fixtures pin the
  // first, and the per-forum cases in cases.json pin every entry of the second. This pins that
  // every format has a forum to belong to.
  for (const forum of Object.keys(FORUM_FORMATS)) {
    if (!FORUMS.includes(forum)) throw new Error(`FORUM_FORMATS names ${forum}, which FORUMS does not offer`)
  }
  return out.join('\n') + '\n'
}

// A Swift string literal. Unicode stays as itself; only what a literal cannot hold is escaped.
function swiftString(value) {
  if (typeof value !== 'string') throw new Error(`expected a string, got ${JSON.stringify(value)}`)
  let out = '"'
  for (const ch of value) {
    const code = ch.codePointAt(0)
    if (ch === '\\') out += '\\\\'
    else if (ch === '"') out += '\\"'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\r') out += '\\r'
    else if (ch === '\t') out += '\\t'
    else if (code < 0x20 || code === 0x7f) out += `\\u{${code.toString(16)}}`
    else out += ch
  }
  return out + '"'
}

// ── Cutting a value out of a source file ─────────────────────────────────────────────────────
function cut(file, startPattern) {
  const text = fs.readFileSync(path.join(src, file), 'utf8')
  const start = text.search(startPattern)
  if (start < 0) throw new Error(`${file}: ${startPattern} not found — has the platform renamed it?`)
  const open = text.slice(start).search(/[{[]/) + start
  const close = { '{': '}', '[': ']' }[text[open]]
  let depth = 0
  for (let i = open; i < text.length; i++) {
    if (text[i] === text[open]) depth++
    else if (text[i] === close && --depth === 0) return text.slice(start, i + 1)
  }
  throw new Error(`${file}: unbalanced ${startPattern}`)
}

// Runs a cut-out declaration and returns the value it declares. `scope` names the free
// identifiers it may mention (the icon components in `META`), each bound to its own name.
function evaluate(declaration, name, scope = []) {
  return new Function(...scope, `${declaration}; return ${name}`)(...scope)
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) yield* walk(p)
    else if (/\.(js|jsx|mjs)$/.test(entry.name)) yield p
  }
}
