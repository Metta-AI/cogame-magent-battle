// broadcast_core.js — magent-battle board renderer and state channel.
//
// Forked from coworld-ctf/client/broadcast_core.js. KEPT, function for
// function: the module shape (a dependency-free IIFE publishing
// `window.BroadcastCore.create`), the canvas/DPR sizing, the whole-board
// camera, the status/text callback contract, the feed queue and `pushFeed`'s
// SIGNATURE, the beat and lull plumbing, the `?embed=1` path, the websocket
// mode the native server page uses, and the `getPaceStats()` shape the static
// adapter mirrors. The starter's wire-constants global read is renamed to
// `window.MAGENT_WIRE`, emitted by tools/gen_wire_constants.nim.
//
// DELETED: the Bitworld sprite-protocol compositor and every ctf-specific
// draw call (flags, paint, hills, hearts, grenades) and the whole FPV
// pipeline. This game has none of them, and its board is a 45x45 INTEGER GRID
// rather than a pixel arena, so the wire is one UTF-8 JSON state object per
// frame instead of a binary sprite stream.
//
// ADDED: drawBattlefield, drawHeat, drawFrontLine.
//
// The native replay page runs this core in a Window. The static bundle runs
// the SAME file in a Dedicated Worker with an OffscreenCanvas. One
// implementation, so a rendering fix cannot drift between the two delivery
// modes.

(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;
  var requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 1000 / 60); };

  var WIRE = globalScope.MAGENT_WIRE || {};
  var SPEEDS = WIRE.speeds || [1, 2, 4, 8];
  var FPS = WIRE.fps || 30;

  var RED = '#e0523a';
  var BLUE = '#3f7cc4';
  var PAPER = '#f2e8d8';
  var CHALK = 'rgba(242,232,216,0.72)';

  var SCORCH_FRAMES = 60;   // a dead cell keeps its mark this long
  var FLASH_FRAMES = 6;     // and flashes white for this long first

  function createCanvasSurface() {
    if (typeof document !== 'undefined') return document.createElement('canvas');
    if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(1, 1);
    throw new Error('Canvas rendering is unavailable in this execution context');
  }

  // Asset base. This file is served from two places and a leading slash is
  // only correct at one of them:
  //   native server, page or proxied  ->  <prefix>/client/…
  //   the STATIC WASM BUNDLE          ->  the assets sit next to the worker
  var ART_BASE = (typeof document === 'undefined')
    ? './'
    : (location.pathname.replace(/\/clients?\/[^/]*$/, '') + '/client/');

  function loadBitmap(name) {
    return fetch(ART_BASE + name, { credentials: 'omit' })
      .then(function (r) {
        if (!r.ok) throw new Error(name + ': HTTP ' + r.status);
        return r.blob();
      })
      .then(function (b) { return createImageBitmap(b); });
  }

  // Soldier chips are BAKED ONCE at load: three sizes x three hp-brightness
  // bands per team = 18 pre-baked chips, so drawing 162 soldiers a frame is
  // 162 blits and never a per-soldier rasterisation.
  var CHIP_SIZES = [6, 10, 16];
  var CHIP_BANDS = [0.55, 0.78, 1.0];

  function bakeChips(bitmap, rim) {
    var chips = [];
    for (var s = 0; s < CHIP_SIZES.length; s++) {
      chips[s] = [];
      for (var b = 0; b < CHIP_BANDS.length; b++) {
        var size = CHIP_SIZES[s];
        var surface = createCanvasSurface();
        surface.width = size;
        surface.height = size;
        var ctx = surface.getContext('2d');
        ctx.clearRect(0, 0, size, size);
        if (bitmap) {
          ctx.globalAlpha = CHIP_BANDS[b];
          ctx.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height,
            0, 0, size, size);
          ctx.globalAlpha = 1;
        } else {
          ctx.fillStyle = rim;
          ctx.globalAlpha = CHIP_BANDS[b];
          ctx.fillRect(1, 1, size - 2, size - 2);
          ctx.globalAlpha = 1;
        }
        // 1 px team rim, so two adjacent soldiers of opposite armies never
        // read as one blob at 8 px per cell.
        ctx.strokeStyle = rim;
        ctx.lineWidth = 1;
        ctx.strokeRect(0.5, 0.5, size - 1, size - 1);
        chips[s][b] = surface;
      }
    }
    return chips;
  }

  function BroadcastCore(config) {
    var canvas = config.canvas;
    var onText = config.onText || function () {};
    var onStatus = config.onStatus || function () {};
    var onFirstFrame = config.onFirstFrame || function () {};
    var onTransform = config.onTransform || function () {};
    var onSendPacket = config.onSendPacket || null;

    var ctx = canvas ? canvas.getContext('2d') : null;
    var viewport = {
      width: config.viewportWidth || 1,
      height: config.viewportHeight || 1,
      dpr: config.devicePixelRatio || 1
    };
    var state = null;
    var firstFrameSent = false;
    var running = false;
    var socket = null;
    var draws = 0;
    var scorch = [];          // {x, y, age, army}
    var frontTrail = [];      // last three front-line polylines
    var heatOn = true;
    var tiny = false;
    var chips = { 0: null, 1: null };
    var floorBitmap = null;
    var floorBake = null;
    var floorBakeKey = '';
    var assetsReady = false;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 1, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };

    // ---- the feed queue -----------------------------------------------------
    // pushFeed's SIGNATURE is load-bearing: a drift here threw mid-replay and
    // latched the static adapter into `failed` with the scrubber still
    // seekable, so every static gate passed (cogball 0.1.4).
    var paceQueue = [];
    function pushFeed(text) {
      if (text === undefined || text === null) return;
      paceQueue.push({ text: String(text) });
      while (paceQueue.length > 64) paceQueue.shift();
    }
    function drainFeed() {
      while (paceQueue.length) onText(paceQueue.shift().text);
    }

    function loadAssets() {
      // unit_<army>.png is the nano-banana render of the Softmax cog, one kit
      // per army (scripts/art/source/soldiers_sheet.png +
      // scripts/art/split_cog_sheet.py). soldier_<army>.png -- the starter's
      // own shipped cog art, carried byte for byte -- is the fallback, so a
      // missing derived sprite degrades to real art rather than to a square.
      function withFallback(preferred, fallback) {
        return loadBitmap(preferred).catch(function () {
          return loadBitmap(fallback).catch(function () { return null; });
        });
      }
      var wanted = [
        withFallback('unit_red.png', 'soldier_red.png'),
        withFallback('unit_blue.png', 'soldier_blue.png'),
        loadBitmap('arena_floor.png').catch(function () { return null; })
      ];
      return Promise.all(wanted).then(function (all) {
        chips[0] = bakeChips(all[0], RED);
        chips[1] = bakeChips(all[1], BLUE);
        floorBitmap = all[2];
        assetsReady = true;
      });
    }

    function setViewportSize(width, height, dpr) {
      viewport.width = Math.max(1, width || 1);
      viewport.height = Math.max(1, height || 1);
      viewport.dpr = dpr || viewport.dpr || 1;
      tiny = viewport.width <= 620;
      if (canvas) {
        canvas.width = Math.round(viewport.width * viewport.dpr);
        canvas.height = Math.round(viewport.height * viewport.dpr);
      }
      draw();
    }

    function boardGeometry() {
      var size = (state && state.mg && state.mg.board && state.mg.board.size)
        || 45;
      var w = canvas ? canvas.width : 1;
      var h = canvas ? canvas.height : 1;
      var cell = Math.max(1, Math.floor(Math.min(w, h) / size));
      var span = cell * size;
      return {
        size: size,
        cell: cell,
        span: span,
        left: Math.floor((w - span) / 2),
        top: Math.floor((h - span) / 2)
      };
    }

    function publishTransform(geo) {
      var next = {
        scale: geo.cell, offsetX: geo.left, offsetY: geo.top,
        nativeW: geo.span, nativeH: geo.span,
        zoom: 1, minZoom: 1, maxZoom: 1, fitScale: geo.cell,
        focusX: geo.size / 2, focusY: geo.size / 2,
        visW: geo.size, visH: geo.size
      };
      var changed = false;
      for (var key in next) {
        if (next[key] !== transform[key]) changed = true;
      }
      transform = next;
      if (changed) onTransform(transform);
    }

    // ---- drawBattlefield ----------------------------------------------------
    function bakeFloor(geo) {
      var key = geo.span + 'x' + geo.cell;
      if (floorBakeKey === key && floorBake) return floorBake;
      var surface = createCanvasSurface();
      surface.width = geo.span;
      surface.height = geo.span;
      var fc = surface.getContext('2d');
      fc.fillStyle = '#241a12';
      fc.fillRect(0, 0, geo.span, geo.span);
      if (floorBitmap) {
        var tile = Math.max(32, floorBitmap.width);
        for (var y = 0; y < geo.span; y += tile) {
          for (var x = 0; x < geo.span; x += tile) {
            fc.drawImage(floorBitmap, x, y, tile, tile);
          }
        }
      }
      // darkened 18 %, so the chips and the chalk read against it
      fc.fillStyle = 'rgba(11,7,4,0.18)';
      fc.fillRect(0, 0, geo.span, geo.span);
      // faint gridlines every 5 cells: the scale of the board with the HUD off
      fc.strokeStyle = 'rgba(242,232,216,0.07)';
      fc.lineWidth = 1;
      var every = (state && state.mg && state.mg.board
        && state.mg.board.gridEvery) || 5;
      for (var g = every; g < geo.size; g += every) {
        var p = g * geo.cell + 0.5;
        fc.beginPath(); fc.moveTo(p, 0); fc.lineTo(p, geo.span); fc.stroke();
        fc.beginPath(); fc.moveTo(0, p); fc.lineTo(geo.span, p); fc.stroke();
      }
      // 1 px chalk border
      fc.strokeStyle = 'rgba(242,232,216,0.28)';
      fc.strokeRect(0.5, 0.5, geo.span - 1, geo.span - 1);
      floorBake = surface;
      floorBakeKey = key;
      return surface;
    }

    function drawBattlefield(geo) {
      ctx.drawImage(bakeFloor(geo), geo.left, geo.top);
      var i;
      for (i = scorch.length - 1; i >= 0; i--) {
        var mark = scorch[i];
        mark.age++;
        if (mark.age > SCORCH_FRAMES) { scorch.splice(i, 1); continue; }
        var px = geo.left + mark.x * geo.cell;
        var py = geo.top + mark.y * geo.cell;
        if (mark.age <= FLASH_FRAMES) {
          ctx.fillStyle = 'rgba(242,232,216,' +
            (1 - mark.age / FLASH_FRAMES).toFixed(2) + ')';
        } else {
          ctx.fillStyle = 'rgba(24,14,8,' +
            (0.45 * (1 - mark.age / SCORCH_FRAMES)).toFixed(2) + ')';
        }
        ctx.fillRect(px, py, geo.cell, geo.cell);
      }
      var units = (state.mg && state.mg.units) || [];
      var sizeIndex = geo.cell >= 14 ? 2 : (geo.cell >= 9 ? 1 : 0);
      for (i = 0; i < units.length; i++) {
        var u = units[i];
        var army = u[2] | 0;
        var hp = u[3] | 0;
        var band = hp >= 800 ? 2 : (hp >= 450 ? 1 : 0);
        var kit = chips[army];
        var cx = geo.left + u[0] * geo.cell;
        var cy = geo.top + u[1] * geo.cell;
        if (kit) {
          ctx.drawImage(kit[sizeIndex][band], cx, cy, geo.cell, geo.cell);
        } else {
          ctx.fillStyle = army === 0 ? RED : BLUE;
          ctx.fillRect(cx, cy, geo.cell, geo.cell);
        }
        // 1 px hp pip along the bottom of the cell
        if (geo.cell >= 5) {
          ctx.fillStyle = army === 0 ? RED : BLUE;
          ctx.fillRect(cx, cy + geo.cell - 1,
            Math.max(1, Math.round(geo.cell * hp / 1000)), 1);
        }
      }
    }

    // ---- drawHeat ----------------------------------------------------------
    function drawHeat(geo) {
      if (!heatOn) return;
      var bins = tiny ? 5 : 9;
      var per = Math.ceil(geo.size / bins);
      var red = [];
      var blue = [];
      var i;
      for (i = 0; i < bins * bins; i++) { red[i] = 0; blue[i] = 0; }
      var units = (state.mg && state.mg.units) || [];
      var peak = 1;
      for (i = 0; i < units.length; i++) {
        var bx = Math.min(bins - 1, Math.floor(units[i][0] / per));
        var by = Math.min(bins - 1, Math.floor(units[i][1] / per));
        var at = by * bins + bx;
        if ((units[i][2] | 0) === 0) red[at]++; else blue[at]++;
        if (red[at] > peak) peak = red[at];
        if (blue[at] > peak) peak = blue[at];
      }
      var box = per * geo.cell;
      ctx.globalCompositeOperation = 'lighter';
      for (var by2 = 0; by2 < bins; by2++) {
        for (var bx2 = 0; bx2 < bins; bx2++) {
          var idx = by2 * bins + bx2;
          var x = geo.left + bx2 * box;
          var y = geo.top + by2 * box;
          if (red[idx] > 0) {
            ctx.fillStyle = 'rgba(224,82,58,' +
              (0.30 * red[idx] / peak).toFixed(3) + ')';
            ctx.fillRect(x, y, box, box);
          }
          if (blue[idx] > 0) {
            ctx.fillStyle = 'rgba(63,124,196,' +
              (0.30 * blue[idx] / peak).toFixed(3) + ')';
            ctx.fillRect(x, y, box, box);
          }
        }
      }
      ctx.globalCompositeOperation = 'source-over';
    }

    // ---- drawFrontLine -----------------------------------------------------
    // For each row y the midpoint between the rightmost living red soldier and
    // the leftmost living blue soldier within rows y +/- 2. Rows where one side
    // is absent leave a GAP, so a broken line literally shows a broken front.
    function frontLine(geo) {
      var units = (state.mg && state.mg.units) || [];
      var size = geo.size;
      var redMax = [];
      var blueMin = [];
      var y;
      for (y = 0; y < size; y++) { redMax[y] = -1; blueMin[y] = size; }
      for (var i = 0; i < units.length; i++) {
        var uy = units[i][1] | 0;
        var ux = units[i][0] | 0;
        if ((units[i][2] | 0) === 0) {
          if (ux > redMax[uy]) redMax[uy] = ux;
        } else if (ux < blueMin[uy]) blueMin[uy] = ux;
      }
      var pts = [];
      for (y = 0; y < size; y++) {
        var rm = -1;
        var bm = size;
        for (var d = -2; d <= 2; d++) {
          var yy = y + d;
          if (yy < 0 || yy >= size) continue;
          if (redMax[yy] > rm) rm = redMax[yy];
          if (blueMin[yy] < bm) bm = blueMin[yy];
        }
        if (rm < 0 || bm >= size) { pts.push(null); continue; }
        pts.push([(rm + bm) / 2, y]);
      }
      return pts;
    }

    function drawFrontLine(geo) {
      var pts = frontLine(geo);
      frontTrail.push(pts);
      while (frontTrail.length > 3) frontTrail.shift();
      for (var t = 0; t < frontTrail.length; t++) {
        var alpha = 0.22 + 0.5 * (t / Math.max(1, frontTrail.length - 1));
        ctx.strokeStyle = 'rgba(242,232,216,' + alpha.toFixed(2) + ')';
        ctx.lineWidth = tiny ? 2 : 1.5;
        ctx.beginPath();
        var open = false;
        var series = frontTrail[t];
        for (var i = 0; i < series.length; i++) {
          var p = series[i];
          if (!p) { open = false; continue; }
          var px = geo.left + (p[0] + 0.5) * geo.cell;
          var py = geo.top + (p[1] + 0.5) * geo.cell;
          if (!open) { ctx.moveTo(px, py); open = true; }
          else ctx.lineTo(px, py);
        }
        ctx.stroke();
      }
      ctx.strokeStyle = CHALK;
    }

    function draw() {
      if (!ctx || !state) return;
      var geo = boardGeometry();
      publishTransform(geo);
      ctx.fillStyle = '#120d09';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      drawBattlefield(geo);
      drawHeat(geo);
      drawFrontLine(geo);
      draws++;
    }

    function feedEventText(event, s) {
      var seats = (s.mg && s.mg.seats) || [];
      function alias(slot) {
        return (seats[slot] && seats[slot].alias) || ('SEAT ' + slot);
      }
      switch (event.k) {
        case 'order':
          return alias(event.slot) + ' ' + event.squad + ' \u2192 ' +
            event.verb + (event.arg ? ' ' + event.arg : '');
        case 'say':
          return (seats[event.slot] ? seats[event.slot].alias : 'SEAT') +
            ': "' + event.text + '"';
        case 'fallback':
          return alias(event.slot) + ' MISSED THE CALL \u2014 scripted orders (' +
            event.cause + ')';
        case 'firstblood':
          return 'FIRST BLOOD \u2014 ' + alias(event.slot);
        case 'rout':
          return alias(event.army) + " IS ROUTED \u2014 " + event.lost + ' DOWN';
        case 'wipe':
          return alias(event.army) + ' IS WIPED OUT';
        default:
          return '';
      }
    }

    function ingest(bytes) {
      var text;
      if (typeof bytes === 'string') text = bytes;
      else text = new TextDecoder('utf-8').decode(bytes);
      var next;
      try {
        next = JSON.parse(text);
      } catch (error) {
        throw new Error('state frame is not JSON: ' + error.message);
      }
      state = next;
      var deaths = (state.mg && state.mg.deaths) || [];
      for (var i = 0; i < deaths.length; i++) {
        scorch.push({ x: deaths[i].x, y: deaths[i].y, age: 0,
          army: deaths[i].v });
      }
      while (scorch.length > 600) scorch.shift();
      var events = (state.mg && state.mg.events) || [];
      for (var e = 0; e < events.length; e++) {
        var row = feedEventText(events[e], state);
        if (row) pushFeed(row);
      }
      // The state object itself is handed to the page as one text payload; the
      // page parses it once and drives the chrome.
      onText(text);
      drainFeed();
      draw();
      if (!firstFrameSent) {
        firstFrameSent = true;
        onFirstFrame();
      }
    }

    function sendCommand(textCommand) {
      if (onSendPacket) {
        onSendPacket(new TextEncoder().encode(String(textCommand)));
        return;
      }
      if (socket && socket.readyState === 1) socket.send(String(textCommand));
    }

    function connect() {
      var url = config.websocket;
      if (typeof url !== 'string' || !url.length) return;
      onStatus('connecting');
      socket = new WebSocket(url);
      socket.onopen = function () { onStatus('open'); };
      socket.onclose = function () { onStatus('closed'); };
      socket.onerror = function () { onStatus('closed'); };
      socket.onmessage = function (event) {
        if (typeof event.data === 'string') ingest(event.data);
      };
    }

    function tick() {
      if (!running) return;
      draw();
      requestFrame(tick);
    }

    function start() {
      if (running) return;
      running = true;
      loadAssets().then(function () { draw(); });
      if (config.websocket) connect();
      requestFrame(tick);
    }

    function stop() {
      running = false;
      if (socket) { try { socket.close(); } catch (e) {} socket = null; }
    }

    return {
      start: start,
      stop: stop,
      ingest: ingest,
      sendCommand: sendCommand,
      clickMap: function () {},
      // Zoom and pan are NO-OPS by design: the board is a fixed square grid
      // with a 1:1 aspect and no off-frame area, so #viewpanel is dropped.
      // The methods stay so the static adapter's API surface is unchanged.
      zoomAt: function () {},
      setZoom: function () {},
      panBy: function () {},
      panByMap: function () {},
      panTo: function () {},
      resetView: function () {},
      attachMinimap: function () {},
      setHeat: function (on) { heatOn = !!on; draw(); },
      getHeat: function () { return heatOn; },
      getTransform: function () { return transform; },
      setViewportSize: setViewportSize,
      setViewportFit: function () { draw(); },
      getState: function () { return state; },
      getPaceStats: function () {
        return {
          enabled: false, queued: paceQueue.length, presented: 0,
          interval: 1000 / FPS, draws: draws
        };
      },
      assetsReady: function () { return assetsReady; },
      SPEEDS: SPEEDS
    };
  }

  globalScope.BroadcastCore = { create: BroadcastCore };
})();
