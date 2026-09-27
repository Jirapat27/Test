from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def load_dotenv(path: str | Path = ".env") -> None:
    """Minimal .env loader (KEY=VALUE lines). Real env vars take precedence."""
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default).strip()


@dataclass(frozen=True)
class SettradeCredentials:
    app_id: str
    app_secret: str
    app_code: str
    broker_id: str
    account_no: str
    pin: str = field(repr=False)

    @classmethod
    def from_env(cls) -> "SettradeCredentials":
        creds = cls(
            app_id=_env("SETTRADE_APP_ID"),
            app_secret=_env("SETTRADE_APP_SECRET"),
            app_code=_env("SETTRADE_APP_CODE", "SANDBOX"),
            broker_id=_env("SETTRADE_BROKER_ID", "SANDBOX"),
            account_no=_env("SETTRADE_ACCOUNT_NO"),
            pin=_env("SETTRADE_PIN"),
        )
        missing = [k for k in ("app_id", "app_secret", "account_no") if not getattr(creds, k)]
        if missing:
            raise ValueError(f"missing Settrade settings: {', '.join('SETTRADE_' + m.upper() for m in missing)}")
        return creds

    @property
    def is_sandbox(self) -> bool:
        return self.broker_id.upper() == "SANDBOX"


@dataclass(frozen=True)
class Settings:
    mode: str  # paper | sandbox | live
    confirm_live: bool

    @classmethod
    def from_env(cls) -> "Settings":
        mode = _env("THAITRADER_MODE", "sandbox").lower()
        if mode not in ("paper", "sandbox", "live"):
            raise ValueError(f"THAITRADER_MODE must be paper|sandbox|live, got {mode!r}")
        return cls(mode=mode, confirm_live=_env("THAITRADER_CONFIRM_LIVE").lower() == "yes")
