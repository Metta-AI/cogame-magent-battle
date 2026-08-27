// Runs the EXACT emitted wasm module headless under Node against a committed
// fixture replay. wasm32-only failures -- integer traps, address-space
// exhaustion, a bad free through -d:useMalloc -- are invisible to the native
// test shards, and the bundle's own browser smoke only proves the page draws.
//
//   node tools/wasm_replay_smoke.cjs <dist dir> <replay path> [frames]
//
// It loads magent_replay.js (non-modularized, ENVIRONMENT includes node), calls
// magent_load_replay on the bytes, steps magent_frame the requested number of
// times, and fails if any frame returns < 0, if the packet is ever empty, or if
// magent_mismatch_tick ever reports a divergence.
'use strict';

const fs = require('fs');
const path = require('path');

const distDir = process.argv[2] || 'replay-viewer/dist';
const replayPath = process.argv[3] || 'tests/replays/magent.replay';
const frames = Number(process.argv[4] || 400);

const modulePath = path.resolve(distDir, 'magent_replay.js');
if (!fs.existsSync(modulePath)) {
  console.error(`missing ${modulePath}`);
  process.exit(1);
}

const Module = {
  locateFile: (file) => path.resolve(distDir, file),
  onAbort: (what) => {
    console.error(`wasm aborted: ${what}`);
    process.exit(1);
  },
  onRuntimeInitialized: () => { run(); },
};
global.Module = Module;

function decode(ptrFn, lenFn) {
  const length = Module[lenFn]();
  if (!length) return '';
  const pointer = Module[ptrFn]();
  return Buffer.from(Module.HEAPU8.slice(pointer, pointer + length))
    .toString('utf8');
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._magent_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (!loaded) {
    console.error('magent_load_replay failed: ' +
      (decode('_magent_error_ptr', '_magent_error_len') ||
       decode('_magent_stage_ptr', '_magent_stage_len')));
    process.exit(1);
  }
  let smallest = Infinity;
  for (let i = 0; i < frames; i++) {
    if (Module._magent_frame() < 0) {
      console.error('magent_frame failed: ' +
        decode('_magent_error_ptr', '_magent_error_len'));
      process.exit(1);
    }
    const length = Module._magent_packet_len();
    if (!length) {
      console.error(`empty packet at frame ${i}`);
      process.exit(1);
    }
    smallest = Math.min(smallest, length);
  }
  const mismatch = Module._magent_mismatch_tick();
  if (mismatch >= 0) {
    console.error(`replay hash mismatch at tick ${mismatch}`);
    process.exit(1);
  }
  const packet = JSON.parse(decode('_magent_packet_ptr', '_magent_packet_len'));
  if (!packet.mg || !Array.isArray(packet.mg.units)) {
    console.error('the final packet carries no board state');
    process.exit(1);
  }
  console.log(`wasm smoke ok: ${frames} frames, smallest packet ${smallest} ` +
    `bytes, tick ${packet.mg.tick}, alive ${packet.mg.alive.join(' v ')}`);
}

require(modulePath);
