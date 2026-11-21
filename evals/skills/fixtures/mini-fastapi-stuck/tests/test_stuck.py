import pytest
from fastapi.testclient import TestClient

from app import app

client = TestClient(app)


def test_stuck_contract():
    # Unsatisfiable on purpose: the first error line is fixed text, independent
    # of the app, so every fix attempt fails with the identical signature.
    client.get("/stuck")
    pytest.fail("contract is unsatisfiable by design")
