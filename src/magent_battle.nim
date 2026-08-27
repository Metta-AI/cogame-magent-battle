## The magent-battle game server entrypoint.
##
## SEED RANDOMISATION HAPPENS HERE, before `config.update`, so every
## seed-derived draw follows the FINAL seed (the starter's rule). `battle` uses
## the seed for nothing today -- spawns are a pure function of mapSize, the
## controller is deterministic and resolution order is by unit id -- but it is
## recorded in the replay config and in `results.seed`, and the `battlefield`
## and `gather` variants will need it.

import std/[os, random, strutils]
import bitworld/runtime
import magent/[sim, server]

when isMainModule:
  let runtimeCfg = readRuntimeConfig()
  var config = defaultGameConfig()
  randomize()
  config.seed = rand(1 .. 2_000_000_000)
  config.update(runtimeCfg.config)
  config.clampConfig()

  let replayOut = block:
    let path = outputPathFromCogameEnv(
      CogameSaveReplayUriEnv, "magent-battle.replay")
    if path.len > 0: path
    else: getEnv("MAGENT_REPLAY_OUT").strip()
  if replayOut.len > 0:
    let dir = replayOut.parentDir()
    if dir.len > 0:
      createDir(dir)

  runServerLoop(
    host = runtimeCfg.host,
    port = runtimeCfg.port,
    initialConfig = config,
    saveReplayPath = replayOut,
    loadReplayPath = (if runtimeCfg.replayMode:
        pathFromCogameEnv(CogameLoadReplayUriEnv) else: ""),
    runtimeConfig = runtimeCfg
  )
