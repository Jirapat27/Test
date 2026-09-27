from __future__ import annotations

import argparse
import json
import logging
import sys

from .config import Settings, SettradeCredentials, load_dotenv
from .fees import FeeSchedule


def _strategy(args: argparse.Namespace):
    from .strategy import SmaCross

    return SmaCross(fast=args.fast, slow=args.slow, lots=args.lots)


def cmd_backtest(args: argparse.Namespace) -> int:
    from .backtest import run_backtest
    from .data import load_csv, load_yfinance

    candles = load_csv(args.csv) if args.csv else load_yfinance(args.yf, period=args.period)
    if not candles:
        print("no data loaded", file=sys.stderr)
        return 1
    symbol = args.symbol or (args.yf or "CSV").removesuffix(".BK")
    res = run_backtest(
        candles, _strategy(args), symbol=symbol, initial_cash=args.cash,
        fees=FeeSchedule(), slippage_ticks=args.slippage_ticks,
    )
    print(f"{symbol}: {len(candles)} bars {candles[0].ts:%Y-%m-%d} -> {candles[-1].ts:%Y-%m-%d}")
    print(res.summary())
    return 0


def _settrade():
    from .brokers.settrade import SettradeBroker

    return SettradeBroker(SettradeCredentials.from_env())


def cmd_inspect(args: argparse.Namespace) -> int:
    snap = _settrade().raw_snapshot(args.symbol)
    print(json.dumps(snap, indent=2, ensure_ascii=False, default=str))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    from .brokers import PaperBroker
    from .engine import TradingEngine
    from .notify import notifier_from_env
    from .risk import RiskLimits, RiskManager

    settings = Settings.from_env()
    mode = args.mode or settings.mode
    creds = SettradeCredentials.from_env()

    if mode == "live":
        if creds.is_sandbox:
            print("live mode but SETTRADE_BROKER_ID is SANDBOX", file=sys.stderr)
            return 2
        if not settings.confirm_live:
            print("refusing to trade real money: set THAITRADER_CONFIRM_LIVE=yes", file=sys.stderr)
            return 2
    elif mode == "sandbox" and not creds.is_sandbox:
        print("sandbox mode requires SETTRADE_BROKER_ID=SANDBOX", file=sys.stderr)
        return 2

    from .brokers.settrade import SettradeBroker

    real = SettradeBroker(creds)
    broker = PaperBroker(cash=args.cash, data_source=real) if mode == "paper" else real
    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    risk = RiskManager(RiskLimits.from_env(allowed_symbols=frozenset(symbols)))
    engine = TradingEngine(
        broker, _strategy(args), risk, symbols, interval=args.interval,
        notifier=notifier_from_env(), aggressiveness_ticks=args.aggressiveness_ticks,
    )
    logging.getLogger(__name__).warning("starting in %s mode", mode.upper())
    try:
        engine.run_forever(poll_seconds=args.poll)
    except KeyboardInterrupt:
        print("stopped")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="thaitrader", description="Thai stock auto-trading toolkit")
    sub = p.add_subparsers(dest="cmd", required=True)

    def strategy_args(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--fast", type=int, default=10)
        sp.add_argument("--slow", type=int, default=30)
        sp.add_argument("--lots", type=int, default=1, help="board lots (x100 shares) when long")

    b = sub.add_parser("backtest", help="backtest the SMA strategy on historical data")
    src = b.add_mutually_exclusive_group(required=True)
    src.add_argument("--csv", help="CSV with date,open,high,low,close,volume")
    src.add_argument("--yf", help="Yahoo ticker, e.g. PTT.BK (needs thaitrader[yf])")
    b.add_argument("--period", default="5y")
    b.add_argument("--symbol")
    b.add_argument("--cash", type=float, default=100_000)
    b.add_argument("--slippage-ticks", type=int, default=1)
    strategy_args(b)
    b.set_defaults(func=cmd_backtest)

    i = sub.add_parser("inspect", help="print raw Settrade API responses (check field names)")
    i.add_argument("--symbol", default="PTT")
    i.set_defaults(func=cmd_inspect)

    r = sub.add_parser("run", help="run the trading engine")
    r.add_argument("--mode", choices=["paper", "sandbox", "live"], help="overrides THAITRADER_MODE")
    r.add_argument("--symbols", required=True, help="comma separated, e.g. PTT,AOT")
    r.add_argument("--interval", default="1d", help="candle interval, e.g. 1m, 5m, 15m, 60m, 1d")
    r.add_argument("--poll", type=float, default=60, help="seconds between cycles")
    r.add_argument("--cash", type=float, default=100_000, help="starting cash for paper mode")
    r.add_argument("--aggressiveness-ticks", type=int, default=0,
                   help="price limit orders this many ticks through the last price")
    strategy_args(r)
    r.set_defaults(func=cmd_run)
    return p


def main(argv: list[str] | None = None) -> int:
    load_dotenv()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
