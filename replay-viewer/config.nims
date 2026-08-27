import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped static bundle owns the WASM
# runtime in a Dedicated Worker, and node so CI can smoke-run that EXACT
# emitted module (tools/wasm_replay_smoke.cjs) -- wasm32-only failures
# (integer traps, address-space exhaustion) are invisible to the native tests.
#
# ABORTING_MALLOC is NON-NEGOTIABLE: with -d:useMalloc Nim never checks malloc
# for nil, and wasm32 has no memory protection, so a failed allocation would
# otherwise write a seq header through the nil pointer into address 0 --
# silently corrupting the module's own globals, which is how oversized replays
# died with an EMPTY error length. Aborting keeps linear memory intact, and the
# page reads magent_stage_ptr/len afterwards to report what the runtime was
# doing.
#
# The module is emitted NON-MODULARIZED as magent_replay.js and the Worker sets
# Module.onRuntimeInitialized. Never mix that with MODULARIZE/EXPORT_NAME from
# another starter's shell: the factory is then never called, nothing throws,
# and the page sits on "Loading replay..." forever (cogame-lantern, 2026-08-23).
switch(
  "passL",
  (&"""
  -o {distDir / "magent_replay.js"}
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_magent_load_replay,_magent_frame,_magent_input,_magent_packet_ptr,_magent_packet_len,_magent_mismatch_tick,_magent_error_ptr,_magent_error_len,_magent_stage_ptr,_magent_stage_len
  """).replace("\n", " ")
)
