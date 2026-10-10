"""Turn a title into a URL slug."""

import re


def slugify(title):
    """Lower-case `title` and collapse runs of non-alphanumerics to one hyphen."""
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
