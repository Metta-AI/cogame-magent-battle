#!/usr/bin/env python3
"""One strict-UTF-8 JSON object describing a magent-battle replay.

Python 3 standard library ONLY -- no Nim, no Docker, no dependencies -- so a
spectator, a CI step or a phase-60 check can read a hosted replay with nothing
but curl and python3:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict JSON: ok
    jq -r '.protocol, .results.reason, .results.kills[0]' /tmp/ep.json
    jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

The replay is the binary COWLDMAG format the static wasm viewer parses. This
tool is the JSON VIEW of the same bytes: it reads the header, brace-matches the
resolved config JSON, and decodes the chat records. Every string in the file was
truncated on a RUNE boundary by the writer, so the output decodes as strict
UTF-8 with no lone surrogates -- which `tests/test_magent_replay.nim` asserts
with 4-byte emoji sitting exactly on every cap.
"""

import json
import struct
import sys

MAGIC = b"COWLDMAG"
FORMAT_VERSION = 1

RK_JOIN = 1
RK_LEAVE = 2
RK_GAME_START = 3
RK_ORDERS = 4
RK_CHAT = 5
RK_HASH = 6
RK_STOP = 7

SQUAD_COUNT = 9
ORDER_KINDS = ["advance", "hold", "focus", "flank", "retreat"]
FLANK_SIDES = ["left", "right"]


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def need(self, count: int) -> None:
        if self.pos + count > len(self.data):
            raise SystemExit(f"replay truncated at byte {self.pos}")

    def u8(self) -> int:
        self.need(1)
        value = self.data[self.pos]
        self.pos += 1
        return value

    def u16(self) -> int:
        self.need(2)
        value = struct.unpack_from("<H", self.data, self.pos)[0]
        self.pos += 2
        return value

    def u32(self) -> int:
        self.need(4)
        value = struct.unpack_from("<I", self.data, self.pos)[0]
        self.pos += 4
        return value

    def u64(self) -> int:
        self.need(8)
        value = struct.unpack_from("<Q", self.data, self.pos)[0]
        self.pos += 8
        return value

    def text(self) -> str:
        length = self.u32()
        self.need(length)
        raw = self.data[self.pos:self.pos + length]
        self.pos += length
        # STRICT: a byte-truncated codepoint raises here rather than being
        # smuggled out as a replacement character or a lone surrogate.
        return raw.decode("utf-8")


def brace_match(text: str, start: int) -> str:
    """The balanced {...} beginning at `start` -- the technique the starter's
    AGENTS.md documents for prod forensics, used here for the config JSON."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise SystemExit("unbalanced config JSON in the replay header")


def summarize(path: str) -> dict:
    data = open(path, "rb").read()
    if not data.startswith(MAGIC):
        raise SystemExit(f"{path} is not a {MAGIC.decode()} replay")
    reader = Reader(data)
    reader.pos = len(MAGIC)
    version = reader.u16()
    if version != FORMAT_VERSION:
        raise SystemExit(f"replay format {version} is not {FORMAT_VERSION}")
    game_name = reader.text()
    game_version = reader.text()
    config_text = reader.text()
    config = json.loads(brace_match(config_text, config_text.index("{")))

    joins = []
    orders = []
    chats = []
    hashes = 0
    stops = []
    game_starts = []
    while reader.pos < len(data):
        kind = reader.u8()
        if kind == RK_JOIN:
            tick, slot = reader.u32(), reader.u16()
            joins.append({"tick": tick, "slot": slot,
                          "name": reader.text(), "token": reader.text()})
        elif kind == RK_LEAVE:
            reader.u32()
            reader.u16()
        elif kind == RK_GAME_START:
            game_starts.append({"tick": reader.u32(),
                                "game": reader.u8() + 1,
                                "redSlot": reader.u8()})
        elif kind == RK_ORDERS:
            record = {"tick": reader.u32(), "game": reader.u8(),
                      "turn": reader.u16(), "slot": reader.u8(), "orders": []}
            for squad in range(SQUAD_COUNT):
                verb = ORDER_KINDS[reader.u8()]
                x, y = reader.u16(), reader.u16()
                target = reader.u8() - 1
                side = FLANK_SIDES[reader.u8()]
                entry = {"squad": ("A" if record["slot"] == 0 else "B") +
                                  str(squad + 1), "verb": verb}
                if verb == "hold":
                    entry["x"], entry["y"] = x, y
                elif verb == "focus":
                    entry["target"] = ("B" if record["slot"] == 0 else "A") + \
                        str(target + 1)
                elif verb == "flank":
                    entry["side"] = side
                record["orders"].append(entry)
            orders.append(record)
        elif kind == RK_CHAT:
            tick, slot = reader.u32(), reader.u16()
            chats.append({"tick": tick, "slot": slot, "text": reader.text()})
        elif kind == RK_HASH:
            reader.u32()
            reader.u64()
            hashes += 1
        elif kind == RK_STOP:
            stops.append({"tick": reader.u32(), "endRule": reader.text()})
        else:
            raise SystemExit(f"unknown replay record {kind} "
                             f"at byte {reader.pos - 1}")

    directives = []
    fallbacks = 0
    registers = []
    results = {}
    for chat in chats:
        text = chat["text"]
        if not text.startswith("{"):
            continue
        try:
            node = json.loads(text)
        except json.JSONDecodeError:
            continue
        kind = node.get("k")
        if kind == "directive":
            directives.append({
                "game": node.get("game"),
                "turn": node.get("turn"),
                "slot": node.get("slot"),
                "alias": node.get("alias"),
                "side": node.get("side"),
                "source": node.get("source"),
                "latency_ms": node.get("latency_ms"),
                "say": node.get("say", ""),
                "orders": node.get("orders", []),
            })
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append({"slot": node.get("slot"),
                              "alias": node.get("alias"),
                              "policy": node.get("policy"),
                              "kind": node.get("kind"),
                              "baseline": node.get("baseline")})
        elif kind == "result":
            results = node.get("results", {})

    return {
        "protocol": config.get("protocol", "magent-battle/v1"),
        "game": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "mapSize": config.get("mapSize"),
        "names": results.get("names") or [join["name"] for join in joins],
        "aliases": results.get("aliases", []),
        "policyKinds": results.get("policyKinds",
                                   [r["kind"] for r in registers]),
        "games": max([g["game"] for g in game_starts], default=0),
        "tickCount": hashes,
        "gameStarts": game_starts,
        "stops": stops,
        "registrations": registers,
        "directives": directives,
        "fallbacks": fallbacks,
        "orderRecords": len(orders),
        "results": results,
        "config": config,
    }


def main(argv: list) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <replay path>", file=sys.stderr)
        return 2
    summary = summarize(argv[1])
    # ensure_ascii=False keeps the real UTF-8 bytes, so the output is a genuine
    # strict-UTF-8 test of what the writer produced rather than an escaped copy.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
