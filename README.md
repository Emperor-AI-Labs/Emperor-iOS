# Emperor

A native SwiftUI iOS client for the **Emperor** platform.

**Emperor** names the whole product: this app, the Android client, and the web platform.
Juristar was the platform's earlier name and survives only in older comments.

v1 scope: **chat with your documents** and **document capture + upload**.

## Layout

| Path | What it is |
|---|---|
| `Sources/EmperorCore/` | Pure-logic core: stream parsing, wire models, HTTP layer. Foundation-only, no UI framework. |
| `Emperor/` | The SwiftUI app: session, views, view models, document scanner. |
| `Tests/EmperorCoreTests/` | Tests for the core. Runs on Linux and macOS. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |

The app target compiles `Sources/EmperorCore` directly, so the code under test is
byte-for-byte the code that ships — there is no second copy to drift.

## Brand

The app icon is generated from the landing page's `logo.svg` — the same mark the website uses.
The source SVG is kept at `Emperor/Resources/logo.svg`, and the rendered icon at
`Emperor/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (1024x1024, RGB, no
alpha channel — the App Store rejects icons with transparency).

To regenerate after a logo change: render the SVG to PNG, trim the surrounding whitespace,
and centre the mark on a square white canvas at about 66% fill.

## Build

```bash
brew install xcodegen
xcodegen generate
open Emperor.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` before archiving.

The logic tests need no Mac:

```bash
swift test
```

## Why the core is a separate, Foundation-only layer

The backend's chat endpoint is a hand-rolled wire format with enough edge cases that
verifying it on a device would be slow and unreliable. Keeping the parser free of UIKit and
SwiftUI means it compiles and tests anywhere, including CI.

## What this client has to know about the backend

These are not stylistic choices — each one is load-bearing, and getting it wrong fails
quietly rather than loudly.

**The chat stream is not SSE.** It is `text/plain` with `Transfer-Encoding: chunked`,
carrying prose with pseudo-XML control tags interleaved directly into the text. No framing,
no `data:` prefixes, **no terminator** — end-of-body is the only completion signal.

**A clean end-of-stream does not mean the answer finished.** An aborted run ends its
response with no error bytes at all, so a truncated answer is indistinguishable from a
complete one at the transport layer. `GET /stream-status` is the only authoritative signal,
and the client checks it after every turn.

**`<truncate:N/>` retroactively shortens the answer.** It means a generation round is being
rolled back and retried. `N` is a **UTF-16 offset**, because the server computes it with
JavaScript's `.length`. Slicing by Swift `Character` offsets drifts on any emoji or non-BMP
character.

**`POST /chat` is destructive to history.** The server replaces the chat's stored messages
with exactly what the request contained, plus the new answer. Anything omitted from the
`messages` array is **deleted server-side**. Always send the full conversation.

**Do not call `POST /sync` after a chat turn.** `/chat` already persists the turn twice, and
`/sync` silently drops any chat whose message count is lower than the server's — so a stale
local copy is discarded without an error.

**A 200 on the final upload chunk means "bytes received", not "file ready".** Assembly,
OCR and indexing all run after the response has closed, so a failure there produces no HTTP
error — it surfaces only as an `ERROR:` string from `/upload-status`. Polling is mandatory.

**Filenames are sanitised per UTF-16 code unit.** `[^A-Za-z0-9._-]` becomes `_`, applied the
way a JavaScript regex applies it. Mapping over Swift `Character`s collapses each Devanagari
grapheme cluster to one underscore, so a Hindi filename would be polled at a path that never
resolves and the upload would appear to hang forever.

**Timestamps arrive in two formats on the same field.** SQLite's `"YYYY-MM-DD HH:MM:SS"`
(UTC, no zone marker) for server-side writes, ISO-8601 with milliseconds for anything
`/sync` stored. The ingest `progress` object uses epoch milliseconds instead. `WireDate`
handles all three.

**Status codes are not reliable.** A missing parameter yields 500 on most routes;
`/stream-status` returns 200 for every error including `Forbidden`. Branch on the `error`
key in the body.

**`role` must be omitted, never sent empty.** The value reaches the model's leading
instructions. A JavaScript default parameter fires on `undefined` only — so `null` tells the
model it is "a top-tier, highly experienced null", and `""` leaves the sentence dangling.
`ChatRole?` maps `nil` to an omitted key for exactly this reason, and the allowed set is an
enum rather than free text.

**`ChatModel` is an enum because only these aliases are supported.** An unrecognised one is not
rejected locally, so a typo becomes a request for a model that does not exist. `preferred_model`
from the login response is only a seed for the picker; the per-request value wins
unconditionally.

**Artifact wrappers are a claim, not a fact.** The platform records a live incident
(`src/lib/canvasShape.js:1-9`) where a pleading arrived as 81 HTML paragraphs inside
`<table_content>`. Render by sniffing the body, not by trusting the tag.

**Citations travel inline, in three forms** — `<@file.ext:MARK>`, `<@file.ext:MARK:7>` and
`<@file.ext:MARK:4-9>`. These are the paper trail — the product's whole claim is that every
line names a page you can open — so they are parsed into `AnnexureMention`, surfaced as a
tappable strip, and resolved to the source document. They must also be preserved when writing
an edited document back, or the trail is destroyed.

Handle **all three** forms: the server strips only *well-formed* tokens, so one the client
fails to match is not stripped either — it renders verbatim in the middle of a pleading. The
cited page is **1-based** (`pageNumber: idx + 1`, `sync-server.js:1479`); PDFKit is 0-based.

**Reasoning arrives under six different wrappers**, not just `<think>`: also `<thinking>`,
`<scratchpad>`, `<reasoning>`, `<internal>`, `<reflection>`. Missing one puts the model's
private working in front of a client.

**Attachments must be sent twice** — the top-level array and the last message are read by
different passes, so both must carry them or the model sees an incomplete set.

### A caution on reading the platform

The platform's own `AGENTS.md` was corrected on 2026-08-25 and now carries a `file:line`
citation on every claim. Before that it named the wrong LLM provider, the wrong models and
the wrong vector collection — so if you are reading a copy older than that date, verify
against source first.

The bigger trap is dead code that reads like specification: `ChatWindow.jsx`,
`ChatWindow_original.jsx`, `Canvas.jsx`, `clerkConfig.js` (whose `supportedRoles` list is
*not* the wire contract), `models_registry.json`, and `convertTemplateTags()` with its
`%center%`/`%table%` token language. All were verified unreachable by grepping for importers.
The live chat surface is `src/tools/ToolWorkspace.jsx` rendering through
`src/tools/renderers/Markdown.jsx`.

Everything in this client was read from source rather than from those docs.

## Server-side hardening is still in progress

Send both the bearer token **and** `userId` on every request — `APIClient` does this
automatically. The client sends both so that it keeps working unchanged once the server derives
the caller from the token alone.

Some features are built and tested but deliberately have no path to them from any screen — file
and folder deletion, auction watchlists, server-side OCR history. Each is marked at its
definition with the reason. **Do not wire one up without confirming the endpoint contract
first.**

The specifics — what is outstanding, and in what order — are tracked privately rather than here.

The session token is long-lived, which is why it lives in the Keychain as
`WhenUnlockedThisDeviceOnly` and never in `UserDefaults`.

## The reasoning panel

`ReasoningTracker` is a faithful port of the platform's `src/lib/streamManager.js`, because
that design solves problems that are not obvious from outside:

- The model emits `<plan>` as **one JSON blob**, so every row arrives in the same instant.
  A flat cursor advances through it, driven only by real signals — a `<status>` meaning a
  genuine tool call finished, or the answer starting to stream — never by a timer. Without
  it the panel snaps from empty straight to a finished list.
- The server writes every tool call of a round back-to-back **before** any result returns, so
  a run of statuses with no prose between them *is* one agentic round. That natural batching
  becomes a group; the model narrating again closes it.
- Ambient chatter ("Preparing…", "Thinking…", Pre-RAG's "Reading: a.pdf, b.pdf") is a useful
  live status but is not work the model chose to do. Counting it once padded a run of 8 tool
  calls into "14 steps", so only four label shapes qualify as steps — the colon is what
  separates a real "Reading pages 55-73 of X" from the ambient listing.
- A rolled-back round's calls are marked **superseded**, not deleted: they really happened,
  but their results were discarded, so they must never wear the same tick as a call that
  delivered.

Step labels are kept raw. The platform generalises them to "Reading your files…" for its
one-line status, which would throw away the document name and page range — exactly what
makes a log worth reading.

**Known limitation:** the work log is not persisted. The server stores only the answer text,
so reopening a chat shows the answer without the log of how it was produced.

## Still to do
- Markdown artifacts render as monospace text. GFM tables need a real renderer —
  `AttributedString(markdown:)` does not support tables.
- File library is picker-only. No preview, rename, move, delete, or favourite toggling yet
  (`/view-file`, `/rename-file`, `/move-file`, `/delete-file`, `/favorite-file` all exist).
- `GET /user-files` returns the whole tree with no pagination and runs a consolidation pass
  plus a `statSync` per entry, so it is refreshed on appear and pull-to-refresh only, never
  polled. A large library will need a cheaper path.
- Background upload via `URLSessionConfiguration.background` so a large paperbook survives
  the app being backgrounded.
- Chat rename/delete via `POST /sync` (metadata only — never after a turn).
