"""Tiny helper module for the sdlc-recurring-catch eval fixture."""


def parse_limit(raw: str, default: int = 10) -> int:
    """Parse a user-supplied page limit, falling back to `default` on bad input."""
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default
