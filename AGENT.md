# Saydrop: Execution Instructions for Future Development Agents

> **Current status: documentation, static UI design mockups, and app icon assets have been delivered; implementation has not been authorized or started.** This file defines the execution constraints that apply after explicit development instructions are received. It must not be used to claim that the client, server, tests, model quality, signing, notarization, or deployment have been completed.

## 0. Required reading before starting: files, order, and precedence

Every time you work on implementation, review, testing, or release for this project, read the following in this order:

1. The user's latest explicit instructions and authorization boundaries in the current session.
2. This file in the repository root: [`AGENT.md`](./AGENT.md).
3. The confirmed product baseline: [`specs/product-requirements.md`](./specs/product-requirements.md).
4. The technical implementation specification and established business API: [`specs/technical-specification.md`](./specs/technical-specification.md).
5. If the work involves client UI, components, styling, the menu bar, the floating bar, first-run onboarding, or app icons, you must also read the [UI interaction guide](./assets/Saydrop-UI-interaction-guide.md) and review the visual mockups and assets referenced in section 0.1. Only reference it as needed when handling backend tasks with no UI relationship.

The repository-relative paths of the project specification and UI guide are:

- `AGENT.md`
- `specs/product-requirements.md`
- `specs/technical-specification.md`
- `assets/Saydrop-UI-interaction-guide.md`

Precedence is strictly: **the user's latest explicit instructions > confirmed product decisions > technical implementation defaults and this file**.

All links in this file are relative to the repository root. New root-level documentation links must continue to use correct relative paths (for example, `specs/...`); machine-specific absolute paths must not be used as Markdown links.

If product and technical documents differ in minor wording, do not edit the originals to "unify" them. Use the consolidated baseline summarized in this file for implementation, and note any differences and the basis for the choice in the final report. Without a new user decision, do not change confirmed boundaries on the grounds that something is "more reasonable."

Whether `AGENT.md` is loaded automatically depends on the agent tool in use; do not assume it will be loaded automatically. If the tool does not load it automatically, the development task prompt must explicitly require reading this file and the two specifications above first. When UI is involved, the prompt must also explicitly name the UI interaction guide and the corresponding design assets.

Do not create an `AGENTS.md` automatically, and do not replace the user-specified `AGENT.md` with another file of the same name or any substitute.

### 0.1 UI design and icon asset index

Design assets are located under `assets/`. The entry point is the [Saydrop UI interaction guide](./assets/Saydrop-UI-interaction-guide.md), which covers interface organization, user flows, state copy, colors, typography, spacing, and size recommendations. Future agents must not ignore these assets merely because they are outside the source directory.

Review the static mockups relevant to the current task:

- [App window: history and details](./assets/ui/01-main-window.png).
- [App window: settings](./assets/ui/02-settings-window.png).
- [Menu bar: standby and quick actions](./assets/ui/03-menu-bar.png).
- [Floating bar: six core states](./assets/ui/04-floating-bar-states.png).
- [Floating bar: safe preview when the target changes](./assets/ui/05-safe-preview.png).

App icon assets are located under `assets/icons/`. Reuse the existing design where possible, and do not conflate monochrome menu bar status icons with the full app icon:

- [High-resolution app icon PNG, 1920 × 1920](./assets/icons/Saydrop-app-icon.png).
- [Standard app icon PNG, 1024 × 1024](./assets/icons/Saydrop-app-icon-1024.png).
- [macOS ICNS icon asset](./assets/icons/Saydrop.icns).

Usage rules:

- These files are static design and asset deliverables. They are not runtime screenshots, completed components, verified real permissions, or a built app. Their presence does not authorize development, signing, packaging, or release.
- Product behavior, APIs, security, and privacy constraints take precedence over the UI guide and visual mockups. The UI guide explains the mockups; dimensions, colors, and component organization are design recommendations. Do not use the sample quotas, permissions, or history shown in screenshots to claim real data or to change business defaults.
- **Known outdated content:** The current UI guide and some mockups still contain "local feedback", "feedback upload not yet available", and a permanently disabled upload button. These behaviors have been superseded by the latest product FR-09, section 7.8 of the technical document, and the normal feedback integration requirements in this file. Reference only their layout and visuals; do not copy the old placeholder logic, and do not pretend that updating this index means the UI mockups have been synchronized.
- UI implementation or review work must state which design files were referenced and which necessary differences arise from the latest requirements, security constraints, or native platform capabilities. Do not weaken real recording state, original-target validation, mode locking, or feedback confirmation rules in pursuit of screenshot fidelity.

## 1. Current authorization and future operational boundaries

Only documentation delivery is currently authorized. Unless the user gives separate explicit authorization later, **do not start development**.

Without subsequent development authorization, do not create source code, install SDKs or dependencies, run development services, call models, configure secrets, deploy, sign, notarize, package, submit externally, or make Git commits.

Even after development authorization is later granted, it does not automatically extend to deployment, paid real-model calls, creating vendor/cloud accounts, uploading data, notarization, signing, or external Git commits. Each such operation requires explicit authorization from the user for that turn.

Do not describe mocks, fakes, screenshots, static samples, or incomplete permission demos as production ready, fully verified, or released.

## 2. Workspace and change discipline

- Work only in this repository. Do not place source code, caches, databases, audio, secrets, or logs in `specs/`.
- First inspect existing directories, existing code, the uncommitted working tree, and the current turn's changes. Respect the existing architecture and dirty Git state; do not overwrite, reformat, revert, or delete files that are not part of the current task.
- Change only the minimal set of files required for the currently authorized implementation. Do not opportunistically rewrite confirmed product or technical documents.
- The product name is confirmed as **Saydrop**. Keep this spelling in the UI, app display name, and external documentation. Do not rename it or add an unconfirmed Chinese name. Engineering uses `Saydrop.xcodeproj` / scheme `Saydrop`, `SaydropApp`, `SaydropCore`, and `saydrop_server`; artifacts are `Saydrop.app` and `Saydrop-{version}-arm64.dmg`. The existing working directory `stt` must not be renamed; the technical abbreviation STT for Speech-to-Text and vendor interfaces remain unchanged. Bundle IDs, backend URLs, signing certificates, production budgets, vendor accounts, and data retention commitments must not be fabricated.
- SDKs, SPM packages, Python packages, versions, and Swift language modes must first be resolved, compiled, or tested in the target Xcode/environment, and only then pinned to exact versions. Do not write unverified APIs from memory, and do not upgrade dependencies automatically.
- Any newly supported platform, architecture, store channel, model, vendor, or runtime form requires a new explicit product decision. Do not expand for convenience to Intel, iOS, Windows, Web, Mac App Store, Docker, multiple workers, or multiple instances.

## 3. Hard product scope

The implementation target is **Saydrop**, a macOS system-wide menu bar voice input MVP: Apple Silicon only, macOS 14+, independently distributed. The app may stand by but records only when the user actively triggers it; it must never keep the microphone open continuously.

The default shortcut is `Command + Option + T`, customizable by the user; both toggle and push-to-talk are supported. The bar provides start, pause, finish, and cancel; `Esc` cancels the current session.

While recording, the app must show a real green indicator and textual state. Paused, uploading, transcribing, and standby states must not be disguised as still recording. Mixed Chinese/English speech is supported and retains the original language; translation is not performed by default.

On finish, text may be inserted safely only into the **original input target captured when recording started**. If the target changes, permission is revoked, secure input is active, writability/scope is unknown, or the paste destination is unclear, the app must degrade to preview and manual copy. It must never write into whatever happens to be focused.

Automatic writing may proceed only in one direction: safe direct insertion → provably safe paste fallback → preview/copy. Do not replace the entire `AXValue` or delete the user's existing text; replace a selection only when its range can be verified, using normal input semantics.

If a paste is sent but consumption or the result is `unknown`, stop automatic writing immediately: do not insert directly again, do not paste a second time, and do not "recover" using another strategy. No path may automatically press Enter, send a message, or execute a command.

Output modes are only `raw` (verbatim) and `light_polish` (light polish). The first output is verbatim; the user can select the mode only manually in the bar, and the mode is locked for the session when it ends. The raw path must not call a text model.

Light polish may only add punctuation, add reasonable paragraph breaks, and remove obvious verbal fillers. It must not summarize, expand, translate, or intentionally alter the original meaning, numbers, names, English terms, URLs, emails, code, or identifiers. If validation fails, times out, or the upstream errors, the app must fall back to the raw text with a clear notice.

## 4. Explicit non-goals

The MVP does not do offline recognition, real-time word-by-word writing, automatic translation, summarization, expansion, automatic second-pass polishing of already inserted text, covert segmentation of long audio, or automatic cross-model/cross-vendor fallback.

The MVP does not do accounts, login, invitations, payments, subscriptions, user-provided keys, team collaboration, cross-device sync, customer support systems, strict "per-natural-person" quotas, hardware serial numbers, or covert device fingerprinting.

The MVP does not build a feedback server from scratch, and does not do an offline upload queue, automatic sending of historical feedback, or unconfirmed attachment uploads. Per the user's latest decision, assume an existing feedback service is available and implement normal feedback integration; do not keep a permanently disabled placeholder. The actual service address/authentication/policy and contract remain to be configured and integrated; do not fake submission success.

The MVP does not use Redis, Celery, Docker, unbounded background queues, multiple workers, or multi-instance SQLite deployment. When scaling is needed, migrate to PostgreSQL first and redesign locking and queues.

## 5. Canonical technology stack and configuration boundaries

The macOS client uses Swift + SwiftUI + AppKit + AVAudioEngine + Accessibility/ApplicationServices + NSPasteboard; the minimum deployment target is macOS 14, and artifacts may be `arm64` only.

The shortcut candidate is the SPM package `KeyboardShortcuts`, using its `Recorder`, `onKeyDown`, and `onKeyUp`. Test compatibility with the current Xcode/Swift first and pin the version. The library not prompting for permissions does not mean the app as a whole does not need Input Monitoring permission.

The local history candidate is GRDB + SQLite; adopt it only after a compatible version has actually been resolved. Keychain stores the anonymous credential and a local 256-bit key; CryptoKit AES-GCM protects local sensitive text and audio. Tests use XCTest.

The backend uses Python 3.12+, FastAPI, Pydantic 2, httpx, SQLAlchemy 2, SQLite WAL, and version-controlled migrations. The MVP is a single-process, single-worker, bounded-memory model.

The client uploads in the foreground in memory using `URLSession`. Background sessions, file-based uploads, URLCache, writing upload bodies to disk, and network logs that record audio content are prohibited.

The server-side vendor key exists only in controlled server secret configuration. It must never enter any client location, including installers, settings, Keychain, or configuration; it must also not enter SQLite, logs, HTTP responses, examples, or obfuscated strings. The client Keychain stores only the anonymous credential and the local encryption key.

Production allows HTTPS only; explicitly configured development-machine loopback may use HTTP; other environments must not downgrade to cleartext.

Transcription candidate slugs are fixed by a server-side allowlist: default `elevenlabs/scribe-v2`, comparison `openai/whisper-large-v3-turbo`; the light polish candidate is `openai/gpt-4.1-mini`. None of these is a tested commitment regarding quality, performance, price, or final model.

Vendor calls are server-internal details: STT uses OpenRouter's dedicated STT capability, and light polish uses Chat Completions with a fixed system prompt, low temperature, and no tools/function calling. The client business API is never an alias of the OpenRouter API.

## 6. Centralized defaults: visible and not to be silently changed

The following are implementation defaults for this round, not item-by-item user confirmation. They should be centralized as reviewable configuration/constants and settings UI semantics. Scattered hard-coding, implicit changes, or silent A/B rewrites are prohibited.

- Anonymous, no-login: each anonymous installation instance gets 50 transcriptions per day—not per natural person. The server resets at 00:00 natural day in `Asia/Shanghai`.
- On first run the client automatically requests a random 256-bit anonymous token; Keychain stores only the local token. The server stores only a peppered one-way hash/HMAC and the key version.
- The first output mode is raw; afterward the app remembers the user's last **manual** selection. The bar always shows the current mode. The default recording mode is toggle; do not launch at login by default.
- Per-session capture limit is 120 seconds (pause time excluded); a single pause may last at most 5 minutes, after which the session is cancelled; WAV upload limit is 8 MiB; at most one active transcription session per installation instance.
- Server limits: 30 seconds to read the upload, 45 seconds for STT, 8 seconds for light polish, 60 seconds total per task; do not automatically resend model requests.
- Use the default system input device; device selection is a reserved capability only. Do not perform undisclosed vendor/model failover.
- Local audio saving and text history are independent switches, both enabled by default, both retained for 7 days. Options are 1 day, 30 days, forever, or a custom positive integer from `1...3650` days.
- The transcription backend keeps the result body in process memory for at most 120 seconds; `GET` does not extend it. Status/idempotency tombstones are retained for 7 days; SQLite stores no body text or audio.
- When audio persistence is disabled, keep audio in memory for 60 seconds from the time a displayable final result exists (including retryable failures), using a monotonic clock. Opening the bar, previewing, feedback, or network loss does not extend it.

## 7. Inviolable rules for sessions, input, and retention

Use an explicit reducer keyed by `session_id`. Every asynchronous callback must carry the session ID; late or mismatched callbacks are always discarded. After cancellation, late results must not be inserted, must not enter history, and must not trigger new model requests. The 120-second capture limit is treated as "finish"; only a 5-minute pause timeout cancels the session. After insertion, `Esc` only closes the bar and does not retract text or delete history.

At recording start, capture only the necessary original-target context (process, bundle, window/AX reference, writability, secure input state, selection range, position, capture time). Do not save the control's full text.

All capture/pause/60-second temporary-audio TTLs use a monotonic clock; system wall-clock changes must not alter session limits or server quotas.

Audio is captured at the device's native sample rate and converted to 16 kHz, mono, 16-bit PCM WAV after leaving the realtime callback. No I/O, networking, SQLite, encryption, large memory allocation, WAV assembly, or synchronous logging may occur in the tap callback.

Do not promise that RAM, swap, crash dumps, SSDs, or backups can be physically zeroized; encryption and releasing references only reduce risk.

All four local storage combinations must be implemented precisely:

- Audio on, text on: save each encrypted payload and necessary metadata; purge each according to its own retention period.
- Audio on, text off: save only audio and non-content metadata; do not save transcribed text or user-corrected text.
- Audio off, text on: save text and necessary metadata; audio may be kept only under the 60-second in-memory TTL.
- Audio off, text off: no reviewable history is formed; feedback applies only to the current session and must not exceed the applicable 60-second audio boundary.

Normal feedback upload is independent cloud processing: positive feedback proactively submits minimal metadata; negative feedback opens a panel without uploading and uploads only after the user confirms the actual recording/text of this session, the recipient, purpose, and retention policy. Changes to the material require re-confirmation; when there is no audio, a text-only submission may be confirmed. Disabling local history does not prohibit this explicitly consented feedback, nor does it permit saving a local payload or an offline queue. When audio is off, all copies still obey the original 60-second TTL; at expiry, any incomplete upload with audio stops. Already-sent content cannot be guaranteed to be recalled. If a receipt is lost, check the same feedbackId first; do not resend automatically; success is shown only after a reliable `received` receipt. Feedback does not consume the 50-item quota and must not affect transcription/insertion; local deletion does not equal cloud feedback deletion.

Turning switches off affects only future sessions; clearing existing content, deleting a single item, and deleting all items require local confirmation. If shortening a retention period affects existing items, show the impact and obtain confirmation first. Purge expired items at launch, on wake, and hourly while the app runs; access/copy/playback/feedback does not extend retention.

## 8. Server identity, quota, idempotency, and budget safety

No login does not mean no authentication. `POST /v1/installations` issues an access token exactly once; the client immediately writes it to Keychain, and the server stores only a hash. `installation_id` is not a credential.

Installation registration, per-instance, IP-assisted dimension, and global concurrency must all be rate-limited. IP may only assist abuse prevention; it must not be the sole identity or a long-term identity dossier. Do not claim to prevent Sybil bypass.

All tasks are bound to an owner installation instance; status reads and cancellation must enforce owner ACL. Both non-existent and non-owner requests return a generic `404`; do not leak task existence.

Quota authority comes only from the server; the client must not treat local time or local counts as authoritative. `remaining = max(0, limit - used - reserved)`.

Only after WAV/authentication/idempotency validation passes may a single `BEGIN IMMEDIATE` transaction check `used + reserved < 50`, create the task, and reserve quota. Of 51 concurrent valid requests, at most 50 are accepted.

Before dispatching to the vendor, another atomic transaction writes an irreversible `dispatch_marked_at`, converts `reserved` to `used`, and reserves budget. The mark may precede the actual network send; once it cannot be ruled out that the upstream received the request, count conservatively, hold the budget, and never automatically replay.

A cancellation or failure determined before dispatch releases the reservation; after dispatch, cancellation, upstream failure, target insertion failure, or an unknown result all do not refund used quota. Tasks spanning midnight remain in the server date bucket of the time of reservation.

The same `(owner, idempotency key, audio fingerprint, output mode)` returns the same task within 7 days and must not call the vendor again or deduct quota. The same key with different audio/mode returns `409 idempotency_conflict`. `failed`, `unknown`, and `cancelled` must not be implicitly re-run; an explicit user retry must use a new UUID and may count again.

If the production budget is unconfigured, invalid, zero, or the operational limit is reached, the server must `fail closed` and return `budget_unavailable`. Budget is reserved by maximum duration plus at most one light polish; settle only with verifiable actual usage, otherwise hold conservatively. The budget is not a hard cap on the vendor bill; operations must set a separate hard limit.

## 9. API, state, and error contracts

Do not invent new business APIs, replace paths, rename fields, or expose vendor APIs to the client. The sole authoritative contract is [section 7 of the technical document](./specs/technical-specification.md#7.-Product-HTTP-contract-(v1)).

Transcription uses: `GET /healthz`, `POST /v1/installations`, `GET /v1/quota`, `POST /v1/transcriptions`, `GET /v1/transcriptions/{requestId}`, `DELETE /v1/transcriptions/{requestId}`. Feedback integration expects `POST /v1/feedback` and `GET /v1/feedback/{feedbackId}`, following section 7.8 of the technical document. Read the real service documentation first and map to it; do not rebuild the external service. Record any inconsistencies. Do not send the transcription token or vendor key directly to a new origin.

`POST /v1/transcriptions` must be a raw PCM WAV body with `Content-Type: audio/wav`, carrying Bearer, a UUID `Idempotency-Key`, and `X-Output-Mode: raw|light_polish`. It must not accept JSON base64, multipart, model names, prompts, or provider parameters. `requestId` equals the client UUID and is identified by the composite of owner and UUID. If the POST receipt is lost, query/cancel the same UUID first; do not re-upload audio. JSON fields use camelCase consistently.

Task states use only `processing`, `ready`, `failed`, `cancelled`, `unknown`, `result_expired`. On process restart, tasks that were dispatched but cannot be determined are `unknown`; lost or expired bodies are `result_expired`; neither may trigger replay of old audio.

All errors must return the established typed error envelope: `error.code`, a user-understandable and non-sensitive `message`, `retryable`, and—only when safe to return—`requestId` and `quota`. Do not return raw vendor bodies, keys, audio, or body text. Vendor names should be disclosed transparently in the privacy disclosure.

## 10. P0–P5 vertical implementation order

For each phase, write/update the corresponding tests first, run the available tests, then proceed to the next phase. Completing a phase gate does not mean the whole project is release-ready.

### P0: Workspace reconnaissance and buildable skeleton

- Read the documents listed in section 0, inspect the workspace and dirty Git, and confirm no out-of-scope operations are being performed.
- Establish the minimal target directories, a pure `SaydropCore` boundary, DTOs, dependency-injection interfaces, encrypted-storage interfaces, a SQLite migration skeleton, and mock boundaries; do not include real keys.
- Required tests: the pure reducer, DTOs, WAV metadata, and retention calculations can be tested independently and locally; pin dependencies after actually resolving/compiling them.
- Done gate: target platform is arm64/macOS 14, core tests are repeatable, no real models are called, and no system permission is claimed to be verified.

### P1: macOS safe recording and minimal original-target slice

- Implement permission description/state, shortcut debounce, toggle/push-to-talk, real recording state, pause and cancel, session ID, in-memory WAV pipeline, target snapshot, and the strict three-tier fallback of direct insertion/paste/preview.
- Required tests: 120-second and 5-minute monotonic clocks, `Esc` does not insert, key repeat does not resend, target switching does not miswrite, secure fields are not written, selection is not overwritten wholesale, paste `unknown` does not double-insert, and lock screen/device interruption ends the session.
- Done gate: unit/integration tests with mocked and fake AX/pasteboard pass; if real system permissions, third-party focus, and clipboard have not been accepted, they must be explicitly marked as not accepted.

### P2: Backend anonymous identity, quota, and idempotency slice

- Implement a single-worker FastAPI, raw WAV stream validation, installation token hash, ACL, rate limiting, SQLite WAL/migration, atomic quota/budget, in-memory result TTL, restart `unknown`, and the established v1 API; the provider may only be mocked.
- Required tests: HTTP DTOs and typed errors, token/owner ACL, 7-day idempotency, same-key conflict 409, cancellation semantics, restart `unknown`, `result_expired`, cross-midnight bucket, client clock changes having no effect, and 51 concurrent requests accepting at most 50.
- Done gate: under temporary SQLite/mock provider, transactions do not over-allocate, and no body text/audio/token is written to disk or logs in cleartext; no real vendor is connected.

### P3: Controlled model adapters and output safety

- After development authorization, real STT/light polish adapter code may be implemented, but test with mock transport first and do not trigger external calls. Real paid calls and sample uploads require separate explicit authorization. Keep the server-side key and fixed prompt, prohibit automatic retry/fallback, and complete raw fallback and budget fail-closed behavior.
- Required tests: raw path does not call polish, polish token protection/exception fallback, dispatch boundary, possible-dispatch failures still counted, refusal without budget, and no leakage of supplier body/key.
- Done gate: adapter mock contract and safety tests pass, allowing P4 to proceed; when real models are not authorized, explicitly mark them as "not tested," and do not block other offline implementation or falsely claim real verification. Before release, record actual results using authorized, minimized samples.
### P4: Local history, bar, and existing feedback service integration slice

- Implement encrypted local history, the four storage combinations, retention-change confirmation, 60-second buffer, bar mode visibility, normal positive/negative feedback upload, accurate preview and confirmation for negative feedback, FeedbackAPIClient adaptation, and receipt querying, without rebuilding the feedback backend.
- Required tests: 1/7/30/forever/custom boundaries, four combinations, disabling affects only the future, shortening requires confirmation, launch/wake/hourly cleanup, TTL not extended, no submission without confirmation, duplicate deduplication, reliable receipt/unknown-state query, upload cancellation at TTL expiry, re-confirmation when material changes, feedback still possible with zero transcription quota, no offline queue, and no fake success.
- Done gate: disabled content types cannot be saved locally via feedback or logs; mock contract tests pass, and the entry point can submit normally once configured. If real service integration is incomplete, report it explicitly; do not keep it permanently disabled, fake success, or present assumptions as tested facts.

### P5: Real-system acceptance and release-candidate gate

- Only after obtaining the corresponding operational authorization, conduct real testing on Apple Silicon macOS 14 and at least one newer system: permissions, AX, shortcuts, recording, target fallback, multiple displays, offline, lock screen, device reconnect, performance, secret review, and model benchmarks.
- Required tests: record real system permission verification separately from unit tests; complete the hard security gates, arm64 packaging checks, vendor data-processing disclosure, and review of the real feedback service's authentication/deduplication/receipt/retention policy.
- Done gate: only after functionality, security, privacy, real compatibility, and performance records all pass may separate authorization for signing, notarization, DMG, or deployment be requested; notarization does not automatically mean functionality or privacy has passed.

## 11. Test honesty and acceptance reports

Unit tests may use fakes/mocks to cover the reducer, WAV, retention, API, quota, and policy; they must be explicitly identified as test doubles.

Real microphone authorization, Accessibility, Input Monitoring, AX writability, third-party app focus, clipboard formats, signing/notarization, and real model performance cannot be replaced by mocks. They must be separate, authorized real-system acceptance items.

It is prohibited to hide mocks, silently fake provider success or feedback upload success, or package fake API responses as real runtime results.

At the end of every implementation task, the final report must include: files actually changed; commands actually executed; the real result of each command (pass/fail/not run); the mock and real boundaries used; accepted items; unaccepted items; blockers, risks, and next steps requiring user decisions/authorization. Do not write "not run" as "pass."

## 12. Copyable user task prompt for moving from documentation to implementation

The user may copy the following prompt when starting a future task; it does not approve paid, deployment, or external operations on the user's behalf:

```text
Please implement only the minimal vertical slice for phase P[fill in phase] in this repository.
First read AGENT.md, specs/product-requirements.md, and specs/technical-specification.md, and follow the precedence: my latest instructions > confirmed product decisions > technical implementation defaults.
When UI is involved, also read assets/Saydrop-UI-interaction-guide.md and review the visual mockups and icon assets referenced in section 0.1 of AGENT.md; the disabled feedback-upload logic in the old UI mockups is outdated—use the current product FR-09 and section 7.8 of the technical document as authoritative.
Inspect existing code and dirty Git first; change only the files required for this phase and respect existing implementations. Do not modify confirmed product/technical documents and do not create AGENTS.md.
Strictly use the established /v1 transcription API in the technical document; feedback follows section 7.8 and adapts to the real existing service—do not rebuild the feedback backend or fake its contract. All defaults are centralized and must not be changed silently.
Within this development scope, you may resolve and install the dependencies declared by the project and pin versions; check existing configuration first, do not upgrade the global SDK, modify the system toolchain, or overwrite other project environments. Test SDK/package compatibility and pin it.
Do not deploy, make paid real-model calls, create external accounts, sign/notarize, submit externally, or make Git commits unless I explicitly authorize each item in this task.
When done, run the tests available for this phase and submit a final report: changed files, executed commands and actual results, mock/real boundaries, accepted/unaccepted items, blockers, and the authorization needed for the next step.
```

## 13. Handoff reminders

Candidate models, performance targets, API/framework recommendations, and release paths are all future verification targets, not existing achievements. Safety takes precedence over automation rate: when permissions, targets, insertion, quota, budget, TTL, or data retention are uncertain, stop, preserve copyable results, return a typed error, or fail closed—do not guess success, retry automatically, or expand data processing.
