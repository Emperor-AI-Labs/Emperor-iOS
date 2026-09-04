# Emperor — working notes

**Emperor** is the whole product — this app, the Android client, and the web platform. Juristar
was the platform's earlier name; `emperor-ai/WORK-LOG.md:8` records the change. Where an old
comment still says Juristar, it means this same system.

## Where the platform reference lives

This app is a client for a backend whose wire format is hand-rolled and largely undocumented.
**Read the platform source rather than guessing** — that is how every real bug in this client
was found.

Expected local layout:

```
<your projects dir>/
  emperor-ios/     ← this repo
  emperor-ai/     ← platform source, reference only. Never edit.
```

If `emperor-ai/` sits elsewhere, adjust the paths below. That checkout is what the backend
citations in this repo refer to.

The reference copy is **source only** — no `node_modules`, no `Data/`, no `chroma_db/`, no
`venv/`. It does not run. It is there to be read.

### The files worth reading

| Path | Why |
|---|---|
| `sync-server.js` | Every backend route. One 13,665-line `if/else` chain — **grep it, never read it whole** |
| `src/lib/clerk_identity.js` | The only live system prompt. Defines citation tokens and artifact wrappers |
| `src/lib/output.js` | How the web client strips control tags — the spec our `StreamContent` mirrors |
| `src/lib/streamManager.js` | Plan cursor + agentic work log — the spec our `ReasoningTracker` ports |
| `src/lib/canvasShape.js` | Why artifact format must be sniffed, not trusted |
| `src/lib/api.js` | The transport layer: `<status>` extraction, chunk holdback |
| `src/providers/OpenRouterProvider.js` | Model aliases, retries, `<truncate:N/>` |
| `src/roles/roleConfig.js` | The real role contract (7 UI roles → 3 wire values) |
| `lib/filing/index.js` | Filing assembly. Follow `getUserFromRequest` in `sync-server.js` for caller resolution |
| `AGENTS.md` | Corrected 2026-08-25; every claim carries a `file:line` |

### Do not trust these — verified dead code

`ChatWindow.jsx`, `ChatWindow_original.jsx`, `Canvas.jsx`, `clerkConfig.js` (its
`supportedRoles` is **not** the wire contract), `models_registry.json`,
`convertTemplateTags()`, `src/pages/Library.jsx`, `FeedbackWidget.jsx`, `POST /draft`,
`/library-books/*`, `/bare-acts/*`.

**Always `grep` for an importer before treating a component as specification.** The live chat
surface is `src/tools/ToolWorkspace.jsx`, rendering through `src/tools/renderers/Markdown.jsx`.

## Repository

Emperor is its own repository, independent of the platform.

```bash
git clone https://github.com/Emperor-AI-Labs/Emperor-iOS.git emperor-ios
```

**This repository is public.** The platform it talks to is still being hardened, so nothing here
may name which server route is unscoped, or how to construct a request that gets past a check.
Say what this client does and why; never what the server fails to do. `scripts/check-public-safe.sh`
enforces that and runs in CI — if it fails, rewrite the comment rather than narrowing the pattern.

The platform lives in a separate, private repo and must never be committed here — the
`emperor-ai/` copy beside this one is read-only reference.

## Working on Linux (the normal case)

Development happens on Linux; a Mac is used only for what genuinely cannot be done without
one — compiling the SwiftUI layer, the simulator, signing, and submission. So **push as much
as possible into `Sources/EmperorCore/`**, which builds and tests here.

```bash
sudo apt install swiftlang     # Swift 6.1.3 on Ubuntu; no iOS SDK, but the core builds
cd emperor-ios && swift test    # 618 tests
```

View models live in the core for this reason — turn state, recovery and error handling are
where the real bugs are, and they are all verifiable without a device.

### Two Linux toolchain traps, both already worked around

**1. `@Observable` compiles but does not link on Linux.** The apt toolchain ships a
`libswiftObservation.so` with an undefined `swift::threading::fatal`, so the macro builds and
then fails at link time — taking the whole test suite with it. The workaround is to apply the
attribute only on Apple platforms:

```swift
#if canImport(Darwin)
import Observation
#endif

#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SomeViewModel { … }
```

On Linux it is then a plain class, which is exactly what tests need. Note `swift file.swift`
runs *interpreted* and never links, so a quick one-off script will wrongly suggest it works.

**2. Linux XCTest cannot invoke a `@MainActor` test method.** It aborts the run with
`Could not cast value of type '(Tests) -> @MainActor () -> ()'`. Keep test classes
un-isolated and hop through a **free function** helper — not a method, because an
`XCTestCase` is not `Sendable` and Swift 6 rejects capturing `self` in a `@MainActor`
closure. See `ChatViewModelTests.swift` for the working shape.

**3. A stale `.build` can produce a phantom linker error.** If you hit an undefined symbol
that makes no sense against the current source, `rm -rf .build` before investigating further.

## How to work on this repo

- **Put logic in `Sources/EmperorCore/`.** It is Foundation-only — no UIKit, no SwiftUI — so it
  compiles and tests anywhere, including Linux and CI. `swift test` runs 618 tests in a few
  seconds. Anything that could plausibly live there should.
- **A view should hold no logic worth testing.** Everything a screen does other than lay itself
  out — loading, error wording, selection, empty-state rules — belongs in a `@MainActor` view
  model in the core. Where that needs a service, the service declares a protocol next to itself
  (`ChatProviding`, `ChatListProviding`, `FileProviding`, `UploadProviding`, `CredentialStore`)
  and the view model takes the protocol, so the screen can be driven with no server and no
  device. `Tests/EmperorCoreTests/Fakes.swift` holds the stand-ins.
- **The SwiftUI layer in `Emperor/` needs Xcode.** It was authored on a Linux box with no iOS
  SDK, so **none of it has ever been type-checked**. Keeping it thin is the point: what remains
  there is what genuinely needs UIKit, SwiftUI or the Security framework.
- **`swiftc -parse $(find Emperor -name '*.swift')` is the standing gate for that layer.** It
  runs without the iOS SDK and catches every syntax error, and it is in CI. It does **not**
  type-check — two real compile errors (a `@Sendable` closure capturing a `@Bindable` local, a
  non-`Sendable` `UserDefaults` in a `Sendable` struct) parsed cleanly and were caught only by
  reproducing them against `swiftc -swift-version 6 -typecheck`. When you suspect something,
  build a minimal repro with mock types and compile it; do not reason about it by eye.
- **The Xcode project is generated**, not committed: `xcodegen generate`. Add files by editing
  `project.yml`.
- The app target compiles `Sources/EmperorCore` directly, so the tested code and the shipped
  code are the same bytes.

## Backend gotchas that bite silently

Full detail in `README.md`. The short list:

1. **`POST /chat` is destructive to history** — the server stores exactly the messages you sent
   plus the answer, deleting the rest. Always send the full conversation.
2. **A clean end-of-stream does not mean the answer finished.** Confirm with `/stream-status`.
3. **`<truncate:N/>` offsets are UTF-16**, because the server computes them in JavaScript.
4. **Filenames are sanitised per UTF-16 code unit** — mapping over Swift `Character`s breaks
   every Devanagari filename.
5. **`role` must be omitted, never sent empty** — an empty string lands in the system prompt.
6. **Timestamps arrive in four encodings** on different fields — ISO8601 with milliseconds,
   zoneless SQLite `CURRENT_TIMESTAMP`, bare `YYYY-MM-DD`, and epoch millis. One `GET /case`
   response carries three of them at once. Use `WireDate`; a single `dateDecodingStrategy`
   cannot do it.
7. **Status codes are unreliable** — `/stream-status` returns 200 for errors. Branch on `error`.
8. **A 200 on the last upload chunk means "bytes received", not "file ready".** Poll.
9. **Every court date means a day in India**, not in the device's zone. Bucketing the cause
   list against `Calendar.current` shows the wrong day's hearings to anyone travelling. Use
   `WireDate.dayKey` / `WireDate.parseDay`, which are pinned to `Asia/Kolkata`.
10. **`/cause-list` takes no date range** — it returns every listing for every date. Fetch once,
    window locally.
11. **`/enhance-prompt` answers 200 on every failure**, with an empty or half-finished body and
    no error envelope. Streaming it straight into the composer leaves a truncated half-sentence
    the user never wrote. Once a chunk has landed the box is *ours*: restore the original.
12. **The four diary routes answer 200 for everything**, and a *validation* error is caught and
    reported as "could not reach the court". An incomplete form is therefore indistinguishable
    from an outage — check completeness client-side, or the user retries forever.
13. **`favorite-file` tests `favorite !== false`.** A missing key stars the document. Omitting
    the field is not a read; it is a write in the wrong direction.
14. **`rename-file` force-preserves the extension** and sanitises the rest. The name the user
    typed is a request; render the one the response echoes back. Annexure citations match the
    exact on-disk name.
15. **`delete-file` and `delete-folder` succeed on a path that is not there.** "It worked" is
    not evidence the file existed. Refetch rather than patching the local model.
16. **`/documents` and `/tables` return the same array under both keys** — on `/tables`, the
    `documents` key holds tables. Key off the path you called, never the key name.
17. **`POST /save-case` can refuse an unrelated case with "already on the team dashboard".**
    `ext_id` falls back to `courtCode|caseType|caseNumber|caseYear`, and the diary routes leave
    all of those empty for NCLAT (always), NCLT and CNR-less SC matters — so they collide on a
    unique index. A 409 means "already pinned" only if the card has a CNR or a case number.
18. **`/documents/content` returns `{"success":true,"content":""}` for an id that does not
    exist**, so "gone" and "empty" are the same response. Treat an empty body as "unknown",
    never as "confirmed empty".

## Runtime connectivity

The host is chosen by `APIEnvironment`, not hard-coded. Debug builds resolve to
`dev.emperorailabs.com`; Release resolves to `backend.emperorailabs.com`. A Release build
**cannot** be made to point at the dev tunnel — `APIConfig.resolveEnvironment` forces production
regardless of the build setting, and `APIEnvironmentTests` pins that.

Both hosts are public and need no VPN, so a build on your Mac reaches the platform straight
away.

Server-side hardening is still in progress, and this client already sends both a bearer token
and `userId` so it keeps working unchanged once the server derives the caller from the token.
Where a route is not yet scoped to the authenticated caller, the corresponding feature is held
back rather than shipped — see `README.md` and the `- Warning:` notes at each definition.

## The reports

The status reports, the platform audit and the parity plan are **not in this repository** — they
are kept privately. Ask if you need them.
