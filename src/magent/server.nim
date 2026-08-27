## The mummy game server: the Coworld contract, the seat sockets, the command
## turns, the artifact writes and the bounded shutdown grace.
##
## Routes, and why each one exists:
##   GET  /healthz                     the runner's liveness probe
##   WS   /player?slot=<i>&token=<t>    one seat; token-checked
##   WS   /global                       the spectator status feed (the
##                                      certifier pings it AFTER the player
##                                      pods start, so it keeps answering for
##                                      the shutdown grace)
##   GET  /client/player?slot&token      served for real, token-checked, and it
##                                      must NOT open the player socket
##   GET  /client/global                 served for real
##   GET  /client/replay                 the developer-local broadcast page
##   GET  /client/*                      fonts and locker-room art
##   GET  /replay-data                   the recorded bytes, for local tooling
## Both /client routes are registered BEFORE any catch-all asset route (the
## lantern 0.1.1 scar).
##
## The serve thread runs independently of the game loop, so a 14 s LLM stall
## cannot drop a connection or stall /healthz.

import std/[json, locks, monotimes, os, strutils, tables, times]
import mummy
import bitworld/runtime, bitworld/spriteprotocol
import sim, decide, baselines, roster, replays, replay_runtime, broadcast,
  episode, wire_constants, labels

const
  HealthPath = "/healthz"
  PlayerWsPath = "/player"
  GlobalWsPath = "/global"
  ReplayWsPath = "/replay"
  PlayerClientPath = "/client/player"
  GlobalClientPath = "/client/global"
  ReplayClientPath = "/client/replay"
  ReplayDataPath = "/replay-data"
  FontPath = "/client/font.ttf"
  ShutdownGraceSeconds = 20
    ## /healthz + /global keep answering this long after the artifacts are
    ## written, then the process exits (the lantern 0.1.3 scar). The runner
    ## waits on process exit anyway.

  EmbeddedBroadcastHtml = staticRead("../../client/replay_broadcast.html")
    .replace("<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
    .spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/unit_red.png", staticRead("../../data/unit_red.png")),
    ("/client/unit_blue.png", staticRead("../../data/unit_blue.png")),
    ("/client/soldier_red.png", staticRead("../../data/soldier_red.png")),
    ("/client/soldier_blue.png", staticRead("../../data/soldier_blue.png")),
    ("/client/arena_floor.png", staticRead("../../data/arena_floor.png"))
  ]

type
  SeatSocket = object
    slot: int
    token: string
    name: string
    ready: bool

  AppState = object
    lock: Lock
    seats: Table[WebSocket, SeatSocket]
    globals: Table[WebSocket, bool]
    registrations: Table[WebSocket, string]
    closed: seq[WebSocket]
    config: GameConfig
    replayBytes: string
    serving: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: AppState

proc initAppState(config: GameConfig) =
  initLock(appState.lock)
  appState.seats = initTable[WebSocket, SeatSocket]()
  appState.globals = initTable[WebSocket, bool]()
  appState.registrations = initTable[WebSocket, string]()
  appState.closed = @[]
  appState.config = config
  appState.serving = true

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc queryInt(request: Request, key: string, fallback: int): int =
  let text = request.queryParams.getOrDefault(key, "").strip()
  if text.len == 0:
    return fallback
  try: parseInt(text)
  except CatchableError: fallback

proc textHeaders(kind: string): HttpHeaders =
  result["Content-Type"] = kind
  result["Cache-Control"] = "no-cache"

proc respondText(request: Request, status: int, body: string) =
  request.respond(status, textHeaders("text/plain; charset=utf-8"), body)

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's Sprite v1 chat message, read as its registration:
  ##   {"policy":"…","prompt":"…","scripted":"line"|"pincer"|null}
  ## Anything that is not that object is not a registration, and any other
  ## chat text from a seat is dropped: commanders speak through `say`, seats
  ## do not shout.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  if node{"prompt"}.isNil and node{"scripted"}.isNil and
      node{"policy"}.isNil:
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc httpHandler(request: Request) {.gcsafe.} =
  if request.path == HealthPath and request.httpMethod == "GET":
    request.respondText(200, "healthy")
    return
  if request.path == PlayerWsPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.queryInt("slot", -1)
      token = request.queryParams.getOrDefault("token", "").strip()
      name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
    var reject = ""
    {.gcsafe.}:
      withLock appState.lock:
        if slot < 0 or slot >= appState.config.numAgents:
          reject = "Player slot must be between 0 and " &
            $(appState.config.numAgents - 1) & "."
        elif not appState.config.playerJoinAllowed(slot, token):
          reject = "Player token does not match configured slot " & $slot & "."
    if reject.len > 0:
      var headers = textHeaders("text/plain; charset=utf-8")
      headers["Connection"] = "close"
      request.respond(403, headers, reject & "\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.seats[websocket] = SeatSocket(
          slot: slot, token: token, name: name)
    echo "player connected: slot ", slot
    return
  if (request.path == GlobalWsPath or request.path == ReplayWsPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globals[websocket] = true
    return
  # The certifier's browser probes, registered BEFORE the catch-all below.
  if request.path == PlayerClientPath and request.httpMethod == "GET":
    let
      slot = request.queryInt("slot", -1)
      token = request.queryParams.getOrDefault("token", "").strip()
    var ok = false
    {.gcsafe.}:
      withLock appState.lock:
        ok = appState.config.playerJoinAllowed(slot, token)
    if not ok:
      request.respond(403, textHeaders("text/html; charset=utf-8"),
        "<!doctype html><meta charset=utf-8><title>magent-battle seat</title>" &
        "<p>Player slot or token does not match the configured roster.")
      return
    ## Deliberately a PAGE, not a socket: opening the player websocket here
    ## would seat the certifier's probe as a commander (lantern 0.1.1).
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      "<!doctype html><meta charset=utf-8><title>magent-battle seat " &
      $slot & "</title><body style=\"font:14px system-ui;background:#16110d;" &
      "color:#f2e8d8\"><h1>magent-battle</h1><p>Seat " & $slot &
      " is authorised. This seat is driven by /bin/magent-battle-player over " &
      PlayerWsPath & "?slot=" & $slot & "&amp;token=…</p>")
    return
  if request.path == GlobalClientPath and request.httpMethod == "GET":
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      "<!doctype html><meta charset=utf-8><title>magent-battle spectator" &
      "</title><body style=\"font:14px system-ui;background:#16110d;" &
      "color:#f2e8d8\"><h1>magent-battle</h1><p>The hosted spectator " &
      "experience is the static replay bundle. This process streams a live " &
      "status feed over " & GlobalWsPath & ".</p>")
    return
  if request.path == ReplayClientPath and request.httpMethod == "GET":
    ## The developer-local broadcast page. NEVER declared to the platform: the
    ## hosted viewer is the static wasm bundle.
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      EmbeddedBroadcastHtml)
    return
  if request.path == ReplayDataPath and request.httpMethod == "GET":
    var bytes = ""
    {.gcsafe.}:
      withLock appState.lock:
        bytes = appState.replayBytes
    if bytes.len == 0:
      request.respondText(404, "no replay recorded yet\n")
    else:
      request.respond(200, textHeaders("application/octet-stream"), bytes)
    return
  if request.path == FontPath and request.httpMethod == "GET":
    var headers = textHeaders("font/ttf")
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
    return
  if request.httpMethod == "GET":
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        var headers = textHeaders(
          if path.endsWith(".webp"): "image/webp"
          elif path.endsWith(".png"): "image/png"
          else: "image/jpeg")
        headers["Cache-Control"] = "public, max-age=3600"
        request.respond(200, headers, art)
        return
  request.respondText(200, "magent-battle server\n")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) {.gcsafe.} =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
      return
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.seats:
          for item in parseSpriteClientMessages(message.data):
            case item.kind
            of SpriteClientReadyMessage:
              appState.seats[websocket].ready = true
            of SpriteClientChatMessage:
              if item.text.len > 0 and item.text[0] == '{':
                appState.registrations[websocket] = item.text
            else:
              discard
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.closed:
          appState.closed.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload -- exactly {"message","failed_policy_index"},
  ## nothing else -- so a lobby no-show is charged to the seat that caused it
  ## instead of poisoning the episode unattributed. Best-effort: a declaration
  ## write failure must never mask the episode.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"message": message, "failed_policy_index": slot}),
      "application/json")
  except CatchableError as error:
    echo "player-failure declaration failed: ", error.msg

proc playerFrameBlob(frame: int): string =
  ## The one binary frame per tick a seat receives. Seats send NO inputs (the
  ## server computes every action), so this exists only to drive the seat's
  ## acknowledge-and-resend loop.
  result = newString(5)
  result[0] = char(0x02)
  for i in 0 ..< 4:
    result[i + 1] = char((frame shr (i * 8)) and 0xff)

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  runtimeConfig = RuntimeConfig()
) =
  var config = initialConfig
  config.clampConfig()
  initAppState(config)

  let replayMode = loadReplayPath.len > 0
  var
    replayData: ReplayData
    replayPlayer: ReplayPlayer
  if replayMode:
    replayData = loadReplay(loadReplayPath)
    var initialized = initReplayRuntime(replayData)
    config = initialized.config
    replayPlayer = initialized.player
    {.gcsafe.}:
      withLock appState.lock:
        appState.config = config

  var
    sim =
      if replayMode: initSimServer(config)
      else: initSimServer(config)
    engine = initDecisionEngine(config)
    writer = openReplayWriter(saveReplayPath, config.configJson())
    tracker = initBroadcastTracker()
  if replayMode:
    sim.applyJoinRecords(replayData)

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(
        ValueError, "COGAME_EVENTS_URI must be a file:// path, got: " & uri)
  sim.collectEvents = eventsPath.len > 0
  var collectedEvents: seq[SimEvent]

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "magent-battle listening on ", host, ":", port,
    " mapSize=", config.mapSize, " seats=", config.numAgents,
    " army=", sim.units.armyCount[0], " v ", sim.units.armyCount[1]

  var
    driver = initEpisodeState()
    quitAfterFrame = false
    failureDeclared = false
    episodeStart = getMonoTime()
    lastTick = getMonoTime()

  while true:
    let frame = driver.frame
    var
      seatSockets: seq[WebSocket]
      globalViewers: seq[WebSocket]
      newRegistrations: seq[(int, string)]
      allReady = true
      activeSeats = 0

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closed:
          if websocket in appState.seats:
            let slot = appState.seats[websocket].slot
            if slot >= 0 and slot < SeatCount:
              echo "player disconnected: slot ", slot
            appState.seats.del(websocket)
          appState.globals.del(websocket)
          appState.registrations.del(websocket)
        appState.closed.setLen(0)
        for websocket, seat in appState.seats.pairs:
          seatSockets.add(websocket)
          inc activeSeats
          if not seat.ready:
            allReady = false
          if not sim.joined[seat.slot]:
            sim.admitSeat(seat.slot, seat.name)
            writer.writeJoin(frame, seat.slot,
              (if sim.seatNames[seat.slot].len > 0: sim.seatNames[seat.slot]
               else: seatAlias(seat.slot)), seat.token)
        for websocket, text in appState.registrations.pairs:
          if websocket in appState.seats:
            newRegistrations.add((appState.seats[websocket].slot, text))
        appState.registrations.clear()
        for websocket in appState.globals.keys:
          globalViewers.add(websocket)

    # --- registration interception ----------------------------------------
    # A seat's chat is its REGISTRATION: consumed here, never applied as a
    # shout and never written to the replay chat stream (the prompt is a
    # secret). What the replay gets is a REDACTED `register` record. Any other
    # chat text from a seat is dropped: commanders speak through `say`.
    for (slot, text) in newRegistrations:
      if slot < 0 or slot >= SeatCount:
        continue
      let registration = parseRegistration(text)
      if not registration.ok:
        continue
      let firstRegistration = not engine.seats[slot].registered
      engine.seats[slot].registered = true
      engine.seats[slot].prompt =
        registration.prompt.truncateRunes(MaxPromptRunes)
      engine.seats[slot].isLlm = engine.seats[slot].prompt.len > 0
      engine.seats[slot].baseline = parseBaseline(registration.scripted)
      engine.seats[slot].label =
        if registration.policy.len > 0: registration.policy
        elif engine.seats[slot].isLlm: "prompt"
        else: $engine.seats[slot].baseline
      sim.seatPolicyKind[slot] = engine.policyKind(slot)
      sim.seatPolicyLabel[slot] = engine.seats[slot].label
      # The scorebug shows the seat's REAL policy name, spectator side only. A
      # hosted config names each seat; a local run does not, so the
      # registration label is the better name whenever the configured one is
      # just the anonymous alias.
      if sim.seatNames[slot].len == 0 or
          sim.seatNames[slot] == seatAlias(slot):
        sim.seatNames[slot] = engine.seats[slot].label
      if firstRegistration:
        writer.writeChat(frame, slot, registerRecord(
          slot, engine.seats[slot].label, engine.policyKind(slot),
          $engine.seats[slot].baseline))
        echo "seat ", slot, " registered: kind=", engine.policyKind(slot),
          " baseline=", $engine.seats[slot].baseline

    # --- one episode frame, from the SHARED driver -------------------------
    var frameChats: seq[ChatRecord]
    var episodeFrame: EpisodeFrame
    if replayMode:
      replayPlayer.advanceReplayFrame(sim)
      frameChats = replayPlayer.pending
      if replayPlayer.frame > replayPlayer.maxFrame and not replayPlayer.looping:
        quitAfterFrame = true
    else:
      let elapsed = (getMonoTime() - episodeStart).inSeconds.int
      episodeFrame = driver.runEpisodeFrame(sim, engine, writer, elapsed)
      if episodeFrame.startedGame:
        if driver.failureSlot >= 0 and not failureDeclared:
          failureDeclared = true
          declarePlayerFailure(driver.failureSlot,
            "player slot " & $driver.failureSlot &
            " never joined the lobby within " &
            $config.lobbyJoinTimeoutTicks &
            " lobby ticks; its army plays the pincer baseline")
        echo "game 1 of ", config.maxGames, " starts: seat ", sim.redSlot,
          " is red"
      if episodeFrame.finishedGame:
        echo "game ", driver.gamesPlayed, " of ", config.maxGames,
          " done: ", sim.gameLog[^1].endRule, " survivors ",
          sim.gameLog[^1].survivors[0], " v ", sim.gameLog[^1].survivors[1]
        if not driver.finished:
          echo "game ", driver.gamesPlayed + 1, " starts: seat ", sim.redSlot,
            " is red"
      if episodeFrame.faulted:
        echo "magent: HOST ERROR at tick ", sim.tick, ": ", sim.stopDetail
      if sim.collectEvents:
        for event in sim.events:
          collectedEvents.add(event)
        sim.events.setLen(0)
      if driver.stopped:
        echo "magent: ", sim.stopDetail, "; settling from this tick"
      if driver.finished:
        quitAfterFrame = true

    let events = stepEvents(sim, tracker, frameChats)

    # --- broadcast ---------------------------------------------------------
    let statePacket = buildStateJson(
      sim, replayPlayer, tracker, events, live = not replayMode)
    let blob = playerFrameBlob(frame)
    for websocket in seatSockets:
      try:
        websocket.send(blob, BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            if websocket notin appState.closed:
              appState.closed.add(websocket)
    for websocket in globalViewers:
      ## Fire and forget: a slow viewer can never stall the episode.
      try:
        websocket.send(statePacket, TextMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            if websocket notin appState.closed:
              appState.closed.add(websocket)

    if quitAfterFrame:
      break

    # --- the frame limiter -------------------------------------------------
    # fastMode: advance as soon as every connected seat has acknowledged the
    # frame. The seats send no inputs, so the dead-reckoning hazard the
    # protocol warns about cannot arise.
    let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
    while true:
      let elapsed = getMonoTime() - lastTick
      if elapsed >= frameDuration:
        break
      if config.fastMode and activeSeats > 0 and allReady:
        break
      sleep(1)
    lastTick = getMonoTime()
    if config.fastMode:
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.seats.keys:
            appState.seats[websocket].ready = false

  # --- artifacts ----------------------------------------------------------
  if not replayMode:
    driver.finishEpisode(sim, writer)
    {.gcsafe.}:
      withLock appState.lock:
        appState.replayBytes = writer.bytes()
    if saveReplayPath.len > 0 and fileExists(saveReplayPath):
      echo "Replay written: ", saveReplayPath, " (",
        getFileSize(saveReplayPath), " bytes)"
      runtimeConfig.writeReplay(readFile(saveReplayPath))
    elif writer.bytes().len > 0:
      runtimeConfig.writeReplay(writer.bytes())
    if eventsPath.len > 0:
      writeFile(eventsPath, collectedEvents.eventsJsonl(sim.episodeTick))
      echo "Events written: ", eventsPath, " (", collectedEvents.len, " events)"
    let resultsJson = sim.armyResultsJson() & "\n"
    if runtimeConfig.resultsUri.len > 0:
      runtimeConfig.writeResults(resultsJson)
    echo "results: ", resultsJson
    echo "labels: ", emittedLabels().len, " in the manifest vocabulary"

  # Bounded shutdown grace: the certification runner pings /healthz and
  # /global AFTER the player pods start, and a short episode can already have
  # written its artifacts by then.
  let graceUntil =
    getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
  while getMonoTime() < graceUntil:
    sleep(200)
  httpServer.close()
  joinThread(serverThread)
