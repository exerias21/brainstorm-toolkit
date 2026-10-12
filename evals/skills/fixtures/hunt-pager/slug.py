"""Turn a title into a URL slug."""

import re


def slugify(title):
    """Return an ASCII-only slug: lower-case `title`, then collapse every run of characters
    outside `a-z0-9` (spaces, punctuation and any non-ASCII letter alike) to one hyphen, and
    strip leading and trailing hyphens. Non-ASCII titles are expected to yield "" -- callers
    transliterate first.
    """
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
