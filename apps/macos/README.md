# Saydrop native client

macOS 14+ / Apple Silicon, SwiftUI + AppKit. Real AVAudioEngine recording, in-memory WAV, global KeyboardShortcuts, and the cloud business HTTP client are all wired into the source.

## Cloud integration status

The Debug Bundle ID is `local.saydrop.dev`. Debug uses a separate `SaydropApp/Info-Debug.plist` that sets only `NSAllowsLocalNetworking`; there is no global `NSAllowsArbitraryLoads`. Release uses `Info.plist`; the production URL and Bundle ID are still empty, only HTTPS is allowed, and there is no signing, notarization, or release.

App launch, first-run introduction, and UI demos do not initialize an anonymous installation or upload audio. By default the app reads Keychain on demand; it reads an existing anonymous credential only for an explicit connection, quota refresh, or recovery query, and a query does not register a new installation for a lost credential. When actual vendor disclosure is not configured, the cloud recording entry point stays closed; **a successful health check does not replace verification of vendor, budget, or privacy configuration**.

### Configuration before opening the real upload entry point

`CloudDisclosure.example.plist` is an **empty template and is not loaded automatically**. After operations confirms the actual service configuration, fill the following four non-secret keys into the corresponding app's `Info-Debug.plist` / `Info.plist`:

| Key | Actual information that must be provided |
|---|---|
| `SaydropCloudDisclosureVersion` | Disclosure version |
| `SaydropCloudReceiver` | Product backend and the actual recognition/polish recipients |
| `SaydropCloudPurpose` | Actual processing purpose for audio and text |
| `SaydropCloudRetention` | Backend and vendor retention/deletion policy; do not fabricate zero retention |

Upload is not enabled while the template is empty; do not treat candidate models in documentation as verified configuration. The vendor key exists only on the controlled server; this app does not read `server/.env` and does not offer user-provided keys.

After configuration is complete, the user reads the explanation under "Settings → Cloud Recognition" and explicitly clicks "I have read and accept, and will initialize the anonymous connection." Only this action checks health, reads an existing Keychain credential, and if necessary requests an anonymous installation, saves it, and then adopts the server quota. Changes to disclosure material, version, or origin invalidate prior consent. Exiting or withdrawing consent does not automatically delete the anonymous credential, nor does it guarantee withdrawal of processing already dispatched.

**This round is authorized for offline/mock testing only; the real operations above have not been performed.** Subsequent runs will involve real anonymous registration/quota queries; real recording upload and vendor calls require new explicit authorization and confirmation of budget and short audio materials.

### Implemented cloud path

`AppModel → RealSessionBackend → TranscriptionAPIClient → product backend /v1/*`.

Before starting or resuming capture, re-check health and authoritative quota; on failure, do not open the microphone. Local checks do not go through these cloud preconditions. After finishing, submit the in-memory WAV using the same session UUID as the `Idempotency-Key`, locking the session's `raw`/`light_polish` mode. Send requests only to the product backend; do not call vendors directly.

- `POST /v1/installations`: one request; the token is usable only after it is saved successfully. If saving fails, keep the token already issued to this process and retry only saving, without re-registering.
- `GET /v1/quota`: the server's 50-per-installation quota; when unavailable, clear the old value and show the Asia/Shanghai reset time.
- `POST /v1/transcriptions`: raw WAV body, `Authorization`, `Idempotency-Key`, `X-Output-Mode`; no file upload or offline audio queue.
- `GET /v1/transcriptions/{id}`: bounded polling of the same UUID, 202 is not treated as completion, and a lost receipt does not cause the POST to be resent; processing stages do not fake word-by-word or exact polish progress.
- `DELETE /v1/transcriptions/{id}`: best-effort cancellation; a 404 may mean the original POST has not finished reading, so perform a limited re-query/re-DELETE; no guarantee of withdrawal or quota refund.

Known terminal-state validation covers UUID, mode, quota, ISO dates, and body combinations; raw must be `not_requested` and the raw text must equal the output, and a light-polish fallback to raw must be explicitly marked. HTTP response limit is 1 MiB and text is limited to 32,000 characters per segment; exceeding either is rejected rather than truncated. Upload and polling share a 60-second monotonic deadline; a single upload waits at most 30 seconds, GET/DELETE at most 10 seconds, and each request has its own cancellation deadline so slow traffic cannot extend the deadline. System TLS verification is retained, all redirects are rejected, and cache/cookies/credential storage/background sessions are disabled.

When the original request is unknown, query first in Settings; the result is restored only as a manual-copy preview, without writing history, auto-inserting, or restoring audio. The preview stays in memory for at most 60 seconds and repeated queries do not extend it. A cancelled original request does not restore late body text. After an explicit query returns unknown, not-found, or locally cancelled, the user may confirm "abandon recovery and allow a new session"; this only clears the recovery marker, does not resend old audio, and does not prove the original request was not counted. The new session must be started actively, refresh preconditions, and may be counted again.

## Local recording and shortcut check (no upload)

1. Open `Saydrop.xcodeproj`, select the **Debug** configuration of the `Saydrop` scheme, do not enable `--ui-demo`, and run from `Saydrop.app`.
2. Complete the first-run introduction. Open the check window from the menu bar, the window menu, or "Settings → Local Recording Check (no upload)…".
3. Explicitly enable the local-check purpose, click "Allow Microphone" or grant permission in System Settings, then re-check. Enabling the purpose itself does not start capture.
4. Click "Start Local Recording", or use the default **Command + Option + T**. You can re-record the shortcut and choose toggle/push-to-talk; during the local check the shortcut is used only for local capture.
5. Check the real level, pause, resume, finish, and cancel. On finish you can play the in-memory WAV and see format, duration, and frame count; it is not disguised as transcription or insertion.
6. Global Esc requires separately configured Input Monitoring at the user's discretion; when unavailable, cancel from the bar/check window. Esc within the app still works.

The local check does not upload, recognize, or write history. Completed audio stays in memory for at most 60 seconds; playback/opening the page does not extend it; closing, cancelling, restarting, or actively clearing releases references. Sleep/lock screen/session deactivation stops capture and does not resume recording. No guarantee of physical zeroization of RAM, swap, dumps, or backups can be made.

## Local build and tests

From the project root:

```bash
bash apps/macos/scripts/check-cloud.sh --snapshots --build
```

## Structure

- `Services/CloudConfiguration.swift`: strict origin, Debug loopback, disclosure, and security errors; no vendor key.
- `Services/CloudCoordinator.swift`: explicit consent, connection/quota preflight, original-request query, monotonic recovery preview, exit cleanup.
- `Services/InstallationCredentialStore.swift`: Data Protection Keychain, `WhenUnlockedThisDeviceOnly`, sync disabled, partitioned by origin, errors never fall back to cleartext; the app reads on demand by default. Data Protection flags are set according to the current SDK `SecItem.h` macOS documentation; no unconfirmed access group or signing is added.
- `Services/PendingTranscriptionStore.swift`: one id/mode/locallyCancelled marker per origin, no audio/body/token; unknown fields or corrupt records fail closed. System persistence via UserDefaults does not guarantee that the last `set` before a crash reached disk.
- `Services/CloudHTTPTransport.swift`: bounded foreground HTTP, independent deadlines, redirects rejected.
- `Services/TranscriptionAPIClient.swift`: anonymous credential preparation, authoritative quota, one POST with same-ID query/cancel, recovery protection.
- `Services/AudioPipeline.swift` / `RealSessionBackend.swift`: native sample-rate Float32, C11 bounded ring, worker mixing/resampling, 16 kHz mono PCM16 WAV, near-silence rejection before dispatch.
- `Services/ShortcutController.swift`, `ShortcutPreferences.swift`, `GlobalEscapeMonitor.swift`: real hotkey edges, typed recording, in-scope Esc; preserving local-purpose and session-ID safety.
- `Views/CloudConnectionView.swift`: configuration, consent, request query, and manual recovery; other windows and components continue to reuse existing implementations.

## Still to be verified or implemented

The app has not been run; your voice has not actually been recorded, the real Keychain has not been read, and system permissions, global keys, lock screen, or macOS 14 hardware compatibility have not been tested. **An unsigned Debug build's access to the Data Protection Keychain may be limited by signing/identity policy**; development signing and other operations must be separately confirmed and verified on real hardware later. Any Keychain error still closes upload and does not fall back to a preferences file.

The current service was only confirmed reachable in an earlier health check; this round did not prove its actual vendor, budget, retention policy, or recognition quality. Real upload and quality testing require separate authorization.

Original-target AX capture/safe automatic insertion and encrypted GRDB/SQLite history are still unimplemented; real results are offered only as a safe preview and copy, with no plaintext long-term history. Existing saving/expiry/deletion are still UI and in-memory policies, not equivalent to encrypted persistence. Feedback is a separate service and consent flow; the transcription endpoint/token/disclosure have not been automatically applied as feedback configuration.

`--ui-demo` is always an explicit interface simulation and never touches real recording, hotkeys, Keychain, network, or automatic writing.

See [Cloud client integration development report](../../outputs/frontend-development/云端客户端接入开发报告.md) for detailed implementation and acceptance. See [Recording and global shortcut development report](../../outputs/frontend-development/录音与全局快捷键开发报告.md) for earlier-stage recording reports.

## Local-use configuration fix (2026-10-26)

Debug has been filled in with the local backend and OpenRouter processing-purpose disclosure; vendor retention and training settings are unverified, and the UI explicitly discloses this rather than promising zero retention. Release still requires separate configuration.

The Debug build without a developer signature explicitly uses the macOS login keychain to store the anonymous credential, with sync disabled; Release continues to use the Data Protection Keychain. This is a compile-time choice; it does not switch automatically when storage fails and does not fall back to cleartext. Login-keychain access control differs from Data Protection's ThisDeviceOnly guarantee, so Debug must not be described as providing an equivalent device-binding guarantee. The system may prompt for keychain access authorization.

Verified with a temporary synthetic test item: an unsigned process's Data Protection write returned -34018 (missing entitlement); login-keychain write and delete both returned 0. No actual token was read and no vendor was called.

## Automatic write-back (2026-10-26)

`AutoInsertion` and macOS Accessibility are integrated: at the start of a real session, capture the input field, window, selection, and current text of the frontmost external app; the original text is kept only briefly in local memory and is not sent to the transcription service or written to history. After transcription, verify permissions, app/window/input field, original text, and selection, replace the selection with `AXSelectedText` or insert at an empty selection, and read back the target text to verify the result. At most one attempt per session; on failure or inability to confirm, keep the preview and do not simulate paste, retry, or send Return. Cancel, failure, or session end clears the target context; UI demos and the local recording check do not capture or write to targets.

Allow Saydrop in System Settings under "Privacy & Security → Accessibility". Place the cursor in the target input field, start and stop with the default `⌘⌥T`, and keep the input field, text, and cursor unchanged while waiting for recognition. If you start from the Saydrop main window without capturing an external input field, the preview is still shown. Only text fields that provide readable text/selection and writable `AXSelectedText` are supported; password fields, secure input, read-only fields, multiple selections, editors without Accessibility support, and very large text are not written back. Compatibility with all web editors is not promised; AX verification and writing are not atomic across processes, and when the result cannot be verified after writing it is marked unknown to avoid duplicate operations.

## History storage fix (2026-10-26)

After transcription completes, a real history record is generated according to the current audio/text saving switches, retaining the server request UUID, output mode, original input target name, and insertion result. Both successful insertion and preview-only can be recorded; cancellation, failure, local recording checks, and UI demos do not write real history. When both switches are off, no record is generated. Turning a switch off does not delete existing records.

Local history uses a CryptoKit AES-256-GCM encrypted archive (text, recordings, and metadata are all encrypted), stored at Application Support/<bundle id>/history-v1.enc, with the key stored separately in the keychain. Debug reuses the login-keychain access approach; Release uses the Data Protection Keychain; the key is never written to preferences. The archive is replaced atomically, directories are 0700 and files 0600; no plaintext long-term storage is used, and no third-party database dependency is added. If history cannot be read, old files are not overwritten; save failures show a notice, and the current result stays in memory.

Local history is loaded at startup, and retention is calculated from the original creation time; startup and the existing cleanup task handle expired content. Deletion, clearing, and shortening the retention period write back to the encrypted archive; clearing the temporary playback buffer does not delete history recordings still within the retention period. Sessions that were never saved cannot be recovered.
