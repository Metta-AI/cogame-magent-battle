## Frozen numeric commander policy over the ordinary seat observation.

import std/[json, os]
import curly
import policy_actions
import sim_types

proc chooseNumericActions*(request: JsonNode, session: string): seq[int] =
  let endpoint = getEnv("PLAYER_NUMERIC_URL")
  doAssert endpoint.len > 0
  var mask = newJArray()
  for _ in 0 ..< SquadCount * ActionCount: mask.add(%true)
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0: headers["authorization"] = "Bearer " & key
  let body = %*{"session": session, "seat": request["seat"],
    "decision_id": (request["game"].getInt() - 1) * 1000 +
      request["turn"].getInt(),
    "values": values(request["observation"]), "action_mask": mask}
  let response = newCurly().post(endpoint, headers, $body,
    max(1, (request["deadline_ms"].getInt() - 1000) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "numeric policy HTTP " & $response.code)
  for action in parseJson(response.body)["actions"]:
    result.add(action.getInt())
  if not validActions(result):
    raise newException(ValueError, "numeric policy returned illegal actions")
