#!/usr/bin/env node
// Regenerates the file-tool golden fixtures from the platform's own source.
//
//   node scripts/generate-file-tool-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The fixtures in Tests/EmperorCoreTests/Resources/file-tools/ are what the Swift ports of the web's
// Document Utilities are held to. They come from running the platform's JavaScript, not from
// anyone's reading of it — `generate-tool-fixtures.mjs` explains why that matters.
//
// Three kinds of source are run here:
//   - `src/lib/pageOrder.js` is plain ESM with no imports, so it is imported as it stands.
//   - `src/lib/imagePdf.js` imports `pdf-lib`, which the reference copy does not install. A
//     stand-in records every page size and every `drawImage` rectangle instead of building a
//     PDF, which is exactly the part this client ports — the layout, not the byte format.
//   - The rest lives inside `.jsx` pages that Node cannot parse. Each function this client ports
//     is plain JavaScript inside that file, so it is cut out by name, brace-matched, and run
//     under the minimum stand-ins it touches (a canvas whose `toBlob` reports a size from a
//     model, an `Image` that "loads" the dimensions it was handed). Cutting by name means a
//     renamed or deleted function fails this script loudly rather than leaving a stale fixture.
//
// `--check` writes nothing and exits 1 if any fixture differs.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/lib/pageOrder.js'))) {
  console.error('usage: generate-file-tool-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/file-tools')

// ── pdf-lib stand-in ─────────────────────────────────────────────────────────────────────────
// `embedJpg` / `embedPng` receive whatever the fake File's `arrayBuffer()` returned, which here
// is the image's own pixel size, and hand it back the way pdf-lib reports an embedded image.
const pdfLibStub = `
export const PDFDocument = {
  create: async () => {
    const pages = []
    return {
      embedJpg: async (b) => ({ width: b.width, height: b.height, kind: 'jpeg' }),
      embedPng: async (b) => ({ width: b.width, height: b.height, kind: 'png' }),
      addPage: ([w, h]) => {
        const page = { size: [w, h], draws: [] }
        pages.push(page)
        return { drawImage: (image, opts) => page.draws.push({ kind: image.kind, ...opts }) }
      },
      save: async () => pages,
    }
  },
}
`
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'pdf-lib') return { url: 'emperor-stub:pdf-lib', shortCircuit: true }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (url === 'emperor-stub:pdf-lib') return { format: 'module', source: pdfLibStub, shortCircuit: true }
    return next(url, context)
  },
})

// ── Cutting a function out of a .jsx file ────────────────────────────────────────────────────
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

const fixtures = {}

// ── Rearrange: parsePageOrder / formatPageOrder / summarise ──────────────────────────────────
const { parsePageOrder, formatPageOrder, MAX_OUTPUT_PAGES } =
  await import(pathToFileURL(path.join(src, 'lib/pageOrder.js')).href)
const summarise = new Function(`${cut('pages/tools/RearrangePdf.jsx', /function summarise\(/)}; return summarise`)()

// A deterministic generator, so the random half of the corpus is the same on every run.
let seed = 0x5eed1234
const rand = () => { seed = (seed * 1103515245 + 12345) >>> 0; return seed / 2 ** 32 }
const pick = (list) => list[Math.floor(rand() * list.length)]

const handWritten = [
  // the self-test's own cases, so the port answers to them directly
  '9-7', '5, 3, 1', '10, 1', '1-3, 9-7', '3-7', 'reverse', '5, 5, 5', '5x3', '5*3', '3-4x2',
  '1, 5, 1, 6, 1', '2x2, 1-3', '5, all', '1, 2, 1, 3, 1', 'all', 'odd', 'even', 'last, first',
  'odd, even', '  3 - 5 ,  8  ', '3..5', '3 to 5', 'ALL', '1\n2\n3', '', '11', 'banana',
  '1-3, banana, 5', '5x0', 'all x1000', '1, 2', '1x5',
  // separators, case and spacing
  '1 TO 3', '1To3', '3..1', '3 .. 1', '5 X 3', '5 x 3', '5 * 3', 'Rev', 'REVERSE x2', 'rev*2',
  'first x 3', 'LAST', 'odd x2, even', '1-1', '7-7x2', '1,,2', ',1,', '\n\n', '1\r\n2', ' , , ',
  '1;2', '1 2', '1 - - 2', '1-', '-1', '-3', 'x3', '5x', '5xx3', '5x3x2', '5 x', '1..', '..3',
  '1to', 'to5', 'all,all', 'reverse, all', '0', '0-3', '3-0', '0x2', '00', '007', '1-007',
  '5x01', '5x00',
  // whitespace that JavaScript trims and `\\s` matches, which Swift's own trimming does not all agree on
  ' 1 ', '﻿2', '1 ', '　3', '1 - 3', '5 x 2',
  '\u000b4\u000c', '1​', '\u00851',
  // digits that are digits to ICU but not to JavaScript
  '١', '٣-٥', '５', '1-٣',
  // numbers past every integer type, so the message formatting is pinned too
  '99999999999999', '99999999999999999999', '123456789012345678901234',
  '1-99999999999999999999', '1x99999999999999999999', '2x9007199254740993',
  // the expansion cap, at and around the limit
  'all x500', 'all x501', '1x4999, 1', '1x4999, 1, 1', '1x5000', '1x5001', '1, all x1000, 2',
  // keywords that are not keywords
  'alll', 'al', 'everything', 'odds', 'evens', 'first-last', '1-last', 'last-1', 'reversed',
  'ALL\tX\t2', 'ǅ', 'ſ', 'Kx2',
]

const randomToken = () => {
  const n = () => String(Math.floor(rand() * 14))
  switch (Math.floor(rand() * 12)) {
    case 0: case 1: return n()
    case 2: case 3: return `${n()}${pick(['-', ' - ', '..', ' to ', 'TO'])}${n()}`
    case 4: return `${n()}${pick(['x', 'X', '*', ' x '])}${pick(['0', '1', '2', '3', '12'])}`
    case 5: return `${n()}-${n()}${pick(['x', '*'])}${pick(['2', '3'])}`
    case 6: return pick(['all', 'reverse', 'rev', 'odd', 'even', 'first', 'last', 'ALL', 'Odd'])
    case 7: return `${pick(['all', 'odd', 'even', 'reverse'])}${pick(['x', ' x '])}${pick(['2', '3'])}`
    case 8: return pick(['', ' ', 'abc', '-', 'x', '1-', '-2', '5x', '1..', 'to'])
    case 9: return `${pick([' ', '  ', '\t'])}${n()}${pick([' ', '', '\t'])}`
    case 10: return pick(['0', '00', '014', '99'])
    default: return `${n()}x${n()}`
  }
}
const randomSpecs = Array.from({ length: 400 }, () =>
  Array.from({ length: 1 + Math.floor(rand() * 5) }, randomToken)
    .join(pick([',', ', ', '\n', ' ,'])))

const pageCounts = [0, -1, 1, 2, 3, 7, 10, 13, 500]
const parseCases = []
// The expansion-cap cases produce up to 5,000 pages each, so they run against the two page
// counts where the cap is the point rather than against all nine.
const isCapCase = (spec) => /x\d{3,}|all x/i.test(spec)
for (const spec of handWritten) {
  for (const pageCount of isCapCase(spec) ? [10, 500] : pageCounts.filter(n => n !== 500)) {
    parseCases.push({ spec, pageCount, ...parsePageOrder(spec, pageCount) })
  }
}
for (const spec of randomSpecs) {
  const pageCount = pick([1, 2, 5, 10, 13])
  parseCases.push({ spec, pageCount, ...parsePageOrder(spec, pageCount) })
}

const formatInputs = [
  [], [7], [1, 2], [2, 1], [1, 2, 3], [3, 2, 1], [9, 8, 7], [4, 4, 4], [4, 4], [1, 1, 2, 3],
  [1, 2, 3, 3, 3], [5, 3, 1], [1, 5, 1, 6, 1], [2, 2, 1, 2, 3], [1, 3, 5, 2, 4, 6],
  [1, 2, 3, 2, 1], [3, 4, 5, 4, 3], [10, 1], [1, 2, 4, 5, 6], [6, 5, 4, 1, 2, 3],
]
for (let i = 0; i < 200; i++) {
  formatInputs.push(Array.from({ length: Math.floor(rand() * 12) }, () => 1 + Math.floor(rand() * 9)))
}
const formatCases = formatInputs.map(pages => {
  const formatted = formatPageOrder(pages)
  return { pages, formatted, roundTrip: parsePageOrder(formatted, 9).pages }
})

const summariseInputs = [[], [3], [3, 4], [3, 4, 5], [3, 4, 5, 9], [1, 3, 5], [1, 2, 4, 5, 6, 9, 10],
  [2, 3, 4, 5, 6, 7, 8, 9, 10], [1, 2, 3, 5, 6, 8]]
const summariseCases = summariseInputs.map(list => ({ list, text: summarise(list) }))

// The one-tap examples, filled the way the page fills them (`RearrangePdf.jsx`, the chip row).
const EXAMPLES = new Function(`${cut('pages/tools/RearrangePdf.jsx', /const EXAMPLES =/)}; return EXAMPLES`)()
const exampleCases = EXAMPLES.map(ex => ({
  label: ex.label, spec: ex.spec, why: ex.why,
  filled: Object.fromEntries([1, 2, 7, 30].map(n =>
    [n, ex.spec.replace('{n}', String(n)).replace('{prev}', String(Math.max(1, n - 1)))])),
}))

fixtures['page-order'] = { maxOutputPages: MAX_OUTPUT_PAGES, examples: exampleCases, parse: parseCases, format: formatCases, summarise: summariseCases }

// ── Byte sizes, as every tool prints them ────────────────────────────────────────────────────
const fmtBytes = new Function(`${cut('pages/tools/_shared.jsx', /function fmtBytes\(/)}; return fmtBytes`)()
const byteInputs = [0, 1, 999, 1023, 1024, 1025, 1280, 1331, 1332, 10240, 102400, 102399, 104857,
  1048575, 1048576, 1053818, 1059061, 1310720, 5242880, 104857600, 1073741824, 5368709120]
for (let i = 0; i < 160; i++) byteInputs.push(Math.floor(rand() * 2 ** (10 + Math.floor(rand() * 22))))
// Either side of every rounding boundary near the units' edges, where an off-by-one in the
// half-up rule would show.
for (const tenths of [10, 11, 99, 105, 9994, 10234]) {
  const edge = Math.floor(1024 * (tenths + 0.5) / 10)        // n / 1024 straddles t.t5
  byteInputs.push(edge, edge + 1)
}
for (const hundredths of [100, 101, 999, 10049, 102399]) {
  const edge = Math.floor(1048576 * (hundredths + 0.5) / 100) // n / 2^20 straddles h.hh5
  byteInputs.push(edge, edge + 1)
}
fixtures['byte-format'] = { cases: byteInputs.map(n => ({ bytes: n, text: fmtBytes(n) })) }

// ── Compress Image: the size search ──────────────────────────────────────────────────────────
// `encode` draws on a canvas and asks it for a JPEG. Here the "canvas" reports a size from a
// model monotone in both quality and pixel count, and every call is recorded, so the Swift
// search can be held to the same sequence of attempts — not merely the same answer.
{
  const block = [
    cut('pages/tools/CompressImage.jsx', /const PRESETS =/),
    cut('pages/tools/CompressImage.jsx', /function loadImage\(/),
    cut('pages/tools/CompressImage.jsx', /function encode\(/),
    cut('pages/tools/CompressImage.jsx', /async function compressToTarget\(/),
  ].join('\n')
  let calls = []
  const model = (w, h, q) => Math.round(w * h * (0.02 + 1.5 * q * q) + 600)
  const env = {
    URL: { createObjectURL: (f) => f, revokeObjectURL: () => {} },
    Image: class {
      set src(file) { this.naturalWidth = file.width; this.naturalHeight = file.height; queueMicrotask(() => this.onload()) }
    },
    document: {
      createElement: () => ({
        getContext: () => ({ fillRect() {}, drawImage() {}, set fillStyle(_) {} }),
        toBlob(cb, _type, q) {
          const size = model(this.width, this.height, q)
          calls.push({ w: this.width, h: this.height, q, size })
          cb({ size })
        },
      }),
    },
  }
  const factory = new Function('URL', 'Image', 'document', `${block}; return { compressToTarget, PRESETS }`)
  const { compressToTarget, PRESETS } = factory(env.URL, env.Image, env.document)
  // A one-line constant with no brackets, so it is read by its own line rather than cut.
  const limitLine = fs.readFileSync(path.join(src, 'pages/tools/CompressImage.jsx'), 'utf8')
    .match(/^const MAX_FILE_BYTES = ([^\n]+)$/m)
  if (!limitLine) throw new Error('CompressImage.jsx: MAX_FILE_BYTES not found')
  const maxFileBytes = new Function(`return ${limitLine[1]}`)()

  const searches = []
  for (const [width, height] of [[4032, 3024], [3024, 4032], [1200, 800], [640, 480], [50, 50], [1, 1], [9000, 120]]) {
    for (const targetKB of [1, 20, 50, 100, 200, 500, 5000]) {
      calls = []
      const r = await compressToTarget({ width, height }, targetKB * 1024)
      searches.push({
        width, height, targetBytes: targetKB * 1024, calls,
        result: { size: r.blob.size, width: r.width, height: r.height, quality: r.quality, hitTarget: r.hitTarget },
      })
    }
  }
  fixtures['compress-image'] = { presetsKB: PRESETS, maxFileBytes, searches }
}

// ── Compress PDF: the levels, and the per-image decision ─────────────────────────────────────
{
  const levels = new Function(`${cut('pages/tools/CompressPdf.jsx', /const LEVELS =/)}; return LEVELS`)()
  const block = [
    cut('pages/tools/CompressPdf.jsx', /function loadJpeg\(/),
    cut('pages/tools/CompressPdf.jsx', /async function recompressImage\(/),
  ].join('\n')
  let blobSize = 0
  let encoded = null
  const PDFName = { of: (n) => n }
  const PDFNumber = { of: (n) => n }
  const env = {
    URL: { createObjectURL: (b) => b, revokeObjectURL: () => {} },
    Blob: class { constructor(parts) { this.dims = parts[0].dims } },
    Image: class { set src(blob) { this.width = blob.dims[0]; this.height = blob.dims[1]; queueMicrotask(() => this.onload()) } },
    document: {
      createElement: () => ({
        getContext: () => ({ fillRect() {}, drawImage() {}, set fillStyle(_) {} }),
        toBlob(cb, _type, q) { encoded = { w: this.width, h: this.height, q }; cb({ size: blobSize, arrayBuffer: async () => new ArrayBuffer(0) }) },
      }),
    },
  }
  const factory = new Function('URL', 'Blob', 'Image', 'document', 'PDFName', 'PDFNumber',
    `${block}; return recompressImage`)
  const recompressImage = factory(env.URL, env.Blob, env.Image, env.document, PDFName, PDFNumber)

  const decisions = []
  for (const level of levels) {
    for (const [w, h] of [[2480, 3508], [3508, 2480], [1120, 800], [800, 1120], [1680, 1680], [600, 400], [5000, 7], [1, 1]]) {
      for (const jpegBytes of [100, 4095, 4096, 50_000, 900_000]) {
        for (const ratio of [0.5, 0.96, 0.97, 0.9701, 0.98, 1.2]) {
          blobSize = Math.round(jpegBytes * ratio)
          encoded = null
          const dict = { get: () => undefined, set: () => {}, delete: () => {} }
          const contents = Object.assign(new Uint8Array(jpegBytes), { dims: [w, h] })
          const stream = { dict, getContents: () => contents }
          const saved = await recompressImage(stream, level)
          decisions.push({ level: level.id, width: w, height: h, originalBytes: jpegBytes, candidateBytes: blobSize, encoded, saved })
        }
      }
    }
  }
  fixtures['compress-pdf'] = { levels, decisions }
}

// ── Image to PDF: page sizes and placement ───────────────────────────────────────────────────
{
  const { IMAGE_EXTS, PAGE_SIZES, imagesToPdf } = await import(pathToFileURL(path.join(src, 'lib/imagePdf.js')).href)
  const images = [[4032, 3024], [3024, 4032], [800, 600], [100, 100], [1, 5000], [5000, 1], [595, 842], [2480, 3508]]
  const layouts = []
  for (const size of Object.keys(PAGE_SIZES)) {
    const files = images.map(([width, height], i) => ({
      name: `img${i}.${i % 2 ? 'png' : 'jpg'}`, type: '', arrayBuffer: async () => ({ width, height }),
    }))
    const pages = await imagesToPdf(files, size)
    layouts.push({ pageSize: size, images, pages })
  }
  // The key order is the order the web offers them in; a JSON object does not keep it for Swift.
  fixtures['image-to-pdf'] = { imageExtensions: IMAGE_EXTS, pageSizeOrder: Object.keys(PAGE_SIZES), pageSizes: PAGE_SIZES, layouts }
}

// ── Write ────────────────────────────────────────────────────────────────────────────────────
fs.mkdirSync(out, { recursive: true })
let changed = 0
for (const [name, value] of Object.entries(fixtures).sort()) {
  const file = path.join(out, `${name}.json`)
  const text = render(value)
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null
  if (before === text) continue
  changed++
  console.log(`${before === null ? 'new' : 'changed'}  ${name}`)
  if (!checkOnly) fs.writeFileSync(file, text)
}
console.log(`${Object.keys(fixtures).length} fixtures, ${changed} ${checkOnly ? 'differ' : 'written'}`)
if (checkOnly && changed) process.exit(1)

// One case per line: diffable when the platform moves, without a 5,000-page expansion spending
// 5,000 lines of the file.
function render(value) {
  const lines = Object.entries(value).map(([key, v]) => {
    const body = Array.isArray(v) && v.length && typeof v[0] === 'object'
      ? `[\n${v.map(item => `  ${JSON.stringify(item)}`).join(',\n')}\n ]`
      : JSON.stringify(v)
    return ` ${JSON.stringify(key)}: ${body}`
  })
  return `{\n${lines.join(',\n')}\n}\n`
}
