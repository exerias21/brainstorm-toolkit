from app import parse_limit


def test_parse_limit_ok():
    assert parse_limit("25") == 25


def test_parse_limit_bad_input_falls_back():
    assert parse_limit("abc") == 10
    assert parse_limit("-3") == 10
