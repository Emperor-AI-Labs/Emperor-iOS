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
`messages` array is **deleted server-side**. Always send the full conversation — every
message with every key it was stored with. A field this client does not model (the web's work
log, `serverRun`) is deleted unless it goes back; `ChatMessage.extra` keeps them.

**`POST /sync` after a chat turn is for the work log only, and only when it is provably
safe.** `/chat` already persists the turn, and `/sync` either silently ignores a chat whose
message count is lower than the server's or deletes and re-inserts every message of it. The web
calls it at the end of every turn to store the turn's work log — safe for the web because at
that instant its array is exactly what the server holds. This client does the same only when
`WorkLogSync` allows: the turn ended cleanly, the history loaded whole, `/stream-status`
reports nothing running, and a fresh `GET /messages` matches the transcript message for
message, ending in this client's own question (by id) and the server's finished answer. What it
posts is those stored bytes with the log added to the last message — never a re-encoding — and
its next turn waits for it. A save that does not happen is silent; the answer is stored either
way.

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
from the login response only seeds the composer's Quick | Thinking switch; the per-request value wins
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
(403), `RATE_LIMIT` (429). `Refusal` recognises them and `DisplayText` words them: a refusal
says what happened, never "Upgrade your plan…", and `RefusalTests` fails the build if one says
upgrade, buy or pricing. A refused question goes back to the composer; a refused background
upload is stopped and its reason kept, because asking again gets the same answer.

**Plans are bought on the web.** This app takes no money. Where a plan is the answer — the
plan refusals, the no-plan banner, Plan & usage in Settings — a separate **View plans** button
opens the web app's `/buy` page in Safari, on the same host the app talks to, so the plan lands
on the signed-in account. Returning to the app reads the account at once
(`Session.noteOpenedPlans`). It is never offered for a paused account or the hourly ceiling,
which no plan changes. App Review restricts links to purchases made outside the app (guidelines
3.1.1 and 3.1.3) and what is allowed differs by storefront: `EMPEROR_WEB_PLANS: "NO"` in
`project.yml` removes every button. Check the current guidelines before each submission. See
`WebPlans`.

**The role is the account's.** `users.practice_role` holds the web's id for it, so switching
role in Settings switches the web too, and the other way round (`Practice`). The device keeps a
copy for drawing the toolkit offline; a switch made here that has not reached the account yet
is sent again rather than overwritten. A role this app does not carry — the web's Devil's
Advocate — is left alone on the account. Needs the platform's `practice_role` change deployed;
until then the role stays on the device and nothing breaks.

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

### Notifications

Settings → Notifications schedules, on the device, a morning briefing and an evening-before
reminder for each day the person's matters are listed — never for an empty day — and announces
new items in the Updates feed from background refresh. Permission is asked for only from the
switch. The "Email briefing" switch is the platform's own daily email, account-wide and shared
with the web. Tapping a hearing opens the Calendar on that hearing's day; tapping an update
opens Updates over Home — and if another sheet is open at the time, as soon as it closes; the
person's own sheet is never taken away. The app-icon badge is the unread count, set on every
refresh, on return to the app, and the moment Updates marks something read. There is no remote
push: the server has no APNs sender, so a reminder for a listing added on the web reaches the
device at its next refresh.

### Today: widget, Siri and links

- **Widget** (`EmperorWidget/`): Home Screen small/medium/large, Lock Screen rectangular and
  inline. It reads only a snapshot the app writes to the app group (`TodaySnapshot`: the next
  seven days of listings, when they were fetched, and whether anyone is signed in — no token)
  whenever the cause list is saved; cleared on sign-out. Days are IST, and the timeline turns at
  each Indian midnight. Matter rows are `.privacySensitive()`, so a locked device shows counts
  only.
- **The app group is found at run time** (`AppGroup`): `EmperorAppGroup` (`EMPEROR_APP_GROUP`),
  then `group.` + the installed bundle id — a sideloading tool may rename it. With none, the app
  is unaffected and the widget says to open the app.
- **Links**: `emperor://calendar[?day=YYYY-MM-DD]` and `emperor://updates`. They only navigate
  (`EmperorLink`), through the same path as a notification tap.
- **Siri and Shortcuts** (App Intents): What's Listed Today / Tomorrow, from the cached cause
  list (its age said past six hours; requires the device unlocked), and Open My Calendar.
- **Signing**: the widget is a second bundle (`com.emperorailabs.emperor.widget`) and needs its
  own App ID and the App Groups capability.

### App lock and privacy cover

Settings → Security turns on "Require Face ID" (Touch ID / Optic ID / passcode, whichever the
device has — `LAPolicy.deviceOwnerAuthentication`), with a "Lock after" choice (Immediately to
After 1 hour; default 1 minute). Turning it on asks first; a device without a passcode cannot
turn it on. The app locks at a cold start with a stored session and on a return after the
background has lasted at least the timeout, measured on `ContinuousClock` so a changed date
cannot shorten it. Whenever the scene is not active a brand cover hides the app — lock or no
lock — so the app switcher never shows a matter. The cover is its own `UIWindow` above alerts,
because a view-level cover sits under sheets. The setting is the device's and survives sign-out;
the login screen is never locked. Decisions are `AppLock` (core, tested); drawing is
`AppLockShield`. Widgets, Spotlight results and notification text live outside the app and are
not behind the lock — each has its own privacy rule (above, and below).

### Offline reading

Conversations, documents (a Word file as the server's PDF of it) and matters that open are kept
on the device per account. They are read back only when the system reports no connection or a
request cannot reach the server — never in place of an answer the server gave
(`OfflineReading`). A saved conversation is read-only: `POST /chat` and `/sync` rewrite stored
history, so nothing is sent until a fresh, whole history has loaded
(`ChatViewModel.savedCopyAt`). Documents are capped at 300 MB — least recently opened first,
"Save for offline" last. Copies live in Application Support, excluded from backup, sealed
whenever the device is locked; the response cache stays readable after first unlock because
background refresh reads the cause list. Signing out wipes all of it (`ResponseCache.clear`).
Settings → Storage shows and clears it.

### Profile, documents shared in, and Spotlight

- **`/update-profile` clears what it is not sent.** It writes `avatar`, `title` and
  `organization` from the request, so a missing key clears that field; only `name` keeps its
  value when omitted, and `phone` changes only when its key is present. `ProfileEditor` sends
  all four fields on every save and never sends `phone`. The photo uses the web's format:
  centre-cropped to 256 px, JPEG, as a `data:image/jpeg;base64,` URL, capped at 150 KB. The
  reply is adopted into `Session` (`adoptProfile`), keeping the plan, starting model and role.
- **Documents shared into the app** arrive through "Open in…" and the share sheet via
  `CFBundleDocumentTypes`, with `LSSupportsOpeningDocumentsInPlace` off, so iOS hands over a
  copy. There is no share extension — that would need an app group a sideloading tool may not
  grant. `IncomingDocumentStore` keeps each file until it is saved or let go; one that arrives
  signed out waits for the next sign-in, and signing out lets all of them go. "Save to My Files"
  uploads through `LibraryUploadFlow`, duplicate check included.
- **Spotlight.** Cases and documents are indexed into the app's own protected index, replaced in
  full on every docket and My Files load. It is emptied on sign-out, when the Settings switch is
  off, and at launch if either applies.

### Matters and calendars

- **`court_type` is `'district'` by default** — the `cases` column's default, and what
  `/save-case` writes when no type is sent. `CourtTier` lets a court code or name that says
  otherwise outrank a stored `district`, and reads the code and name whenever the type is
  missing. The docket's headings run Supreme Court → High Courts → NCLAT → NCLT → Tribunals →
  District Courts → Consumer Commissions → Other courts; NCLAT sits above NCLT deliberately,
  unlike the web's `COURT_ORDER`.
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

## iPad

At regular width the Cases and Chat tabs show the list beside what it opens
(`ListBesideDetail`). Both layouts read one navigation path — the phone pushes it, the split
shows its last element (`ListDetailPath`) — so `AppNavigator` requests work unchanged. Sheets
that are whole screens get `.pageSizedSheet()` (iOS 18+); single-list screens get
`.readableColumn()`. A matter whose load is cancelled part-way (the column rebuilt while its
tab was off screen) goes back to idle and loads on its next appearance.

## Accessibility

Contrast is tested, not eyeballed: `PaletteTests` measures every text colour on every surface
and every wash text is drawn on (`Palette.Wash`), in both themes. Text in the accent is
`accentText`, never `accent`, which is a fill. Layouts survive the accessibility text sizes
through `AdaptiveStack` (a row that becomes a column) and `.dynamicLineLimit(n)`; outcomes that
land away from VoiceOver's focus are said with `VoiceOver.announce`.
`UITests/AccessibilityAuditTests.swift` runs Xcode's accessibility audit over the main screens on
iPhone and iPad, in both themes, and photographs the main tabs at the largest text size
(`a11y-xxxl-*` in the screenshot-tour artifact). A failure names the screen, the issue and the
element; the few waivers, each with its reason, are listed in that file.

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

**The work log is stored with the answer, in the web's shapes.** The web stores `reasoning`,
`workflowTasks` and `workLog` on every assistant message it finishes (`streamManager.js`), and
the server keeps message JSON verbatim. `WorkLogWire` reads them back — leniently: a malformed
field costs only itself — and the panel is drawn, collapsed, above every stored answer that has
one. This client attaches its own finished panel to its own answer in the same shapes, so the
next `POST /chat` carries it, and stores it straight away through `/sync` when that is safe
(above). Both directions are pinned to the web's own `startStream` run under Node
(`scripts/generate-worklog-fixtures.mjs`). One deliberate difference: a stopped run keeps the
plan rows it never reached pending, where the web ticks every row.

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
- A way to set fields on one stored message without rewriting the chat would let the work log
  be stored after every turn, not only when the stored conversation provably matches, and would
  remove the `GET /chats` the save makes to echo the chat's title, role and model back.
- `save-case` should include `diaryNumber` in `ext_id`; without it, unrelated matters collide on
  the unique index and the second is refused as "already on the team dashboard"
  (`CourtSearchViewModel.collisionWarning` warns about this from the client, which is the most
  it can do).
