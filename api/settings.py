import os


def load_settings(path="/etc/vpn/api.env"):
    values = {}
    try:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    values[key.strip()] = value.strip().strip("\"'")
    except OSError:
        pass
    return {
        "api_key": os.environ.get("VPN_API_KEY", values.get("API_KEY", "")),
        "domain": os.environ.get("VPN_DOMAIN", values.get("DOMAIN", "localhost")),
        "api_docs": os.environ.get("API_DOCS", values.get("API_DOCS", "0")) == "1",
        "registry_db": os.environ.get("VPN_REGISTRY_DB", values.get("REGISTRY_DB", "/var/lib/vpn/accounts.db")),
        "xray_front_proxy": os.environ.get("XRAY_FRONT_PROXY", values.get("XRAY_FRONT_PROXY", "0")) == "1",
    }
