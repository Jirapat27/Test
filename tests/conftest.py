import math
from datetime import datetime, timedelta

import pytest

from thaitrader.models import Candle


@pytest.fixture
def wave_candles():
    """Deterministic sine-wave prices so SMA crossovers happen."""
    start = datetime(2024, 1, 1)
    out = []
    for i in range(300):
        px = round(30 + 5 * math.sin(i / 15), 2)
        out.append(Candle(start + timedelta(days=i), px, px + 0.5, px - 0.5, px, 1e6))
    return out
