"""All tests use explicit configuration and forbid real provider network transports."""
import httpx
import pytest


@pytest.fixture(autouse=True)
def no_real_provider_network(monkeypatch):
    async def reject_network(self, request):
        raise AssertionError("Real network access is forbidden in the Saydrop test suite")
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", reject_network)
