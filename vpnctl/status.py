"""Status helpers; system inspection is implemented with the API in phase 4."""

def account_counts(registry):
    return registry.count_by_service()
