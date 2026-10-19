# Web ↔ iOS parity (audit of 2026-10-19)

The web app (`EmperorAI`, `master` at the merge of PR 51) was walked route by route — the
router in `src/App.jsx`, the sidebar (`src/shell/Sidebar.jsx`), the phone nav
(`src/shell/MobileNav.jsx`), the topbar and its menus, every page under `src/pages/**`, the tool
registry (`src/tools/**`) and every backend call the client makes — and each user-facing thing
was compared with this app. Items marked **built now** landed on branch `web-parity-rest`
(together with the Library and Fetch Orders work on its sibling branch).

Status key: **done** = already in the app before this audit · **built now** = added by this
branch · **partial** = present, with the named gap · **held back** = built or buildable, kept
out of the screens for the stated reason · **n/a** = web-only by nature.

## Navigation and shell

| Web feature | Web source | iOS status |
|---|---|---|
| Home (role deck, greeting, today's cause list, recent conversations, matters card) | `src/pages/Home.jsx`, `src/pages/home/*` | done — Ask tab (`AskHomeView`) and the role workspace (`RoleHomeView`) |
| Phone nav: Home · Matters · Chat · Corporate (when entitled) · More | `src/shell/MobileNav.jsx` | done — four tabs (Ask, Matters, Files, You); Corporate Calendar and the rest under You → Tools |
| Sidebar: History, My Files, Library, Matters, Calendar, Fetch Orders, Devil's Advocate, Doc Index, List of Dates, Doc tools group | `src/shell/Sidebar.jsx` | done / built now — see the rows below; every row has a destination in the app |
| Role selector and per-role sub-modes (corporate context, NGO mode, student level, litigator matter) | `src/shell/Topbar.jsx`, `src/roles/segOptions.js` | done — `RolePickerView`, `ROLE_CARD_FILTERS`, `LitigatorWorkspaceView`. The Devil's Advocate *role* is deliberately not carried (CLAUDE.md); its *tool* is |
| Notification bell (list, unread count) | `src/shell/NotificationBell.jsx` | done — `NotificationsView` |
| Help menu → Report a bug (description + screenshots to the support inbox) | `src/shell/HelpMenu.jsx`, `BugReportModal.jsx` | built now — `BugReportSheet` under You (`POST /support-feedback`, kind `bug`) |
| Help menu → Hard refresh | `src/shell/HelpMenu.jsx` | n/a — a browser cache reset |
| Command palette, product tour, update gate, coming-soon pages | `src/shell/CommandPalette.jsx`, `Tour.jsx`, `UpdateGate.jsx`, `ComingSoonFeature.jsx` | n/a — keyboard/browser affordances; the App Store handles updates |
| Account menu: Settings, sign out | `src/shell/Topbar.jsx` | done — You tab |

## Ask Emperor (chat, drafting, tools)

| Web feature | Web source | iOS status |
|---|---|---|
| Streaming chat with status, thinking, plan/work log, citations, artifacts (document/table), follow-ups, usage | `src/tools/ToolWorkspace.jsx`, `src/lib/api.js`, `src/lib/output.js`, `streamManager.js`, `citations.js` | done — `ChatViewModel`, `ChatStreamParser`, `ReasoningTracker`, `AnswerCitations`, `ArtifactView` |
| Fast / deep-thinking mode, web search on purpose | `src/tools/ToolWorkspace.jsx` | done — `ChatModel`, `webSearch` |
| Attach documents (Submit Files drawer, My Files picker) | `src/tools/AttachControl.jsx`, `useAttachments.js` | done — `FileLibraryView` picker, scans via `DocumentScannerView` |
| Prompt enhancer with `{{PLACEHOLDER}}` fill-in fields | `src/lib/usePromptEnhancer.js`, `src/tools/EnhancedPromptFields.jsx` | done — `PromptEnhancerViewModel` (restores the original on the 200-on-failure quirk), `EnhancedPromptSheet` |
| Edit and re-answer a question | `ToolWorkspace.jsx` | done — `ChatViewModel.edit` |
| Stop generation; rejoin a run after leaving | `ToolWorkspace.jsx`, `/stream-status` | done |
| Report an answer (thumbs down + reason) | `src/components/chat/*Feedback*`, `POST /draft-feedback` | done — `ReportAnswerSheet` |
| Export a drafted document: Word / PDF, with or without citations | `src/lib/output.js`, `DocumentExportMenu` | done — `DocumentExportMenu`, `DocxDocument`, `AnswerPDF` |
| List of Annexures under a finished draft (open original PDF or typed copy) | `ToolWorkspace.jsx` `AnnexuresCard`, `/filing/annexures*` | built now — `AnnexuresCard`, `FilingAnnexureService` |
| Filing-ready package download (draft + annexures, Word or PDF) | `src/lib/output.js` ~300-360 | built now — `FilingPackage` + export menu items |
| Twenty-nine registry tools (`/w/:toolId`) and the role card decks | `src/tools/registry.js`, `src/tools/definitions/*`, `src/roles/*Cards.js` | done — `REGISTRY_TOOLS`, `ROLE_CARDS` (golden-pinned against the platform's JavaScript) |
| Litigator matter workspace (`/litigator/:matter`) | `src/pages/LitigatorMatter.jsx`, `Litigator*.jsx` | done — `LitigatorWorkspaceView` |
| Document canvas editing in place (contenteditable A4 page, page setup) | `src/tools/DocPane.jsx`, `useDocEditor.js`, `PageSetupMenu.jsx` | n/a — a desktop editing surface; the draft is read, exported and continued in conversation on the phone |
| Deep research (`/deep-research`) | `src/components/chat/ChatWindow.jsx` only | n/a — dead code on the web (the only caller is the unmounted `ChatWindow.jsx`; see CLAUDE.md) |
| Share a conversation (`/share-chat`, `/share/:shareId`) | `src/lib/api.js`, `src/pages/SharedChatView` | held back — privileged legal conversations; no screen creates a share link until the product confirms the sharing contract (README, "Built and deliberately held back") |
| History page: list, search, open | `src/pages/ChatHistory.jsx` | done + built now — `ChatListView`; search added (`ChatListViewModel.searchText`) |
| History page: rename, delete | `src/pages/ChatHistory.jsx` | held back — the web does both through `/sync`, which re-writes the conversation's stored messages; see CLAUDE.md gotcha 19 and `ChatMetadataService` |
| Saved drafts and tables (`/docs`, `/tables` → Library) | `src/pages/HistoryV2.jsx`, `GET /documents`, `/tables` | done — `DraftHistoryView` |

## Analysis tools (server-run jobs)

| Web feature | Web source | iOS status |
|---|---|---|
| Analysis hub | `src/pages/analysis/AnalysisHub.jsx` | built now — `AnalysisHubView` (You → Tools → Analysis tools) |
| Doc Index: pick My Files documents, start, poll, typed table result | `DocIndexPage.jsx`, `useAnalysis.js`, `lib/analysis/schemas.js` | built now — `AnalysisService`, `AnalysisRunViewModel`, `DocIndexResultView` |
| List of Dates: rules/events chart, limitation line, In sum | `ListOfDatesPage.jsx` | built now — `ListOfDatesResultView` |
| Devil's Advocate: exposure, weak spots, bench questions, gaps, authorities, checklist | `DevilsAdvocate.jsx` | built now — `DevilsAdvocateResultView` |
| Per-tool history: list, reopen, delete | `AnalysisHistory.jsx`, `useAnalysisHistory.js` | built now — `AnalysisHistoryView` |
| Result export | `AnalysisKit.jsx` (print/DOCX) | built now — plain-text share of a result |
| Highlighter | `HighlighterPage.jsx` | n/a — the web's page is a sample with no route behind it, hidden from the sidebar and admin-only by address (`App.jsx:271`); the prompt-only Highlighter tool is in the registry on both |
| List of Dates "Enlarge → editable document" | `ListOfDatesPage.jsx` (PR 51) | n/a — the desktop canvas editor (see above); the result is readable and shareable |
| Prompt-only analysis tools (Blind Spots, Caseflow, …) | `src/tools/definitions/*` | done — `ANALYSIS_TOOLS` |

## Matters

| Web feature | Web source | iOS status |
|---|---|---|
| Matters list: search, status filter, practice-area filter, sort, archived | `src/pages/Projects.jsx` | done (search, archived) + built now (status, area, sort) — `ProjectListViewModel` |
| Grid / list layout toggle | `Projects.jsx` | n/a — one list on a phone |
| Tracked cases without a matter listed alongside; opening one makes the matter | `src/components/matters/trackedCases.js`, `POST /project-from-case` | done — `MattersView` docket + `ProjectService.projectFromCase` (opened from the case page and Tools) |
| New matter: name, banner preset, folder colour, then the court case (find / not filed yet / later) | `NewMatterDialog.jsx`, `trackCase.js` | built now — `NewMatterSheet`, `NewMatterViewModel` |
| Edit details (every project field) | `src/components/projects/shared.jsx` | built now — `EditMatterSheet` |
| Delete a matter (typed confirmation) | `ProjectWorkspace.jsx`, `DELETE /project?confirm=` | built now — Overview → Delete matter |
| Workspace header: banner image or preset gradient | `ProjectBanner.jsx`, `/project-banner` | built now — `MatterBannerView`, upload (≤ 2 MB JPEG/PNG/WebP) and remove |
| Overview: where things stand, setup strip, tiles, facts | `sections/OverviewSection.jsx` | done — `ProjectDetailViewModel` (`MatterStanding`, `MatterSetup`) |
| Overview timeline (alternating sides, horizontal option) | `OverviewSection.jsx` | partial — the chronology and court record are two sections, by design (see `ProjectDetailViewModel`); no drawn timeline |
| Ask Emperor inside the matter (its own conversations, matter files only, open full screen) | `sections/AskSection.jsx` | built now — `MatterAskSection`, `ChatThreadView(projectID:)`, `MatterFilePicker`; every turn carries `projectId` |
| Files: folders, attach from My Files, open, rename, delete, processing status | `sections/FilesSection.jsx`, `AttachFromMyFiles.jsx` | partial — attach, list and processing status are done; rename and delete of a matter's file are not offered from the matter (My Files' own screen carries them) |
| Drafts made in the matter's conversations | `sections/DraftsSection.jsx`, `/documents?projectId=` | built now — `MatterDraftsSection` |
| Chronology: add/edit/delete; "Build from documents" (AI proposals to accept); export as List of Dates & Events | `sections/ChronologySection.jsx`, `/project-chronology-extract` | partial — add/delete done; "Build from documents" built now (`ChronologyBuildSheet`, proposals saved only when accepted, `source: ai`); the List of Dates & Events export of the chronology is not built (the server-run List of Dates tool covers the documents) |
| Court: link/unlink a case, hearings, orders (open PDF), parties, refresh from court | `sections/CourtSection.jsx` | done — `ProjectDetailView.court`, `refreshFromCourt`, order PDFs via the case page |
| Tasks and deadlines by kind, done toggle, "Check limitation" | `sections/TasksSection.jsx` | done + built now (Check limitation → Limitation Radar) |
| Fees, payments, expenses, totals; printable fee receipt | `sections/FeesSection.jsx` | done (ledger, totals); partial — no printed receipt |
| People by role | `sections/PeopleSection.jsx` | done |
| Teams (create a team, add a member by email; team-owned cases) | `src/components/cases/TeamModal.jsx`, `/teams*` | built now — `TeamsSheet`, `TeamService` |
| Cause list view (month, day, Court No./Item, download as PDF / Word / CSV) | `src/components/cases/CauseListSection.jsx`, `src/lib/causeList.js` | done (calendar, day, rows) + built now (download menu, `CauseListExport`) |
| Case page (`/cases/:id` → the case's matter) | `src/pages/CaseToMatter.jsx` | done — `CaseDetailView` → "Open the matter" |

## Files and documents

| Web feature | Web source | iOS status |
|---|---|---|
| My Files: upload (chunked, background), folders, rename, move, delete, favourite, processing status, search | `src/pages/MyFilesPage.jsx`, `src/components/chat/DmsSidebar.jsx` | done — `MyFilesView`, `BackgroundUploader`, `FileManagementService` |
| Upload dialog: per-file rows, speed, estimates, closes itself 5 s after a clean batch | `src/components/upload/UploadTray.jsx` | done + built now — `UploadBatch.finishedCleanly`, `UploadAutoClose` |
| Duplicate check before upload | `/check-duplicates` | done — `DuplicateCheck` |
| Photos stored as PDF (`storedName`) | `docs/searchable-pdf.md` | done — `StoredUpload` |
| Open a document: PDF, office preview, searchable text layer, click-to-source citations | `FileViewerModal`, `PdfCitePane`, `/page-words`, `/resolve-file` | done — `SourceDocumentView`, `OfficePreview`, `CitationViews` |
| Download several files as a zip | `POST /download-files` | partial — one document at a time through the share sheet |
| Cloud import/export (Google Drive, OneDrive) | `/cloud/*`, `MyFilesPage.jsx`, `Settings.jsx` | n/a — the consent flow lands on the web app's own origin and is wired to the browser session; on the phone the Files app and "Open in…" cover import, the share sheet covers export |
| Doc tools: OCR, Translate, PDF to DOCX, Split, Merge, Rearrange, Compress PDF, Image to PDF, Compress image | `src/pages/tools/*`, `OCRTranslate.jsx` | done — `PDFToolsView` (on-device), `OCRView` (server) |
| Library (catalogue, documents, acts) and Fetch Orders | `src/pages/Library.jsx`, `FetchOrders.jsx` | owned by the sibling branch `web-parity-library`; Fetch Orders was already on `web-parity-oct` (`CourtSearchView(purpose: .lookup)`) |

## Calendars, auctions, registries

| Web feature | Web source | iOS status |
|---|---|---|
| My Calendar (cases + hearings, feed URL subscription) | `src/pages/MyCalendar.jsx`, `/calendar/feed-url` | done — `CalendarView`, `CalendarSubscriptionSheet` |
| Corporate (compliance) calendar | `src/pages/ComplianceCalendar.jsx` | done — `ComplianceCalendarView` |
| Compliance: mark a statutory deadline done; delete an event | `ComplianceCalendar.jsx` | held back — read-only until the write contract is confirmed (README) |
| Compliance history | `src/pages/ComplianceHistory.jsx` | held back — the page reads a separate local service beside the web app that a phone cannot reach |
| eAuctions (IBBI notices: list, filters, facets, detail) | `src/pages/Liquidations.jsx` | done — `AuctionListView` (row hidden at the product owner's request; see `ToolsSections`) |
| Auction watchlists | `Liquidations.jsx`, `McaRegistry.jsx` | held back — README, "Built and deliberately held back" |
| MCA Registry (CIN decoder, companies from notices, gaps) | `src/pages/McaRegistry.jsx` | built now — `McaRegistryView` (the web hides its sidebar row; the page is address-only there) |
| Limitation Landmine Radar | `src/pages/LimitationRadarPage.jsx`, `POST /limitation-radar` | built now — `LimitationRadarView`, golden-pinned to `features/limitation-radar/audit.js` |
| Filing Assembly page (`/filing`: annexure registry, paperbook assembler, bundles, checklist) | `src/pages/FilingAssembly.jsx`, `lib/filing/*` | n/a — the web removed its sidebar row (address-only, `Sidebar.jsx:361`); the bundle is rendered server-side for a desktop download. The parts that surface in chat (annexures card, filing-ready package) are built now |

## Account, settings, notifications

| Web feature | Web source | iOS status |
|---|---|---|
| Sign in with password or one-time code, sign up with confirmation, password reset | `Login.jsx`, `Register.jsx`, `ResetPassword.jsx`, `lib/authFlows.js` | done — `SignInFlow`, `LoginView`, `PasswordResetSheet` |
| Social sign-in | `Login.jsx` | done behind a build switch (`SocialSignInConfig`) until the platform's routes exist |
| Onboarding (role choice) | `src/pages/Onboarding.jsx` | done — `RoleWelcomeView` |
| Profile: photo, name, title, organisation | `Settings.jsx`, `POST /update-profile` | done — `EditProfileView` (sends all four fields; see gotcha 29) |
| Daily cause-list briefing opt-in, email briefing, test delivery | `Settings.jsx`, `/notif/*` | done — `NotificationSettingsView` |
| Browser push alerts | `Settings.jsx`, `public/sw.js` | n/a — no push channel to an iPhone; local reminders planned by `NotificationPlanner` instead (gotcha 28) |
| Active role / change role | `Settings.jsx` | done — `RolePickerView` |
| Plan and usage meter, plan refusals, "View plans" | `src/components/billing/UsageMeter.jsx`, `UsageLimit.jsx` | done — `PlanUsageSection`, `Refusal`, `WebPlans` |
| Buy / billing checkout (Razorpay) | `Buy.jsx`, `Billing.jsx`, `BillingDashboard.jsx` | n/a — payments happen on the web; the app opens the plans page |
| Admin: hub, users, usage, usage costs, feedback, feature requests, integrations, billing admin | `AdminHub.jsx`, `UsersAdmin.jsx`, `Usage.jsx`, `UsageCosts.jsx`, `FeedbackAdmin.jsx`, `FeatureRequestsAdmin.jsx`, `AdminSettings.jsx`, `BillingAdmin.jsx` | n/a — administrator consoles |
| Landing / scrolling page, maintenance and backend-down pages, 404 | `Maintenance.jsx`, `BackendDown.jsx`, `NotFound.jsx` | n/a — marketing and hosting pages; the app words maintenance itself (`APIError.maintenance`) |
| App lock, offline copies, Spotlight, widget, Siri | — | iOS-only additions (README) |

## Pages with no route or no importer (not counted)

`Subjectwise.jsx`, `PracticeArea.jsx`, `Industries.jsx`, `CorporateDashboard.jsx`,
`JudgeDashboard.jsx`, `StudentDashboard.jsx`, `LitigatorDashboard.jsx` (the `.bak` and the
superseded decks), `TableDashboard.jsx`, `DocDashboard.jsx`, `ChatWindow*.jsx`, `Canvas.jsx`,
`Library.jsx` (the old one), `FeedbackWidget.jsx`: none is reachable from the router or has an
importer on `master`. They are not features.

## Counts

- Rows: 86. done 38 · built now 26 · partial 3 · held back 5 · n/a 12 · two rows outside
  the scale (Library/Fetch Orders on the sibling branch; iOS-only additions). A row that is
  both done and built now is counted once, as built now.
- Gaps named inside rows: the drawn Overview timeline; rename/delete from inside a matter's
  Files; zip download of several files; the chronology's own List of Dates & Events export;
  the printable fee receipt.
- Held back, each with its reason above: sharing a conversation; chat rename/delete;
  compliance done-markers; compliance history; auction watchlists.
- Not applicable, each with its reason above: browser-only shell affordances, the desktop
  canvas editor, cloud OAuth, browser push, billing checkout, admin consoles, hosting pages,
  the address-only Filing Assembly page, the sample-only Highlighter page, dead code.
