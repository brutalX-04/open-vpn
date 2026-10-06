from datetime import datetime, timezone


def utc_now():
    return int(datetime.now(timezone.utc).timestamp())


def expires_after(*, days=None, hours=None, now=None):
    if (days is None) == (hours is None):
        raise ValueError("provide exactly one of days or hours")
    return int(now if now is not None else utc_now()) + (days * 86400 if days is not None else hours * 3600)


def iso_utc(epoch):
    return datetime.fromtimestamp(int(epoch), timezone.utc).isoformat().replace("+00:00", "Z")
