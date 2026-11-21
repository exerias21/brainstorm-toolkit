# Makes `from app import app` resolve without PYTHONPATH=. (see mini-fastapi).
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
