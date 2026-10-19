#!/usr/bin/env node
// Regenerates Tests/EmperorCoreTests/Resources/composer/draft-depth.json from the platform.
//
//   node scripts/generate-draft-depth-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web's Short / Detailed draft length is two things, and neither is exported:
//   - the choices — `DEPTHS` in `src/ui/DraftDepthToggle.jsx` (id, label, hint);
//   - the sentence each choice appends to a tool's prompt — `lengthLine` in
//     `src/tools/ToolWorkspace.jsx`, two template literals inside `generate()`, and where that
//     line sits in the prompt's concatenation.
// So they are cut out of the files by name and evaluated (the technique
// `generate-litigator-fixtures.mjs` uses), never retyped. A renamed or reworded line fails this
// script loudly rather than leaving the phone asking for a length the web no longer asks for.
//
// `--check` writes nothing and exits 1 if the fixture differs.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const workspace = platform && path.join(platform, 'src/tools/ToolWorkspace.jsx')
const toggle = platform && path.join(platform, 'src/ui/DraftDepthToggle.jsx')
if (!workspace || !fs.existsSync(workspace) || !fs.existsSync(toggle)) {
  console.error('usage: generate-draft-depth-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/composer/draft-depth.json')

// ── The two sentences ────────────────────────────────────────────────────────────────────────
const ws = fs.readFileSync(workspace, 'utf8')
const lengthMatch = ws.match(
  /const lengthLine = \(st\.draftDepth \|\| '(\w+)'\) === '(\w+)'\s*\?\s*`([^`]*)`\s*:\s*`([^`]*)`/)
if (!lengthMatch) throw new Error('ToolWorkspace.jsx: lengthLine not found — has the platform renamed it?')
const [, fallback, shortId, shortTemplate, otherTemplate] = lengthMatch
for (const t of [shortTemplate, otherTemplate]) {
  if (t.includes('${')) throw new Error('lengthLine now interpolates a value — port that by hand')
}
// A template literal with no substitutions is its own value once its escapes are read.
const literal = (t) => new Function('return `' + t + '`')()

// ── Where it sits ────────────────────────────────────────────────────────────────────────────
const promptMatch = ws.match(/const prompt = (tool\.buildPrompt\(values2\)(?:\s*\+\s*\w+)+)/)
if (!promptMatch) throw new Error('ToolWorkspace.jsx: the tool prompt concatenation was not found')
const order = promptMatch[1].split('+').map(s => s.trim())

// ── The choices ──────────────────────────────────────────────────────────────────────────────
const tg = fs.readFileSync(toggle, 'utf8')
const depthsDecl = cut(tg, /const DEPTHS =/, 'DraftDepthToggle.jsx')
const icons = [...tg.matchAll(/import\s*\{([^}]*)\}\s*from\s*['"]lucide-react['"]/g)]
  .flatMap(m => m[1].split(',').map(s => s.trim()).filter(Boolean))
const DEPTHS = new Function(...icons, `${depthsDecl}; return DEPTHS`)(...icons)
const defaultMatch = tg.match(/useStore\(s => s\.draftDepth\) \|\| '(\w+)'/)
if (!defaultMatch) throw new Error('DraftDepthToggle.jsx: the default depth was not found')

const fixture = {
  default: defaultMatch[1],
  workspaceFallback: fallback,
  depths: DEPTHS.map(d => ({ id: d.id, label: d.label, hint: d.hint, icon: d.icon })),
  lengthLine: {
    [shortId]: literal(shortTemplate),
    // Anything that is not `shortId` — which, from the toggle, is `detailed`.
    otherwise: literal(otherTemplate),
  },
  promptOrder: order,
}

const text = JSON.stringify(fixture, null, 1) + '\n'
const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === text) { console.log('draft-depth.json unchanged'); process.exit(0) }
if (checkOnly) { console.log('draft-depth.json differs from the platform'); process.exit(1) }
fs.mkdirSync(path.dirname(out), { recursive: true })
fs.writeFileSync(out, text)
console.log('draft-depth.json written')

// Cuts `const NAME = [...]` / `{...}` out of a file, brace-matched.
function cut(text, startPattern, file) {
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
