## The tier-2 analysis stream: one JSON line per event plus the mandatory
## trailing summary row, written to COGAME_EVENTS_URI. Off unless the platform
## configured a destination, so a server nobody is analysing pays nothing.

import std/[json, strutils]
import sim_types

type
  SimEventKind* = enum
    Attack = "attack"
    Kill = "kill"
    Rout = "rout"
    Wipe = "wipe"
    TurnStart = "turn_start"
    Directive = "directive"
    Fallback = "fallback"
    PhaseChange = "phase_change"

  SimEvent* = object
    kind*: SimEventKind
    tick*: int
    game*: int
    source*: int
    target*: int
    amount*: int
    detail*: string

proc eventJson*(event: SimEvent): JsonNode =
  %*{
    "type": $event.kind,
    "tick": event.tick,
    "game": event.game,
    "source": event.source,
    "target": event.target,
    "amount": event.amount,
    "detail": event.detail
  }

proc eventsJsonl*(events: seq[SimEvent], ticks: int): string =
  ## JSON lines, then the summary row. The summary is how a reader tells "this
  ## match had no events" from "the upload never happened".
  var lines: seq[string]
  for event in events:
    lines.add($event.eventJson())
  lines.add($(%*{
    "type": "summary",
    "ticks": ticks,
    "events": events.len,
    "gameVersion": GameVersion
  }))
  lines.join("\n") & "\n"
