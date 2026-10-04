# Makes `from app import app` resolve from tests/test_app.py without requiring
# PYTHONPATH=. on the invoking shell -- `pytest -q` (this fixture's
# `.claude/project.json` test.unit) must be runnable standalone, since the
# skill-eval harness invokes it exactly as configured, with no extra env.
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
