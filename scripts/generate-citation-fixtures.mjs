#!/usr/bin/env node
// Regenerates the citation golden fixtures from the platform's own source.
//
//   node scripts/generate-citation-fixtures.mjs <path-to-emperor-ai> [--check]
//
// `Tests/EmperorCoreTests/Resources/citations.json` is what `CitationGoldenTests` holds the Swift
// port to. Each case is an answer, and the platform's `formatCitationsInMarkdown`
// (`src/lib/citations.js`) is run over it for real, under Node, with nothing stubbed — the module
// imports nothing. From its output two things are read back:
//
//   - `references`: every reference box it drew (`<div id="cite-ref-N" …>`), with its number and
//     its text, and any badge inside that text written back as `[N]`;
//   - `markers`: the number on every badge outside those boxes, in document order.
//
// Those are the two things a reader sees, so they are what the port has to reproduce. The exact
// HTML the web wraps them in is not: the app draws its own.
//
// A case with a `deviation` is one where the app deliberately does not do what the web does —
// rewriting inside code, for instance. Its web output is still recorded, and the test asserts the
// app *differs*, so if the web ever changes its mind the test says so.
//
// `--check` writes nothing and exits 1 if the fixture would change.

import { registerHooks } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import path from 'node:path'

const platform = process.argv[2]
const checkOnly = process.argv.includes('--check')
if (!platform || !fs.existsSync(path.join(platform, 'src/lib/citations.js'))) {
  console.error('usage: generate-citation-fixtures.mjs <path-to-emperor-ai> [--check]')
  process.exit(2)
}
const src = path.resolve(platform, 'src')
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../Tests/EmperorCoreTests/Resources/citations.json')

// The platform's package.json may not declare "type": "module"; its sources are ESM regardless.
registerHooks({
  load(url, context, next) {
    if (url.startsWith('file:') && url.startsWith(pathToFileURL(src).href)) {
      return { format: 'module', source: fs.readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
    }
    return next(url, context)
  },
})

const { formatCitationsInMarkdown } = await import(pathToFileURL(path.join(src, 'lib/citations.js')).href)

// A realistic answer, written the way the system prompt asks for one
// (`src/lib/clerk_identity.js:7-15`): markers in the prose, a table and a quotation carrying them
// too, and a References section at the end.
const POSH = [
  'Under the Sexual Harassment of Women at Workplace (Prevention, Prohibition and Redressal) Act, 2013 (the **POSH Act**) [1], every employer with ten or more employees must constitute an Internal Committee. The obligation is not discretionary: Section 4 makes it mandatory, and Section 26 [1] attaches a penalty of up to ₹50,000 for non-compliance.',
  '',
  '### Whether the complaint is within time',
  '',
  'The Delhi High Court in *Santosh Kumar* [2] held that the three-month limitation under Section 9 may be extended by a further three months for reasons recorded in writing. The framework itself derives from **Vishaka v. State of Rajasthan** [3], which laid down binding guidelines before Parliament legislated [1, 3].',
  '',
  '1. Constitute the Committee under Section 4 [1].',
  '2. Record reasons for any extension of time, as *Santosh Kumar* requires [2].',
  '3. Keep the minutes of every sitting; Ref. 3 explains why the guidelines still matter.',
  '',
  '| Step | Authority |',
  '| --- | --- |',
  '| Constitution of the Committee | Section 4 [1] |',
  '| Extension of limitation | Santosh Kumar [2] |',
  '',
  "> The Committee's inquiry is a fact-finding exercise, not a trial [3].",
  '',
  '## References',
  '[1] Sexual Harassment of Women at Workplace (Prevention, Prohibition and Redressal) Act, 2013 — Sections 4, 9, 26.',
  '[2] Santosh Kumar vs. Secretary, Ministry of Defence, (2018) WP(C) 6919/2017 — Scope of statutory remedy.',
  '[3] Vishaka vs. State of Rajasthan, (1997) 6 SCC 241 — Guidelines for workplace harassment.',
].join('\n')

const cut = (text, marker) => text.slice(0, text.indexOf(marker) + marker.length)

const cases = [
  // ── Agreement: the app must find exactly what the web finds ──────────────────────────────
  ['the platform selftest: one marker and its entry', 'Right to life [1].\n\n[1] Article 21, Constitution of India.'],
  ['the platform selftest: a numbered list under References & Authorities', 'Fundamental rights [1].\n\n### References & Authorities\n1. Constitution of India.'],
  ['the platform selftest: a list of markers', 'See documents [1, 2, 3] for details.'],
  ['the platform selftest: full-width and spoken markers', 'As noted in 【2】 and Citation 4.'],
  ['the platform selftest: a link and a trigger are not markers', '[Read More](https://example.com) and [CANVAS_TRIGGER: doc]'],
  ['a realistic answer', POSH],
  ['a realistic answer, streaming, mid-marker', cut(POSH, '*Santosh Kumar* [2')],
  ['a realistic answer, streaming, References heading arrived', cut(POSH, '## References\n')],
  ['a realistic answer, streaming, first entry arriving', cut(POSH, '## References\n[1] Sexual Har')],
  ['a realistic answer, streaming, second entry not yet numbered', cut(POSH, 'Sections 4, 9, 26.\n[2')],
  ['the three separators an entry may use', 'Held [1], [2] and [3].\n\n[1]: Indian Contract Act, 1872\n[2] - Specific Relief Act, 1963\n[3] — Limitation Act, 1963'],
  ['entries behind a bullet or a number', 'Cited [1] [2] [3] [4].\n\nReferences:\n- [1] Code of Civil Procedure, 1908\n* [2] Code of Criminal Procedure, 1973\n• [3] Bharatiya Nagarik Suraksha Sanhita, 2023\n1. [4] Bharatiya Sakshya Adhiniyam, 2023'],
  ['a marker or number glued to the bracket', 'Cited [1] and [2].\n\n-[1] Glued to a dash\n1.[2] Glued to a number'],
  ['an indented bullet is not an entry, an indented bracket is', 'Cited [1] and [2].\n\n  - [1] Indented bullet\n  [2] Indented bracket'],
  ['a quotation is not an entry', 'Cited [1].\n\n> [1] Inside a quotation'],
  ['a bracket glued to its text is not an entry', 'Cited [1].\n\n[1]Glued'],
  ['a bold References heading still lists its bracketed lines', 'Body [3].\n\n**References**\n[3] - Maneka Gandhi v. Union of India, (1978) 1 SCC 248'],
  ['Sources: with a numbered list', 'Per [1] and [2].\n\nSources:\n1. Indian Kanoon\n2. SCC Online'],
  ['Authorities, numbered, after blank lines', 'Per [1].\n\n#### Authorities\n\n\n1. K.S. Puttaswamy v. Union of India, (2017) 10 SCC 1'],
  ['a numbered list with no heading is not references', 'Per [1].\n\n1. First step\n2. Second step'],
  ['the heading word inside a sentence is not a heading', 'The References section follows.\n1. Not an entry'],
  ['five hashes is not a heading', 'Per [1].\n\n##### Sources\n1. Not an entry'],
  ['References and Authorities spelt out is not a heading', 'Per [1].\n\n## References and Authorities\n1. Not an entry'],
  ['a heading with trailing colon and spaces', 'Per [1].\n\nREFERENCES :  \n1. Constitution of India'],
  ['a numbered entry under the heading needs a space', 'Per [1].\n\nReferences\n1.Not an entry\n2. An entry'],
  ['an indented number under the heading is not an entry', 'Per [1].\n\nReferences\n  1. Indented'],
  ['only the first heading starts the section', 'Steps:\n1. Before any heading\n\nSources\n1. After the first\n\nReferences\n2. After the second'],
  ['two trailing spaces make an entry with no text', 'Per [1].\n\n[1]  '],
  ['one trailing space is not an entry', 'Per [1].\n\n[1] '],
  ['a colon with nothing after it is not an entry', 'Per [1].\n\n[1]:'],
  ['a dash with nothing after it is the text', 'Per [1].\n\n[1] -'],
  ['a body line that opens with a marker is an entry', '[1] The Act came into force in 2013 [2].\n\n[2] Gazette notification, 9 December 2013'],
  ['a number listed twice', 'Per [1].\n\n[1] First listing\n[1] Second listing'],
  ['markers inside a reference', 'Per [1] and [2].\n\n[1] Vishaka v. State of Rajasthan, as affirmed in [2]\n[2] Medha Kotwal Lele v. Union of India, (2013) 1 SCC 297'],
  ['list spacing variants', 'A [1,2] B [1 , 2] C [ 1 ] D [1, ] E [,1]'],
  ['ranges, letters and words are not markers', 'See [2–4], [1-3], [1a], [a1], [Settled], [^1], [ ] and [x].'],
  ['a link whose text is a number is not a marker', '[1](https://indiankanoon.org/doc/1) and [2] (see above).'],
  ['adjacent markers', 'Held [1][2] and [3]【4】.'],
  ['a marker inside literal brackets', 'Held [[1]] and [see [2]].'],
  ['leading zeros', 'Held [01] and [007].'],
  ['spoken markers', 'See Citation 1, citation 2, CITATION 3, Ref 4, ref. 5 and REF.6.'],
  ['spoken markers inside words', 'A Recitation 4 and a Cross-ref 2, but not Ref 12a, citation 3_x, Refs 5 or Reference 6.'],
  ['spoken markers across a line break', 'As Citation\n7 shows.'],
  ['a neutral citation number is citation-shaped', 'Reported as Citation 2023 INSC 5.'],
  ['full-width lists', 'See 【1, 2】 and 【3】【4】.'],
  ['Devanagari prose', 'भारतीय न्याय संहिता [1] की धारा 63 [2] देखें।\n\n## References\n[1] भारतीय न्याय संहिता, 2023\n[2] धारा 63 — बलात्संग'],
  ['Devanagari digits are not markers', 'धारा [१] और [1].\n\n[१] Not an entry\n[1] An entry'],
  ['a table carrying markers', 'Chronology:\n\n| Date | Event |\n| --- | --- |\n| 09.12.2013 | Act in force [1] |\n| 13.08.1997 | Vishaka decided [2] |\n\n[1] POSH Act, 2013\n[2] Vishaka v. State of Rajasthan'],
  ['an orphan marker', 'Body [1] and [7].\n\n[1] Listed'],
  ['no references at all', 'Under the Act [1], and as held [2].'],
  ['nothing citation-shaped', 'No citations here.'],

  // ── Deviations: the app refuses what the web rewrites ─────────────────────────────────────
  ['inline code keeps its brackets', 'Write `arr[1]` in code, cite [1].\n\n[1] Listed', 'code'],
  ['a fenced block is never references', '```\n[1] not an entry\nSee [1]\n```\nCite [1].\n\n[1] Listed', 'code'],
  ['a link keeps its text', '[see [1] here](https://example.com) and [1].\n\n[1] Listed', 'link'],
  ['a reference-style link keeps its label', 'Read [the judgment][2], cite [1].\n\n[1] Listed\n[2] Also listed', 'link'],
  ['a link definition that a link uses is not an entry', 'Read [the Act][3].\n\n[3]: https://indiankanoon.org/doc/1', 'link'],
  ['an escaped bracket is the author asking for one', 'The form \\[1] is literal; cite [1].\n\n[1] Listed', 'escape'],
  ['an autolink keeps its URL', 'See <https://example.com/a[1]> and [1].\n\n[1] Listed', 'link'],
  ['an annexure token still arriving is not read', 'Annexure P-1 <@Agreement [1].pdf:P-', 'annexure'],
  ['the web inserts markers the model left out', 'The Supreme Court in Vishaka vs. State of Rajasthan formulated guidelines.\n\n## References\n[1] Vishaka vs. State of Rajasthan, (1997) 6 SCC 241.', 'autolink'],
  ['the web lets an entry run onto the next line', 'Cited [1].\n\n[1]\nPOSH Act, 2013', 'multiline'],
  ['the web cuts a numbered entry at its first <', 'Per [1].\n\nReferences\n1. Damages < 50,000 under Section 73', 'angle'],
]

function derive(output) {
  const references = []
  const boxes = /<div id="cite-ref-(\d+)" data-cite-target="\d+" class="ex-cite-ref-item"><span class="ex-cite-ref-pill">&#91;\d+&#93;<\/span> ([^\n]*?)<\/div>/g
  for (const m of output.matchAll(boxes)) {
    references.push({ number: Number(m[1]), text: m[2].replace(/\[(\d+)\]\(#cite-\d+\)/g, '[$1]') })
  }
  const body = output.replace(boxes, '')
  const markers = [...body.matchAll(/\[(\d+)\]\(#cite-(\d+)\)/g)].map(m => Number(m[1]))
  return { references, markers }
}

const fixtures = cases.map(([name, input, deviation]) => {
  const output = formatCitationsInMarkdown(input)
  return { name, input, deviation: deviation ?? null, web: { output, ...derive(output) } }
})

const text = JSON.stringify({
  source: 'src/lib/citations.js — formatCitationsInMarkdown',
  generatedBy: 'scripts/generate-citation-fixtures.mjs',
  cases: fixtures,
}, null, 1) + '\n'

const before = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : null
if (before === text) {
  console.log(`${fixtures.length} cases, unchanged`)
} else if (checkOnly) {
  console.log(`${fixtures.length} cases, fixture differs`)
  process.exit(1)
} else {
  fs.writeFileSync(out, text)
  console.log(`${fixtures.length} cases, written`)
}
