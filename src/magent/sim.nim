## The step loop: the whole physics of the game and nothing else mutates the
## world. Re-exports the sim modules, so `import magent/sim` sees everything --
## the starter's layout, kept, and the reason the SAME module compiles natively
## for the server and to wasm for the replay viewer.
##
## PURE INTEGER (see arena.nim). Resolution order is pinned: all attacks in
## ascending unit id, then all moves in ascending unit id, then recovery.

import sim_types, sim_config, upstream, arena, units, events, sim_state,
  directives, control

export sim_types, sim_config, upstream, arena, units, events, sim_state,
  directives, control

proc evaluateEnd*(sim: var SimServer) =
  ## The game-end conditions, evaluated at the end of a tick. Annihilation
  ## first (both armies at once is a draw), then the tick cap.
  if sim.phase != Playing:
    return
  if sim.units.aliveCount[0] == 0 or sim.units.aliveCount[1] == 0:
    sim.wipedArmy =
      if sim.units.aliveCount[0] == 0 and sim.units.aliveCount[1] == 0: 2
      elif sim.units.aliveCount[0] == 0: 0
      else: 1
    sim.emitEvent(Wipe, amount = sim.wipedArmy)
    sim.bankGame(EndRuleWipe)
  elif sim.tick >= sim.config.maxTicks:
    sim.bankGame(EndRuleTickCap)

proc applyStop*(sim: var SimServer, endRule: string) =
  ## The load-bearing stop. A wall-clock or fault stop cannot be re-derived
  ## from sim state, so it is written to the replay as one record and applied
  ## by THIS proc on record AND on playback -- which is what keeps the hash
  ## chain clean at the stop tick (the particle-worlds scar).
  if sim.phase == GameOver:
    return
  sim.bankGame(endRule)

proc chooseActions*(sim: SimServer): seq[int] =
  ## One action per living soldier, in ascending unit id, from the snapshot
  ## world -- no rule in `resolveTick` reads a partially updated board.
  result = newSeq[int](sim.units.soldiers.len)
  for id in 0 ..< sim.units.soldiers.len:
    result[id] =
      if sim.units.soldiers[id].alive: chooseAction(sim, id)
      else: ActionDoNothing

proc resolveTick*(sim: var SimServer, actions: seq[int]) =
  ## Steps 2-4 of one MAgent cycle, given the actions. Split out from `step` so
  ## `tests/test_magent_sim.nim` can force an action the deterministic
  ## controller would never choose -- an attack on an empty cell or on a
  ## friendly -- and assert upstream's not-registered rule directly.
  if sim.phase != Playing:
    return
  inc sim.tick
  inc sim.episodeTick

  let aliveStart = sim.units.aliveCount
  for army in 0 ..< 2:
    sim.rewardMilli[army] += aliveStart[army] * StepRewardMilli
  # Who was alive at the START of the tick. The attack phase reads THIS, not
  # the live flags: a soldier's action was chosen from the snapshot, so a
  # soldier killed by a lower id earlier in the same phase still lands the blow
  # it had already thrown -- which is what makes mutual annihilation reachable
  # and keeps the phase a function of the snapshot rather than of its own
  # partial results.
  var aliveAtStart = newSeq[bool](sim.units.soldiers.len)
  for id in 0 ..< sim.units.soldiers.len:
    aliveAtStart[id] = sim.units.soldiers[id].alive

  # 2. attacks, ascending attacker id. A hit on an empty cell or a friendly is
  #    NOT REGISTERED (upstream's rule) but still costs attack_penalty.
  for id in 0 ..< sim.units.soldiers.len:
    if not aliveAtStart[id]:
      continue
    let action = actions[id]
    if action < ActionAttackBase:
      continue
    let
      army = sim.units.soldiers[id].army
      offset = AttackOffsets[action - ActionAttackBase]
      tx = sim.units.soldiers[id].x + offset.dx
      ty = sim.units.soldiers[id].y + offset.dy
    sim.rewardMilli[army] += AttackPenaltyMilli
    let occupant = occupantAt(sim.units, tx, ty)
    if occupant < 0 or not sim.units.soldiers[occupant].alive or
        sim.units.soldiers[occupant].army == army:
      continue
    sim.rewardMilli[army] += AttackOpponentRewardMilli
    sim.units.soldiers[occupant].hp -= Damage
    sim.emitEvent(Attack, source = id, target = occupant, amount = Damage)
    if sim.units.soldiers[occupant].hp <= 0:
      let victimArmy = sim.units.soldiers[occupant].army
      sim.units.kill(occupant)
      inc sim.killsByArmy[army]
      sim.rewardMilli[army] += KillRewardMilli
      sim.rewardMilli[victimArmy] += DeadPenaltyMilli
      sim.lastKills.add((sim.tick, id, occupant, tx, ty))
      sim.emitEvent(Kill, source = id, target = occupant)

  # 3. moves, ascending unit id. A destination freed in step 2, or by an
  #    earlier mover this tick, is available.
  for id in 0 ..< sim.units.soldiers.len:
    if not sim.units.soldiers[id].alive:
      continue
    let action = actions[id]
    if action < ActionMoveBase or action >= ActionAttackBase:
      continue
    let
      offset = MoveOffsets[action - ActionMoveBase]
      nx = sim.units.soldiers[id].x + offset.dx
      ny = sim.units.soldiers[id].y + offset.dy
    if not onBoard(sim.units.mapSize, nx, ny):
      continue
    if occupantAt(sim.units, nx, ny) >= 0:
      continue
    sim.units.moveTo(id, nx, ny)

  # 4. recovery, capped at HpMax. The dead never recover.
  for id in 0 ..< sim.units.soldiers.len:
    if sim.units.soldiers[id].alive:
      sim.units.soldiers[id].hp =
        min(HpMax, sim.units.soldiers[id].hp + StepRecover)

  sim.evaluateEnd()

proc step*(sim: var SimServer) =
  ## One MAgent cycle: choose, then resolve.
  if sim.phase != Playing:
    return
  sim.resolveTick(sim.chooseActions())

proc applyGameStart*(sim: var SimServer, gameIndex, redSlot: int) =
  ## Starts one game. Recorded as a `gameStart` record and applied by THIS
  ## proc on record and on playback, so the side swap re-derives exactly.
  if gameIndex > 0:
    sim.resetToLobby()
  sim.gameIndex = gameIndex
  sim.redSlot = redSlot
  sim.startGame()

proc advanceFrame*(sim: var SimServer) =
  ## ONE server frame. The single advance proc both the live loop and the
  ## replay player call, which is what keeps the hash chain aligned across
  ## lobby, play and the game-over hold.
  case sim.phase
  of Lobby: inc sim.lobbyTicks
  of Playing: sim.step()
  of GameOver: inc sim.gameOverHold
  if sim.phase != Playing:
    inc sim.episodeTick

proc applyOrders*(sim: var SimServer, seat: int, directive: ArmyDirective) =
  ## Installs one seat's orders. A squad the directive does not name keeps its
  ## previous order -- the directive already carries it, because the parser
  ## starts from the previous one.
  sim.directives[seat] = directive
  sim.haveDirective[seat] = true

proc squadIsExtinct*(sim: SimServer, seat, squad: int): bool =
  squadStat(sim.units, sim.armyOfSeat(seat), squad).alive == 0
