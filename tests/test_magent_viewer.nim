## Viewer tests. Static assertions over the committed chrome: the byte-identical
## shared file, the provenance of the broadcast page, the removed elements, the
## beat CSS, the transport rules and the 360 px rules.

import std/[os, sequtils, sets, sha1, strutils, unittest]
import helpers
import magent/[labels, wire_constants]

const
  StarterPath = "/workspace/starters/coworld-ctf"
    ## The read-only starter mount. Present in the build sandbox, absent on a
    ## CI runner, so every test that reads it degrades to the committed
    ## fingerprint instead of failing.

proc pageText(): string = readRepoFile("client/replay_broadcast.html")
proc coreText(): string = readRepoFile("client/broadcast_core.js")
proc chromeText(): string = readRepoFile("client/chrome_common.js")

proc stripLineComments(text: string): string =
  ## Whole-line and trailing `//` comments removed. Crude about `//` inside a
  ## string literal, which is fine for the files it is pointed at.
  var lines: seq[string]
  for line in text.splitLines():
    let at = line.find("//")
    if at < 0:
      lines.add(line)
    elif line[0 ..< at].count('"') mod 2 == 0 and
        line[0 ..< at].count('\'') mod 2 == 0:
      lines.add(line[0 ..< at])
    else:
      lines.add(line)
  lines.join("\n")

proc stripHtmlComments(text: string): string =
  ## HTML comments, CSS comments and whole-line `//` comments removed, so a
  ## vocabulary grep asks about what the page SHOWS.
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
    if line.strip().startsWith("//"):
      continue
    lines.add(line)
  lines.join("\n")

suite "magent viewer":

  test "chrome_common is byte-identical to the starter's":
    ## Everything this game adds lives in the appended game block; the shared
    ## chrome is copied, never edited and never reformatted. The pin is the
    ## file's own sha256 as a literal, so an edit fails here even with the
    ## starter mount absent.
    let text = chromeText()
    ## The pin is the file's own length and SHA-1 as literals, so an edit fails
    ## HERE even with the starter mount absent (a CI runner has no mount).
    check text.len == 40022
    check $secureHash(text) == "D970EBE4EFF1B0154BA604B4E9ADF62D601CB3EB"
    ## the machinery the appended block relies on, still present
    for name in ["window.ChromeCommon", "markBeat", "renderBeatMarkers",
                 "ingestBeats", "ingestLullSpans", "renderLullSpans",
                 "renderMomentum", "ingestLeadSeries", "recordMomentum",
                 "renderTransport", "renderClock", "getSpoilers"]:
      check name in text
    ## ingestBeats ignores kinds it does not know, which is why this game's five
    ## kinds can ride the same call
    check "if (b.k === 'steal'" in text
    if dirExists(StarterPath):
      check text == readFile(StarterPath / "client/chrome_common.js")

  test "the broadcast page is the starter's, minus the removed elements, plus a block":
    let page = pageText()
    ## the starter's landmarks, in the starter's order
    var at = 0
    for landmark in ["<!DOCTYPE html>", "Ink & Print", "--hudscale",
                     "<div id=\"viewport\">", "<div id=\"stage\">",
                     "<canvas id=\"board\">", "<div id=\"lockerroom\"",
                     "<div id=\"scorebug\">", "<div id=\"transport\">",
                     "<div class=\"scrub\" id=\"scrub\">",
                     "<div id=\"endcard\">", "<div id=\"status\">",
                     "<!-- WIRE_CONSTANTS -->", "<!-- CHROME_COMMON -->",
                     "<!-- BROADCAST_CORE -->"]:
      let found = page.find(landmark, at)
      checkpoint(landmark)
      check found >= at
      at = max(at, found)
    ## the appended game block comes AFTER the whole inherited page
    let banner = page.find(
      "MAGENT-BATTLE additions to the inherited coworld-ctf chrome")
    check banner > at
    check page.find("window.MagentChrome = {") > banner
    check page.find("battleBeat") > banner
    ## and the builder that produced it is committed, so the fork is auditable
    check repoFileExists("tools/build_broadcast_page.py")
    check repoFileExists("client/page_script.js")
    check repoFileExists("client/game_block.html")

  test "the inherited page prefix is byte-pinned":
    ## `tools/build_broadcast_page.py` is the provenance record -- it rebuilds
    ## this page from the read-only starter and the committed page compares
    ## equal -- but it needs the starter MOUNT, and a CI runner has none. So
    ## nothing on main would catch a hand-edit of the inherited page above the
    ## splice. Pin that region (everything before the forked page IIFE) by its
    ## own length and SHA-1: an edit there fails HERE, and the fix is to
    ## re-run the builder against the starter, not to re-pin the literals.
    let page = pageText()
    let scriptOpen = page.find(
      "<script>", page.find("<!-- BROADCAST_CORE -->"))
    check scriptOpen > 0
    let inherited = page[0 ..< scriptOpen]
    check inherited.len == 60731
    check $secureHash(inherited) == "753E95A58A73072D58E8CA1FC4B2293AB6256395"

  test "the removed elements appear nowhere":
    ## Zoom decision: DROPPED. The board is a fixed square grid with a 1:1
    ## aspect and no off-frame area, so relayout() fits it whole at every width
    ## and #viewpanel has nothing to do. Checked against the page with comments
    ## STRIPPED: what matters is that nothing is styled, marked up or scripted,
    ## not that the inherited commentary never mentions the word.
    let page = pageText()
    let visible = stripHtmlComments(page)
    for id in ["#viewpanel", "id=\"viewpanel\"", "#minimap", "minimap-canvas",
               "#zoombar", "zoom-in", "zoom-out", "zoom-slider", "zoom-read",
               "#fpv", "fpv-canvas", "fpv-hud", "fpv-map", "povBadge",
               "attachMinimap(", ".squad-pip", ".flagicon", ".hillchip",
               ".ec-heart", ".lives-num", ".lives-label"]:
      if id in visible:
        checkpoint("removed element still present: " & id)
        fail()
    ## and the kept ones are all still there
    for id in ["viewport", "stage", "board", "lightpool", "grain",
               "lockerroom", "chrome", "scorebug", "plates-l", "plates-r",
               "clock", "clock-time", "clock-caption", "bannerlane",
               "killfeed", "mmwarn", "transport", "btn-restart", "btn-back",
               "btn-play", "btn-fwd", "btn-end", "btn-loop", "btn-skip",
               "btn-spoilers", "ffwd-chip", "ffwd-mini", "win-chip",
               "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill",
               "lulls", "scrub-win", "scrub-head", "endcard", "ec-headline",
               "ec-wincond", "ec-how", "ec-teams", "ec-replay", "status"]:
      if ("id=\"" & id & "\"") notin page:
        checkpoint("kept element missing: " & id)
        fail()

  test "no shadowed chrome aliases":
    ## The page's chrome alias block declares the shared beat builder with a
    ## hoisted `var markBeat`, so a game-block function of that name is silently
    ## swallowed and the scrubber ends up with unlabelled div markers that never
    ## seek (cogame-tandem, 2026-08-23).
    let page = pageText()
    let banner = page.find(
      "MAGENT-BATTLE additions to the inherited coworld-ctf chrome")
    check banner > 0
    ## from the END of the banner comment, so the banner's own prose (which
    ## names markBeat to explain why the block does not use it) is not the thing
    ## under test
    let appended = stripLineComments(
      stripHtmlComments(page[page.find("-->", banner) + 3 .. ^1]))
    var aliases: seq[string]
    for line in page[0 ..< banner].splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("var "):
        continue
      for part in trimmed[4 .. ^1].split(','):
        let name = part.split('=')[0].strip().strip(chars = {';'})
        if name.len > 0 and '(' notin name and ' ' notin name:
          aliases.add(name)
    check aliases.len > 20
    check "markBeat" in aliases
    for name in aliases:
      checkpoint("alias " & name)
      check ("function " & name & "(") notin appended
    ## the block's own beat builder is battleBeat, and it NEVER calls markBeat
    check "function battleBeat(" in appended
    check "markBeat" notin appended

  test "beat CSS matches exactly the kinds the sim emits":
    let page = pageText()
    var styled: HashSet[string]
    var scan = 0
    while true:
      let at = page.find(".beat-marker.", scan)
      if at < 0:
        break
      scan = at + 13
      var kind = ""
      var i = scan
      while i < page.len and page[i] in {'a' .. 'z'}:
        kind.add(page[i])
        inc i
      if kind.len > 0:
        styled.incl(kind)
    let emitted = ["firstblood", "rout", "wipe", "fallback", "end"].toHashSet()
    check styled == emitted
    ## buttons, not divs: labelled and clickable
    check "var el = document.createElement('button');" in page
    check "el.setAttribute('aria-label', label);" in page
    check "CTX.send('s:' + tick);" in page

  test "transport, endcard and the 360 px rules":
    let page = pageText()
    ## the endcard stops at the transport band and every seek dismisses it
    check "#endcard {" in page
    check "bottom: var(--band, 0px)" in page or "bottom: var(--band)" in page
    check "card.classList.remove('on');" in page
    ## relayout owns the three custom properties, on :root
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--topband'" in page
    check "root.style.setProperty('--band'" in page
    ## labels hidden UNDER 640 px of board (checklist item 11); the starter's
    ## own threshold was 620, which left 621-640 px labelled
    check "stage.classList.toggle('tiny', boardW < 640);" in page
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in page
    ## nothing this game adds is positioned INSIDE the transport band: the heat
    ## chip is anchored to the TOP of #chrome
    let heat = page.find("#heatchip {")
    check heat > 0
    let heatRule = page[heat ..< page.find("}", heat)]
    check "top:" in heatRule
    check "bottom:" notin heatRule
    ## the three 360 px rules
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    check "#stage.tiny .plate .kill-num" in page
    check "var bins = tiny ? 5 : 9;" in coreText()
    check "ctx.lineWidth = tiny ? 2 : 1.5;" in coreText()

  test "broadcast_core keeps the starter's module shape and API":
    let core = coreText()
    let code = stripLineComments(stripHtmlComments(core))
    check "globalScope.BroadcastCore = { create: BroadcastCore };" in core
    for name in ["start:", "stop:", "ingest:", "sendCommand:", "clickMap:",
                 "zoomAt:", "setZoom:", "panBy:", "panByMap:", "panTo:",
                 "resetView:", "attachMinimap:", "getTransform:",
                 "setViewportSize:", "setViewportFit:", "getPaceStats:"]:
      checkpoint(name)
      check name in core
    ## pushFeed's SIGNATURE is load-bearing: a drift threw mid-replay and
    ## latched the static adapter into `failed` (cogball 0.1.4)
    check "function pushFeed(text) {" in core
    ## the wire rename, and no ctf identifier left
    check "globalScope.MAGENT_WIRE" in core
    check "CTF_WIRE" notin code
    ## what this fork adds
    for name in ["function drawBattlefield(", "function drawHeat(",
                 "function drawFrontLine("]:
      check name in core
    ## and what it deletes
    for name in ["hill", "paintUnder", "flagicon", "drawFpv", "SnappyJS"]:
      if name in code:
        checkpoint("a deleted ctf draw call survived: " & name)
        fail()

  test "the static viewer files all come from ONE starter":
    ## Splicing one starter's shell onto another's emscripten link flags
    ## (MODULARIZE/EXPORT_NAME vs an onRuntimeInitialized bootstrap) deadlocks
    ## the viewer silently (cogame-lantern, 2026-08-23).
    let
      configRaw = readRepoFile("replay-viewer/config.nims")
      config = stripNimComments(configRaw)
      worker = readRepoFile("replay-viewer/static_replay_worker.js")
      adapter = readRepoFile("replay-viewer/static_replay.js")
    check "Module.onRuntimeInitialized" in worker
    check "MODULARIZE" notin config
    check "EXPORT_NAME" notin config
    check "-s ABORTING_MALLOC=1" in configRaw
    check "-s ALLOW_MEMORY_GROWTH" in configRaw
    check "-s ENVIRONMENT=web,worker,node" in configRaw
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in configRaw
    check "--define:useMalloc" in configRaw
    check "--mm:arc" in configRaw
    check "--exceptions:goto" in configRaw
    for symbol in ["_main", "_malloc", "_free", "_magent_load_replay",
                   "_magent_frame", "_magent_input", "_magent_packet_ptr",
                   "_magent_packet_len", "_magent_mismatch_tick",
                   "_magent_error_ptr", "_magent_error_len",
                   "_magent_stage_ptr", "_magent_stage_len"]:
      checkpoint(symbol)
      check symbol in configRaw
    ## importScripts order: constants, then the core, then the module
    let order = worker.find(
      "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./magent_replay.js');")
    check order > 0
    ## the load and error signals, both the starter's, on <html>
    check "document.documentElement.setAttribute('data-replay-loaded', 'true')" in
      adapter
    check "'data-replay-error'" in adapter
    ## and 'loaded' is posted only AFTER the first frame has been ingested
    let ingest = worker.find("ingestPacket();")
    let posted = worker.find("type: 'loaded',")
    check ingest > 0 and posted > ingest

  test "the wasm entry keeps the starter's abort-safe structure":
    let entry = readRepoFile("replay-viewer/magent_replay.nim")
    for name in ["stampStage", "bytesFromPointer", "lastError",
                 "emscripten_exit_with_live_runtime", "stageNote"]:
      check name in entry
    check "magent/[broadcast, replay_runtime, replays, roster, sim]" in entry
    check "pre-scan" in entry

  test "the wire constants are emitted from the Nim consts":
    check WireConstantsJs.startsWith("window.MAGENT_WIRE={")
    check ("fps:" & $TargetFps) in WireConstantsJs
    check ("maxSayRunes:" & $MaxSayRunes) in WireConstantsJs
    check ("squads:" & $SquadCount) in WireConstantsJs
    check ("gameVersion:\"" & GameVersion & "\"") in WireConstantsJs
    check WireConstantsMarker in pageText()

  test "label manifest":
    ## The emitted sprite-label vocabulary equals tests/label_manifest.txt,
    ## regenerated in the same commit as any label change.
    let pinned = readRepoFile("tests/label_manifest.txt")
    check labelManifest() == pinned
    ## and no REAL policy name is ever a label -- the anti-collusion half of the
    ## two-name-space rule
    for label in emittedLabels():
      check label.len <= 10
      check "daveey" notin label

  test "the ctf rename sweep is complete":
    ## The fork is a rename sweep (`ctf` -> `magent`, `CTF_WIRE` ->
    ## `MAGENT_WIRE`). A surviving `ctf_` identifier is not cosmetic: the
    ## viewer shipped once with `Module._ctf_mismatch_tick` in the Worker, which
    ## loaded the module, drew the board and THEN threw on the first frame.
    for path in ["replay-viewer/static_replay.js",
                 "replay-viewer/static_replay_worker.js",
                 "replay-viewer/magent_replay.nim",
                 "replay-viewer/config.nims",
                 "client/broadcast_core.js",
                 "client/page_script.js",
                 "client/game_block.html",
                 "Dockerfile",
                 "Dockerfile.replay-viewer"]:
      let text = readRepoFile(path)
      for token in ["_ctf_", "ctf_replay", "CtfStaticReplay", "CTF_WIRE",
                    "src/ctf", "ctf/sim"]:
        if token in text:
          checkpoint(path & " still carries the ctf identifier " & token)
          fail()
