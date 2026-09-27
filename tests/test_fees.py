from thaitrader.fees import FeeSchedule


def test_fee_includes_vat():
    f = FeeSchedule(commission_rate=0.001, trading_fee_rate=0, clearing_fee_rate=0,
                    regulatory_fee_rate=0, vat_rate=0.07)
    assert f.cost(100_000) == 107.0


def test_min_commission():
    f = FeeSchedule(commission_rate=0.001, min_commission=50, trading_fee_rate=0,
                    clearing_fee_rate=0, regulatory_fee_rate=0, vat_rate=0)
    assert f.cost(1_000) == 50
    assert f.cost(-1_000) == 50
