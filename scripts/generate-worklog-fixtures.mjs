#!/usr/bin/env node
// Regenerates the work-log golden fixtures from the platform's own stream manager.
//
//   node scripts/generate-worklog-fixtures.mjs <path-to-emperor-ai> [--check]
//
// The web finishes every chat turn by building the assistant message it persists as
// `{ role, content, reasoning, workflowTasks, workLog }` (`src/lib/streamManager.js`, the end of
// `startStream`), and that is the record a reopened conversation redraws its reasoning panel
// from. The app reads those three fields off stored answers and writes its own in the same
// shapes, so the shapes are pinned here against the real thing rather than against anyone's
// reading of `finalizeLog`, `completePlanTasks` and the reasoner's `finish()`.
//
// Nothing is reimplemented. `startStream` is imported and run for real, with its real
// dependencies — `src/lib/api.js`'s `streamAI` (status extraction, chunk holdback),
// `src/tools/reasoning.js`, `src/lib/output.js`'s `stripMeta` — and only these stand-ins:
//   - `fetch` replays a recorded response body, chunk by chunk, as `/chat` writes it;
//   - the clock advances with the recording, so the reasoner's `seconds` is fixed;
//   - `Math.random` is pinned, because the "stopped" wording is drawn at random;
//   - `react` and `useEntitlements` (store, hooks) are inert: a turn never renders.
//
// The recordings are built the way `src/providers/OpenRouterProvider.js` writes a run: `<think>`
// goes to the client only, content goes to the client and to `fullContent`, a round that is
// discarded is rolled back to the `fullContent` length it started at (`rollbackRound`), and the
// first delta of a round after one that ended mid-sentence gets the seam space (`emitContent`).
// `serverContent` is that `fullContent`, trimmed — what `finalizeChatRun` stores as the answer.
//
// Output: `Tests/EmperorCoreTests/WorkLogGolden.swift`, a Swift source file rather than a
// resource, so it needs no change to Package.swift or project.yml.
//
// `--check` writes nothing and exits 1 if the fixture differs.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/lib/streamManager.js'))) {
  console.error('usage: generate-worklog-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/WorkLogGolden.swift')

const stubs = {
  react: 'export const useCallback = (f) => f; export const useSyncExternalStore = () => undefined;',
  '@/lib/useEntitlements': 'export const refreshEntitlements = () => {};',
}

registerHooks({
  resolve(specifier, context, next) {
    if (specifier in stubs) return { url: `emperor-stub:${specifier}`, shortCircuit: true }
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

// A clock the recording drives. 3 October 2026, noon in India, at the start of every run.
const T0 = Date.UTC(2026, 9, 3, 6, 30, 0)
let now = T0
const RealDate = Date
globalThis.Date = class extends RealDate {
  constructor(...args) { if (args.length === 0) super(now); else super(...args) }
  static now() { return now }
}
Math.random = () => 0
// streamAI logs a deliberate stop as a failure; it is not one here.
console.error = () => {}

const { startStream, stopStream } = await import(pathToFileURL(path.join(src, 'lib/streamManager.js')).href)

// ── Recordings ──────────────────────────────────────────────────────────────────────────────
// A recording is a list of segments, at milliseconds from the send:
//   { at, status }   a <status> line (client only)
//   { at, think }    a reasoning sentence (client only — never part of fullContent)
//   { at, text }     content (client and fullContent); `seam: true` marks a round's first delta
//   { at, round }    a new provider round begins here (records fullContent.length)
//   { at, rollback } the round is discarded: <truncate:roundStart/> and fullContent is cut back
//   { at, usage }    the final token accounting, written once at the end (client only)
//   { at, split }    the previous segment's bytes end here — the rest arrives as a new chunk
//   { at, stop }     the reader presses Stop
//   { at, end }      the response ends
function record(segments) {
  const chunks = []   // [at, bytes] exactly as the client receives them
  let fullContent = ''
  let roundStart = 0
  for (const s of segments) {
    if ('round' in s) { roundStart = fullContent.length; continue }
    if ('status' in s) chunks.push([s.at, `<status>${s.status}</status>`])
    else if ('think' in s) chunks.push([s.at, `<think>${s.think}</think>`])
    else if ('text' in s) {
      let bytes = s.text
      // emitContent's seam fix: the round's first delta after text that ends mid-sentence.
      if (s.seam && fullContent && !/\s$/.test(fullContent)) { fullContent += ' '; bytes = ' ' + bytes }
      fullContent += s.text
      chunks.push([s.at, bytes])
    } else if ('rollback' in s) {
      fullContent = fullContent.slice(0, roundStart)
      chunks.push([s.at, `<truncate:${roundStart}/>`])
    } else if ('usage' in s) chunks.push([s.at, `\n<usage>${JSON.stringify(s.usage)}</usage>`])
    else if ('split' in s) {
      // Re-cut the last chunk so a tag straddles two network reads.
      const [at, bytes] = chunks.pop()
      chunks.push([at, bytes.slice(0, s.split)], [s.at, bytes.slice(s.split)])
    } else if ('stop' in s) chunks.push([s.at, null, 'stop'])
    else if ('end' in s) chunks.push([s.at, null, 'end'])
  }
  return { chunks, serverContent: fullContent.trim() }
}

const researchPlan = {
  tasks: [
    {
      title: 'Read the record',
      subtasks: [
        { label: 'Reading the 2019 lease deed to fix the tenancy terms and the notice clause', tools: ['read_raw_pages'], description: 'Establishes the rent, the term and what notice the lease requires.' },
        { label: 'Mapping the eviction notice dated 3 March 2026', tools: ['get_document_map'], description: 'Finds the grounds the landlord relies on.' },
      ],
    },
    {
      title: 'Test the notice',
      subtasks: [
        { label: 'Checking service of the notice against Section 106 of the Transfer of Property Act', tools: ['search_knowledge_base'], description: "Whether fifteen days' notice expiring with the tenancy month was given." },
        { label: 'Writing the advice', description: 'States whether the notice survives and what to plead.' },
      ],
    },
  ],
}

const debtPlan = {
  tasks: [
    {
      title: 'Establish the debt',
      subtasks: [
        { label: 'Reading the supply agreement for the payment terms', tools: ['read_raw_pages'] },
        { label: 'Tracing the unpaid invoices in the ledger', tools: ['search_knowledge_base'] },
      ],
    },
    { title: 'Advise on the demand notice', subtasks: [{ label: 'Testing the debt against Section 8 of the IBC' }] },
  ],
}

const cases = [
  {
    name: 'research',
    about: 'A reasoning model over two attached documents: ambient statuses, a heartbeat, a plan, three notes and two rounds of tool calls, one status split across two reads, citations, follow-ups and usage.',
    ended: 'completed',
    segments: [
      { at: 0, round: true },
      { at: 0, status: 'Thinking...' },
      { at: 400, status: 'Reading: Lease_Deed_2019.pdf, Eviction_Notice_March_2026.pdf' },
      { at: 2100, think: 'The tenant wants to know whether the eviction notice can be resisted.' },
      { at: 2600, think: 'I need the lease terms first, then the notice itself,\n  and how it was served.' },
      { at: 3900, text: `<plan>${JSON.stringify(researchPlan)}</plan>\n` },
      { at: 4200, text: 'I will start with the lease and the notice.' },
      { at: 4300, status: 'Reading pages 1–6 of Lease Deed 2019' },
      { at: 4310, status: 'Mapping the structure of Eviction Notice March 2026' },
      { at: 24400, status: 'Still working…' },
      { at: 31000, round: true },
      { at: 31000, think: 'Clause 11 requires one calendar month of notice.' },
      { at: 31500, seam: true, text: "The lease creates a monthly tenancy at a rent of ₹42,000, payable by the seventh of each month, and clause 11 requires one calendar month's written notice from either side. The notice of 3 March 2026 relies on four months of arrears and gives fifteen days to vacate. Before reaching a view I need to see how the notice was served and whether the arrears were ever tendered." },
      { at: 31700, status: 'Searching the record for: service of the notice by registered post' },
      { at: 31705, status: 'Reading page 2 of Eviction Notice March 2026' },
      { at: 31710, split: -4 },
      { at: 38900, round: true },
      { at: 38900, think: 'The notice was posted on 4 March and delivered on 9 March, so it gave fewer than fifteen days before the month ended.' },
      { at: 39400, seam: true, text: 'Service is proved by the postal receipt, but the period is short.\n\n' },
      { at: 39500, text: '## Short answer\n\nThe notice is **defective**. A monthly tenancy ends only with the tenancy month, on fifteen days\' notice [1], and this one was delivered on 9 March <@Eviction_Notice_March_2026.pdf:EN-1:2> while the lease runs month to month from the first <@Lease_Deed_2019.pdf:LD-1:4>.\n\n' },
      { at: 44100, text: '## What to plead\n\n1. Delivery on 9 March left fewer than fifteen days before 31 March.\n2. The arrears were tendered by cheque on 20 March <@Eviction_Notice_March_2026.pdf:EN-1:3-4>.\n\n## References\n\n[1] Transfer of Property Act, 1882 — Section 106.\n' },
      { at: 46800, text: '<follow-up-queries>["Draft a reply to the eviction notice","What if the arrears are paid now?","Can the landlord sue for mesne profits?"]</follow-up-queries>' },
      { at: 47200, usage: { prompt_tokens: 18234, completion_tokens: 1290, total_tokens: 19524, cost: 0.0412 } },
      { at: 47650, end: true },
    ],
  },
  {
    name: 'rollback',
    about: 'A flash-tier model (no reasoning) whose answer round is rolled back by the server and redone. The rule the platform applies (`s.at >= offset`) strikes out the round announced at the cut and drops its note: those are the calls written immediately before the discarded round began.',
    ended: 'completed',
    segments: [
      { at: 0, round: true },
      { at: 0, status: 'Thinking...' },
      { at: 300, status: 'Reading: Supply_Agreement.pdf, Invoice_Ledger_FY25.pdf' },
      { at: 1500, text: `<plan>${JSON.stringify(debtPlan)}</plan>\n` },
      { at: 1650, text: 'Let me read the payment clause first.' },
      { at: 1700, status: 'Reading pages 3–5 of Supply Agreement' },
      { at: 8800, round: true },
      { at: 8800, seam: true, text: 'Clause 7 gives the buyer 45 days from each invoice to pay. Now the ledger.' },
      { at: 9000, status: 'Searching the record for: invoices unpaid after 45 days' },
      { at: 9010, status: 'Searching the record for: part payments received' },
      { at: 16000, round: true },
      { at: 16000, seam: true, text: 'The ledger shows four invoices unpaid since January 2026, totalling ₹38,40,000, with one part payment of ₹2,00,000 on 14 February.\n\n## Answer\n\nThe operational debt is' },
      { at: 16400, rollback: true },
      { at: 18400, seam: true, text: 'The ledger shows four invoices unpaid since January 2026, totalling ₹38,40,000, against one part payment of ₹2,00,000 on 14 February 2026.\n\n' },
      { at: 18900, text: '## Short answer\n\nAn operational debt of ₹36,40,000 is due and unpaid <@Invoice_Ledger_FY25.pdf:IL-2:7>, well above the threshold, so a demand notice under Section 8 can issue now.\n' },
      { at: 21000, usage: { prompt_tokens: 9120, completion_tokens: 412, total_tokens: 9532 } },
      { at: 21300, end: true },
    ],
  },
  {
    name: 'plan-only',
    about: 'A reasoning model that plans and answers without calling a tool: a plan and reasoning, an empty work log.',
    ended: 'completed',
    segments: [
      { at: 0, round: true },
      { at: 0, status: 'Thinking...' },
      { at: 1200, think: 'This is a question of law, not of the record.' },
      { at: 1900, think: 'Section 34(3) fixes three months, and the proviso allows thirty days more.' },
      { at: 2600, text: '<plan>{"tasks":[{"title":"State the law","subtasks":[{"label":"Setting out the limitation under Section 34(3)","description":"Three months, plus thirty days on sufficient cause."}]}]}</plan>\n' },
      { at: 2900, text: 'A petition under Section 34 must be filed within three months of receiving the award, extendable by thirty days on sufficient cause and no further [1].\n\n[1] Arbitration and Conciliation Act, 1996 — Section 34(3).' },
      { at: 9400, end: true },
    ],
  },
  {
    name: 'direct',
    about: 'A flash-tier answer with no plan, no reasoning and no tools. The web still stores the three fields, empty.',
    ended: 'completed',
    segments: [
      { at: 0, round: true },
      { at: 0, status: 'Thinking...' },
      { at: 1100, text: 'Yes. Order VII Rule 11 lets the court reject a plaint that is barred by law on its face.' },
      { at: 3300, end: true },
    ],
  },
  {
    name: 'stopped',
    about: 'A reasoning model stopped by the reader while its first round of tool calls is still in flight. Steps never confirmed are stopped, never ticked; the web nevertheless ticks every plan row (`completePlanTasks` runs on every ending).',
    ended: 'stopped',
    segments: [
      { at: 0, round: true },
      { at: 0, status: 'Thinking...' },
      { at: 900, think: 'The question is whether the bail order can be challenged.' },
      { at: 1800, text: '<plan>{"tasks":[{"title":"Read the order","subtasks":[{"label":"Reading the bail order of 12 August 2026","tools":["read_raw_pages"]},{"label":"Finding the conditions imposed","tools":["search_knowledge_base"]}]}]}</plan>\n' },
      { at: 2000, text: 'Let me read the order first.' },
      { at: 2100, status: 'Reading pages 1–3 of Bail Order 12 August 2026' },
      { at: 2110, status: 'Searching the record for: conditions of bail' },
      { at: 6200, stop: true },
    ],
  },
]

// ── Replay ──────────────────────────────────────────────────────────────────────────────────
// streamAI reads `response.ok`, `response.body.getReader()` and `reader.read()`, and nothing
// else, so the replay is exactly that surface. One recorded chunk per read, which is what keeps
// the split status split.
async function replay(c) {
  const { chunks } = record(c.segments)
  const id = `fixture-${c.name}`
  now = T0
  let index = 0
  globalThis.fetch = async (_url, init) => ({
    ok: true,
    status: 200,
    body: {
      getReader: () => ({
        read: async () => {
          const next = chunks[index++]
          if (!next) return { done: true, value: undefined }
          const [at, bytes, kind] = next
          now = T0 + at
          if (kind === 'end') return { done: true, value: undefined }
          if (kind === 'stop') {
            stopStream(id)
            if (init?.signal?.aborted) throw new DOMException('The operation was aborted.', 'AbortError')
          }
          return { done: false, value: new TextEncoder().encode(bytes) }
        },
      }),
    },
  })
  const base = [{ role: 'user', content: 'The question for this fixture.' }]
  const finished = await new Promise((resolve) => {
    startStream(id, {
      kind: 'chat',
      messages: base,
      api: { role: 'Litigator', userId: 1, model: 'fast', source: 'chat', chatId: id },
      onComplete: resolve,
    })
  })
  const message = finished.messages[finished.messages.length - 1]
  if (message?.role !== 'assistant') throw new Error(`${c.name}: no assistant message was built`)
  return {
    name: c.name,
    about: c.about,
    ended: c.ended,
    aborted: finished.aborted,
    // The exact reads the client received, so the Swift side replays the same bytes.
    chunks: chunks.filter(([, bytes]) => bytes !== null).map(([, bytes]) => bytes),
    serverContent: record(c.segments).serverContent,
    // The three fields as the web persists them, and nothing else of the message: its
    // `content` carries the web's own stop wording, which is not part of this contract.
    stored: { reasoning: message.reasoning, workflowTasks: message.workflowTasks, workLog: message.workLog },
  }
}

const results = []
for (const c of cases) results.push(await replay(c))
for (const r of results) {
  if (r.ended === 'stopped' && !r.aborted) throw new Error(`${r.name}: the stop did not register`)
}

// ── A stored conversation ───────────────────────────────────────────────────────────────────
// What `GET /messages` answers for a matter worked on from both clients: `res.end(JSON.stringify(
// { success: true, messages }))` over `getMessages`, which parses each stored row and adds
// `timestamp` from the row when the message has none. The app splices its work log into the
// last answer of exactly these bytes and posts them back, so this body is the one the
// byte-for-byte test splits.
const research = results.find(r => r.name === 'research')
const rollback = results.find(r => r.name === 'rollback')
const messages = [
  // The oldest shape in the platform's own extract (`chat_extracted.json`): the store's
  // `addMessage` gave every message `sources` and `usage`, null or empty, and an `ai-` id.
  { role: 'user', content: 'give me a gist of the Nirbhaya case', attachments: [], timestamp: '2026-05-15T06:21:37.197Z', id: '0b066c14-bc75-4fe1-a75c-a3a42d46ee77', sources: [], usage: null },
  { id: 'ai-1778826098848', role: 'assistant', content: '<think>\nReading the request. ✓\n</think>\nThe **2012 Delhi gang rape and murder case** — "Nirbhaya", meaning fearless — led to the Criminal Law (Amendment) Act, 2013 [iafor.org].', timestamp: '2026-05-15T06:21:38.848Z', sources: [{ title: 'The Nirbhaya case', url: 'https://iafor.org/archives/nirbhaya/' }], usage: { prompt_tokens: 2210, completion_tokens: 640, cost: 0.000731 }, feedback: { rating: 'up', note: 'Quoted in the brief \\ "as is"' } },
  // A turn asked on the web, as `persistAssistantSession` sent it and `/sync` stored it. The user
  // turn carries its attachments; the answer carries the web's work log. Neither had a
  // timestamp, so `getMessages` added the row's.
  { role: 'user', content: 'Is the eviction notice valid?', attachments: [{ name: 'Lease_Deed_2019.pdf', folderName: 'Matters/Sharma v Gupta' }, { name: 'सेल_डीड.pdf', folderName: 'Matters/Sharma v Gupta' }], timestamp: '2026-10-02T11:04:51.302Z' },
  { role: 'assistant', content: research.serverContent, ...research.stored, timestamp: '2026-10-02T11:05:39.950Z' },
  // The question this app asked, as `/chat`'s pre-save stored it — the message verbatim.
  { id: '6F1D3C2A-9B7E-4E15-8C0D-2A4B6E8F1C3D', role: 'user', content: 'Is the operational debt due under the supply agreement?', timestamp: '2026-10-03T06:30:00Z', attachments: [{ name: 'Supply_Agreement.pdf', folderName: 'Matters/Kaveri Steels' }, 'Invoice_Ledger_FY25.pdf'] },
  // The answer as `finalizeChatRun` writes it (`sync-server.js`, the `assistantMsg` literal).
  { role: 'assistant', content: rollback.serverContent, usage: { prompt_tokens: 9120, completion_tokens: 412, total_tokens: 9532 }, isTyping: false, done: true, serverRun: true, incomplete: false, timestamp: '2026-10-03T06:30:21.300Z' },
]
const messagesBody = JSON.stringify({ success: true, messages: JSON.parse(JSON.stringify(messages)) })

const fixture = {
  // Milliseconds from the send to the end of each run — what the reasoner's `seconds` measures.
  cases: results.map(({ aborted, ...r }) => r),
  messagesBody,
  // Which case the last stored answer (the app's own turn) was produced by.
  appTurnCase: 'rollback',
  appQuestionID: '6F1D3C2A-9B7E-4E15-8C0D-2A4B6E8F1C3D',
}
const json = JSON.stringify(fixture, null, 2)
if (json.includes('"""#') || messagesBody.includes('"""#')) {
  throw new Error('fixture would terminate the Swift raw string early')
}

const swift = `// Generated by scripts/generate-worklog-fixtures.mjs from the platform's own
// src/lib/streamManager.js. Do not edit by hand — regenerate it.
//
// Each case is a recorded \`/chat\` response replayed through the web's real \`startStream\`;
// \`stored\` is the \`reasoning\`, \`workflowTasks\` and \`workLog\` the web persisted for it.
// \`messagesBody\` is a \`GET /messages\` response, exactly as the route serialises it.

enum WorkLogGolden {
    static let json = #"""
${json}
"""#
}
`

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === swift) {
  console.log('work-log fixtures: up to date')
  process.exit(0)
}
if (checkOnly) {
  console.error('work-log fixtures: out of date — rerun without --check')
  process.exit(1)
}
fs.writeFileSync(out, swift)
console.log(`work-log fixtures: wrote ${results.length} cases`)
