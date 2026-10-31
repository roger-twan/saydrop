# Saydrop server

Saydrop's single-process, single-worker FastAPI backend, with SQLite persistence for performance metrics and offline reference quality evaluation.

## Environment and installation

This round was tested on macOS Apple Silicon with Python **3.13.7**. The project declares Python 3.12+, but it has not yet been tested on 3.12 or other systems. Exact dependency versions are pinned in `pyproject.toml`, and transitive dependencies are locked in `uv.lock`; Docker, Redis, and Celery are not required.

Run from the repository root, using the Python 3.13 path already present on this machine without upgrading the system toolchain:

```bash
uv venv server/.venv --python /usr/local/bin/python3.13
uv sync --project server --extra test --locked --python /usr/local/bin/python3.13
cd server
.venv/bin/python -m pytest -q
.venv/bin/python -m ruff check saydrop_server tests
```

The `uv` installation location may differ; use the command available on the local machine. The source delivery includes lock files but excludes `.venv`, audio, databases, or `.env`.

## Secrets and budget

`server/.env` in this workspace has mode `0600` and contains separate random token pepper, audio fingerprint HMAC key, and metrics token values. The OpenRouter key was not rewritten for this round of monitoring, and the budget still requires operational review. Do not paste this file into logs, issue reports, or version control; the root `.gitignore` already ignores secrets, SQLite, and local environments. The source package provides only `.env.example`.

For a new environment, copy the example and then generate and fill in three independent random secrets locally:

```bash
cp .env.example .env
chmod 600 .env
```

Generate `SAYDROP_TOKEN_PEPPER` and `SAYDROP_FINGERPRINT_KEY` separately with `secrets.token_hex(32)`, and write them only to `.env`. `OPENROUTER_API_KEY` is filled in locally by operations and must not enter the client, SQLite, logs, or HTTP errors.

Generate `SAYDROP_METRICS_TOKEN` separately with `secrets.token_urlsafe(32)`, and write it only to `.env`. It is an independent 256-bit operational credential and must not reuse the anonymous installation token or vendor key; when left empty, the internal metrics endpoint fails closed. `SAYDROP_METRICS_RETENTION_DAYS=30` is the reviewed retention period for numeric metrics in this round; it differs from the 120-second TTL for content.

Load order is `.env` first, then overridden by environment variables of the same name. Module import does not read `.env`; configuration is loaded only at factory startup and by the explicit migration command. Tests inject temporary configuration directly and do not need real secrets. Changing the pepper/key affects existing anonymous credentials/fingerprints; review a rotation plan first. No old-key-ring rotation tool or new revocation API is currently provided.

In production and real-vendor mode, when the budget is missing, malformed, zero, has no configured version, or the key is missing, new transcriptions are rejected with `503 budget_unavailable`. Operations must review:

- `SAYDROP_DAILY_BUDGET_UNITS`: daily integer billing-unit limit.
- `SAYDROP_RAW_ESTIMATE_UNITS`: worst-case cost estimate for maximum 120-second STT.
- `SAYDROP_POLISH_ESTIMATE_UNITS`: worst-case total cost for maximum STT plus one polish with at most 16,000 input characters / 2,048 output tokens.
- `SAYDROP_BUDGET_CONFIG_VERSION`: reviewed configuration version.

Do not guess prices or USD conversion. The adapter currently does not convert OpenRouter `usage.cost` into abstract units; `actual_units=None`, and the dispatched ledger conservatively holds the estimate. Settlement occurs only when the injected adapter returns verifiable non-negative integer actual units. The ledger is not a hard cap on the vendor bill; operations must still set a vendor hard limit. Filling in a key or adjusting the budget does not authorize real calls for this task.

## Explicit migration and local startup

Under `server/`:

```bash
.venv/bin/python -m saydrop_server.migrate
.venv/bin/uvicorn saydrop_server.main:create_app \
  --factory --host 127.0.0.1 --port 8000 --workers 1 \
  --no-access-log --no-proxy-headers
```

Factory startup is a user-reviewed and approved adjustment, and section 13.2 of the technical document has been synchronized. The original six business APIs are unchanged; what was added is a separate operational read path. The current SQLite revision is 2: `001_initial.sql` creates the business metadata, and `002_metrics.sql` adds the metrics tables; the explicit v1→v2 migration preserves existing tasks, credentials, and quota. The app does not silently create or ALTER schemas. Startup checks the version and holds a database process lock, rejecting a second business worker/process; no online database is migrated without separate authorization.

Development HTTP is allowed only when `SAYDROP_ENVIRONMENT=development` and `SAYDROP_ALLOW_LOOPBACK_HTTP=true`, and the request originates from loopback. All other cases require HTTPS. The startup command does not trust client `X-Forwarded-*` headers; production TLS termination and trusted proxies must be designed and verified separately when deployment authorization is obtained. Do not simply switch to public HTTP.

The default `SAYDROP_PROVIDER_MODE=openrouter`; this is not a hidden mock. For an explicit local mock demo, set `mock` in the development configuration and provide an explicit local mock budget; the returned body contains `[MOCK]` and does not represent real recognition. Production configuration rejects mock.

## Business contract

The following six business paths are retained; `/docs`, `/redoc`, `/openapi.json`, and model-parameter endpoints are not exposed. There is also an operations-only `GET /internal/metrics`, which does not use anonymous client credentials:

```text
GET    /healthz
POST   /v1/installations
GET    /v1/quota
POST   /v1/transcriptions
GET    /v1/transcriptions/{requestId}
DELETE /v1/transcriptions/{requestId}
```

The installation registration JSON is `{"clientVersion":"0.1.0","platform":"macos-arm64"}`, and it issues a random 256-bit token exactly once. The server stores only the HMAC and key version. `installationId` is not a credential.

Transcription submission is strictly a raw body with `Content-Type: audio/wav`, and must carry Bearer, a UUID `Idempotency-Key`, and `X-Output-Mode: raw|light_polish`. It does not accept multipart, JSON base64, or model/prompt query parameters. `requestId` uses the client UUID; if the receipt is lost, query/cancel the same UUID and do not automatically re-upload. JSON is camelCase, and all responses use `Cache-Control: no-store`.

States are `processing / ready / failed / cancelled / unknown / result_expired`. All task reads/cancellations enforce owner ACL; non-owner and non-existent both return a uniform 404. Errors output only the established code, a Chinese-language non-sensitive message, and `retryable`; when safe, `requestId`/`quota` are included. Vendor responses are not passed through.

## Reviewed implementation parameters

The daily quota is 50 per anonymous installation instance, reset at natural day in `Asia/Shanghai` on the server, and a task belongs to the date at the time of reservation. The remaining value is `max(0, limit-used-reserved)`. The underlying `BEGIN IMMEDIATE` test verifies that at most 50 of 51 competing requests are reserved; at the HTTP layer, only one active task per installation instance is allowed at a time, so of 51 simultaneous requests from the same instance at most one is accepted and the others return `429 rate_limited`. This distinction has been reviewed by the user.

Installation registration is limited to 5 per IP per hour and 100 globally per hour; authenticated requests are limited to 60 per installation per minute and 120 per IP per minute as an auxiliary limit. IPs are stored in memory only as process-keyed digests, cleared when the window ends, and do not form a long-term identity dossier. The in-memory number of rate-limit buckets is also bounded. The anonymous mechanism cannot guarantee a per-natural-person limit or prevent Sybil.

Globally, at most 4 upload/processing tasks and at most 32 results are allowed, with result capacity reserved for in-flight tasks. When capacity is full, new tasks are rejected; there is no wait queue and no silent eviction. Upload 30 seconds, STT 45 seconds, light polish 8 seconds, and 60 seconds total from submission to terminal state. Raw WAV is 16 kHz mono PCM16, 8 MiB, 120 seconds; RMS ≤ 32 is judged empty/near-silent. The threshold is only a basic protection and is not equivalent to real VAD acceptance.

Quota is atomically reserved after WAV validation and authentication succeed. Before dispatch, another transaction writes an irreversible `dispatch_marked_at`, converts reserved to used, and reserves budget; failure/cancellation before dispatch releases quota, while cancellation/failure/uncertainty after dispatch still counts. The primary model allowlist defaults to `elevenlabs/scribe-v2` with comparison `openai/whisper-large-v3-turbo`, with no automatic switching. Light polish uses only `openai/gpt-4.1-mini`, a fixed system prompt, no tools, and at most one attempt. The raw path does not call polish.

The light-polish mechanical check protects numbers, English text, URLs, emails, code/identifiers, and other non-punctuation character sequences, allowing only conservative changes to punctuation, whitespace, and the explicit fillers "嗯" and "呃". On validation failure, timeout, truncation, or upstream error, it falls back to the raw text with `polishStatus=failed_fallback_raw`. This cannot guarantee that all semantics/names remain absolutely unchanged; real quality is still not accepted.

## Retention and recovery

SQLite persistently stores authentication, quota, tasks, idempotency, budget, and anonymous numeric metrics, but not audio, body text, plaintext tokens, or provider keys. The metrics tables do not store requestId, owner, IP, or content digests. Audio exists only in memory within the bounded request/task and is released when STT completes; the base64 sent to the vendor is also memory-only. Result bodies have a maximum 120-second monotonic TTL, reads do not extend it, a 0.5-second maintenance cycle purges them, and reads encountering expiry immediately return `result_expired`.

Startup recovery: dispatched but uncertain `processing` tasks become `unknown` and are not replayed; previously `ready` tasks become `result_expired`; orphaned reservations that were never dispatched are released after the original task deadline. Status/idempotency tombstones are kept for at least 7 days, cleaned at startup and hourly; the same UUID conflict returns 409, and terminal states are not re-run. An explicit new attempt uses a new UUID and may be counted again.

Request/body logging is currently not configured, and local startup disables the access log. Reverse-proxy buffering to disk, request caching, TLS, system swap/crash dumps, and vendor retention cannot be proven by a local mock and must be reviewed separately before production deployment. Do not claim physical zeroization of RAM/SSD.

## Performance and quality monitoring

Metrics are written directly to `metric_samples`, retained for 30 days by default, with fixed UTC observation/expiry times and no extension on read. Expired data is immediately invisible to queries and is physically purged at startup and hourly. No monitoring framework is used, no external telemetry is connected, and no dashboard is developed; the metrics tables must not be used to extend recording or body retention.

Runtime metrics include upload, validation, receipt, STT, light polish, result-ready, and total task durations; application-layer TTFB; audio duration, character count, RTF/processing throughput; and success, failure, unknown, cancellation, timeout, rejection, and polish-fallback rates with explicit denominators. `ttftSeconds` is fixed to `NULL / non_streaming`: the verified OpenRouter STT contract does not provide real word-by-word streaming, HTTP chunked reading is not incremental text, and TTFB or full-JSON latency must not be treated as TTFT.

`GET /internal/metrics?days=1&source=live` uses `Authorization: Bearer <independent metrics token>`; missing/incorrect credentials return a generic 403. days is 1–30, and source may be only live, mock, or offline, defaulting to live; do not put credentials in URLs, shell logs, or reports. The endpoint returns no details, no requestId, and no body text; it returns fixed groups' count/unavailableCount, mean, min/max, sum, and nearest-rank p50/p95/p99, plus summary numerator/denominator/value. Rates with no samples are null. Aggregation is completed within a single WAL read snapshot and moved off the business event loop; at most one aggregate read runs at a time, overlapping reads return 429, and there is no unbounded wait queue.

The source and model labels are for classification and are not proof that real calls were made or that model quality has been tested. Mock is not mixed into live, and offline is not mixed into online latency. Phase samples are written in bounded batches at terminal state; idempotent re-uploads do not double-count accepted/terminal, and true terminal classification is recorded both before and after cancellation. Written metrics can be recovered after restart; phases not written before a crash cannot be recovered. A metrics write failure does not change the result, quota, or number of model calls; the in-process `writeFailureCountSinceStart` makes the loss visible.

Online result validity and explicit truncation checks are not accuracy or semantic-completeness checks. The offline tool only compares the human reference you provide against the actual hypothesis: CER, strict CER, English/numbers-only WER, the project's mixed-token error rate, deletion-unit omission rate, and key number/term retention rate. Missing/empty references are unavailable, and reports do not output the source text; error rates may exceed 1 and are not clipped to "100%". See [section 14 of the technical document](../outputs/specs/technical-specification.md) for the versioned normalization and full formulas.

In the server directory, use an in-place JSONL input with only `reference`, `hypothesis`, and optionally `protectedTerms` per line. No real test set or model score examples are provided, to avoid any impression that acceptance has already occurred:

```bash
.venv/bin/python -m saydrop_server.quality \
  --input /path/to/authorized-reference-results.jsonl \
  --output /path/to/new-numeric-report.json

# .env is loaded only with explicit --persist, writing content-free corpus metrics; the database must already be migrated to v2
.venv/bin/python -m saydrop_server.quality \
  --input /path/to/authorized-reference-results.jsonl \
  --output /path/to/another-new-numeric-report.json \
  --persist --model elevenlabs/scribe-v2 --mode raw
```

The default --model/--mode is none, and the model source is not guessed. Limits are 256 KiB per line, 32 MiB total, 10,000 lines, 32,000-character fields, and 2,000,000 DP cells per run; exceeding a limit does not truncate the scoring. Output cannot overwrite the source file or an existing report. Persistence stores only corpus rates and each S/D/I/N weight; running manually again adds a new evaluation batch and does not guarantee global sample deduplication. Database and report writes are not atomic across resources; any failure is reported explicitly and not retried automatically.

This round's limited SQLite stress test used 4 writers and 64,000 synthetic numeric rows with no loss, retaining SQLite; see the monitoring development report for specific timings. This is not a model benchmark or production capacity verification. When multiple business instances, sustained high write-lock contention, or unacceptable actual latency is needed, submit evidence to evaluate PostgreSQL first; do not simply increase the number of SQLite workers.

## Tested and untested

Detailed test counts, command results, and changed files are in this round's server development report. Tests include synthetic WAV, `httpx.MockTransport`, FakeProvider, temporary SQLite, concurrent reservation, ACL, cancellation, cross-day, restart, TTL, budget, and secrets not written to disk. Tests automatically reject the real httpx network transport.

Real OpenRouter calls, audio/mixed-language quality, real cost, vendor disclosure, production HTTPS/proxy, load performance, and other Python/OS versions have not been accepted. There is no client, signing, notarization, DMG, feedback upload, or deployment artifact. Next steps involving real calls/sample uploads, budget, and any deployment require separate explicit authorization from the user.

## Groq speech recognition

Set the following in the local `.env`:

```dotenv
SAYDROP_PROVIDER_MODE=groq
SAYDROP_STT_MODEL=whisper-large-v3-turbo
GROQ_API_KEY=fill-in-local-key
```

`whisper-large-v3` is also supported. Startup fails when the vendor and model do not match; in Groq mode the budget check uses the Groq key while retaining the existing local quota and budget preflight. The key is never sent to the client. Free-tier limits are governed by the Groq account, and the program cannot guarantee that it will always remain free.

Groq uses the official HTTPS multipart audio transcription endpoint and does not automatically retry or fall back to another vendor. Raw mode returns text normally; light polish mode does not access OpenRouter and explicitly returns `failed_fallback_raw` with the raw text. Speech recognition is not performed offline. Logs record only Groq's HTTP status code, not error bodies, audio, or keys.

Database revision 3 extends the model allowlist for numeric metrics while preserving existing records. Before upgrading, stop the backend, back up the database, and then run `python -m saydrop_server.migrate`. The client Debug notes have added Groq as a recipient; after updating, the notes must be accepted again.

Offline verification: 139 backend tests pass, including Groq multipart requests, error redaction, model configuration, v2→v3 upgrade with metrics preservation, and the complete business path for raw/light-polish fallback; mock transport is used and no real vendor is called.

A Groq-specific proxy can be configured with `SAYDROP_GROQ_PROXY_URL=http://127.0.0.1:7890`. Only explicit loopback HTTP(S) proxies are accepted; system proxy environment variables are not read. The setting takes effect after restart. TLS verification remains enabled. The proxy must run continuously; in this round a read-only model-list query returned 200 through this proxy, while a direct connection had returned 403. Real recording transcription has not yet been executed through the proxy.
