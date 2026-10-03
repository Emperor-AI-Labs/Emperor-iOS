#!/usr/bin/env node
// Regenerates the icon-tile golden fixture from the platform's own source.
//
//   node scripts/generate-tile-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web draws every tool as a small filled tile: the tool's own lucide icon in white, on a
// colour that `toolColor(id)` picks from an eight-colour muted palette by hashing the tool's id
// (`src/tools/registry.js`, `TOOL_PALETTE` and `toolColor`). Each role has its own colour too
// (`src/roles/roleConfig.js`). The app draws the same tiles, so a tool wears the same colour and
// the same picture on both — and the hash, the palette order and the icon for each tool are the
// platform's to decide, not this client's.
//
// Tests/EmperorCoreTests/Resources/tool-tiles.json records, from running that JavaScript:
//   - `palette` — `TOOL_PALETTE`, in order.
//   - `tools` — for every tool in the registry and every analysis tool: `toolColor(id)` and the
//     name of the lucide icon the tool carries.
//   - `hashes` — `toolColor` for ids no tool has: long enough to wrap the 32-bit hash many times
//     over, and one outside ASCII, so the port is held to the arithmetic and to UTF-16 rather
//     than merely to thirty short strings.
//   - `roles` — each role's colour, keyed by its label.
//   - `roleIds` — each role's id, keyed by its label: the value the account stores as its role
//     (`practice_role`), so a role chosen on the phone is the same role on the web.
//
// The modules are imported for real, under Node, with the stand-in `generate-tool-fixtures.mjs`
// uses: `lucide-react` resolves each icon name the platform imports to a string of that name,
// which is exactly what this fixture wants to read.
//
// `--check` writes nothing and exits 1 if the fixture differs — the way to ask "has the platform
// moved since this was made?" without touching the tree.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/tools/registry.js'))) {
  console.error('usage: generate-tile-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/tool-tiles.json')

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

const { TOOLS, toolColor } = await import(pathToFileURL(path.join(src, 'tools/registry.js')).href)
const { ANALYSIS_TOOLS } = await import(pathToFileURL(path.join(src, 'tools/definitions/index.js')).href)
const { ROLES } = await import(pathToFileURL(path.join(src, 'roles/roleConfig.js')).href)

// `TOOL_PALETTE` is private to registry.js, so it is cut out of the file by name and evaluated —
// the technique `generate-litigator-fixtures.mjs` uses for private values. Cutting by name means a
// renamed palette fails this script loudly rather than leaving a stale fixture.
const registrySource = fs.readFileSync(path.join(src, 'tools/registry.js'), 'utf8')
const paletteMatch = registrySource.match(/const\s+TOOL_PALETTE\s*=\s*(\[[^\]]*\])/)
if (!paletteMatch) {
  console.error('TOOL_PALETTE not found in src/tools/registry.js')
  process.exit(1)
}
const ordered = new Function(`return ${paletteMatch[1]}`)()
// Every colour `toolColor` returns has to be one of these, or the cut found the wrong array.
for (const id of Object.keys(TOOLS)) {
  if (!ordered.includes(toolColor(id))) {
    console.error(`toolColor('${id}') is not in TOOL_PALETTE — the palette cut is stale`)
    process.exit(1)
  }
}

const tools = {}
for (const [id, tool] of Object.entries({ ...TOOLS, ...ANALYSIS_TOOLS })) {
  tools[id] = { color: toolColor(id), icon: typeof tool.icon === 'string' ? tool.icon : null }
}

const hashes = {}
for (const id of [
  '', 'a', 'ldoc-civil-plaint', 'lsec-criminal-bail',
  'ldoc-constitutional-writ-petition-under-article-32-with-synopsis-and-list-of-dates',
  'cdoc-share-purchase-agreement', 'adoc-award-drafting', 'pdoc-list-of-documents',
  'sdoc-moot-memorial', 'ndoc-rti-application', 'scdoc-opinion',
  // `charCodeAt` reads UTF-16 code units, so a character outside the Basic Multilingual Plane
  // is hashed as its two surrogates. Only an id like this one tells that apart from hashing
  // whole characters.
  '\u{1D4D4}mperor-\u0928\u094D\u092F\u093E\u092F',
]) {
  hashes[id] = toolColor(id)
}

const roles = {}
const roleIds = {}
for (const role of ROLES) {
  roles[role.label] = role.color
  roleIds[role.label] = role.id
}

const fixture = JSON.stringify({ palette: ordered, tools: sortKeys(tools), hashes, roles, roleIds }, null, 2) + '\n'
const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === fixture) {
  console.log(`tool-tiles.json is current — ${Object.keys(tools).length} tools, ${ordered.length} colours`)
} else {
  console.log(`${before === null ? 'new' : 'changed'}  tool-tiles.json`)
  if (checkOnly) process.exit(1)
  fs.writeFileSync(out, fixture)
}

function sortKeys(object) {
  return Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.localeCompare(b)))
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) yield* walk(p)
    else if (/\.(js|jsx|mjs)$/.test(entry.name)) yield p
  }
}
