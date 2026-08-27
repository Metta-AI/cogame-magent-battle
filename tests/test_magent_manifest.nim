## Manifest pins. Every one of these corresponds to a release that was rejected
## by the platform validator with repo CI green, so each check names its scar.

import std/[json, os, sets, strutils, tables, unittest]
import helpers
import magent/roster

suite "magent manifest":

  test "num_agents is inside every game_config and nowhere else":
    ## `CoworldVariant` is additionalProperties:false and the platform reads
    ## only `game_config.num_agents` (goofspiel-oshi-zumo 0.1.0).
    let manifest = manifestJson()
    var seen = 0
    for variant in manifest["variants"]:
      check not variant.hasKey("num_agents")
      check variant["game_config"]["num_agents"].getInt() == SeatCount
      inc seen
    check seen == 2
    check manifest["certification"]["game_config"]["num_agents"].getInt() ==
      SeatCount
    check manifest["game"]["config_schema"]["properties"]["num_agents"][
      "minimum"].getInt() == SeatCount
    check manifest["game"]["config_schema"]["properties"]["num_agents"][
      "maximum"].getInt() == SeatCount

  test "no game_config carries a literal tokens array":
    ## matriculate rejects "game_config must not include runner-managed tokens"
    ## (knights-archers 0.1.0), while config_schema keeps REQUIRING tokens
    ## because the runner injects them.
    let manifest = manifestJson()
    for variant in manifest["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not manifest["certification"]["game_config"].hasKey("tokens")
    check "tokens" in manifest["game"]["config_schema"]["required"].to(
      seq[string])

  test "every array in config_schema declares minItems and maxItems":
    ## Not just `required` membership -- every ARRAY property needs bounds
    ## (tandem 0.1.0).
    let properties = manifestJson()["game"]["config_schema"]["properties"]
    var arrays = 0
    for name, schema in properties.pairs:
      if schema{"type"}.getStr() != "array":
        continue
      inc arrays
      checkpoint("config_schema.properties." & name)
      check schema.hasKey("minItems")
      check schema.hasKey("maxItems")
    check arrays >= 3

  test "the certification fixture's four seat counts agree":
    ## The four SEAT-COUNT invariants tools/ci/docker_smoke.sh cross-checks.
    let certification = manifestJson()["certification"]
    check certification["players"].len == SeatCount
    check certification["game_config"]["players"].len == SeatCount
    check certification["game_config"]["num_agents"].getInt() == SeatCount
    ## and every DECLARED player occupies a certification slot (raid 0.1.2)
    var declared: HashSet[string]
    for player in manifestJson()["player"]:
      declared.incl(player["id"].getStr())
    var seated: HashSet[string]
    for entry in certification["players"]:
      seated.incl(entry["player_id"].getStr())
    check declared == seated
    check declared.len == 2

  test "the 0.1.42 upload contract":
    let manifest = manifestJson()
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check manifest.hasKey("episode_timeout_minutes")      ## TOP level
    check not manifest["game"].hasKey("episode_timeout_minutes")
    check not manifest.hasKey("version")                  ## no top-level version
    check not manifest["game"].hasKey("display_name")
    check not manifest["game"].hasKey("tags")             ## pistonball 0.1.0
    check manifest["game"]["description"].getStr().len > 40
    check manifest["game"]["owner"].getStr().len > 0
    check manifest["game"]["name"].getStr() == GameName
    check manifest["game"]["runnable"]["type"].getStr() == "game"
    check manifest["game"]["runnable"]["run"][0].getStr() == "/bin/magent-battle"
    ## replay_viewer UNDER game, and the static bundle -- never a pod
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    ## the secret namespace must equal game.name EXACTLY (cooperative-hunting)
    check manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & GameName & "/anthropic_api_key"
    for variant in manifest["variants"]:
      check variant.hasKey("description")
      check variant["description"].getStr().len > 20

  test "protocols and docs are objects, not bare strings":
    ## garble v0.1.0: repo CI does not catch it, the platform validator does.
    let game = manifestJson()["game"]
    for key in ["player", "global"]:
      check game["protocols"].hasKey(key)
      check game["protocols"][key].kind == JObject
      check game["protocols"][key]["type"].getStr().len > 0
      check game["protocols"][key]["value"].getStr().startsWith("https://")
    ## docs are INLINE TEXT, the shape the acceptance checklist spells (item
    ## 10) -- and inline means the manifest carries a COPY, so each value is
    ## asserted equal to the file it came from. Regenerate with
    ## `python3 tools/embed_manifest_docs.py` after editing any of them.
    check game["docs"]["readme"].kind == JObject
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["readme"]["value"].getStr() == readRepoFile("README.md")
    check game["docs"]["pages"].len == 2
    let pageFiles = {
      "rules.md": "docs/RULES.md",
      "porting.md": "docs/PORTING-MAGENT.md"}.toTable
    for page in game["docs"]["pages"]:
      check page.hasKey("id")
      check page.hasKey("title")
      check page["title"].getStr().len > 0
      check page["content"].kind == JObject
      check page["content"]["type"].getStr() == "text"
      let id = page["id"].getStr()
      checkpoint("docs page " & id)
      check id in pageFiles
      check page["content"]["value"].getStr() == readRepoFile(pageFiles[id])

  test "bundled players declare a cpu limit of at least 1":
    ## Upload 400 "player cpu limit '500m' is below the minimum of '1'"
    ## (pistonball 0.1.1).
    for player in manifestJson()["player"]:
      checkpoint(player["id"].getStr())
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["resources"]["requests"]["cpu"].getStr().len > 0
      check player["run"][0].getStr() == "/bin/magent-battle-player"
      check player.hasKey("description")
      check player.hasKey("source_url")
      check player["type"].getStr() == "player"

  test "the image placeholder is derived from the compose service name":
    ## `{{GAME_IMAGE}}` is not a thing: the placeholder comes from the compose
    ## SERVICE (lantern 0.1.0).
    let compose = readRepoFile("compose.yaml")
    check "magent_battle:" in compose
    check "image: coworld-magent-battle:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    ## exactly ONE service
    var services = 0
    for line in compose.splitLines():
      if line.startsWith("  ") and line.endsWith(":") and
          not line.startsWith("    "):
        inc services
    check services == 1
    let raw = readRepoFile("coworld_manifest_template.json")
    check "{{MAGENT_BATTLE_IMAGE}}" in raw
    check "{{GAME_IMAGE}}" notin raw

  test "every wallClockBudgetSeconds settles inside 60 percent of the timeout":
    ## The game container never receives COWORLD_TIMEOUT_SECONDS, so it assumes
    ## 1200 s and must settle inside 720. Every shipped budget is <= 660.
    let manifest = manifestJson()
    let timeoutSeconds = manifest["episode_timeout_minutes"].getInt() * 60
    check timeoutSeconds >= 1200
    for variant in manifest["variants"]:
      let budget = variant["game_config"]["wallClockBudgetSeconds"].getInt()
      checkpoint(variant["id"].getStr() & " budget " & $budget)
      check budget <= 660
      check budget * 100 <= timeoutSeconds * 60
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getInt() <= 660
    check manifest["game"]["config_schema"]["properties"][
      "wallClockBudgetSeconds"]["maximum"].getInt() == 660

  test "every variant's game_config constructs a valid GameConfig":
    let manifest = manifestJson()
    for variant in manifest["variants"]:
      var config = defaultGameConfig()
      config.update($variant["game_config"])
      checkpoint(variant["id"].getStr())
      var clamped = config
      clamped.clampConfig()
      ## clamping must be an IDENTITY on a shipped config: a variant that only
      ## works because it was silently repaired is a variant nobody tested
      check clamped == config
      check config.numAgents == SeatCount
      check config.maxGames == 2
      check config.fastMode
      check not config.showPlayerLabels
      check config.turnTicks > 0
      check config.maxTicks div config.turnTicks >= 10

  test "the results schema is closed and matches armyResultsJson exactly":
    var config = testConfig()
    var sim = initSimServer(config)
    sim.applyGameStart(0, 0)
    sim.applyStop(EndRuleWallClock)
    var produced: HashSet[string]
    for key, _ in parseJson(sim.armyResultsJson()).pairs:
      produced.incl(key)
    var declared: HashSet[string]
    for key, _ in manifestJson()["game"]["results_schema"]["properties"].pairs:
      declared.incl(key)
    check produced == declared
    check manifestJson()["game"]["results_schema"][
      "additionalProperties"].getBool() == false
    let reasons = manifestJson()["game"]["results_schema"]["properties"][
      "reason"]["enum"].to(seq[string])
    check reasons == @[ReasonComplete, ReasonDeadline, ReasonFault]

  test "the policy set is two prompt champions and two scripted fillers":
    let policies = parseJson(readRepoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var ownedByDaveey1 = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/magent-battle-player"
      check policy["name"].getStr().startsWith("magent-battle-")
      ## no USE_BEDROCK: the LLM call is made by the GAME pod, not the player
      check not policy["env"].hasKey("USE_BEDROCK")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in ["line", "pincer"]
      if policy{"player"}.getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d":
        inc ownedByDaveey1
        check policy["env"].hasKey("PLAYER_PROMPT")
    check prompts == 2
    check scripted == 2
    check ownedByDaveey1 == 1
    ## the two champion prompts must actually differ
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()

  test "the release and submit workflows expose the inputs phase 40 and 50 use":
    let release = readRepoFile(".github/workflows/coworld-release.yml")
    for input in ["version:", "policies:", "put_secret:", "skip_certify:"]:
      check input in release
    check "release-result" in release
    check "\"player\"" in release or "'player'" in release
    check "--timeout-seconds 300" in release
    let submit = readRepoFile(".github/workflows/coworld-submit.yml")
    for input in ["player_id:", "policy:", "league_id:"]:
      check input in submit
    check "submit-result" in submit
    let ci = readRepoFile(".github/workflows/ci.yml")
    check "SMOKE_REQUIRE_REPLAY_JSON" in ci
    check "viewer_smoke.mjs" in ci
    check "build_replay_viewer.sh" in ci
    ## no unsubstituted scaffold placeholder survived
    for placeholder in ["<slug>", "<IMAGE>", "<SEATS>"]:
      check placeholder notin ci
      check placeholder notin release
      check placeholder notin submit
      check placeholder notin readRepoFile("tools/ci/docker_smoke.sh")
      check placeholder notin readRepoFile("tools/ci/policies.json")

  test "both committed scripts are executable":
    ## `coworld build` hard-requires os.X_OK on the replay-viewer hook, and
    ## ci.yml invokes the smoke by path.
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      checkpoint(path)
      check repoFileExists(path)
      check fpUserExec in getFilePermissions(repoRoot() / path)
