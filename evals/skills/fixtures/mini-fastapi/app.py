"""Minimal FastAPI app -- the fixture consumed by evals/skills/*.

Two routes on purpose: enough surface for a skill to add a third (GET /health)
without the fixture itself being interesting. Intentionally has no /health
route yet -- that gap is exactly what task-health-endpoint and sdlc-two-step
ask an agent to fill in.
"""

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def read_root():
    return {"message": "mini-fastapi fixture"}


@app.get("/items/{item_id}")
def read_item(item_id: int):
    return {"item_id": item_id}
