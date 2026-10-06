import hmac


def valid_api_key(provided, expected):
    return bool(provided and expected) and hmac.compare_digest(provided.encode(), expected.encode())
