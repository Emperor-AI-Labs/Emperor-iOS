#!/usr/bin/env node
// Regenerates Tests/EmperorCoreTests/Resources/composer/page-setup.json from the platform.
//
//   node scripts/generate-page-setup-fixtures.mjs <path-to-emperor-ai> [--check]
//
// `src/lib/pageSetup.js` is the web's single source of truth for paper: the five sizes in
// millimetres, the two orientations, the default margins, and the normalising rule every stored
// setup goes through. It is a plain ES module, so it is imported as it stands and run against a
// spread of stored shapes — partial, legacy, nonsense — and every answer is recorded.
//
// Word's numbers come from `src/lib/htmlToDocx.js`, which keeps its own copy of the sizes and its
// own millimetre-to-twip rounding (`mmTwip`). Those two are private to the file, so they are cut
// out by name and evaluated; `docxPageSize` hands the docx library PORTRAIT twips and the
// orientation, and the library swaps width and height for landscape (see the comment above it).
// The fixture records what lands in `<w:pgSz>` and `<w:pgMar>` after that swap.
//
// `--check` writes nothing and exits 1 if the fixture differs.
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const source = platform && path.join(platform, 'src/lib/pageSetup.js')
const docxSource = platform && path.join(platform, 'src/lib/htmlToDocx.js')
if (!source || !fs.existsSync(source) || !fs.existsSync(docxSource)) {
  console.error('usage: generate-page-setup-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/composer/page-setup.json')

const ps = await import(pathToFileURL(source).href)

const docxText = fs.readFileSync(docxSource, 'utf8')
const mmTwipLine = docxText.match(/const mmTwip = \(mm\) => [^\n]+/)
if (!mmTwipLine) throw new Error('htmlToDocx.js: mmTwip not found')
const mmTwip = new Function(`${mmTwipLine[0]}; return mmTwip`)()
const DOCX_SIZES = new Function(`${cut(docxText, /const DOCX_SIZES =/, 'htmlToDocx.js')}; return DOCX_SIZES`)()
const docxPageSize = new Function('DOCX_SIZES', 'mmTwip',
  `${cut(docxText, /function docxPageSize\(/, 'htmlToDocx.js')}; return docxPageSize`)(DOCX_SIZES, mmTwip)

const inputs = [
  null,
  {},
  { size: 'a4' },
  { size: 'letter', orientation: 'landscape' },
  { size: 'legal', orientation: 'portrait' },
  { size: 'a3', orientation: 'landscape', margins: { top: 10, right: 12.5, bottom: 10, left: 30 } },
  { size: 'a5', margins: { top: 0, right: 0, bottom: 0, left: 0 } },
  { size: 'tabloid', orientation: 'sideways' },
  { size: 'A4', orientation: 'Landscape' },
  { orientation: 'landscape', margins: { top: -5, right: '20', bottom: null, left: 15 } },
  { margins: { top: 200, right: 120, bottom: 200, left: 120 } },
  { size: 'letter', margins: { left: 38.1 } },
]

const cases = inputs.map(input => {
  const normalized = ps.normalizePageSetup(input)
  const metrics = ps.pageMetrics(input)
  // What htmlToDocx hands the docx library, then what the library writes: it swaps w:w/w:h
  // itself when the orientation is landscape.
  const size = docxPageSize(normalized)
  const landscape = size.orientation === 'landscape'
  return {
    input,
    normalized,
    dimensions: ps.pageDimensions(input),
    contentMm: { width: metrics.mm.contentWidth, height: metrics.mm.contentHeight },
    px: { width: metrics.px.width, height: metrics.px.height,
      contentWidth: metrics.px.contentWidth, contentHeight: metrics.px.contentHeight },
    label: ps.pageSizeLabel(input),
    docx: {
      width: landscape ? size.height : size.width,
      height: landscape ? size.width : size.height,
      orientation: size.orientation,
      margins: {
        top: mmTwip(normalized.margins.top), right: mmTwip(normalized.margins.right),
        bottom: mmTwip(normalized.margins.bottom), left: mmTwip(normalized.margins.left),
      },
    },
  }
})

const fixture = {
  sizes: ps.PAGE_SIZE_LIST,
  orientations: ps.ORIENTATIONS,
  defaultMargins: ps.DEFAULT_MARGINS,
  defaultSetup: ps.DEFAULT_PAGE_SETUP,
  pxPerMm: ps.PX_PER_MM,
  mmTwip: [0, 1, 10, 12.5, 20, 25, 25.4, 38.1, 148, 210, 215.9, 279.4, 297, 355.6, 420].map(mm => ({ mm, twip: mmTwip(mm) })),
  cases,
}

const json = JSON.stringify(fixture, null, 1) + '\n'
const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === json) { console.log(`page-setup.json unchanged (${cases.length} cases)`); process.exit(0) }
if (checkOnly) { console.log('page-setup.json differs from the platform'); process.exit(1) }
fs.mkdirSync(path.dirname(out), { recursive: true })
fs.writeFileSync(out, json)
console.log(`page-setup.json written (${cases.length} cases)`)

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
