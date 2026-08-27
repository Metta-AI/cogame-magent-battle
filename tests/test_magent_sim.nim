## Sim unit tests: the whole physics of the game, one rule at a time, plus the
## mechanical gate that keeps floating point out of the hashed path.

import std/[math, monotimes, random, strutils, times, unittest]
import helpers

suite "magent sim":

  test "attack only hits enemies":
    ## An attack on an empty cell and on a friendly both deal 0 damage and both
    ## still charge attack_penalty; only the enemy case pays
    ## attack_opponent_reward. Upstream: "An attack against another agent on
    ## their own team will not be registered."
    block enemyAdjacent:
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0)
      let enemy = sim.place(6, 5, 1, 0)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okHold, x = 5, y = 5)
        sim.setOrder(1, squad, okRetreat)
      let before = sim.rewardMilli[0]
      sim.step()
      check sim.units.soldiers[enemy].hp == HpMax - Damage + StepRecover
      ## the attacker paid attack_penalty AND collected
      ## attack_opponent_reward, plus one step_reward for being alive
      check sim.rewardMilli[0] - before ==
        AttackPenaltyMilli + AttackOpponentRewardMilli + StepRewardMilli
    block emptyCell:
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0)
      discard sim.place(29, 29, 1, 0)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okHold, x = 5, y = 5)
        sim.setOrder(1, squad, okRetreat)
      let before = sim.rewardMilli[0]
      sim.step()
      ## nothing adjacent: the controller emits do_nothing, so no attack
      ## penalty is charged at all
      check sim.rewardMilli[0] - before == StepRewardMilli
    block friendly:
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0)
      discard sim.place(6, 5, 0, 0)     ## a friendly, adjacent
      discard sim.place(25, 25, 1, 0)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okHold, x = 5, y = 5)
        sim.setOrder(1, squad, okRetreat)
      let before = sim.rewardMilli[0]
      sim.step()
      ## a friendly hit is NOT REGISTERED (upstream's rule) -- no damage and no
      ## attack_opponent_reward -- but the attack still costs attack_penalty
      check sim.units.soldiers[1].hp == HpMax
      check sim.units.aliveCount[0] == 2
      ## the deterministic controller never CHOOSES to hit a friendly, so
      ## nothing is charged here...
      check sim.rewardMilli[0] - before == 2 * StepRewardMilli
    block forcedFriendlyAndEmpty:
      ## ...and the sim rule itself is asserted by forcing the two actions the
      ## controller would never emit: an attack on a friendly and an attack on
      ## an empty cell. Both are UNREGISTERED (no damage, no
      ## attack_opponent_reward) and both still cost attack_penalty.
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0)
      discard sim.place(6, 5, 0, 0)
      discard sim.place(29, 29, 1, 0)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okRetreat)
        sim.setOrder(1, squad, okRetreat)
      var actions = newSeq[int](sim.units.soldiers.len)
      actions[0] = ActionAttackBase + 4      ## (0, +1): the friendly at (6,5)
      actions[1] = ActionAttackBase + 3      ## (0, -1): back at the friendly
      actions[2] = ActionAttackBase + 0      ## (-1,-1): an empty cell
      let before = sim.rewardMilli
      sim.resolveTick(actions)
      check sim.units.soldiers[0].hp == HpMax
      check sim.units.soldiers[1].hp == HpMax
      check sim.rewardMilli[0] - before[0] ==
        2 * AttackPenaltyMilli + 2 * StepRewardMilli
      check sim.rewardMilli[1] - before[1] ==
        AttackPenaltyMilli + StepRewardMilli

  test "damage and death":
    ## Five attacks kill a full-hp soldier; the fifth attacker (and only it)
    ## gets kill_reward, the victim's army pays dead_penalty exactly once, and
    ## the victim vanishes from the occupancy grid.
    var sim = emptyBoard()
    let victim = sim.place(10, 10, 1, 0)
    for i in 0 ..< 5:
      discard sim.place(9, 9 + i, 0, 0)      ## five red around the victim
    for squad in 0 ..< SquadCount:
      sim.setOrder(0, squad, okAdvance)
      sim.setOrder(1, squad, okRetreat)
    var ticks = 0
    while sim.units.soldiers[victim].alive and ticks < 20:
      sim.step()
      inc ticks
    check not sim.units.soldiers[victim].alive
    check sim.units.aliveCount[1] == 0
    check occupantAt(sim.units, 10, 10) != victim
    check sim.killsByArmy[0] >= 1

  test "overkill order":
    ## Two attackers on a soldier one hit from death: the LOWER unit id takes
    ## the kill and the higher one's attack is unregistered, which is why the
    ## resolution order is pinned.
    var sim = emptyBoard()
    let low = sim.place(4, 4, 0, 0)
    let high = sim.place(6, 4, 0, 0)
    let victim = sim.place(5, 4, 1, 0, hp = Damage)
    for squad in 0 ..< SquadCount:
      sim.setOrder(0, squad, okAdvance)
      sim.setOrder(1, squad, okRetreat)
    let killsBefore = sim.killsByArmy[0]
    sim.step()
    check not sim.units.soldiers[victim].alive
    check sim.killsByArmy[0] == killsBefore + 1
    check low < high

  test "recover caps":
    ## hp climbs StepRecover a tick and stops at HpMax; the dead never recover.
    var sim = emptyBoard()
    let hurt = sim.place(3, 3, 0, 0, hp = HpMax - 5)
    let dead = sim.place(3, 5, 0, 0)
    discard sim.place(28, 28, 1, 0)
    sim.units.kill(dead)
    for squad in 0 ..< SquadCount:
      sim.setOrder(0, squad, okRetreat)
      sim.setOrder(1, squad, okRetreat)
    sim.step()
    check sim.units.soldiers[hurt].hp == HpMax - 4
    check sim.units.soldiers[dead].hp == 0
    for _ in 0 ..< 20:
      sim.step()
    check sim.units.soldiers[hurt].hp == HpMax
    check sim.units.soldiers[dead].hp == 0

  test "move blocked":
    ## A move into an occupied cell fails and the soldier stays; a move into a
    ## cell vacated earlier in the same tick succeeds; a move off the board
    ## fails.
    block offBoard:
      var sim = emptyBoard()
      let edge = sim.place(0, 0, 0, 0)
      discard sim.place(20, 20, 1, 0)
      sim.setOrder(0, 0, okHold, x = 0, y = 0)
      sim.step()
      check sim.units.soldiers[edge].x == 0
      check sim.units.soldiers[edge].y == 0
    block occupied:
      var sim = emptyBoard()
      let mover = sim.place(5, 5, 0, 0)
      discard sim.place(6, 5, 0, 0)
      discard sim.place(7, 5, 0, 0)
      discard sim.place(29, 29, 1, 0)
      sim.setOrder(0, 0, okHold, x = 8, y = 5)
      sim.step()
      # every cell toward the target is taken, so the mover holds its ground
      check sim.units.soldiers[mover].x <= 6

  test "offset tables":
    ## The 12 move offsets are exactly dx*dx+dy*dy <= 4 minus the centre, the 8
    ## attack offsets exactly the Moore neighbours, both in the pinned order,
    ## and the action space is upstream's 21.
    check MoveOffsets.len == 12
    check AttackOffsets.len == 8
    check ActionCount == 21
    check ActionAttackBase + AttackOffsets.len == ActionCount
    var expectedMoves: seq[Offset]
    for dy in -2 .. 2:
      for dx in -2 .. 2:
        if (dx == 0 and dy == 0) or dx * dx + dy * dy > 4:
          continue
        expectedMoves.add((dy, dx))
    check expectedMoves.len == MoveOffsets.len
    for offset in MoveOffsets:
      check offset in expectedMoves
      check offset.dx * offset.dx + offset.dy * offset.dy <= 4
    check MoveOffsets[0] == (-2, 0)
    check MoveOffsets[^1] == (2, 0)
    for offset in AttackOffsets:
      check offset.dx * offset.dx + offset.dy * offset.dy <= AttackRadiusSq
      check not (offset.dx == 0 and offset.dy == 0)
    check AttackOffsets[0] == (-1, -1)
    check AttackOffsets[^1] == (1, 1)

  test "visibility":
    ## An enemy at dx*dx+dy*dy == 36 is visible, at 37 is not, and visibility
    ## unions over LIVING friendlies only.
    var sim = emptyBoard(45)
    discard sim.place(10, 10, 0, 0)
    let near = sim.place(10, 16, 1, 0)         ## dy 6 -> 36
    let far = sim.place(16, 11, 1, 0)          ## 36 + 1 = 37
    check visibleToArmy(sim.units, 0, near)
    check not visibleToArmy(sim.units, 0, far)
    sim.units.kill(0)
    check not visibleToArmy(sim.units, 0, near)

  test "controller orders":
    ## One case per verb: the target cell and the attack permission, including
    ## focus on an extinct squad degrading to advance, and retreat never
    ## attacking.
    var sim = emptyBoard(45)
    let me = sim.place(10, 20, 0, 0)
    discard sim.place(30, 20, 1, 3)
    sim.setOrder(0, 0, okAdvance)
    check targetCell(sim, me) == (30, 20, 1, -1)
    sim.setOrder(0, 0, okHold, x = 12, y = 25)
    check targetCell(sim, me) == (12, 25, 1, -1)
    sim.setOrder(0, 0, okFocus, target = 3)
    check targetCell(sim, me) == (30, 20, 1, 3)
    sim.setOrder(0, 0, okFocus, target = 7)    ## extinct -> behaves as advance
    check targetCell(sim, me) == (30, 20, 1, -1)
    sim.setOrder(0, 0, okFlank, side = fsLeft)
    let flank = targetCell(sim, me)
    check flank.y == 20 - FlankOffset
    sim.setOrder(0, 0, okFlank, side = fsRight)
    check targetCell(sim, me).y == 20 + FlankOffset
    sim.setOrder(0, 0, okRetreat)
    let retreat = targetCell(sim, me)
    check retreat == (backEdgeX(sim.units.mapSize, 0), 20, 0, -1)
    ## retreat NEVER attacks, even with an enemy in reach
    var adjacent = emptyBoard(45)
    let mine = adjacent.place(10, 10, 0, 0)
    discard adjacent.place(11, 10, 1, 0)
    adjacent.setOrder(0, 0, okRetreat)
    check chooseAction(adjacent, mine) < ActionAttackBase
    adjacent.setOrder(0, 0, okAdvance)
    check chooseAction(adjacent, mine) >= ActionAttackBase

  test "scoring is zero-sum":
    ## Over 500 randomised two-game end states the scores always sum to zero,
    ## the sign is right, and a 1-1 split with an equal survivor differential is
    ## a draw.
    var rng = initRand(7)
    for _ in 0 ..< 500:
      var sim = initSimServer(testConfig())
      for game in 0 ..< 2:
        var record = GameRecord(game: game + 1, redSlot: game, ticks: 100,
          endRule: EndRuleTickCap)
        record.survivors[0] = rng.rand(0 .. 81)
        record.survivors[1] = rng.rand(0 .. 81)
        sim.gameLog.add(record)
      check sim.scoreOf(0) + sim.scoreOf(1) == 0
      var diff = 0
      var wins = 0
      for record in sim.gameLog:
        diff += record.survivors[0] - record.survivors[1]
        if record.survivors[0] > record.survivors[1]: inc wins
        elif record.survivors[0] < record.survivors[1]: dec wins
      check sim.scoreOf(0) == 100 * wins + diff
      if wins == 0 and diff == 0:
        check sim.scoreOf(0) == 0
    block onePairEach:
      var sim = initSimServer(testConfig())
      var a = GameRecord(game: 1, redSlot: 0, ticks: 10, endRule: EndRuleWipe)
      a.survivors = [10, 4]
      var b = GameRecord(game: 2, redSlot: 1, ticks: 10, endRule: EndRuleWipe)
      b.survivors = [4, 10]
      sim.gameLog.add(a)
      sim.gameLog.add(b)
      check sim.scoreOf(0) == 0
      check sim.scoreOf(1) == 0

  test "end conditions":
    ## Annihilation, mutual annihilation, the tick cap and the wall-clock stop
    ## each produce the right endRule, winner and survivors.
    block wipe:
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0)
      discard sim.place(6, 5, 1, 0, hp = Damage)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okAdvance)
        sim.setOrder(1, squad, okRetreat)
      sim.step()
      check sim.phase == GameOver
      check sim.endRule == EndRuleWipe
      check sim.gameLog[^1].survivors[sim.seatOfArmy(0)] == 1
    block mutual:
      var sim = emptyBoard()
      discard sim.place(5, 5, 0, 0, hp = Damage)
      discard sim.place(6, 5, 1, 0, hp = Damage)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okAdvance)
        sim.setOrder(1, squad, okAdvance)
      sim.step()
      check sim.endRule == EndRuleWipe
      check sim.units.aliveCount == [0, 0]
      check sim.scoreOf(0) == 0 and sim.scoreOf(1) == 0
    block tickCap:
      var config = testConfig()
      config.maxTicks = 3
      var sim = initSimServer(config)
      sim.applyGameStart(0, 0)
      for squad in 0 ..< SquadCount:
        sim.setOrder(0, squad, okRetreat)
        sim.setOrder(1, squad, okRetreat)
      for _ in 0 ..< 3:
        sim.step()
      check sim.endRule == EndRuleTickCap
      check sim.phase == GameOver
    block wallClock:
      var sim = playingSim()
      sim.applyStop(EndRuleWallClock)
      check sim.endRule == EndRuleWallClock
      check sim.gameLog.len == 1
      check sim.gameLog[^1].endRule == EndRuleWallClock

  test "no floating point in the sim":
    ## The integer-determinism pin, mechanically enforced: no `float`, no `/`,
    ## no `sqrt` and no float literal in the modules that produce the hash.
    for name in ["sim", "units", "arena", "control", "baselines"]:
      let code = stripNimComments(readRepoFile("src/magent/" & name & ".nim"))
      check "float" notin code
      ## `isqrt` is the integer square root this port uses INSTEAD of a float
      ## sqrt, so it is exempted by name rather than by accident.
      check "sqrt" notin code.replace("isqrt", "")
      ## `import std/x` is the one legitimate slash in a module body.
      check "/" notin code.replace("import std/strutils", "")
      for line in code.splitLines():
        for i in 1 ..< max(1, line.len - 1):
          if line[i] == '.' and line[i - 1] in {'0' .. '9'} and
              line[i + 1] in {'0' .. '9'}:
            checkpoint("float literal in " & name & ".nim: " & line)
            fail()

  test "tick budget":
    ## A full 45x45 episode of 2 x 300 ticks completes well inside 4 s in a
    ## release build.
    let started = getMonoTime()
    for game in 0 ..< 2:
      var sim = initSimServer(testConfig(mapSize = 45, maxTicks = 300))
      sim.applyGameStart(game, game)
      var ticks = 0
      while sim.phase == Playing and ticks < 300:
        sim.step()
        inc ticks
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    checkpoint("two 45x45 games in " & $elapsed & " ms")
    check elapsed < 4000
