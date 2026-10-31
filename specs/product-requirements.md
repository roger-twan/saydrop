# Saydrop Product Requirements

**Purpose:** Product requirements and acceptance baseline for the macOS system-wide voice input MVP. This document defines expected behavior, boundaries, and acceptance criteria.

**Product name:** Saydrop. Use this spelling in the UI, app name, and public communications.

**Version:** MVP

**Related document:** See the [technical specification](./technical-specification.md) for architecture, API state machines, storage, and security constraints. This document does not repeat the complete API contract or database schema.

## 1. Product goal

Saydrop is a system-wide voice input tool for real macOS users. Users deliberately begin recording while editing text in another app. When they finish, they receive a faithful transcript or a lightly polished version they chose. If the original input target can still be proven safe, Saydrop inserts the result there automatically. Otherwise, it falls back to a preview and manual copying.

The MVP aims to remove one confirmation step without writing to the wrong place. Running in the background means the app can wait for a user action; it does not mean continuous listening, recording, or microphone upload.

## 2. Decisions and scope

### 2.1 Confirmed product decisions

These are confirmed requirements, not optional suggestions:

- The MVP is for real users, not only developers.
- Support system-wide input on Apple Silicon Macs running macOS 14 or later. Do not provide an Intel build.
- Distribute a standalone installer, not through the Mac App Store. DMG is the chosen packaging default. Developer signing and notarization are release gates, not completed results.
- Do not require invitations, login, registration, user supplied API keys, or provider keys. The product operator manages cloud recognition access and costs.
- Use cloud speech recognition, not offline recognition. The background app must not keep the microphone open.
- Default shortcut: `Command + Option + T`, customizable by the user. Support Hold to Talk and Press to Toggle recording.
- The floating bar provides Start, Pause, and End. `Esc` cancels the current session. Recording needs a clear green indicator and text label.
- Preserve mixed Chinese and English speech in the spoken languages; do not translate by default.
- Normally insert a recognized result safely into the original target captured when recording began. If the target cannot be verified, require user action or offer copying. Never write to an arbitrary field that happens to be focused later.
- Output modes are Raw and Light Polish. The first session defaults to Raw. The user chooses manually in the bar; content must not trigger automatic mode switching.
- Default local retention is seven days. Also offer one day, 30 days, Forever, and Custom. Audio and text history have separate switches. Starting with both on is the working interpretation of the default, not a separate confirmation of each switch.
- When persistent audio saving is off, an in-memory buffer may remain for at most 60 seconds for immediate feedback. Feedback must support normal upload through an existing usable feedback backend; do not build a new feedback server in this release. Ask for explicit confirmation before uploading audio and text with negative feedback.
- Allow at most 50 transcription requests per day. Counting per anonymous installation is the implementation interpretation; it does not guarantee 50 per natural person.
- The first session uses Raw. Later sessions remember the last output mode the user **manually** selected in the bar. Always show the current mode. Recording defaults to Press to Toggle.
- Quota resets at 00:00 on the server's `Asia/Shanghai` calendar day. The day assigned to a request is fixed when quota is successfully reserved; it does not move across midnight.
- A capture lasts at most 120 seconds, excluding pauses. A pause lasts at most five minutes before automatic cancellation. Upload size is capped at 8 MiB. One anonymous installation may have only one concurrent transcription session.
- Protective server time limits target 30 seconds to read the upload, 45 seconds for transcription, eight seconds for Light Polish, and 60 seconds for the whole task. Timeout or network failure must not silently resend a model request.
- Reserve the “System default device” display and a future device selection entry point. The MVP uses the system default input device. Launch at login is off by default.
- Do not automatically fall back across models or providers. If the primary model is unavailable, show a clear failure; never secretly send audio to another provider to improve apparent success.
- Audio and text saving both start on, each with seven day retention. This interprets “save for seven days by default.” Custom retention accepts a positive integer from 1 to 3,650 days, or Forever.

### 2.3 Included in the MVP

Onboarding and permission checks; a global shortcut; recording state machine; floating bar; cloud transcription proxy; Raw and Light Polish output; safe insertion into the original target with copy fallback; anonymous installation quota; local history with independent retention; a 60 second in-memory audio buffer for feedback; integration with an existing feedback service and positive/negative feedback upload; and clear errors and quota messages.

### 2.4 Outside this release

- Intel macOS, iPhone/iPad, Windows, a web client, Mac App Store distribution, offline recognition, and real-time character-by-character writing into external apps.
- Accounts, invitations, subscriptions, payments, user API keys, team collaboration, cross-device sync, and a customer support ticket system.
- Building a feedback server from scratch, an offline upload queue, automatic upload of historical feedback, or uploading feedback attachments without user confirmation. Client integration with the existing feedback service is included.
- Automatically repolishing text already inserted elsewhere, automatic translation, summarization, expansion, sending messages, pressing Enter, or executing commands.
- An unlimited standalone polishing API, silently splitting a long recording into multiple quota-consuming requests, or selecting a model or output mode automatically from content.
- Strict per-person quota enforcement, hardware serial collection, hidden device fingerprinting, or unverified promises about a provider's data retention.

## 3. Core concepts and rules

### 3.1 Original input target

The original target consists of the app, window, editable control, and selection context, when present, captured when recording begins. After processing, Saydrop may write only after revalidating that target. It must never write the result into a newly focused arbitrary control.

If a normal editable selection and its context remain safely verifiable, the result may replace that selection using ordinary typing semantics. Do not automatically write into secure fields, password fields, or controls whose editability cannot be reliably determined. No successful path may send a message, submit a form, press Enter, or execute a command.

### 3.2 Output modes

- **Raw:** Faithfully transcribe mixed Chinese and English speech without calling a generative text model to rewrite it.
- **Light Polish:** Add punctuation, make moderate paragraph breaks, and remove obvious spoken fillers from the raw result. Do not summarize, expand, translate, change meaning, or rewrite numbers, names, or English terms.

The user may change the current mode in the bar before or during recording. Ending recording locks the mode; it cannot be changed for the current processing path afterward. Each transcription may have at most one Light Polish operation. Polishing does not consume another transcription credit, but remains subject to server cost and budget controls. If text processing fails or critical numeric token validation fails, return to Raw with an explanation. Do not present an inferred result as verified fact.

Changing the bar mode after a result has been inserted into another app must not automatically replace that external text or overwrite subsequent edits.

### 3.3 Three-stage insertion fallback

A result may follow only this order. Stop automatic writing immediately after success or an uncertain outcome. Proceed to the next stage only if the previous stage is proven not to have written anything. Not every failure is safe to retry.

1. **Safe direct insertion:** Require verifiable Accessibility permission, control writability, range or selection, and original target identity.
2. **Safe paste fallback:** Paste only if it can still be proven to reach the original target. Best-effort snapshot and restore clipboard formats that can be snapshotted; use the change count to avoid overwriting new clipboard content the user placed there meanwhile. Do not claim invisible restoration if snapshotting fails, paste consumption cannot be confirmed, or focus is unsafe.
3. **Preview and manual copy:** Show the result, the reason insertion was blocked, and Copy. Do not steal focus or automatically switch to the target app.

If the outcome after sending Paste is uncertain, for example because the app gives no observable confirmation, set `unknown` / “Insertion result unknown.” Never attempt direct insertion or another paste. Avoiding duplicate text takes precedence over automation.

## 4. Onboarding, permissions, and cloud privacy disclosure

### 4.1 Onboarding sequence

Onboarding is stepwise and retryable. It must not treat an ungranted permission as granted or request every system permission unconditionally.

1. **Product and retention:** Before recording is available, show separate default settings for audio and text history. Both start on with seven day retention, with controls to disable or change them independently.
2. **Microphone:** Explain that capture occurs only while the user has started or resumed recording. Idle, paused, transcribing, and background states do not continuously capture. If denied, offer System Settings guidance and a way to recheck on return.
3. **Accessibility:** Explain that it identifies the input target when recording starts and permits safe insertion. If denied, transcription remains possible with microphone and network access, but automatic insertion cannot be promised; use preview and copy.
4. **Input Monitoring, conditionally:** Explain and request it when the final custom global shortcut or `Esc` listener actually requires it. A shortcut library that does not prompt for permission is not proof that the whole product never needs it.
5. **Cloud recognition disclosure:** Before the first actual cloud submission, clearly explain that audio goes by HTTPS to the product backend and then to the chosen recognition provider. Turning off local audio saving does not keep audio on the device. If the user declines or does not continue, do not upload; remain idle without secretly changing the processing route.

System permissions for microphone, Accessibility, and Input Monitoring are independent. UI and permission checks should follow Apple's guidance.[12] [13] [14]

Recognition and feedback upload are separate data processing actions. Introduce feedback during onboarding. Before every negative feedback submission, separately show the data to be uploaded, recipient, purpose, and server retention policy, and ask for explicit confirmation. Update the disclosure if the recipient or purpose changes. Cloud recognition consent does not authorize feedback attachments.

### 4.2 Minimum privacy disclosure

- Saydrop requires no account but obtains an anonymous installation credential for quota, abuse prevention, and revocation. Store it securely on the device; retain only its hash on the server. An installation is not a person's identity.
- Do not use hardware serial numbers or hidden device fingerprints to imply a strict per-person daily limit. The server may use credential issuance rate, per-installation throttling, supplementary IP throttling, global concurrency, and budget controls. IP alone is not an identity.
- The transcription backend does not routinely store recordings or transcript text as history. Results for asynchronous retrieval may exist in process memory for at most 120 seconds; reading them does not extend that period. Verify and disclose the provider's own processing and retention policy before release; the product backend cannot promise it on the provider's behalf.
- Turning off local audio saving still allows an in-memory buffer for no more than 60 seconds after the current result. It is not history and does not create another recording copy for feedback.
- The feedback backend handles user-submitted content according to the existing service's disclosed policy, which may retain audio and text. This policy is separate from the transcription backend's 120 second result cache and seven day local history. The service address, authentication, and policy have not been verified; do not invent them or upload without them. Show “Feedback submitted” only after server confirmation.

## 5. Interaction and state semantics

### 5.1 Shortcut and bar are entry points to one session

The global shortcut starts or ends input from another app. The bar shows state, lets the user choose the current output mode, and provides Start, Pause, End, Cancel, Copy, and Feedback. Both use one session state machine and one snapshot of the original input target.

Prefer a floating panel that does not activate an app outside the target, placed near the cursor or input field when possible and at a safe fixed position on the current display otherwise. A nonactivating panel cannot absolutely preserve focus. Revalidate the original target before every actual write; clicking the bar is not proof that it remains safe.[8]

Raw/Light Polish and Hold to Talk/Press to Toggle are independent choices. Changing either does not change the other.

### 5.2 States and actions

- **Idle:** The app responds to the shortcut or bar while the microphone is off. Background idle is not continuous listening. On Start, capture the original input target before recording. If microphone permission, quota, network prerequisites, or safety conditions fail, explain why without recording unusable audio.
- **Recording:** Capture only in this state. Show a green indicator and “Recording.” Pause stops capture; End or the next valid toggle shortcut ends capture and starts finalization. End at 120 seconds with a message; do not split into multiple requests.
- **Paused:** Do not show Recording or capture usable speech. Resume or End from the bar. Cancel and release the session after five minutes without uploading. `Esc` cancels during pause.
- **Finalizing, uploading, transcribing:** Turn the microphone off and show the corresponding nonrecording state. Cancel is allowed. If supplier dispatch has not been crossed, cancellation does not consume quota. Once dispatch may have occurred, cancellation is best effort; supplier processing and a quota refund cannot be promised. Slow network must not trigger a hidden model resend.
- **Result ready and insertion:** Apply the one-way strategy in §3.3. Show Complete after safe success; otherwise show a copyable preview and specific blocking reason. Start the 60 second buffer timer when the result is formed if persistent audio saving is off.
- **Failed, unknown, expired:** Show the reason, retry options, and whether quota may have been consumed. For `unknown`, timeout, or an unrecoverable result after client restart, first query the same request. Never implicitly reupload or call the supplier again. Only an explicit user retry creates a new request that may count again. Do not pretend an expired result is recoverable.
- **Cancelled:** A late result from a session cancelled before writing must never be inserted into another app. Do not add a cancelled session to local history; release its audio buffer immediately.

Sleep, screen lock, audio device loss, or an unrecoverable permission change must end the recording as cancelled or an explainable failure. Do not resume an old session or write a late result to its target after recovery.

### 5.3 Recording methods

- **Press to Toggle (default):** First valid shortcut starts recording; the next valid trigger while recording ends it. Bar buttons always perform their labeled actions. Key repeat must not become multiple endings, submissions, or new sessions.
- **Hold to Talk:** Key down starts and the corresponding key up ends. If paused, key down resumes and key up ends; the user can also End from the bar. Key repeat during a hold must not create extra starts, endings, or requests.

During recording, pause, upload, transcription, or a result preview not yet inserted, `Esc` cancels and ignores late results. After insertion or completion, `Esc` only closes the bar; it does not undo text, delete saved history, or send Undo to the external app. `Esc` while idle creates no session. Request any listener permission according to the actual implementation.

## 6. Functional requirements

### FR-01 Platform, distribution, and idle behavior

Support only Apple Silicon running macOS 14 or later. Distribute through a standalone DMG by default. Before release, use appropriate developer signing, Hardened Runtime, notarization, and stapling.[11] The app may wait in the background after a user launches it, but must not launch at login by default or keep the microphone open while idle.

### FR-02 Onboarding, permissions, and privacy

Follow §4 for microphone, Accessibility, and conditional Input Monitoring onboarding. Check actual states and provide a repair path. Before the first cloud transcription, clearly disclose the cloud data flow and local retention. Permission denial, unavailable network, or a user who does not continue must not cause hidden upload.

### FR-03 Session recording and controls

Support the customizable default `Command + Option + T` shortcut, Press to Toggle and Hold to Talk, Start/Pause/End in the bar, `Esc` cancellation, and a green indicator plus text while recording. Enforce the 120 second capture limit excluding pauses, five minute pause limit, 8 MiB upload limit, and one concurrent session per installation.

Capture at the input device's native sample rate, then convert outside the real-time audio callback to 16 kHz mono 16-bit PCM WAV for upload. Upload from a foreground in-memory data stream. Do not use background sessions, file uploads, request body disk spooling, URL caching, or network logs containing audio. These constraints do not prove that RAM can be physically zeroed or that swap and crash dumps leave no trace.

### FR-04 Transcription, mode, and language

Default to Raw. Let the user manually choose Light Polish in the bar and lock the mode as described in §3.2. Preserve spoken Chinese and English without default translation. Raw must not invoke the text polishing model implicitly. A Light Polish exception must safely fall back to Raw with a notice. Do not claim unmeasured model quality, latency, price, or superiority.

### FR-05 Safe writing to the original target

Capture the original input target when recording begins and revalidate it before writing. Execute the one-way sequence of safe direct insertion, provably safe paste, then preview/copy. Stop automatic writing and retain a copyable result if the target changes, its window or control disappears, Accessibility is revoked, the input is secure, the writable range cannot be verified, the paste destination is uncertain, or insertion outcome is unknown. Do not steal focus.

Do not replace an opaque Accessibility value wholesale or delete existing user content. Replace a selection using normal input semantics only when that selection remains safely verified. Never send, submit, or execute the result.

### FR-06 Anonymous installation, quota, and transparent counting

On first network use, request a revocable anonymous installation credential and store it securely. Do not embed a supplier key, shared fixed secret, or an obfuscated string in the client as a substitute for key management. Enforce 50 transcriptions per installation per server day. Show “N / 50 remaining today” and the next reset time with a time zone, using server values rather than the local clock or count as authority.

Quota checking and reservation must be atomic: at most 50 of 51 concurrently competing valid requests are accepted. Reserve after validating the upload. Before supplier dispatch, persist the dispatch boundary and commit counting atomically. Release a reservation for cancellation, empty audio, invalid parameters, or failure before dispatch. Once supplier receipt cannot be ruled out, count conservatively even if the user cancels, transcription fails, or insertion is impossible, and explain that in the UI. The 50 limit applies to logical transcription requests; status reads, copying, history, feedback, and retransmission of the same request do not consume another credit.

Retransmitting the same request ID must not charge again or call the supplier again. The idempotency window is seven days. Reject the same ID with different audio or mode. Do not implicitly rerun failed or unknown requests, including unknown requests after restart. Only an explicit new attempt uses a new ID and counts as a new request. An expired ID is not an indefinite result cache.

Provide a global supplier budget, credential issuance rate limiting, per-installation throttling, supplementary IP throttling, and global concurrency controls. If the production budget is unset or its operational limit is reached, reject new recognition with a clear temporarily unavailable error (fail closed). Do not guess a dollar amount or secretly use another model. Budget protection is not an absolute supplier billing cap; operators must also configure available hard limits at the supplier.

### FR-07 Asynchronous results, failures, and duplicate protection

Maintain a unique session/request association for each logical request so late results after cancellation, successive recordings, and retransmissions cannot cross. Reading the same request's status uses no quota. Show its actual state: processing, complete, failed, cancelled, unknown, or expired.

If the server restarts after recording possible dispatch and cannot prove a result is recoverable, report unknown rather than calling the model again. Keep result text in server process memory for at most 120 seconds; reads do not renew it. Report expiration when it cannot be recovered after expiry or restart. Do not persist recordings or result text in SQLite. State and idempotency tombstones may remain for seven days. See the technical specification for exact states and API contracts.

### FR-08 Local history, retention, and deletion

Audio saving and text history are independent user switches, both on by default with seven day retention each. Each record expires based on creation time; access, viewing, playback, and feedback do not renew it. Clean up expired records at startup, on wake, and hourly while running.

The four combinations are:

- **Audio on, text on:** Keep audio, text, and necessary metadata locally, each subject to its own retention period. Feedback metadata may be stored with history.
- **Audio on, text off:** Keep only necessary metadata and audio. Do not save transcript text or user-entered corrected text, including through feedback.
- **Audio off, text on:** Keep text and necessary metadata, but no persistent recording. After a result is formed, audio may remain in memory for at most 60 seconds.
- **Audio off, text off:** Create no reviewable audio or text history. A feedback draft exists only in the current session, and audio may remain only under the 60 second in-memory rule until timeout or cancellation. The user may confirm upload while content is available; cloud feedback retention follows its separately disclosed policy and creates no local history.

Turning off either switch affects future sessions only. Clearing existing local content requires explicit confirmation. A shorter period applies to existing items; show the impact and obtain confirmation before deleting anything. Both single-item and bulk deletion require local confirmation. Do not promise secure deletion of copies in OS backups. Client logs must not contain recordings, transcript text, or keys. See the technical specification for encryption and key management of local sensitive fields and audio.

### FR-09 60 second buffer and normal feedback upload

Integrate normal feedback with an existing usable feedback backend. Do not leave a permanently disabled placeholder or build a new feedback server. See §7.8 of the technical specification for the default integration and adapter contract. Do not invent actual configuration or integration results.

The result bar offers positive and negative feedback. Label the positive action “Submit positive feedback.” Onboarding explains that it sends a rating, request ID, and necessary version information; by default it includes neither audio nor text. Negative feedback opens a problem panel with available raw transcript, final output, playable recording, reason, and corrected text. Opening the panel sends nothing. Before submission, show the exact data list, recording duration, recipient, purpose, retention policy, and Cancel/Confirm Upload actions. Do not construct a send request before confirmation. If attachments, text, or recipient change before or after confirmation, require confirmation of the actual payload again. Never upload the original full input field, clipboard contents, or material from another session.

Prepare the available recording and recognized text by default for negative feedback. Let users remove audio or send text-only feedback. Disabled local saving does not prohibit this one expressly consented cloud submission, but feedback must not save new local history in violation of the switches. Historical feedback may include only content that actually remains; it cannot retrieve deleted audio or text from the transcription server. Mark missing fields honestly.

When audio saving is off, start a 60 second monotonic TTL when the final result or final failure can be shown. Opening the panel, entering a reason, submitting, losing network, or retrying manually does not extend it. On expiry, stop playback, cancel unfinished audio-bearing upload, and release client audio and encoded copies. Do not write them to disk or queue them offline. Bytes already sent cannot be guaranteed withdrawn; expiry does not mean the server received nothing. After audio expiry, text-only feedback may use text still actually available, but the changed data list requires fresh confirmation. Saved audio history follows its own retention period, never extended by feedback.

Distinguish “Uploading,” “Feedback submitted,” “Submission failed,” and “Submission status unknown.” Show success only after a reliable server receipt. If a receipt is lost, query the same `feedbackId` before resending attachments. An explicit retry with an unchanged payload reuses its idempotency ID; changed attachments or text require reconfirmation and a new ID. Cancelling or closing feedback does not withdraw inserted text. Cancellation after upload begins is best effort and cannot claim cloud deletion. Feedback failure must not alter a completed transcription, insertion, history, or copying. Feedback has separate rate limiting and does not consume the daily 50 transcription credits; it remains available when transcription quota is zero.

Deleting local history does not delete feedback already submitted to the cloud. The confirmation panel must provide the actual service's retention policy and available deletion/contact path. Do not expand the purpose from issue improvement to model training without authorization.

### FR-10 Network, server, and data minimization

Cloud requests use HTTPS, except local loopback in development. The transcription API accepts only a bounded raw WAV request stream, parses its header, and limits accumulated size. Do not replace it with multipart temporary files that spool uploaded audio to disk. Proxies and relays must not cache or log request bodies. The feedback service stores only according to its separately disclosed policy; it is not transcription history storage. Do not put feedback audio or text in ordinary logs. Server tasks use no unbounded background queue. A one-process, one-worker MVP fits only a limited in-memory scale and needs a separate design before expansion.

Access control, throttling, counting, credential hashes, task states, and a conservative budget ledger are required MVP server capabilities; their implementation is not proof of a live service. Do not present a mock demo as production ready or invoke a paid model to claim validation without authorization.

### FR-11 Clear errors, fallbacks, and states

Distinguish and display missing permission, exhausted quota, unavailable network, length/size limit, device interruption, changed target, unsafe field, unknown insertion, unavailable service, unknown request, and expired result. Offer actions appropriate to each state: System Settings, Copy, check the same request, wait for reset, or explicitly start a new attempt. Do not imply that upload or quota use did not happen unless the system can prove the request remained before the dispatch boundary.

A 60 second local buffer keeps its original monotonic expiry during network interruption; do not extend it indefinitely or retry upload in the background. Completed text that was not inserted can be copied. “Copied” must not be presented as “Inserted in the original app.”

## 7. Measurable engineering targets, not achieved results or release promises

Measure these in a real implementation; do not state them as achieved performance or model comparisons:

- Under local mock conditions, floating bar interaction p95 below 300 ms.
- For a ten second sample, median end-to-end completion below three seconds and p95 below eight seconds, subject to network, supplier, and model.
- Idle CPU usage below 1%.

Performance targets should not block release indefinitely. Permission handling, safe writing to the original target, duplicate protection, quota, and retention are hard acceptance gates. A model release also needs a real audio benchmark, error analysis, and provider data processing disclosure; candidate materials are not measurements. Official sources cover transcription interfaces, candidate models, and multilingual data.[1] [2] [3] [4] [5]

## 8. Acceptance criteria

These are the minimum MVP cases. “Pass” means the behavior was observed on a real target system or within a controlled mock boundary. It does not imply that all client or server code existed when this specification was written.

### Permissions, idle state, and session controls

- **AC-01 First-use permissions:** Onboarding explains local retention, microphone, Accessibility, and cloud recognition in order; it does not request Input Monitoring unconditionally. After denial, show actual status and a System Settings repair path without fabricating approval.
- **AC-02 No continuous background capture:** In idle, paused, uploading, transcribing, preview, and feedback states, do not show a recording green light or “Recording,” and do not continuously capture. Enter recording only after an explicit Start or Resume.
- **AC-03 Recording methods:** In default toggle mode, the first shortcut starts and the next valid trigger ends. In hold mode, key down starts and key up ends. Key repeat must not create multiple sessions, endings, or server requests.
- **AC-04 Pause and Esc:** Pause does not count toward 120 captured seconds and cancels after five minutes. `Esc` during pause, recording, upload, or transcription cancels and does not insert. A late result after cancellation cannot write to any external app.
- **AC-05 Interruption:** Screen lock, sleep, device loss, or revoked permission ends the recording as cancellation or an explained failure. It must not resume automatically on return.

### Output, original target, and duplicate write protection

- **AC-06 Mixed language and Raw:** A sample containing Chinese, English terms, numbers, and names remains mixed language in Raw without translation, and the Light Polish path is not called.
- **AC-07 Light Polish boundaries:** When chosen before End, only punctuation, moderate paragraph breaks, and obvious fillers change. No summary, translation, expansion, or rewriting of numbers, names, and English terms. Validation or model failure shows Raw with a fallback notice.
- **AC-08 Target focus change:** If the user switches app, window, or field after Start, or the original control becomes invalid or permission is revoked, do not write to the new focus. The bar shows a reason, preview, and Copy only.
- **AC-09 Selection, secure fields, and paste:** A safely verified target and selection may permit replacement. Never write automatically into a secure field. If direct insertion is unavailable but paste is verified safe, paste may proceed. If clipboard snapshot/restoration or paste destination cannot be verified, show preview.
- **AC-10 Unknown insertion never duplicates:** If consumption cannot be confirmed after sending Paste, mark insertion unknown and do not try direct insertion or a second paste. No path automatically sends or executes the content.

### Quota, idempotency, failure, and retry

- **AC-11 Concurrent limit:** Of 51 valid requests submitted concurrently for one anonymous installation, at most 50 are accepted. Show the accurate remaining count and next `Asia/Shanghai` reset time. Changing the local clock does not change server quota.
- **AC-12 Transparent charge boundary:** Empty audio, invalid parameters, and cancellation/failure before dispatch use no credit. Cancellation or failure after possible supplier dispatch counts conservatively with an explanation. Missing or exhausted global budget fails closed with a clear error and no secret model switch.
- **AC-13 Duplicate request:** Retransmitting identical content with one request ID does not charge or call the supplier twice. Reject a reused ID with different content or output mode. Neither 51-way competition nor retransmissions may exceed 50 accepted requests.
- **AC-14 Unknown and explicit retry:** After restart or timeout creates an unknown outcome, query the original request first; do not implicitly reupload audio. Only an explicit retry creates a new request and possible new charge. An original request is not an indefinite result cache after the seven day idempotency window.

### Retention, TTL, and feedback

- **AC-15 Seven day defaults and four combinations:** A new installation clearly shows audio and text both on with separate seven day periods. Verify each on/off combination from FR-08. Persisted content must match the selected switches; feedback must not save disabled content types.
- **AC-16 Retention change and deletion:** Viewing history does not renew expiry. Startup, wake, and hourly running cleanup remove expired items. Turning off a switch does not silently delete existing items. Shortening a period, deleting one item, and deleting all items show impact and require local confirmation.
- **AC-17 60 second buffer:** When audio saving is off, the in-memory recording expires within 60 seconds after the result appears, unaffected by viewing, opening feedback, or losing network. Playback stops and the buffer is cleared on expiry. Cancellation clears it immediately. A later mode change must not replace already inserted Raw or polished text.
- **AC-18 Normal feedback:** With a configured service, positive feedback sends minimal metadata; negative feedback sends this session's audio/text only after an accurate preview and confirmation. Cancelling confirmation sends no request. Cover reliable success receipt, failure, lost-receipt lookup, idempotent retry, reconfirmation after attachment changes, independent throttling, and feedback at zero transcription quota. With audio saving off, stop an unfinished audio upload at the 60 second deadline and release encoded copies without an offline queue. Text-only feedback after audio expiry needs fresh confirmation and must not claim false success. Feedback must not write to an external input field, alter inserted text, or bypass local history switches. Record real service integration and mock validation separately.

### Pre-release compatibility and disclosure

- **AC-19 System and packaging:** On real Apple Silicon Macs running macOS 14 and at least one newer version, verify key permissions, shortcut, recording, target fallback, signing, and notarization. The installer must not imply Intel or Mac App Store support.
- **AC-20 Provider and secret check:** Before release, make supplier data processing disclosure accessible to users. Ensure the client package, logs, and example configuration contain no server keys, recording bodies, or transcript bodies. Mocks are for development and testing, not proof of production readiness.

## 9. Dependencies and decisions before release

Product and operations must configure or decide these before development or release as appropriate; this document does not invent their current values: Bundle ID, backend URL, feedback service address/authentication/actual API/purpose/retention and deletion policy, signing certificate, actual global budget, supplier account configuration, final supplier data processing disclosure, and model selection based on real audio evaluation. Treat them as auditable operational settings, not hard-coded public promises.

Implementation must use verified macOS permission and Accessibility capabilities and acknowledge that writable attributes, focus behavior, and clipboard consumption vary between third-party apps and cannot be guaranteed absolutely. When capability is unclear, reduce automation and fall back to preview/copy rather than broadening permissions, guessing success, or writing twice.

## References

[1]: https://openrouter.ai/docs/guides/overview/multimodal/stt "OpenRouter Speech-to-Text documentation"
[2]: https://openrouter.ai/elevenlabs/scribe-v2 "OpenRouter ElevenLabs Scribe v2 model"
[3]: https://openrouter.ai/openai/whisper-large-v3-turbo "OpenRouter Whisper Large V3 Turbo model"
[4]: https://elevenlabs.io/blog/introducing-scribe-v2 "ElevenLabs Scribe v2 multilingual and batch transcription"
[5]: https://openrouter.ai/openai/gpt-4.1-mini "OpenRouter GPT-4.1 Mini text model"
[6]: https://github.com/sindresorhus/KeyboardShortcuts "KeyboardShortcuts README"
[7]: https://developer.apple.com/documentation/applicationservices/axuielement "Apple AXUIElement"
[8]: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel "Apple nonactivating panel"
[9]: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox "Apple App Sandbox limitations"
[10]: https://developer.apple.com/documentation/security/app-sandbox "Apple App Sandbox and store distribution"
[11]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution "Apple signing and notarization for independent distribution"
[12]: https://support.apple.com/guide/mac-help/control-access-to-the-microphone-on-mac-mchla1b1e1fe/mac "Apple microphone permission"
[13]: https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac "Apple Accessibility permission"
[14]: https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac "Apple Input Monitoring permission"
