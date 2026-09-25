## Jev chooses from the same finite commander catalog as numeric policies.

import std/[json, os, strutils]
import curly
import policy_actions
import sim_types

proc chooseJevActions*(request: JsonNode): seq[int] =
  let view = request["observation"]
  var questions = newJObject()
  for squad in 0 ..< SquadCount:
    var criteria = newJObject()
    for index, name in ActionNames:
      criteria[$index] = %("Order " & name & " for squad " &
        view["your_army"]["squads"][squad]["id"].getStr())
    questions["squad_" & $squad] = %*{"type": "choice",
      "instructions": "Choose one order for this squad from the catalog. " &
        "Focus numbers name enemy squads; hold positions are map sectors.",
      "criteria": criteria}

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint, model, key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Magent Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $request["seat"].getInt()
  let body = %*{"model": model,
    "state": "You command one army in MAgent Battle. Choose nine squad " &
      "orders using only this seat's fogged observation: " & $view,
    "questions": questions}
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, min(30, (request["deadline_ms"].getInt() - 1000) div 1000)))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  for squad in 0 ..< SquadCount:
    let answer = answers["squad_" & $squad]
    let probabilities = answer["probabilities"]
    if answer["type"].getStr() != "choice" or
        probabilities.len != ActionCount or
        answer["confidence"].getFloat() < 0 or
        answer["confidence"].getFloat() > 1:
      raise newException(ValueError, "Jev returned the wrong action catalog")
    var best = -1.0
    var selected = -1
    var total = 0.0
    for index in 0 ..< ActionCount:
      let probability = probabilities[$index].getFloat()
      if probability < 0 or probability > 1:
        raise newException(ValueError, "Jev probability outside [0, 1]")
      total += probability
      if probability > best:
        best = probability
        selected = index
    if abs(total - 1) > ActionCount.float * 0.005 + 1e-6:
      raise newException(ValueError, "Jev probabilities do not sum to one")
    result.add(selected)
