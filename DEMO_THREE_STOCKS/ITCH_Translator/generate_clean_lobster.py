#!/usr/bin/env python3
import argparse
import bisect
import csv
import math
import random
from math import gcd
from collections import defaultdict

DUMMY_ASK = 9999999999
DUMMY_BID = -9999999999
DEFAULT_OUTPUT_TICK = 100
DEFAULT_START_TIME = 34200.0
DEFAULT_DURATION_SECONDS = 3600.0

class FastBook:
    def __init__(self):
        self.orders = {}  # oid -> {side, price, size, ts}
        self.level_size_bid = defaultdict(int)
        self.level_size_ask = defaultdict(int)
        self.bid_prices = []   # ascending unique prices
        self.ask_prices = []   # ascending unique prices
        self.side_oids = {1: set(), -1: set()}  # active order ids by side
        self.next_order_id = 1

    def _add_price(self, side, price):
        arr = self.bid_prices if side == 1 else self.ask_prices
        i = bisect.bisect_left(arr, price)
        if i == len(arr) or arr[i] != price:
            arr.insert(i, price)

    def _remove_price_if_empty(self, side, price):
        if side == 1:
            if self.level_size_bid[price] != 0:
                return
            arr = self.bid_prices
        else:
            if self.level_size_ask[price] != 0:
                return
            arr = self.ask_prices
        i = bisect.bisect_left(arr, price)
        if i < len(arr) and arr[i] == price:
            arr.pop(i)

    def best_bid(self):
        if not self.bid_prices:
            return None, 0
        p = self.bid_prices[-1]
        return p, self.level_size_bid[p]

    def best_ask(self):
        if not self.ask_prices:
            return None, 0
        p = self.ask_prices[0]
        return p, self.level_size_ask[p]

    def active_orders(self, side=None):
        if side is None:
            return [(oid, self.orders[oid].copy()) for oid in self.orders]
        return [(oid, self.orders[oid].copy()) for oid in self.side_oids[side]]

    def add_order(self, ts, side, price, size):
        oid = self.next_order_id
        self.next_order_id += 1
        self.orders[oid] = {"side": side, "price": price, "size": size, "ts": ts}
        self.side_oids[side].add(oid)
        if side == 1:
            if self.level_size_bid[price] == 0:
                self._add_price(1, price)
            self.level_size_bid[price] += size
        else:
            if self.level_size_ask[price] == 0:
                self._add_price(-1, price)
            self.level_size_ask[price] += size
        return oid

    def reduce_order(self, oid, qty):
        if oid not in self.orders:
            return False
        o = self.orders[oid]
        qty = min(qty, o["size"])
        o["size"] -= qty
        if o["side"] == 1:
            self.level_size_bid[o["price"]] -= qty
            self._remove_price_if_empty(1, o["price"])
        else:
            self.level_size_ask[o["price"]] -= qty
            self._remove_price_if_empty(-1, o["price"])
        if o["size"] <= 0:
            self.side_oids[o["side"]].discard(oid)
            del self.orders[oid]
        return True

    def delete_order(self, oid):
        if oid not in self.orders:
            return False
        o = self.orders[oid]
        qty = o["size"]
        if o["side"] == 1:
            self.level_size_bid[o["price"]] -= qty
            self._remove_price_if_empty(1, o["price"])
        else:
            self.level_size_ask[o["price"]] -= qty
            self._remove_price_if_empty(-1, o["price"])
        self.side_oids[o["side"]].discard(oid)
        del self.orders[oid]
        return True

    def top_n_levels(self, n=10):
        row = []
        for i in range(n):
            if i < len(self.ask_prices):
                ap = self.ask_prices[i]
                av = self.level_size_ask[ap]
            else:
                ap, av = DUMMY_ASK, 0
            if i < len(self.bid_prices):
                bp = self.bid_prices[-1 - i]
                bv = self.level_size_bid[bp]
            else:
                bp, bv = DUMMY_BID, 0
            row.extend([ap, av, bp, bv])
        return row

def percentile(sorted_vals, q):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    idx = q * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return sorted_vals[lo]
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac

def snap_price_down(price, tick):
    return (int(price) // tick) * tick

def snap_price_up(price, tick):
    price = int(price)
    return ((price + tick - 1) // tick) * tick

def snap_price_nearest(price, tick):
    price = int(price)
    lower = snap_price_down(price, tick)
    upper = snap_price_up(price, tick)
    if (price - lower) <= (upper - price):
        return lower
    return upper

def infer_tick(diffs):
    tick = 0
    for diff in diffs:
        if diff <= 0:
            continue
        tick = diff if tick == 0 else gcd(tick, diff)
        if tick == 1:
            break
    return tick if tick > 0 else DEFAULT_OUTPUT_TICK

def clamp(value, lo, hi):
    return max(lo, min(hi, value))

def read_message_stats(path):
    times, sizes, prices = [], [], []
    type_counts = defaultdict(int)
    prev_t = None
    row_count = 0
    first_t = None
    last_t = None
    with open(path, newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if not row:
                continue
            try:
                t = float(row[0]); typ = int(row[1]); size = int(row[3]); price = int(row[4])
            except Exception:
                continue
            row_count += 1
            if first_t is None:
                first_t = t
            last_t = t
            if prev_t is not None and t >= prev_t:
                times.append(max(t - prev_t, 1e-9))
            prev_t = t
            if typ in (1, 2, 3, 4):
                type_counts[typ] += 1
            if size > 0:
                sizes.append(size)
            if price > 0:
                prices.append(price)

    if not sizes:
        raise ValueError(f"Could not parse useful rows from message file: {path}")

    prices.sort()
    sizes.sort()
    times.sort()

    diffs = []
    for i in range(1, len(prices)):
        d = prices[i] - prices[i - 1]
        if d > 0:
            diffs.append(d)

    tick = infer_tick(diffs)

    sample_dt_expected = (
        0.25 * (0.5 * (percentile(times, 0.25) if times else 0.01))
        + 0.50 * (0.5 * ((percentile(times, 0.25) if times else 0.01) + (percentile(times, 0.75) if times else 0.12)))
        + 0.25 * (2.0 * (percentile(times, 0.75) if times else 0.12))
    )

    return {
        "dt_q25": percentile(times, 0.25) if times else 0.01,
        "dt_q50": percentile(times, 0.50) if times else 0.05,
        "dt_q75": percentile(times, 0.75) if times else 0.12,
        "size_q25": max(1, int(percentile(sizes, 0.25))),
        "size_q50": max(1, int(percentile(sizes, 0.50))),
        "size_q75": max(1, int(percentile(sizes, 0.75))),
        "price_q50": int(percentile(prices, 0.50)),
        "tick": int(tick),
        "type_counts": dict(type_counts),
        "row_count": int(row_count),
        "first_t": first_t,
        "last_t": last_t,
        "duration_seconds": max(0.0, (last_t - first_t)) if first_t is not None and last_t is not None else 0.0,
        "sample_dt_expected": float(max(1e-9, sample_dt_expected)),
    }

def read_orderbook_stats(path):
    mids = []
    spreads = []
    best_bids = []
    best_asks = []
    change_count = 0
    source_levels = 0
    prev_bid = None
    prev_ask = None
    with open(path, newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 4:
                continue
            if source_levels == 0:
                source_levels = max(1, len(row) // 4)
            try:
                ask = int(float(row[0])); bid = int(float(row[2]))
            except Exception:
                continue
            if ask >= DUMMY_ASK or bid <= DUMMY_BID:
                continue
            if bid < ask:
                best_bids.append(bid)
                best_asks.append(ask)
                mids.append((ask + bid) // 2)
                spreads.append(ask - bid)
                if prev_bid is not None and (bid != prev_bid or ask != prev_ask):
                    change_count += 1
                prev_bid = bid
                prev_ask = ask
    if not mids:
        return None
    mids.sort()
    spreads.sort()
    best_bids.sort()
    best_asks.sort()
    row_count = len(mids)
    return {
        "mid_q50": int(percentile(mids, 0.50)),
        "spread_q50": int(percentile(spreads, 0.50)),
        "spread_q75": int(percentile(spreads, 0.75)),
        "spread_q90": int(percentile(spreads, 0.90)),
        "mid_min": int(mids[0]),
        "mid_max": int(mids[-1]),
        "best_bid_min": int(best_bids[0]),
        "best_bid_max": int(best_bids[-1]),
        "best_ask_min": int(best_asks[0]),
        "best_ask_max": int(best_asks[-1]),
        "change_count": int(change_count),
        "change_rate": float(change_count) / float(max(1, row_count - 1)),
        "row_count": row_count,
        "source_levels": int(source_levels),
    }

def choose_weighted(rng, weighted_items):
    total = sum(w for _, w in weighted_items)
    x = rng.uniform(0, total)
    acc = 0.0
    for item, w in weighted_items:
        acc += w
        if x <= acc:
            return item
    return weighted_items[-1][0]

def weighted_choice(rng, weighted_items):
    total = sum(weight for _, weight in weighted_items)
    x = rng.uniform(0, total)
    acc = 0.0
    for item, weight in weighted_items:
        acc += weight
        if x <= acc:
            return item
    return weighted_items[-1][0]

def top_level_oids(book, side, levels=2):
    prices = book.bid_prices[::-1] if side == 1 else book.ask_prices
    wanted = set(prices[:levels])
    if not wanted:
        return []
    return [oid for oid in book.side_oids[side] if book.orders[oid]["price"] in wanted]

def random_active_order(book, side, rng, touch_bias=0.80, top_levels=2):
    touch_oids = top_level_oids(book, side, levels=top_levels)
    if touch_oids and rng.random() < touch_bias:
        oid = rng.choice(tuple(touch_oids))
    else:
        oid = rng.choice(tuple(book.side_oids[side]))
    return oid, book.orders[oid].copy()

def generate_clean_pair(
    rows,
    levels,
    seed,
    message_in=None,
    orderbook_in=None,
    out_prefix="synthetic",
    output_tick=DEFAULT_OUTPUT_TICK,
    start_time=DEFAULT_START_TIME,
    market_mode="volatile",
    duration_seconds=None,
):
    rng = random.Random(seed)

    stats = {
        "dt_q25": 0.010,
        "dt_q50": 0.050,
        "dt_q75": 0.120,
        "size_q25": 50,
        "size_q50": 100,
        "size_q75": 250,
        "price_q50": 2235000,
        "tick": 100,
        "type_counts": {1: 45, 2: 20, 3: 15, 4: 20},
    }
    ob_stats = None

    if message_in:
        stats = read_message_stats(message_in)
    if orderbook_in:
        ob_stats = read_orderbook_stats(orderbook_in)

    if duration_seconds is None:
        duration_seconds = stats.get("duration_seconds", 0.0)
    duration_seconds = float(duration_seconds)

    if rows is None or rows <= 0:
        expected_dt = max(1e-9, float(stats.get("sample_dt_expected", stats.get("dt_q50", 0.05))))
        rows = max(levels * 2, int(round(duration_seconds / expected_dt)))
    rows = int(rows)

    tick = max(1, int(output_tick))
    raw_mid = ob_stats["mid_q50"] if ob_stats else int(stats["price_q50"])
    raw_spread = ob_stats["spread_q50"] if ob_stats and ob_stats["spread_q50"] > 0 else 2 * tick
    mid = snap_price_nearest(raw_mid, tick)
    spread = snap_price_up(raw_spread, tick)
    if spread < 2 * tick:
        spread = 2 * tick

    volatile_mode = (market_mode != "calm")
    change_rate = ob_stats["change_rate"] if ob_stats else 0.10
    if volatile_mode:
        drift_step_prob = min(0.20, max(0.03, change_rate * 0.25))
        jump_prob = min(0.03, max(0.005, change_rate * 0.03))
        targeted_event_prob = min(0.75, max(0.20, change_rate * 0.90))
    else:
        drift_step_prob = 0.0
        jump_prob = 0.0
        targeted_event_prob = 0.0
    reference_mid = mid
    reference_mid_lo = ob_stats["mid_min"] if ob_stats else (mid - 32 * tick)
    reference_mid_hi = ob_stats["mid_max"] if ob_stats else (mid + 32 * tick)

    weighted_types = [(typ, max(1, stats["type_counts"].get(typ, 1))) for typ in (1, 2, 3, 4)]

    def sample_dt():
        u = rng.random()
        if u < 0.25:
            return max(1e-9, rng.uniform(1e-9, stats["dt_q25"]))
        elif u < 0.75:
            return max(1e-9, rng.uniform(stats["dt_q25"], stats["dt_q75"]))
        else:
            return max(1e-9, rng.uniform(stats["dt_q75"], max(stats["dt_q75"] * 3, stats["dt_q75"] + 1e-6)))

    def sample_size():
        u = rng.random()
        if u < 0.25:
            lo, hi = 1, max(1, stats["size_q25"])
        elif u < 0.75:
            lo, hi = stats["size_q25"], max(stats["size_q25"], stats["size_q75"])
        else:
            lo, hi = stats["size_q75"], max(stats["size_q75"], stats["size_q75"] * 3)
        return rng.randint(int(lo), int(hi))

    def sample_touch_size():
        lo = max(1, stats["size_q25"] // 4)
        hi = max(lo, stats["size_q50"])
        return rng.randint(int(lo), int(hi))

    def choose_safe_price(side, bb, ba, aggressive=False):
        if side == 1:
            safe_max = ba - tick
            if volatile_mode:
                if aggressive and safe_max >= bb + tick:
                    weighted_candidates = [
                        (min(bb + tick, safe_max), 8),
                        (bb, 2),
                        (bb - tick, 2),
                        (bb - 2 * tick, 1),
                        (bb - 3 * tick, 1),
                    ]
                else:
                    weighted_candidates = [
                        (bb - tick, 5),
                        (bb - 2 * tick, 4),
                        (bb, 2),
                        (bb - 3 * tick, 2),
                        (bb - 4 * tick, 1),
                    ]
            else:
                weighted_candidates = [
                    (min(bb + tick, safe_max), 5),
                    (bb, 3),
                    (bb - tick, 2),
                    (bb - 2 * tick, 1),
                    (bb - 3 * tick, 1),
                ]
            candidates = []
            seen = set()
            for price, weight in weighted_candidates:
                if price <= safe_max and price not in seen:
                    candidates.append((price, weight))
                    seen.add(price)
            return weighted_choice(rng, candidates) if candidates else safe_max
        else:
            safe_min = bb + tick
            if volatile_mode:
                if aggressive and safe_min <= ba - tick:
                    weighted_candidates = [
                        (max(ba - tick, safe_min), 8),
                        (ba, 2),
                        (ba + tick, 2),
                        (ba + 2 * tick, 1),
                        (ba + 3 * tick, 1),
                    ]
                else:
                    weighted_candidates = [
                        (ba + tick, 5),
                        (ba + 2 * tick, 4),
                        (ba, 2),
                        (ba + 3 * tick, 2),
                        (ba + 4 * tick, 1),
                    ]
            else:
                weighted_candidates = [
                    (max(ba - tick, safe_min), 5),
                    (ba, 3),
                    (ba + tick, 2),
                    (ba + 2 * tick, 1),
                    (ba + 3 * tick, 1),
                ]
            candidates = []
            seen = set()
            for price, weight in weighted_candidates:
                if price >= safe_min and price not in seen:
                    candidates.append((price, weight))
                    seen.add(price)
            return weighted_choice(rng, candidates) if candidates else safe_min

    def choose_directional_plan(bb, ba):
        nonlocal reference_mid
        current_mid = snap_price_nearest((bb + ba) // 2, tick)

        if rng.random() < jump_prob:
            reference_mid += rng.choice([-3, -2, 2, 3]) * tick
        elif rng.random() < drift_step_prob:
            reference_mid += rng.choice([-1, 1]) * tick
        reference_mid = snap_price_nearest(clamp(reference_mid, reference_mid_lo, reference_mid_hi), tick)

        if current_mid + tick <= reference_mid:
            pressure = 1
        elif current_mid - tick >= reference_mid:
            pressure = -1
        else:
            pressure = 0

        if not volatile_mode or rng.random() >= targeted_event_prob:
            return None

        if pressure > 0:
            return weighted_choice(rng, [
                (("add", 1, True), 5),
                (("reduce", -1, True), 7),
                (("delete", -1, True), 5),
                (("execute", -1, True), 5),
            ])
        if pressure < 0:
            return weighted_choice(rng, [
                (("add", -1, True), 5),
                (("reduce", 1, True), 7),
                (("delete", 1, True), 5),
                (("execute", 1, True), 5),
            ])
        if (ba - bb) <= tick:
            return weighted_choice(rng, [
                (("reduce", 1, True), 3),
                (("reduce", -1, True), 3),
                (("delete", 1, True), 2),
                (("delete", -1, True), 2),
            ])
        return None

    def pick_side_with_orders():
        if book.side_oids[1] and book.side_oids[-1]:
            return 1 if rng.random() < 0.5 else -1
        if book.side_oids[1]:
            return 1
        return -1

    book = FastBook()
    msg_rows = []
    ob_rows = []

    def append_message(ts, typ, oid, size, price, direction):
        msg_rows.append([f"{ts:.9f}", typ, oid, size, price, direction])
        ob_rows.append(book.top_n_levels(levels))

    # Seed with visible levels so replay from row 1 reconstructs correctly.
    t = float(start_time)
    target_end_time = t + duration_seconds if duration_seconds > 0.0 else None
    initial_levels = max(5, min(10, levels))
    half_spread_ticks = max(1, spread // (2 * tick))
    for i in range(initial_levels):
        bid_price = mid - (half_spread_ticks + i) * tick
        ask_price = mid + (half_spread_ticks + i) * tick
        seed_size_b = sample_touch_size() if volatile_mode and i < 2 else sample_size()
        seed_size_a = sample_touch_size() if volatile_mode and i < 2 else sample_size()
        oid_b = book.add_order(t, 1, bid_price, seed_size_b)
        append_message(t, 1, oid_b, book.orders[oid_b]["size"], bid_price, 1)
        t += sample_dt()
        oid_a = book.add_order(t, -1, ask_price, seed_size_a)
        append_message(t, 1, oid_a, book.orders[oid_a]["size"], ask_price, -1)
        t += sample_dt()

    while len(msg_rows) < rows:
        bb, _ = book.best_bid()
        ba, _ = book.best_ask()

        # Restore either side if needed.
        if bb is None:
            restore_price = (ba - tick) if ba is not None else (mid - tick)
            oid = book.add_order(t, 1, restore_price, sample_size())
            append_message(t, 1, oid, book.orders[oid]["size"], restore_price, 1)
            t += sample_dt()
            if len(msg_rows) >= rows:
                break
            bb, _ = book.best_bid()
            ba, _ = book.best_ask()

        if ba is None:
            restore_price = (bb + tick) if bb is not None else (mid + tick)
            oid = book.add_order(t, -1, restore_price, sample_size())
            append_message(t, 1, oid, book.orders[oid]["size"], restore_price, -1)
            t += sample_dt()
            if len(msg_rows) >= rows:
                break
            bb, _ = book.best_bid()
            ba, _ = book.best_ask()

        bid_count = len(book.side_oids[1])
        ask_count = len(book.side_oids[-1])
        plan = choose_directional_plan(bb, ba)
        typ = choose_weighted(rng, weighted_types) if plan is None else None

        if plan is not None and plan[0] == "add":
            _, side, aggressive = plan
            price = choose_safe_price(side, bb, ba, aggressive=aggressive)
            size = sample_touch_size() if aggressive else sample_size()
            oid = book.add_order(t, side, price, size)
            append_message(t, 1, oid, size, price, side)

        elif plan is not None and plan[0] in ("reduce", "delete", "execute"):
            _, side, aggressive = plan
            side_count = bid_count if side == 1 else ask_count
            if side_count == 0:
                price = choose_safe_price(side, bb, ba, aggressive=True)
                size = sample_touch_size()
                oid = book.add_order(t, side, price, size)
                append_message(t, 1, oid, size, price, side)
            else:
                oid, o = random_active_order(book, side, rng, touch_bias=0.96 if aggressive else 0.80, top_levels=1 if aggressive else 2)
                if plan[0] == "reduce":
                    qty = max(1, min(o["size"], sample_touch_size() if aggressive else sample_size()))
                    book.reduce_order(oid, qty)
                    append_message(t, 2, oid, qty, o["price"], side)
                elif plan[0] == "delete":
                    qty = o["size"]
                    book.delete_order(oid)
                    append_message(t, 3, oid, qty, o["price"], side)
                else:
                    qty = max(1, min(o["size"], sample_touch_size() if aggressive else sample_size()))
                    book.reduce_order(oid, qty)
                    append_message(t, 4, oid, qty, o["price"], side)

        elif typ == 1:
            side = rng.choice([1, -1])
            price = choose_safe_price(side, bb, ba, aggressive=False)
            size = sample_size()
            if volatile_mode and price in (bb, ba):
                size = sample_touch_size()
            oid = book.add_order(t, side, price, size)
            append_message(t, 1, oid, size, price, side)

        elif typ == 2:
            side = pick_side_with_orders()
            oid, o = random_active_order(book, side, rng, touch_bias=0.92 if volatile_mode else 0.80, top_levels=1 if volatile_mode else 2)
            qty = 1 if o["size"] == 1 else rng.randint(1, o["size"] - 1)
            book.reduce_order(oid, qty)
            append_message(t, 2, oid, qty, o["price"], side)

        elif typ == 3:
            side_choices = []
            if bid_count > 1:
                side_choices.append(1)
            if ask_count > 1:
                side_choices.append(-1)

            if not side_choices:
                side = rng.choice([1, -1])
                price = choose_safe_price(side, bb, ba, aggressive=False)
                size = sample_touch_size() if volatile_mode else sample_size()
                oid = book.add_order(t, side, price, size)
                append_message(t, 1, oid, size, price, side)
            else:
                side = rng.choice(side_choices)
                oid, o = random_active_order(book, side, rng, touch_bias=0.95 if volatile_mode else 0.80, top_levels=1 if volatile_mode else 2)
                qty = o["size"]
                book.delete_order(oid)
                append_message(t, 3, oid, qty, o["price"], side)

        else:
            side = pick_side_with_orders()
            oid, o = random_active_order(book, side, rng, touch_bias=0.95 if volatile_mode else 0.80, top_levels=1 if volatile_mode else 2)
            side_count = bid_count if side == 1 else ask_count
            if side_count == 1 and o["size"] > 1:
                qty = rng.randint(1, o["size"] - 1)
            elif side_count == 1:
                side = -side
                price = choose_safe_price(side, bb, ba, aggressive=True)
                size = sample_touch_size() if volatile_mode else sample_size()
                oid = book.add_order(t, side, price, size)
                append_message(t, 1, oid, size, price, side)
                bb, _ = book.best_bid()
                ba, _ = book.best_ask()
                if bb is not None and ba is not None and bb >= ba:
                    raise RuntimeError(f"Cross detected during generation: bid={bb}, ask={ba}")
                t += sample_dt()
                continue
            else:
                qty = rng.randint(1, o["size"])
            book.reduce_order(oid, qty)
            append_message(t, 4, oid, qty, o["price"], side)

        bb, _ = book.best_bid()
        ba, _ = book.best_ask()
        if bb is not None and ba is not None and bb >= ba:
            raise RuntimeError(f"Cross detected during generation: bid={bb}, ask={ba}")

        t += sample_dt()

    if target_end_time is not None and len(msg_rows) > 1 and t > start_time:
        generated_span = t - start_time
        if generated_span > 0.0:
            scale = duration_seconds / generated_span
            for idx, row in enumerate(msg_rows):
                if idx == 0:
                    row[0] = f"{start_time:.9f}"
                else:
                    current_t = float(row[0])
                    scaled_t = start_time + ((current_t - start_time) * scale)
                    row[0] = f"{scaled_t:.9f}"

    msg_path = f"{out_prefix}_message_clean.csv"
    ob_path = f"{out_prefix}_orderbook_clean.csv"
    meta_path = f"{out_prefix}_metadata.txt"

    with open(msg_path, "w", newline="") as f:
        csv.writer(f).writerows(msg_rows)
    with open(ob_path, "w", newline="") as f:
        csv.writer(f).writerows(ob_rows)

    crosses = locks = normal = 0
    for row in ob_rows:
        ask1, _, bid1, _ = row[:4]
        if ask1 >= DUMMY_ASK or bid1 <= DUMMY_BID:
            continue
        if bid1 > ask1:
            crosses += 1
        elif bid1 == ask1:
            locks += 1
        else:
            normal += 1

    with open(meta_path, "w") as f:
        f.write("Clean synthetic LOBSTER-style replay pair\n")
        f.write(f"market_mode={market_mode}\n")
        f.write(f"rows={len(msg_rows)}\n")
        f.write(f"duration_seconds={duration_seconds:.9f}\n")
        f.write(f"levels={levels}\n")
        f.write(f"tick={tick}\n")
        f.write(f"mid_seed={mid}\n")
        f.write(f"spread_seed={spread}\n")
        f.write(f"targeted_event_prob={targeted_event_prob:.6f}\n")
        f.write(f"drift_step_prob={drift_step_prob:.6f}\n")
        f.write(f"jump_prob={jump_prob:.6f}\n")
        f.write(f"normal_rows={normal}\n")
        f.write(f"locked_rows={locks}\n")
        f.write(f"crossed_rows={crosses}\n")
        if message_in:
            f.write(f"message_in={message_in}\n")
        if orderbook_in:
            f.write(f"orderbook_in={orderbook_in}\n")
        if ob_stats:
            f.write(f"source_change_rate={ob_stats['change_rate']:.6f}\n")
            f.write(f"source_spread_q75={ob_stats['spread_q75']}\n")
            f.write(f"source_spread_q90={ob_stats['spread_q90']}\n")
            f.write(f"source_orderbook_levels={ob_stats['source_levels']}\n")
            f.write("anchor_basis=best_bid_ask_only\n")

    return msg_path, ob_path, meta_path

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=0, help="Number of output rows/messages. Use 0 to auto-size from source message rate and duration.")
    ap.add_argument("--levels", type=int, default=10, help="Number of order book levels in output")
    ap.add_argument("--seed", type=int, default=7, help="Random seed")
    ap.add_argument("--tick-size", type=int, default=DEFAULT_OUTPUT_TICK, help="Output price tick for the generated replay")
    ap.add_argument("--start-time", type=float, default=DEFAULT_START_TIME, help="Starting timestamp in seconds")
    ap.add_argument("--duration-seconds", type=float, default=DEFAULT_DURATION_SECONDS, help="Target replay duration in seconds")
    ap.add_argument("--message-in", type=str, default=None, help="Optional LOBSTER message CSV to calibrate from")
    ap.add_argument("--orderbook-in", type=str, default=None, help="Optional LOBSTER orderbook CSV to calibrate from")
    ap.add_argument("--out-prefix", type=str, default="synthetic", help="Output file prefix")
    ap.add_argument("--market-mode", choices=("calm", "volatile"), default="volatile", help="Generation style. 'volatile' creates more top-of-book churn while staying uncrossed.")
    args = ap.parse_args()

    msg_path, ob_path, meta_path = generate_clean_pair(
        rows=args.rows,
        levels=args.levels,
        seed=args.seed,
        message_in=args.message_in,
        orderbook_in=args.orderbook_in,
        out_prefix=args.out_prefix,
        output_tick=args.tick_size,
        start_time=args.start_time,
        market_mode=args.market_mode,
        duration_seconds=args.duration_seconds,
    )

    print("Wrote:")
    print(msg_path)
    print(ob_path)
    print(meta_path)

if __name__ == "__main__":
    main()
