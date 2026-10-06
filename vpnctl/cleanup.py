"""Expiry orchestration is wired to protocol drivers in phase 3."""

def expired_accounts(registry, now=None):
    return registry.expired(now)
