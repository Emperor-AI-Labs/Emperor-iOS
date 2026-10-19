#!/usr/bin/env node
// Regenerates the draft-editing golden fixture from the platform's own source.
//
//   node scripts/generate-draft-edit-fixtures.mjs <path-to-emperor-ai> [--check]
//
// `Tests/EmperorCoreTests/DraftEditGolden.swift` is what `DraftEditGoldenTests` holds `DraftEdit`
// to. Everything in it comes from running the platform's JavaScript under Node:
//
//   - `folds` — `withEditedDraft(conversation, html, ownerIndex)` and `lastAssistantIndex`, cut by
//     name out of `src/tools/ToolWorkspace.jsx` and evaluated over the real `replaceCanvasBody`
//     (`src/lib/output.js`, imported with its two export-only dependencies stood in). A case
//     records the conversation's contents afterwards, or `null` when the web returned it untouched.
//   - `strips` — `stripMeta` (exported), and `stripLeadingNarration` and `isBlockHtml`, cut by name
//     from `src/lib/output.js`.
//   - `stored` — what the server files in the Drafts list for one assistant message: the derivation
//     inside `setMessages` (`sync-server.js`), cut out verbatim and run with its database calls
//     recorded instead of made, over `cleanCanvasContent` and `stripLeadingNarration` cut from the
//     same file, `stripMentions` cut from `lib/filing/registry.js`, and the real
//     `resolveCanvasType` from `src/lib/canvasShape.js`. Every fold's result is run through it
//     too, so the test can hold the app to the body the server will recognise.
//   - `shapes` — `canvasShape` (`src/lib/canvasShape.js`).
//
// The platform checkout must carry `sync-server.js` beside `src/` and `lib/`.
// `--check` writes nothing and exits 1 if the fixture differs.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
const need = ['src/tools/ToolWorkspace.jsx', 'src/lib/output.js', 'src/lib/canvasShape.js', 'sync-server.js', 'lib/filing/registry.js']
if (!platform || need.some(f => !fs.existsSync(path.join(platform, f)))) {
  console.error('usage: generate-draft-edit-fixtures.mjs <path-to-emperor-ai> [--check]')
  console.error(`  the checkout must contain: ${need.join(', ')}`)
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/DraftEditGolden.swift')

// output.js imports these for its download helpers only; nothing exercised here reaches them.
const stubs = {
  '@/lib/htmlToDocx': 'export const htmlToDocxBlob = () => null;',
  '@/lib/pageSetup': 'export const pageDimensions = () => ({});',
}

registerHooks({
  resolve(specifier, context, next) {
    if (specifier in stubs) return { url: `emperor-stub:${specifier}`, shortCircuit: true }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (url.startsWith('emperor-stub:')) {
      return { format: 'module', source: stubs[url.slice('emperor-stub:'.length)], shortCircuit: true }
    }
    // The platform's package.json may not declare "type": "module"; its sources are ESM regardless.
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

const { replaceCanvasBody, stripMeta } = await import(pathToFileURL(path.join(src, 'lib/output.js')).href)
const { canvasShape, resolveCanvasType } = await import(pathToFileURL(path.join(src, 'lib/canvasShape.js')).href)

const read = (f) => fs.readFileSync(path.join(platform, f), 'utf8')

// A top-level `function name(…) { … }`, cut from its line to the first closing brace in column 0.
// A renamed or reshaped function fails here, loudly.
function cutFunction(text, name, file) {
  const m = text.match(new RegExp(`(?:^|\\n)(?:export )?function ${name}\\([\\s\\S]*?\\n\\}`))
  if (!m) { console.error(`${name} not found in ${file}`); process.exit(1) }
  return m[0].replace(/^\n/, '').replace(/^export /, '')
}
function cutConst(text, name, file) {
  const m = text.match(new RegExp(`(?:^|\\n)(?:export )?const ${name} = [^\\n]*`))
  if (!m) { console.error(`${name} not found in ${file}`); process.exit(1) }
  return m[0].replace(/^\n/, '').replace(/^export /, '')
}

// ── The web's fold ────────────────────────────────────────────────────────────────────────────
const workspace = read('src/tools/ToolWorkspace.jsx')
const { withEditedDraft, lastAssistantIndex } = new Function('replaceCanvasBody', `
  ${cutFunction(workspace, 'lastAssistantIndex', 'ToolWorkspace.jsx')}
  ${cutFunction(workspace, 'withEditedDraft', 'ToolWorkspace.jsx')}
  return { withEditedDraft, lastAssistantIndex }
`)(replaceCanvasBody)

const output = read('src/lib/output.js')
const { stripLeadingNarration, isBlockHtml } = new Function(`
  ${cutFunction(output, 'stripLeadingNarration', 'output.js')}
  ${cutConst(output, 'BLOCK_TAG_RE', 'output.js')}
  ${cutFunction(output, 'isBlockHtml', 'output.js')}
  return { stripLeadingNarration, isBlockHtml }
`)()

// ── The server's derivation ───────────────────────────────────────────────────────────────────
const server = read('sync-server.js')
const registry = read('lib/filing/registry.js')
const startMark = 'const hasTrigger = !!msg.content'
const endMark = '\n    });\n    tx();\n}'
const start = server.indexOf(startMark)
const end = server.indexOf(endMark, start)
if (start < 0 || end < 0) { console.error('the setMessages derivation was not found in sync-server.js'); process.exit(1) }
const derive = new Function('resolveCanvasType', `
  ${cutFunction(server, 'stripLeadingNarration', 'sync-server.js')}
  ${cutFunction(server, 'cleanCanvasContent', 'sync-server.js')}
  ${cutConst(registry, 'MENTION_RE', 'registry.js')}
  ${cutFunction(registry, 'stripMentions', 'registry.js')}
  return function derive(message) {
    const saved = []
    const db = { prepare: () => ({ get: () => ({ user_id: 7 }), run: () => {} }) }
    const chatId = 'chat-1', DATA_DIR = '', source = 'chat'
    const syncAnnexuresFromMentions = () => {}
    const saveCanvasDocument = (_db, row) => { saved.push(row) }
    const messages = [message]
    // The block below is the body of setMessages' loop, from its first line to the loop's close.
    for (const msg of messages) {
      ${server.slice(start, end)}
    return saved
  }
`)(resolveCanvasType)

function stored(content) {
  const rows = derive({ role: 'assistant', content })
  if (!rows.length) return null
  const row = rows[0]
  return { title: row.title, declaredType: row.type, resolvedType: resolveCanvasType(row.type, row.content).type, content: row.content }
}

// ── Cases ─────────────────────────────────────────────────────────────────────────────────────
const PLAINT = [
  '<h1 style="text-align:center">IN THE HIGH COURT OF DELHI AT NEW DELHI</h1>',
  '<p style="text-align:center"><strong>CS (COMM) No. ___ of 2026</strong></p>',
  '<p><strong>SYNOPSIS</strong></p>',
  '<p>The Plaintiff supplied steel coils to the Defendant under a Supply Agreement dated 4 March 2024 — invoices were raised — and the Defendant has not paid [1].</p>',
  '<p>Annexure P-2: True copy of the ledger <@Ledger_FY25.pdf:P-2:4-9></p>',
  '<h2>PRAYER</h2>',
  '<p>It is therefore prayed that this Hon\'ble Court may be pleased to decree the suit for ₹42,00,000 with interest at 18% p.a.</p>',
].join('\n')
const EDITED = [
  '<h1 style="text-align: center;">IN THE HIGH COURT OF DELHI AT NEW DELHI</h1>',
  '<p style="text-align: center;"><strong>CS (COMM) No. 412 of 2026</strong></p>',
  '<p><strong>SYNOPSIS</strong></p>',
  '<p>The Plaintiff supplied <u>hot-rolled</u> steel coils to the Defendant under a Supply Agreement dated 4 March 2024 and the Defendant has not paid [1].</p>',
  '<p>Annexure P-2: True copy of the ledger</p>',
  '<h2 id="doc-h-3">PRAYER</h2>',
  '<p>It is therefore prayed that this Hon\'ble Court may be pleased to decree the suit for ₹42,00,000 with interest at 18% p.a. — costs $1 and \\1 included.</p>',
].join('\n')
const LOD = '| Date | Event |\n| --- | --- |\n| 04.03.2024 | Supply Agreement executed |\n| 12.09.2025 | Demand notice served |'
const LOD_EDITED = '<table><thead><tr><th>Date</th><th>Event</th></tr></thead><tbody><tr><td>04.03.2024</td><td>Supply Agreement executed</td></tr><tr><td>12.09.2025</td><td>Demand notice served by <b>speed post</b></td></tr></tbody></table>'
const USER = { role: 'user', content: 'Draft a commercial plaint for recovery of ₹42 lakh.' }
const REFS = '\n\n## References\n[1] Commercial Courts Act, 2015 — Section 12A.'
const LONG = '<p>' + 'The Defendant acknowledged the debt in writing on several occasions. '.repeat(5) + '</p>'

const conversations = [
  { name: 'wrapped', about: 'The usual turn: narration, the trigger, the wrapper, then references.',
    conversation: [USER, { role: 'assistant', content: `Here is the plaint.\n\n[CANVAS_TRIGGER: Commercial Plaint — Kaveri Steels]\n<canvas_content>\n${PLAINT}\n</canvas_content>${REFS}<usage>{"prompt_tokens":10}</usage>` }],
    html: EDITED, ownerIndex: 1 },
  { name: 'mentionKept', about: 'An edit that kept the citation token carries nothing extra.',
    conversation: [USER, { role: 'assistant', content: `[CANVAS_TRIGGER: Plaint]\n<canvas_content>${PLAINT}</canvas_content>` }],
    html: EDITED.replace('the ledger</p>', 'the ledger <@Ledger_FY25.pdf:P-2:4-9></p>'), ownerIndex: 1 },
  { name: 'table', about: 'A Markdown List of Dates edited as the HTML table it is drawn as stays in <table_content>.',
    conversation: [USER, { role: 'assistant', content: `[TABLE_TRIGGER: List of Dates]\n<table_content>\n${LOD}\n</table_content>` }],
    html: LOD_EDITED, ownerIndex: 1 },
  { name: 'unclosed', about: 'A wrapper that never closed is closed by the fold.',
    conversation: [USER, { role: 'assistant', content: `[CANVAS_TRIGGER: Notice]\n<canvas_content>\n<p>Notice under Section 80 CPC</p>\n` }],
    html: '<p>Notice under Section 80 of the Code of Civil Procedure, 1908</p>', ownerIndex: 1 },
  { name: 'uppercaseWrapper', about: 'The wrapper is matched whatever its case, and keeps its own spelling.',
    conversation: [USER, { role: 'assistant', content: `[CANVAS_TRIGGER: Reply]\n<CANVAS_CONTENT><p>Reply to notice</p></CANVAS_CONTENT>` }],
    html: '<p>Reply to the legal notice dated 1 October 2026</p>', ownerIndex: 1 },
  { name: 'triggerOnly', about: 'A trigger with no wrapper: the trigger line is kept and the rest replaced.',
    conversation: [USER, { role: 'assistant', content: `I have drafted it below.\n[CANVAS_TRIGGER: Affidavit]\n${LONG}\n<p>Deponent</p>` }],
    html: '<p>AFFIDAVIT of the deponent, sworn at New Delhi.</p>', ownerIndex: 1 },
  { name: 'bareBlockHtml', about: 'A message that is the document end to end, with no wrapper or trigger.',
    conversation: [USER, { role: 'assistant', content: '<h2>Memo</h2><p>One.</p><p>Two.</p>' }],
    html: '<h2>Memo</h2><p>One, revised.</p><p>Two.</p>', ownerIndex: 1 },
  { name: 'prose', about: 'An ordinary answer holds no document: the edit cannot be placed.',
    conversation: [USER, { role: 'assistant', content: 'Section 12A requires pre-institution mediation unless urgent relief is sought.' }],
    html: '<p>Anything</p>', ownerIndex: 1 },
  { name: 'notLastAssistant', about: 'Position is identity: an earlier draft cannot take an edit.',
    conversation: [USER, { role: 'assistant', content: `[CANVAS_TRIGGER: First]\n<canvas_content><p>First draft</p></canvas_content>` },
      { role: 'user', content: 'Now a reply.' }, { role: 'assistant', content: 'Here it is: <canvas_content><p>Second</p></canvas_content>' }],
    html: '<p>First draft, edited</p>', ownerIndex: 1 },
  { name: 'lastOfSeveral', about: 'The last assistant turn after a user turn takes the edit.',
    conversation: [USER, { role: 'assistant', content: `[CANVAS_TRIGGER: First]\n<canvas_content><p>First draft</p></canvas_content>` },
      { role: 'user', content: 'Now a reply.' }, { role: 'assistant', content: '[CANVAS_TRIGGER: Reply]\n<canvas_content><p>Second</p></canvas_content>' }],
    html: '<p>Second, edited</p>', ownerIndex: 3 },
  { name: 'trailingUser', about: 'A question already sent after the draft: the last assistant index still governs.',
    conversation: [USER, { role: 'assistant', content: '[CANVAS_TRIGGER: Reply]\n<canvas_content><p>Second</p></canvas_content>' }, { role: 'user', content: 'Shorter please.' }],
    html: '<p>Second, edited</p>', ownerIndex: 1 },
  { name: 'unchanged', about: 'An edit identical to the stored body changes nothing.',
    conversation: [USER, { role: 'assistant', content: '[CANVAS_TRIGGER: Reply]\n<canvas_content>\n<p>Same</p>\n</canvas_content>' }],
    html: '<p>Same</p>', ownerIndex: 1 },
  { name: 'emptyEdit', about: 'An empty edit is never placed.',
    conversation: [USER, { role: 'assistant', content: '[CANVAS_TRIGGER: Reply]\n<canvas_content><p>Same</p></canvas_content>' }],
    html: '', ownerIndex: 1 },
  { name: 'thinkAndTrigger', about: 'Reasoning before the draft that names the wrapper: the real wrapper takes the edit.',
    conversation: [USER, { role: 'assistant', content: '<think>I will wrap it in <canvas_content> tags.</think>\n[CANVAS_TRIGGER: Undertaking]\n<canvas_content><p>I undertake</p></canvas_content>' }],
    html: '<p>I solemnly undertake</p>', ownerIndex: 1 },
]

const folds = conversations.map(c => {
  const next = withEditedDraft(c.conversation, c.html, c.ownerIndex)
  const after = next === c.conversation ? null : next.map(m => m.content)
  return {
    name: c.name, about: c.about, html: c.html, ownerIndex: c.ownerIndex,
    roles: c.conversation.map(m => m.role), contents: c.conversation.map(m => m.content),
    lastAssistantIndex: lastAssistantIndex(c.conversation),
    after,
    storedBefore: c.conversation.map(m => (m.role === 'assistant' ? stored(m.content) : null)),
    storedAfter: after ? after.map((content, i) => (c.conversation[i].role === 'assistant' ? stored(content) : null)) : null,
  }
})

const stripInputs = [
  '<think>plan</think>\n<p>Body</p>\n<usage>{"x":1}</usage>',
  '<p>Body</p><status>Reading page 3</status> and more <plan>{"tasks":[]}</plan>',
  '<p>Kept</p>\n<reasoning>still going and never closed',
  '<STATUS foo="bar">x</STATUS><p>case</p><truncate:12/>',
  'Now I will draft the plaint.\n\n<h1>PLAINT</h1>',
  'The plaint follows.\n\n<h1>PLAINT</h1>',
  '  Let me prepare it\n \n <p>x</p>',
  '<p>one</p>',
  '  <center>Title</center>',
  'Text <td>a</td><td>b</td><li>c</li>',
  'Text <br><br><br> only',
  '| a | b |\n| --- | --- |',
]
const strips = stripInputs.map(input => ({
  input, stripMeta: stripMeta(input), stripLeadingNarration: stripLeadingNarration(input), isBlockHtml: isBlockHtml(input),
}))

const shapeInputs = [
  '', '<p></p>&nbsp;', '<hr>', LOD, LOD_EDITED, PLAINT,
  '<h2>List of Authorities</h2>' + LOD_EDITED,
  '<p>' + 'x'.repeat(500) + '</p>' + LOD_EDITED,
  'Plain words only',
  '<p>&sect;</p>',
]
const shapes = shapeInputs.map(input => ({ input, shape: canvasShape(input), asTable: resolveCanvasType('table', input).type }))

const storedInputs = [
  `[TABLE_TRIGGER: Dates]\n<table_content>\n<p>Not a table at all <@a.pdf:P-1></p>\n</table_content>`,
  `[CANVAS_TRIGGER: Bulleted]\n<canvas_content>\n\`\`\`html\n- <p>one</p>\n• <p>two</p>\n... <p>three</p>\n\`\`\`\n</canvas_content>`,
  `[CANVAS_TRIGGER: Long trigger only]\n${LONG}<usage>{"a":1}</usage>`,
  `[CANVAS_TRIGGER: Short trigger only]\n<p>Too short</p>`,
  `Narration only, no document.`,
]
const storedOnly = storedInputs.map(content => ({ content, stored: stored(content) }))

const fixture = { folds, strips, shapes, stored: storedOnly }
const json = JSON.stringify(fixture, null, 2)
if (json.includes('"""#')) throw new Error('fixture would terminate the Swift raw string early')

const swift = `// Generated by scripts/generate-draft-edit-fixtures.mjs from the platform's own
// src/tools/ToolWorkspace.jsx (withEditedDraft), src/lib/output.js, src/lib/canvasShape.js,
// sync-server.js (setMessages' draft derivation) and lib/filing/registry.js. Do not edit by
// hand — regenerate it.

enum DraftEditGolden {
    static let json = #"""
${json}
"""#
}
`

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === swift) {
  console.log('draft-edit fixtures: up to date')
  process.exit(0)
}
if (checkOnly) {
  console.error('draft-edit fixtures: out of date — rerun without --check')
  process.exit(1)
}
fs.writeFileSync(out, swift)
console.log(`draft-edit fixtures: wrote ${folds.length} folds, ${strips.length} strips, ${shapes.length} shapes, ${storedOnly.length} stored`)
