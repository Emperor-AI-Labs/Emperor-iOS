#!/usr/bin/env node
// Regenerates the golden data for uploading a whole folder.
//
//   node scripts/generate-upload-junk-fixtures.mjs <path-to-emperor-ai> [--check]
//
// Two of the platform's modules decide what a folder upload sends, and `FolderUploadPlan` /
// `UploadJunk` are held to both:
//   - `src/lib/junkNames.js` — which picked files are operating-system debris (`.DS_Store`,
//     `._Award.pdf`, anything under `__MACOSX/`). The web's upload dialog and the server's upload
//     route share it, so a junk file is dropped before the count is shown and never sent.
//   - `src/lib/uploadDuplicates.js` — `destinationFor`, which turns a file's path inside the picked
//     folder into the folder it lands in and the name it lands under, and `normFolder`, the
//     comparison it uses.
// Neither module imports anything, so both are loaded as they are.
//
// Output: `Tests/EmperorCoreTests/Resources/upload-folder/upload-folder.json`. `--check` writes
// nothing and exits 1 if the file would change.

import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const junkPath = platform && path.join(platform, 'src/lib/junkNames.js')
const dupPath = platform && path.join(platform, 'src/lib/uploadDuplicates.js')
if (!platform || !fs.existsSync(junkPath) || !fs.existsSync(dupPath)) {
  console.error('usage: generate-upload-junk-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const junk = await import(pathToFileURL(path.resolve(junkPath)).href)
const dup = await import(pathToFileURL(path.resolve(dupPath)).href)
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/upload-folder/upload-folder.json')

// Paths as a folder pick names them: the picked folder first.
const junkInputs = [
  'Wadhwa/Plaint.pdf',
  'Wadhwa/.DS_Store',
  'Wadhwa/.ds_store',
  'Wadhwa/Orders/._Order.pdf',
  'Wadhwa/._.DS_Store',
  'Wadhwa/__MACOSX/Plaint.pdf',
  'Wadhwa/__macosx/Orders/._x.pdf',
  'Wadhwa/Thumbs.db',
  'Wadhwa/THUMBS.DB',
  'Wadhwa/Thumbs.db:encryptable',
  'Wadhwa/desktop.ini',
  'Wadhwa/Icon\r',
  'Wadhwa/Icon',
  'Wadhwa/Icon\r\r',
  'Wadhwa/._',
  'Wadhwa/._a',
  'Wadhwa/$RECYCLE.BIN/x.pdf',
  'Wadhwa/System Volume Information/x.pdf',
  'Wadhwa/.Spotlight-V100/store.db',
  'Wadhwa/.Trashes/x.pdf',
  'Wadhwa/.Trash-1000/files/x.pdf',
  'Wadhwa/.directory',
  'Wadhwa/.localized',
  'Wadhwa/.apdisk',
  'Wadhwa/recycler/x.pdf',
  'Wadhwa\\Thumbs.db',
  'Wadhwa\\Orders\\Plaint.pdf',
  'Wadhwa/Orders/',
  'Wadhwa/.hidden.pdf',
  'Wadhwa/..',
  'Wadhwa/.',
  '.DS_Store',
  'Plaint.pdf',
  'ehthumbs_vista.db',
  'Wadhwa/देखिए.pdf',
  '',
]

const junkCases = junkInputs.map((p) => ({
  path: p,
  isJunkPath: junk.isJunkPath(p),
  pathReason: junk.junkPathReason(p),
  isJunkName: junk.isJunkName(p),
  nameReason: junk.junkNameReason(p),
}))

// [relativePath, name, destination]. A folder pick always has a path of two segments or more.
const destinationInputs = [
  ['Wadhwa/Plaint.pdf', 'Plaint.pdf', 'Clients'],
  ['Wadhwa/Orders/Order.pdf', 'Order.pdf', 'Clients'],
  ['Wadhwa/Orders/2025/Order.pdf', 'Order.pdf', 'Clients/Matters'],
  ['Wadhwa/Plaint.pdf', 'Plaint.pdf', 'Wadhwa'],
  ['Wadhwa/Orders/Order.pdf', 'Order.pdf', 'Wadhwa'],
  ['Wadhwa/Plaint.pdf', 'Plaint.pdf', 'Clients/Wadhwa'],
  ['Wadhwa Matter/Plaint.pdf', 'Plaint.pdf', 'Wadhwa_Matter'],
  ['WADHWA/Plaint.pdf', 'Plaint.pdf', 'wadhwa'],
  ['Wadhwa/Plaint.pdf', 'Plaint.pdf', 'Clients/Wadhwa/'],
  ['Bakshi/Wadhwa/Plaint.pdf', 'Plaint.pdf', 'Wadhwa'],
  ['Wadhwa//Orders/Order.pdf', 'Order.pdf', 'Clients'],
  ['मामला/आदेश.pdf', 'आदेश.pdf', 'मामला'],
  ['', 'Plaint.pdf', 'Clients'],
]

const destinationCases = destinationInputs.map(([relativePath, name, folder]) => {
  const got = dup.destinationFor({ webkitRelativePath: relativePath, name }, folder)
  return { relativePath, name, folder, folderName: got.targetFolder, fileName: got.fileName }
})

const normInputs = ['Wadhwa Matter', '  Clients/Wadhwa  ', 'A&B (2025)', 'ÉCOLE', 'देखिए', 'a  b', 'x.y-z_w/v', '']
const normCases = normInputs.map((raw) => ({ raw, normalized: dup.normFolder(raw) }))

const json = JSON.stringify({ junk: junkCases, destinations: destinationCases, normFolder: normCases }, null, 2) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === json) {
  console.log('upload-folder fixtures: up to date')
  process.exit(0)
}
if (checkOnly) {
  console.error('upload-folder fixtures: out of date — rerun without --check')
  process.exit(1)
}
fs.mkdirSync(path.dirname(out), { recursive: true })
fs.writeFileSync(out, json)
console.log(`upload-folder fixtures: wrote ${junkCases.length} junk, ${destinationCases.length} destination and ${normCases.length} normFolder cases`)
