"""Legacy FastAPI app fixture -- a runtime-visible route docstring that
docstring-sync must leave untouched by default."""

from fastapi import FastAPI

app = FastAPI()


@app.get("/legacy-status")
def legacy_status():
    """Report legacy service status."""
    return {"status": "ok"}
