import asyncio
import hmac
import json
import time
from contextlib import asynccontextmanager
from ipaddress import ip_address
from uuid import UUID

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse

from saydrop_server.config import Settings
from saydrop_server.dto import InstallRequest, OutputMode, TaskResponse
from saydrop_server.errors import MESSAGES, ApiError
from saydrop_server.monitoring import Monitor, TaskTrace
from saydrop_server.observability import MetricSample
from saydrop_server.providers import GroqProvider, MockProvider, OpenRouterProvider
from saydrop_server.rate_limit import RateLimiter
from saydrop_server.storage import Store, process_lock
from saydrop_server.tasks import TaskManager
from saydrop_server.wav_validation import read_wav, validate_wav


def create_app(settings: Settings | None = None, *, provider=None, wall_clock=None) -> FastAPI:
    settings = settings or Settings.load()

    @asynccontextmanager
    async def lifespan(app):
        with process_lock(settings.database_path):
            store = Store(settings, wall_clock)
            monitor = Monitor(store)
            recovery = store.recover()
            store.release_orphaned()
            store.cleanup()
            monitor.metrics.cleanup()
            for outcome in ("unknown", "failed"):
                if recovery[outcome]:
                    monitor.event("recoveryCount", outcome=outcome, value=recovery[outcome])
            if recovery["result_expired"]:
                monitor.event("resultExpiredCount", value=recovery["result_expired"])
            actual_provider = provider
            if actual_provider is None:
                actual_provider = {"mock": MockProvider, "openrouter": OpenRouterProvider, "groq": GroqProvider}[settings.provider_mode](settings)
            tasks = TaskManager(store, actual_provider, settings, monitor=monitor)
            limiter = RateLimiter(settings)
            app.state.store, app.state.tasks, app.state.limiter = store, tasks, limiter
            app.state.monitor = monitor
            app.state.metrics_job = None

            async def maintenance():
                last_cleanup = time.monotonic()
                while True:
                    await asyncio.sleep(0.5)
                    tasks.sweep()
                    limiter.cleanup()
                    store.release_orphaned()
                    if time.monotonic() - last_cleanup >= 3600:
                        store.cleanup()
                        try:
                            monitor.metrics.cleanup()
                        except Exception:
                            monitor.write_failures += 1
                        last_cleanup = time.monotonic()

            maintenance_job = asyncio.create_task(maintenance())
            try:
                yield
            finally:
                maintenance_job.cancel()
                await asyncio.gather(maintenance_job, return_exceptions=True)
                await tasks.shutdown()
                if app.state.metrics_job is not None:
                    await asyncio.gather(app.state.metrics_job, return_exceptions=True)
                store.engine.dispose()

    app = FastAPI(title="Saydrop", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    def response(data, status=200):
        return JSONResponse(data, status_code=status, headers={"Cache-Control": "no-store"})

    def error_response(request: Request, exc: ApiError):
        payload = {"error": exc.payload()}
        owner = getattr(request.state, "owner", None)
        if request.method == "POST" and request.url.path == "/v1/transcriptions" and not getattr(request.state, "rejection_recorded", False):
            request.state.rejection_recorded = True
            monitor = getattr(app.state, "monitor", None)
            if monitor is not None:
                monitor.event("rejectedCount", outcome="rejected", reason=exc.code)
        if owner:
            if getattr(request.state, "request_id", None):
                payload["requestId"] = request.state.request_id
            try:
                payload["quota"] = app.state.store.quota(owner)
            except Exception:
                pass  # no exception repr or sensitive input in error output/logs
        return response(payload, exc.status_code)

    @app.middleware("http")
    async def secure_transport(request: Request, call_next):
        request.state.received_at = time.monotonic()
        if request.method == "POST" and request.url.path == "/v1/transcriptions":
            app.state.monitor.event("submitCount")
        try:
            # Do not trust client-provided X-Forwarded-* headers.
            if request.url.scheme != "https":
                host = request.client.host if request.client else ""
                try:
                    loopback = ip_address(host).is_loopback
                except ValueError:
                    loopback = False
                if not (settings.environment == "development" and settings.allow_loopback_http and loopback):
                    raise ApiError("forbidden", 403)
            return await call_next(request)
        except ApiError as exc:
            return error_response(request, exc)
        except Exception:
            return error_response(request, ApiError("internal_error", 500, retryable=True))

    @app.exception_handler(ApiError)
    async def typed_error(request: Request, exc: ApiError):
        return error_response(request, exc)

    @app.exception_handler(RequestValidationError)
    @app.exception_handler(ValidationError)
    async def invalid_request(request: Request, exc):
        return error_response(request, ApiError("invalid_request", 422))

    @app.exception_handler(HTTPException)
    async def route_error(request: Request, exc):
        return error_response(request, ApiError("not_found", 404) if exc.status_code == 404
                              else ApiError("invalid_request", 422))

    def ip(request: Request) -> str:
        return request.client.host if request.client else "unavailable"

    def no_query(request: Request):
        if request.query_params:
            raise ApiError("invalid_request", 422)

    def authenticate(request: Request) -> str:
        no_query(request)
        app.state.limiter.ip_request(ip(request))
        header = request.headers.get("authorization", "")
        parts = header.split(" ")
        if len(parts) != 2 or parts[0].lower() != "bearer":
            raise ApiError("invalid_token", 401)
        owner = app.state.store.authenticate(parts[1])
        request.state.owner = owner
        app.state.limiter.installation(owner)
        return owner

    def uuid_value(value: str) -> str:
        try:
            parsed = UUID(value)
            # UUID text must be canonical; prevent aliases of the same logical key.
            if str(parsed) != value.lower():
                raise ValueError
            return str(parsed)
        except (ValueError, AttributeError):
            raise ApiError("invalid_request", 422) from None

    @app.get("/internal/metrics")
    async def metrics(request: Request):
        app.state.limiter.ip_request(ip(request))
        secret = settings.metrics_token.get_secret_value()
        parts = request.headers.get("authorization", "").split(" ")
        if not secret or len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].isascii() or len(parts[1]) != 43:
            raise ApiError("forbidden", 403)
        if not hmac.compare_digest(parts[1], secret):
            raise ApiError("forbidden", 403)
        if set(request.query_params) - {"days", "source"} or any(len(request.query_params.getlist(k)) != 1 for k in request.query_params):
            raise ApiError("invalid_request", 422)
        raw_days = request.query_params.get("days", "1")
        if not raw_days.isascii() or not raw_days.isdecimal() or len(raw_days) > 2:
            raise ApiError("invalid_request", 422)
        days = int(raw_days)
        source = request.query_params.get("source", "live")
        if not 1 <= days <= settings.metrics_retention_days or source not in {"live", "mock", "offline"}:
            raise ApiError("invalid_request", 422)
        if app.state.metrics_job is not None and not app.state.metrics_job.done():
            raise ApiError("rate_limited", 429, retryable=True)
        job = asyncio.create_task(asyncio.to_thread(app.state.monitor.metrics.snapshot, days=days, source=source))
        app.state.metrics_job = job
        # Shield the single admitted read; disconnect cannot create a second overlapping
        # read. Completion always consumes errors without logging SQL parameters.
        def read_done(completed):
            if not completed.cancelled():
                completed.exception()
        job.add_done_callback(read_done)
        data = await asyncio.shield(job)
        data["writeFailureCountSinceStart"] = app.state.monitor.write_failures
        return response(data)

    @app.get("/healthz")
    async def health():
        return response({"status": "ok"})

    @app.post("/v1/installations")
    async def installations(request: Request):
        no_query(request)
        app.state.limiter.registration(ip(request))
        if request.headers.get("content-type", "").split(";")[0].lower() != "application/json":
            raise ApiError("invalid_request", 422)
        body = bytearray()
        try:
            async with asyncio.timeout(settings.upload_timeout):
                async for chunk in request.stream():
                    if len(body) + len(chunk) > 1024:
                        raise ApiError("invalid_request", 422)
                    body.extend(chunk)
            incoming = InstallRequest.model_validate_json(body)
        except TimeoutError:
            raise ApiError("request_timeout", 408, retryable=True) from None
        except (ValidationError, ValueError, json.JSONDecodeError):
            raise ApiError("invalid_request", 422) from None
        owner, token = app.state.store.register(incoming.clientVersion, incoming.platform)
        return response({"installationId": owner, "accessToken": token,
                         "quota": app.state.store.quota(owner)}, 201)

    @app.get("/v1/quota")
    async def quota(request: Request):
        owner = authenticate(request)
        return response(app.state.store.quota(owner))

    @app.post("/v1/transcriptions")
    async def transcriptions(request: Request):
        received_at = request.state.received_at
        deadline = received_at + settings.task_timeout
        owner = authenticate(request)
        request_id = uuid_value(request.headers.get("idempotency-key", ""))
        request.state.request_id = request_id
        mode = request.headers.get("x-output-mode", "")
        if mode not in {item.value for item in OutputMode}:
            raise ApiError("invalid_request", 422)
        if request.headers.get("content-type", "").lower() != "audio/wav":
            raise ApiError("invalid_request", 422)
        tasks = app.state.tasks
        tasks.claim_upload()
        audio = b""
        try:
            upload_started = time.monotonic()
            audio = await read_wav(request, settings, deadline)
            upload_seconds = time.monotonic() - upload_started
            validation_started = time.monotonic()
            metadata = validate_wav(audio, settings)
            validation_seconds = time.monotonic() - validation_started
            if time.monotonic() >= deadline:
                raise ApiError("request_timeout", 408, retryable=True)
            fingerprint = app.state.store.fingerprint(audio)
            task = app.state.store.existing(owner, request_id, fingerprint, mode)
            if task is None:
                if not tasks.has_result_capacity():
                    raise ApiError("rate_limited", 429, retryable=True)
                task, new = app.state.store.reserve(owner, request_id, fingerprint, mode)
                if new:
                    monitor = app.state.monitor
                    trace = TaskTrace(mode, settings.stt_model, monitor.source, received_at, metadata.duration_seconds)
                    trace.add("uploadSeconds", upload_seconds)
                    trace.add("validationSeconds", validation_seconds)
                    monitor.record([MetricSample("acceptedCount", 1, mode=mode, source=monitor.source)])
                    trace.add("audioSeconds", metadata.duration_seconds)
                    trace.add("ttftSeconds", None, reason="non_streaming")
                    tasks.start(owner, request_id, audio, mode, deadline, trace=trace)
                else:
                    app.state.monitor.event("idempotentReplayCount", mode=mode)
            else:
                app.state.monitor.event("idempotentReplayCount", mode=mode)
            # For a repeated ready task, return its actual state after checking RAM expiry.
            tasks.sweep()
            task = app.state.store.status(owner, request_id)
            app.state.monitor.event("submissionSeconds", mode=mode, value=time.monotonic() - received_at)
            return response({"requestId": request_id, "status": task["status"],
                             "quota": app.state.store.quota(owner)}, 202)
        finally:
            tasks.uploads -= 1
            audio = b""

    @app.get("/v1/transcriptions/{requestId}")
    async def status(requestId: str, request: Request):
        owner = authenticate(request)
        request_id = uuid_value(requestId)
        request.state.request_id = request_id
        task = app.state.store.status(owner, request_id)
        result = app.state.tasks.result(owner, request_id)
        if task["status"] == "ready" and result is None:
            app.state.store.expire_result(owner, request_id)
        task = app.state.store.status(owner, request_id)
        data = {"requestId": request_id, "status": task["status"],
                "outputMode": task["output_mode"], "polishStatus": task["polish_status"],
                "quota": app.state.store.quota(owner)}
        if task["result_expires_at"]:
            data["resultExpiresAt"] = task["result_expires_at"]
        if task["status"] == "ready" and result:
            data.update(rawText=result.raw_text, outputText=result.output_text)
        if task["failure_code"]:
            code = task["failure_code"]
            data["error"] = {"code": code, "message": MESSAGES[code],
                             "retryable": code in {"upstream_failed", "request_timeout", "budget_unavailable", "internal_error"}}
        return response(TaskResponse.model_validate(data).model_dump(mode="json", exclude_none=True))

    @app.delete("/v1/transcriptions/{requestId}")
    async def cancel(requestId: str, request: Request):
        owner = authenticate(request)
        request_id = uuid_value(requestId)
        request.state.request_id = request_id
        app.state.store.cancel(owner, request_id)
        app.state.tasks.cancel(owner, request_id)
        return response({"requestId": request_id, "status": "cancelled", "cancellationRecorded": True,
                         "quota": app.state.store.quota(owner)})

    return app
