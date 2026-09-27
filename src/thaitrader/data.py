from __future__ import annotations

import csv
from datetime import datetime
from pathlib import Path

from .models import Candle


def load_csv(path: str | Path) -> list[Candle]:
    """Load OHLCV from CSV with columns date,open,high,low,close[,volume]
    (header names are case-insensitive; 'Date'/'Datetime'/'time' all work)."""
    out: list[Candle] = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            row = {k.strip().lower(): v for k, v in raw.items() if k}
            ts = row.get("date") or row.get("datetime") or row.get("time")
            if not ts or not row.get("close"):
                continue
            out.append(
                Candle(
                    datetime.fromisoformat(ts.strip()),
                    float(row["open"]), float(row["high"]), float(row["low"]), float(row["close"]),
                    float(row.get("volume") or 0),
                )
            )
    out.sort(key=lambda c: c.ts)
    return out


def load_yfinance(ticker: str, period: str = "5y", interval: str = "1d") -> list[Candle]:
    """Unofficial Yahoo data -- fine for research, not for live decisions.
    SET tickers use the .BK suffix, e.g. 'PTT.BK'."""
    try:
        import yfinance as yf
    except ImportError as e:  # pragma: no cover
        raise RuntimeError('yfinance not installed: pip install "thaitrader[yf]"') from e
    df = yf.Ticker(ticker).history(period=period, interval=interval, auto_adjust=False)
    return [
        Candle(ts.to_pydatetime(), float(r.Open), float(r.High), float(r.Low), float(r.Close), float(r.Volume))
        for ts, r in df.iterrows()
    ]
