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

### Accounts, plans and refusals

**Creating an account does not sign anyone in.** `/register` emails a confirmation link and
returns no token; `/login` then refuses the address (403 `EMAIL_UNVERIFIED`) until it is
confirmed. A one-time code from `/auth/otp/request` → `/auth/otp/verify` both signs in and
confirms the address, so it is the quickest way past that — and the only way in for an account
created through Google, which has no password (`/login` answers 409 `SSO_ACCOUNT`). The server
sends at most three codes to one address in fifteen minutes and answers 200 past that, so
`SignInFlow` paces requests rather than promise a code that is not coming.

**Refusals carry a machine-readable `code`; the sentence is for a browser.** The platform meters
plans and refuses new work outside one: `PLAN_REQUIRED`, `QUERY_LIMIT`, `FEATURE_NOT_IN_PLAN`,
`DOCUMENT_LIMIT` (402), `STORAGE_LIMIT` (413), `MATTER_LIMIT`, `SCAN_LIMIT`, `ACCOUNT_SUSPENDED`
(403), `RATE_LIMIT` (429). `Refusal` recognises them and `DisplayText` words them. **This app
takes no money**, so it never repeats the server's "Upgrade your plan…" — a call to action
leading to a purchase made elsewhere is what App Review rejects. `RefusalTests` fails the build
if any refusal message says upgrade, buy or pricing. A refused question goes back to the
composer; a refused background upload is stopped and its reason kept, because asking again gets
the same answer.

**A wrong one-time code is a 401 that says nothing about the session.** `APIError.classify`
reads the `code` before the 401 rule, so `OTP_INVALID` is a refusal and never a sign-out.

**`GET /auth/session` is the `/me` this API lacked.** It returns the account as it stands —
plan, `needsPlan`, `suspended` — and a freshly signed token. The app reads it at launch and on
return (at most every half hour), which is what keeps an account in daily use signed in.

**No cookie jar.** The platform sets an httpOnly auth cookie on every sign-in for browser
requests that cannot carry a header. This client authenticates every request with the bearer
token, so it refuses cookies outright (`APIClient.refuseCookies`) rather than keep a second
credential on the phone. Signing out calls `POST /logout` while the token still works.

**Sign-up asks what the web asks** — full name, email, password and its confirmation, all
required, with the web's placeholders — plus an optional Indian mobile number, sent as
`+91XXXXXXXXXX`. `IndianMobile` ports the platform's `src/lib/phone.js` and is checked against
it case by case (`scripts/generate-phone-fixtures.mjs`); the server stores the number only once
its `users.phone` change is deployed.

**Sign in with Apple and Continue with Google are built and switched off.** They need, in order:
a Google Cloud OAuth client of the **iOS** type; the platform routes `POST /auth/google` and
`POST /auth/apple`, each taking `{ idToken }` (Apple also `name`) and answering as `/login`
does; and the Sign in with Apple capability on the app id. Then set `EMPEROR_GOOGLE_CLIENT_ID`
and `EMPEROR_SOCIAL_SIGN_IN: "YES"` in `project.yml`. Google is never offered without Apple —
App Review guideline 4.8 — and `SocialSignInConfig` enforces that. Google's flow is OAuth with
PKCE in the system browser sheet, because Google refuses sign-in in an embedded web view.

**The chat's busy refusal is recognised by its `[busy]` token**, never by the sentence after it,
which the platform has reworded once already.

**Numbered citations.** The system prompt now asks for `[1]`-style citations and a References
section in every answer. They are a different thing from the `<@file:MARK:7>` annexure tokens
above, and `AnswerCitations` keeps the two apart.

### Matters and calendars

- **`/compliance-calendar` returns a bare array**, and `next_due_date` can be prose — read the
  day from `dateKey`.
- **`/calendar/feed-url` returns a path that already starts with `/api`**, so it is resolved
  against the host, not the API base. A reset happened only if the answer says `rotated: true`.
- **`/cause-list` text fields can arrive as numbers** — the server copies some straight out of
  stored JSON. `CauseListing` decodes either.

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

Some features are built and tested but deliberately have no path to them from any screen —
auction watchlists among them; "Built and deliberately held back" below has the list. Each is
marked at its definition with the reason. **Do not wire one up without confirming the endpoint
contract first.** File and folder deletion, translation history and the calendar subscription
link were held back the same way, and were released once their contracts were confirmed.

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

### Needs a device
- Background upload is built (`BackgroundUploader`) but **its lifecycle is unverified**. The
  chunk arithmetic, the resumable manifest and the body encoding are covered on Linux; the
  delegate callbacks, and above all the terminate-and-relaunch path, need a physical device. A
  simulator does not evict apps the way a phone under memory pressure does.
  `docs/RELEASING.md` lists what to try, in order.

### Built and deliberately held back
These exist, are tested, and have no caller. Each is marked at its definition. **Do not wire one
up without reading why it is held.**
- **Chat rename** (`ChatMetadataService`). `/sync` is the only way to change a title, and it
  either silently ignores the rename or rewrites every message in the conversation. Renaming an
  *empty* chat is safe and is what the service does.
- **Chat delete.** There is no route, and no SQL anywhere deletes a chat. The web client's
  delete is local-only — the conversation returns on the next load and never left any other
  device. A delete that does not delete is worse than none.
- **Auction watchlists.**
- **Sharing a conversation.** These are privileged legal conversations; held back until the
  endpoint contract is confirmed. No screen creates a share link.
- **Marking a statutory deadline done** on the Corporate calendar. The screen reads the web's
  done markers but does not write them, until the endpoint contract is confirmed.
- **The compliance pipeline's history page.** The web's version reads from a service the app
  cannot reach.

### Built, not yet reachable
A different thing from the list above, and worth keeping separate: nobody decided to withhold
these. They are finished, and no screen was ever connected to them. Treat them as work to land
rather than as decisions to respect.
- **CIN decoder** (`Sources/EmperorCore/Cin.swift`). An offline Corporate Identity Number parser
  ported from the platform's `src/lib/cin.js` by way of the Android client's `Cin.kt`, with 515
  lines of tests. Every field is decoded and each result carries its own verification note — for
  a caller that does not exist. The platform reaches this at `/mca-registry`; Android ships it as
  a drawer row. `AuctionDetailView` renders a CIN as a bare string and never decodes it.

### Waiting on the server
- **`POST /delete-account` does not exist.** This blocks App Store listing outright under
  guideline 5.1.1(v) and has no client-side workaround.
- `GET /user-files` returns the whole tree with no pagination and runs a consolidation pass plus
  a `statSync` per entry, so it is refreshed on appear and pull-to-refresh only, never polled. A
  large library will need a cheaper path.
- Two small changes would release the held-back chat features: let `/sync` accept a
  metadata-only update (skip the message rewrite when `messages` is absent, rather than skipping
  the whole chat when it is short), and add a real chat delete.
- `save-case` should include `diaryNumber` in `ext_id`; without it, unrelated matters collide on
  the unique index and the second is refused as "already on the team dashboard"
  (`CourtSearchViewModel.collisionWarning` warns about this from the client, which is the most
  it can do).
