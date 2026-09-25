## The magent-battle player container: scripted, prompt, or external policy.
##
## Prompt decisions run inside the game. External policies receive the same
## fogged seat view and return catalog choices on the player socket.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      line | pincer                -> this seat is scripted
##   PLAYER_NUMERIC_URL   frozen Fabric /actions endpoint
##   PLAYER_JEV           1 to choose through System One
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `pincer`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <magent-battle-image> --name my-magent \
##     --run /bin/magent-battle-player --secret-env PLAYER_PROMPT="<strategy>"

import std/[json, options, os, random, strutils, times]
import bitworld/spriteprotocol
import whisky
import magent/sim_types
import magent/numeric_policy
import magent/jev_policy

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24
  ReconnectAttempts = 6

## The two caps below come from `magent/sim_types` -- the SAME constants and the
## SAME rune-boundary `truncateRunes` the server enforces them with. They were
## re-declared here once, which meant 4000/64 existed twice and could drift
## (r1 review F15).

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "pincer named
  ## explicitly".
  var node = %*{
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "prompt": prompt.truncateRunes(MaxPromptRunes)
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  if external:
    node["mode"] = %"external"
  blobFromSpriteChat($node)

proc actionBlob(request: JsonNode, actions: seq[int]): string =
  var message = "orders:" & $request["game"].getInt() & ":" &
    $request["turn"].getInt() & ":"
  for action in actions:
    message.add(char(ord('0') + action div 10))
    message.add(char(ord('0') + action mod 10))
  blobFromSpriteChat(message)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: the game still owns every soldier's
  ## action, so a fastMode server can advance when both seats acknowledge.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    jev = getEnv("PLAYER_JEV") == "1"
    external = numeric or jev
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif numeric: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "pincer"
  echo "magent-battle player: kind=",
    (if external: "external" elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "pincer"),
    " label=", label
  if external and (prompt.len > 0 or scripted.len > 0) or numeric and jev:
    quit("Choose exactly one player policy mode", 1)
  randomize()
  let session = "magent:" & $getCurrentProcessId() & ":" &
    $getTime().toUnix() & ":" & $rand(high(int))

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The episode runner starts the players at the same
    ## instant as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "magent-battle player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("magent-battle player: game never accepted a connection", 1)
  echo "magent-battle player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES -- so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined -- and the lobby sends frames to a socket before it is
  # admitted, so both the first registration and a single re-send keyed on the
  # first received frame can land while the seat has no index yet (paintball
  # round 3, 2026-08-25). This end keeps re-sending for the first ~10 s of
  # frames; registering twice is harmless, the server just re-reads the same
  # fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external),
        BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external),
            BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request{"type"}.getStr() == "decision":
            let actions = if jev: chooseJevActions(request)
              else: chooseNumericActions(request, session)
            socket.send(actionBlob(request, actions), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "magent-battle player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # army for the whole episode and revives on reconnect. Bounded on both
    # counts, so this can never outlive the game or spin.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "magent-battle player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "magent-battle player: game is no longer listening, exiting cleanly"
      break
    echo "magent-battle player: reconnected, re-registering"
  quit(0)
