from fastapi.testclient import TestClient

from app import app

client = TestClient(app)


def test_stuck_contract():
    # Contradictory on purpose: one request cannot be both 200 and 404, so this
    # fails with the same first error line however the route is written.
    response = client.get("/stuck")
    assert response.status_code == 200
    assert response.status_code == 404
