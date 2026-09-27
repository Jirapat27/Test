from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FeeSchedule:
    """Per-trade costs on SET. Defaults are illustrative for an internet
    cash account -- replace them with your broker's actual schedule."""

    commission_rate: float = 0.0015      # broker commission
    min_commission: float = 0.0          # some brokers charge a minimum per order
    trading_fee_rate: float = 0.00005    # SET trading fee
    clearing_fee_rate: float = 0.00001   # TCH clearing fee
    regulatory_fee_rate: float = 0.00001 # SEC fee
    vat_rate: float = 0.07               # VAT applies to all of the above

    def cost(self, notional: float) -> float:
        notional = abs(notional)
        commission = max(notional * self.commission_rate, self.min_commission)
        exchange = notional * (
            self.trading_fee_rate + self.clearing_fee_rate + self.regulatory_fee_rate
        )
        return round((commission + exchange) * (1 + self.vat_rate), 2)
