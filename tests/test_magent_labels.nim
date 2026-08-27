## The label contract: the emitted sprite/plate/beat vocabulary equals
## tests/label_manifest.txt, and nothing in it can leak an identity.

import std/[algorithm, json, sequtils, strutils, unittest]
import helpers
import magent/[labels, roster, decide]

suite "magent labels":

  test "the manifest is the emitted vocabulary":
    check labelManifest() == readRepoFile("tests/label_manifest.txt")
    let labels = emittedLabels()
    check labels.len == labels.deduplicate().len
    check labels == labels.sorted()

  test "the two name spaces":
    ## Aliases are ARMY-ANONYMOUS: `Alpha` and `Bravo` regardless of which
    ## colour a seat holds this game, so a commander can never learn who it is
    ## playing from a label. showPlayerLabels is false, so no in-board sprite
    ## can leak an identity either.
    check seatAlias(0) == "Alpha"
    check seatAlias(1) == "Bravo"
    check IdentityNames.len == SeatCount
    for seat in 0 ..< SeatCount:
      for squad in 0 ..< SquadCount:
        let id = squadAlias(seat, squad)
        check id.len == 2
        check id in emittedLabels()
    check squadAlias(0, 0) == "A1"
    check squadAlias(0, 8) == "A9"
    check squadAlias(1, 0) == "B1"
    check squadAlias(1, 8) == "B9"
    ## the alias does not follow the side: seat 0 is Alpha in both games
    var sim = playingSim()
    check sim.seatAliases[0] == "Alpha"
    sim.applyGameStart(1, 1)
    check sim.seatAliases[0] == "Alpha"
    check sim.sideOfSeat(0) == "blue"
    check sim.sideOfSeat(1) == "red"

  test "showPlayerLabels is false in every shipped config":
    for name in ["battle", "skirmish"]:
      var found = false
      for variant in manifestJson()["variants"]:
        if variant["id"].getStr() == name:
          found = true
          check variant["game_config"]["showPlayerLabels"].getBool() == false
      check found
    check manifestJson()["certification"]["game_config"][
      "showPlayerLabels"].getBool() == false

  test "the observation and the prompt carry NO real name":
    ## The one place an identity could leak into a decision.
    var config = testConfig()
    var engine = initDecisionEngine(config)
    var sim = initSimServer(config)
    sim.seatNames[0] = "daveey"
    sim.seatNames[1] = "daveey-1"
    sim.applyGameStart(0, 0)
    for seat in 0 ..< SeatCount:
      let view = $engine.seatView(sim, seat, includeNotes = true)
      checkpoint("seat " & $seat)
      check "daveey" notin view
      check seatAlias(seat) in view
      check seatAlias(1 - seat) in view
