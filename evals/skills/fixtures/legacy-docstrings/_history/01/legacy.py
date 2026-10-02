"""Legacy module fixture for the docstring-sync outcome eval."""

import json


def call_payments_api():
    # plans/legacy-retry.md
    return _call_once()


def _call_once():
    return {"ok": True}


def process_batch():
    # see TASKS.md row 12
    return True


def get_cached_value():
    # plans/old-cache-rewrite.md: do not reintroduce the module-level cache.
    return _compute_value()


def _compute_value():
    return 99


def compute_total(a, b):
    """Compute the total.

    Args:
        a: first addend.
        c: second addend.
    """
    return a + b


def compute_average(values, weight):
    """Compute a weighted average.

    Parameters
    ----------
    values : list
        the values to average.
    factor : float
        the weighting factor.
    """
    return sum(values) / len(values)


def normalize_input(value):
    """_summary_"""
    return value.strip()


def parse_config(path):
    """Parse the config file and return its contents as a dict.

    Args:
        path: path to the config file.
    """
    return json.loads(path.read_text(encoding="utf-8"))


def apply_discount(price, rate):
    """Apply a discount rate to a price.

    :param price: the original price.
    :param old_name: the discount rate to apply.
    :returns: the discounted price.
    """
    return price - (price * rate)


def follow_adr():
    # see docs/adr/0001-example.md for the accepted rationale
    return True


def verify_handshake():
    # step 3 of the TLS handshake verifies the certificate chain
    return True


def add_numbers(a, b):
    """Add two numbers.

    Args:
        a: the first addend.
        b: the second addend.

    Returns:
        The sum of a and b.
    """
    return a + b


def not_yet_implemented(x):
    """Not implemented yet.

    Returns:
        The eventual result.
    """
    raise NotImplementedError


def double(x):
    """Double a number.

    >>> double(3)
    6
    """
    return x * 2
