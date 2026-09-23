from fastapi.testclient import TestClient

from app import app

client = TestClient(app)


def test_read_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "mini-fastapi fixture"}


def test_read_item():
    response = client.get("/items/42")
    assert response.status_code == 200
    assert response.json() == {"item_id": 42}


def test_read_item_wrong_type():
    response = client.get("/items/not-an-int")
    assert response.status_code == 422
