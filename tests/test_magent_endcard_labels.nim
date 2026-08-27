## The endcard and chrome VOCABULARY gate.
##
## A forked ctf endcard silently ships paintbot's words: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## spectator chrome STRINGS, because `labels.nim` deliberately scopes itself to
## the policy contract. So the re-labelings are enumerated in the design note and
## enforced here -- zero forbidden words, and every replacement present.

import std/[strutils, unittest]
import helpers

const
  Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart", "paint",
               "hopper", "hill", "POV", "spray", "grenade", "med kit"]
  # The design note's re-mapping table, left column -> right column:
  #   ec-thead Player/K/D/Clstr/Cap  ->  Commander/Kills/Lost/Alive/Reward
  #   fl-cap "Lives left"            ->  "Troops left"
  #   momentum-label "LIVES LEAD"    ->  "TROOPS LEAD"
  #   plate "lives-label Lives"      ->  "alive-label Alive"
  #   lk-cap hoppers/paint line      ->  "Forming up on the line..."
  #   clock-caption locker room      ->  "Mustering"
  #   mmwarn "recorded inputs"       ->  "recorded orders" (with the tick)
  #   btn-spoilers "flag story"      ->  "routs"
  Required = [
    "<span>Commander</span>",
    "<span>Kills</span>",
    "<span>Lost</span>",
    "<span>Alive</span>",
    "<span>Reward</span>",
    "Troops left",
    "TROOPS LEAD",
    "alive-label",
    "Forming up on the line",
    "Mustering",
    "showing recorded orders",
    "kills / routs / winner"
  ]

proc withoutComments(text: string): string =
  ## HTML comments, CSS comments and `//` line comments removed. A comment
  ## explaining what was deleted is documentation; a STRING the spectator reads
  ## is vocabulary, and only the latter is under test.
  var body = text
  for (opener, closer) in [("<!--", "-->"), ("/*", "*/")]:
    var scan = 0
    while true:
      let start = body.find(opener, scan)
      if start < 0:
        break
      let stop = body.find(closer, start)
      if stop < 0:
        body = body[0 ..< start]
        break
      body = body[0 ..< start] & body[stop + closer.len .. ^1]
      scan = start
  var lines: seq[string]
  for line in body.splitLines():
    let at = line.find("//")
    if at >= 0 and line[0 ..< at].count('"') mod 2 == 0 and
        line[0 ..< at].count('\'') mod 2 == 0:
      lines.add(line[0 ..< at])
    else:
      lines.add(line)
  lines.join("\n")

suite "magent endcard labels":

  test "zero paintbot vocabulary outside comments":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
                 "client/page_script.js", "client/game_block.html"]:
      let text = withoutComments(readRepoFile(path))
      for word in Forbidden:
        if word in text:
          let at = text.find(word)
          checkpoint(path & " still says \"" & word & "\": ..." &
            text[max(0, at - 70) ..< min(text.len, at + 40)].replace("\n", " ") &
            "...")
          fail()

  test "every re-mapped string is present":
    let page = readRepoFile("client/replay_broadcast.html")
    for wanted in Required:
      if wanted notin page:
        checkpoint("the re-mapped string is missing: " & wanted)
        fail()

  test "the feed speaks plain language, not internal notation":
    let gameBlock = readRepoFile("client/game_block.html")
    for phrase in ["FIRST BLOOD", "IS ROUTED", "IS WIPED OUT",
                   "MISSED THE CALL"]:
      check phrase in gameBlock
    ## the clock reads the pair and the turn, not a raw countdown
    let script = readRepoFile("client/page_script.js")
    check "'game ' + mg.game + '/' + mg.games" in script
    check "'tick ' + mg.tick + '/' + mg.maxTicks" in script

  test "the two name spaces are respected in the chrome":
    ## The seat's REAL policy name is spectator side only; the in-game alias is
    ## what a commander ever sees. Both appear on the plate, and nothing in the
    ## board layer draws a real name.
    let script = readRepoFile("client/page_script.js")
    check "plate-name" in script
    check "plate-alias" in script
    check "teamHeadline(seat.name" in script
    let core = readRepoFile("client/broadcast_core.js")
    ## the board renderer only ever reads cell/army/hp/squad
    check "seat.name" notin core
    check "roster" notin core
