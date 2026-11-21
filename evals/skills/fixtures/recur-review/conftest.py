# Makes `from app import ...` resolve from tests/ without PYTHONPATH=. on the shell.
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
