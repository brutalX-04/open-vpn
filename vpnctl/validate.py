import re

USERNAME_RE = re.compile(r"^[a-z][a-z0-9_]{2,19}$")
SERVICES = {"ssh", "vmess", "vless", "trojan", "ovpn-tcp", "ovpn-udp"}
RESERVED_SSH_USERS = {"root", "nobody", "admin", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy", "www-data", "backup", "list", "irc", "_apt"}


class ValidationError(ValueError):
    pass


def validate_username(username, service=None, existing_users=None):
    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        raise ValidationError("username must match ^[a-z][a-z0-9_]{2,19}$")
    if service is not None and service not in SERVICES:
        raise ValidationError("unsupported service")
    if service == "ssh":
        reserved = RESERVED_SSH_USERS | set(existing_users or ())
        if username in reserved:
            raise ValidationError("SSH username is reserved or already exists")
    return username


def validate_duration(days=None, hours=None):
    if (days is None) == (hours is None):
        raise ValidationError("provide exactly one of days or hours")
    value = days if days is not None else hours
    low, high = (1, 30) if days is not None else (1, 720)
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValidationError(f"duration must be between {low} and {high}")
    return value


def validate_password(password, *, min_length=8, max_length=128):
    if not isinstance(password, str) or not min_length <= len(password) <= max_length:
        raise ValidationError(f"password length must be between {min_length} and {max_length}")
    if "\x00" in password or "\n" in password or "\r" in password:
        raise ValidationError("password contains unsupported control characters")
    return password
