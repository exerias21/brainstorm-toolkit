import doctest

from fastapi.testclient import TestClient

import legacy
from app import app

client = TestClient(app)


def test_legacy_status_route():
    response = client.get("/legacy-status")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_double_doctest():
    results = doctest.testmod(legacy, verbose=False)
    assert results.failed == 0
