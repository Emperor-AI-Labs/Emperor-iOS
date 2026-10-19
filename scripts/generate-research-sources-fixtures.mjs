#!/usr/bin/env node
// Regenerates Tests/EmperorCoreTests/Resources/composer/research-sources.json from the platform.
//
//   node scripts/generate-research-sources-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web's "Sources" menu (`src/tools/ResearchSourcesMenu.jsx`) lists Web search, ten
// jurisdictions and eight repositories, and the store (`src/lib/store.js`) starts the selection
// at `researchSources: { web: true, in: true }`. Neither list is exported and the file is JSX, so
// each declaration is cut out by name, brace-matched, and evaluated with the file's own lucide
// icon names bound to themselves as strings (the stand-in `generate-tool-fixtures.mjs` uses) —
// never retyped. The default selection is read the same way from the store.
//
// `--check` writes nothing and exits 1 if the fixture differs.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const menu = platform && path.join(platform, 'src/tools/ResearchSourcesMenu.jsx')
const store = platform && path.join(platform, 'src/lib/store.js')
if (!menu || !fs.existsSync(menu) || !fs.existsSync(store)) {
  console.error('usage: generate-research-sources-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/composer/research-sources.json')

const text = fs.readFileSync(menu, 'utf8')
const icons = [...text.matchAll(/import\s*\{([^}]*)\}\s*from\s*['"]lucide-react['"]/g)]
  .flatMap(m => m[1].split(',').map(s => s.trim()).filter(Boolean))
const evaluate = (decl, name) => new Function(...icons, `${decl}; return ${name}`)(...icons)
const JURISDICTIONS = evaluate(cut(text, /const JURISDICTIONS =/, 'ResearchSourcesMenu.jsx'), 'JURISDICTIONS')
const REPOSITORIES = evaluate(cut(text, /const REPOSITORIES =/, 'ResearchSourcesMenu.jsx'), 'REPOSITORIES')

// The full-width row above both columns: `<SourceRow icon={Search} label="Web search" … toggleSource('web')`.
const web = text.match(/<SourceRow icon=\{(\w+)\} label="([^"]+)" on=\{!!sources\.(\w+)\}/)
if (!web) throw new Error('ResearchSourcesMenu.jsx: the web-search row was not found')
const labels = [...text.matchAll(/<SectionLabel[^>]*>([^<]+)<\/SectionLabel>/g)].map(m => m[1].trim())

const storeText = fs.readFileSync(store, 'utf8')
const def = evaluate(cut(storeText, /researchSources: \{/, 'store.js').replace(/^researchSources:/, 'const researchSources ='), 'researchSources')

const row = (r) => ({ id: r.id, label: r.label, flag: r.flag ?? null, icon: r.icon ?? null })
const fixture = {
  web: { id: web[3], label: web[2], icon: web[1] },
  sections: labels,
  jurisdictions: JURISDICTIONS.map(row),
  repositories: REPOSITORIES.map(row),
  defaultSelection: def,
}

const json = JSON.stringify(fixture, null, 1) + '\n'
const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === json) { console.log('research-sources.json unchanged'); process.exit(0) }
if (checkOnly) { console.log('research-sources.json differs from the platform'); process.exit(1) }
fs.mkdirSync(path.dirname(out), { recursive: true })
fs.writeFileSync(out, json)
console.log('research-sources.json written')

function cut(source, startPattern, file) {
  const start = source.search(startPattern)
  if (start < 0) throw new Error(`${file}: ${startPattern} not found — has the platform renamed it?`)
  const open = source.slice(start).search(/[{[]/) + start
  const close = { '{': '}', '[': ']' }[source[open]]
  let depth = 0
  for (let i = open; i < source.length; i++) {
    if (source[i] === source[open]) depth++
    else if (source[i] === close && --depth === 0) return source.slice(start, i + 1)
  }
  throw new Error(`${file}: unbalanced ${startPattern}`)
}
