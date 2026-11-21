"""Minimal FastAPI app -- the fixture for the sdlc-stuck-test eval case.

Same two routes as mini-fastapi. `tests/test_stuck.py` pins a contract that no
implementation can satisfy, so the /sdlc fix loop can never go green here.
"""

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def read_root():
    return {"message": "mini-fastapi fixture"}


@app.get("/items/{item_id}")
def read_item(item_id: int):
    return {"item_id": item_id}
