"""No credentials or production enablement are supplied by this candidate."""
from dataclasses import dataclass
import json
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit

CLIENT_ID = "com.zephyrstudiosllc.Peel"
TEAM_ID = "V729QMY3V6"


def parse_https_origin(value):
    # urllib normalizes scheme case and represents absent/empty query/fragment
    # identically. Native URLComponents does not: require the original spelling
    # and absence of delimiters/user info before using the parsed authority.
    if (not isinstance(value, str) or not value.startswith("https://")
            or "?" in value or "#" in value
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise ValueError("an actual HTTPS origin is required")
    origin = urlsplit(value)
    if (origin.scheme != "https" or not origin.hostname or origin.port not in (None, 443)
            or origin.path not in ("", "/") or origin.username is not None
            or origin.password is not None or origin.hostname.endswith(".invalid")):
        raise ValueError("an actual HTTPS origin is required")
    return origin


@dataclass(frozen=True)
class Settings:
    enabled: bool
    public_origin: str
    public_webroots: tuple[Path, ...]
    private_dir: Path
    apple_key_path: Path
    encryption_key_path: Path
    lookup_key_path: Path
    apple_key_id: str
    apple_team_id: str = TEAM_ID
    client_id: str = CLIENT_ID

    def validate(self):
        if self.enabled is not True:
            raise ValueError("disabled")
        parse_https_origin(self.public_origin)
        if not self.public_webroots or not self.private_dir.is_absolute():
            raise ValueError("private storage and all actual public webroots are required")
        if self.client_id != CLIENT_ID or self.apple_team_id != TEAM_ID:
            raise ValueError("unexpected app/team; this candidate only serves the existing native app")
        if (not isinstance(self.apple_key_id, str) or len(self.apple_key_id) != 10
                or not self.apple_key_id.isascii() or not self.apple_key_id.isalnum()):
            raise ValueError("actual Apple Sign in key ID required")
        root = self.private_dir.resolve(strict=True)
        if self.private_dir.is_symlink() or not root.is_dir() or stat.S_IMODE(root.stat().st_mode) != 0o700:
            raise ValueError("private directory must be an existing 0700 directory")
        if root.stat().st_uid != os.getuid():
            raise ValueError("private directory must belong to the service user")
        for public in self.public_webroots:
            if not public.is_absolute() or root.is_relative_to(public.resolve()):
                raise ValueError("private data must be outside every public webroot")
        for path in (self.apple_key_path, self.encryption_key_path, self.lookup_key_path):
            resolved = path.resolve(strict=True)
            if path.is_symlink() or not resolved.is_relative_to(root):
                raise ValueError("key files must be regular private storage files")
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                raise ValueError("key files must belong to service user with 0600 permissions")

    @classmethod
    def from_file(cls, path):
        # The operator CLI and WSGI loader share exact parsing. Never print parser errors:
        # malformed JSON can contain credentials or private local path names.
        p = Path(path)
        info = p.lstat()
        if (not p.is_absolute() or not stat.S_ISREG(info.st_mode)
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid()
                or info.st_size > 16384):
            raise ValueError("configuration must be an owned regular absolute 0600 file")
        def unique(pairs):
            values = {}
            for key, value in pairs:
                if key in values:
                    raise ValueError("duplicate configuration key")
                values[key] = value
            return values
        with p.open("rb") as stream:
            encoded = stream.read(16385)
        if len(encoded) > 16384:
            raise ValueError("configuration exceeds size limit")
        values = json.loads(encoded.decode("utf-8"), object_pairs_hook=unique)
        fields = {"enabled", "public_origin", "public_webroots", "private_dir", "apple_key_path",
                  "encryption_key_path", "lookup_key_path", "apple_key_id"}
        if (not isinstance(values, dict) or set(values) - fields
                or not (fields - {"enabled"}).issubset(values)
                or any(not isinstance(values[x], str) for x in fields - {"enabled", "public_webroots"})
                or not isinstance(values["public_webroots"], list)
                or any(not isinstance(x, str) for x in values["public_webroots"])):
            raise ValueError("invalid configuration fields")
        result = cls(
            enabled=values.get("enabled", False),
            public_origin=values["public_origin"],
            public_webroots=tuple(Path(x) for x in values["public_webroots"]),
            private_dir=Path(values["private_dir"]),
            apple_key_path=Path(values["apple_key_path"]),
            encryption_key_path=Path(values["encryption_key_path"]),
            lookup_key_path=Path(values["lookup_key_path"]),
            apple_key_id=values["apple_key_id"],
        )
        if any(p.resolve().is_relative_to(root.resolve()) for root in result.public_webroots):
            raise ValueError("configuration must be outside every public webroot")
        return result

    @classmethod
    def from_environment(cls):
        path = os.environ.get("PEEL_ACCOUNT_CONFIG")
        if not path:
            raise ValueError("PEEL_ACCOUNT_CONFIG is not configured")
        return cls.from_file(path)
