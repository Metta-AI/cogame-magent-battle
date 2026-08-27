(function () {
  'use strict';

  // Shared replay chrome (chrome_common.js, spliced over the CHROME_COMMON
  // marker by the server / dist bundle; the literal marker must not appear
  // inside this script or the splice would corrupt it). A raw file:// open of
  // this source has no splice -- same non-functional baseline as the missing
  // BROADCAST_CORE -- so fail loud and early instead of throwing mid-file.
  if (!window.ChromeCommon) {
    console.error('replay_broadcast: chrome_common.js missing - this page must be served spliced (native server or dist bundle), not opened raw.');
    return;
  }
  var C = window.ChromeCommon({
    send: function (cmd) { send(cmd); },
    sendPov: function () {},
    getState: function () { return lastState; }
  });
  // Aliases so the per-view code below reads exactly as before.
  var RED = C.RED, BLUE = C.BLUE, AMBER = C.AMBER, PAPER = C.PAPER;
  var GREEN = C.GREEN, YELLOW = C.YELLOW;
  var TEAM_ORDER = C.TEAM_ORDER, TEAM_COLOR = C.TEAM_COLOR;
  var teamCol = C.teamCol, activeTeams = C.activeTeams, teamOf = C.teamOf;
  var otherTeam = C.otherTeam, stripSeatSuffix = C.stripSeatSuffix;
  var teamPolicies = C.teamPolicies, teamName = C.teamName, teamHeadline = C.teamHeadline;
  var rosterName = C.rosterName, setName = C.setName, esc = C.esc, fmt = C.fmt;
  var togglePov = C.togglePov, renderClock = C.renderClock, renderTransport = C.renderTransport;
  var ingestLullSpans = C.ingestLullSpans, renderLullSpans = C.renderLullSpans;
  var markBeat = C.markBeat, killMarkerTeam = C.killMarkerTeam, renderBeatMarkers = C.renderBeatMarkers;
  var captureTeam = C.captureTeam, ingestBeats = C.ingestBeats, setVerdict = C.setVerdict;
  var ingestLeadSeries = C.ingestLeadSeries, recordMomentum = C.recordMomentum;
  var renderMomentum = C.renderMomentum;
  var getSpoilers = C.getSpoilers, setSpoilers = C.setSpoilers;

  // Engine-authoritative wire constants (read via the shared chrome; the
  // fallback literals for raw file:// opens live in chrome_common.js).
  var WIRE = C.WIRE, SPEEDS = C.SPEEDS, FPS = C.FPS;

  // ART_BASE, not a root-absolute "/client/...": this page is served from
  // three places and a leading slash is only correct at one of them.
  //  - native server, bare:      /client/replay          -> "" + /client/...
  //  - native server, proxied:   /<prefix>/client/replay
  //  - the STATIC WASM BUNDLE:   .../index.html, where the assets sit NEXT TO
  //    the page and there is no server at all.
  var ART_BASE = window.MagentStaticReplay
    ? '.'
    : location.pathname.replace(/\/clients?\/[^/]*$/, '') + '/client';

  // Two independent tempo levers, both the starter's:
  //  (1) ANIM_MAX_FACTOR -- chrome beat animations never play faster than this
  //      no matter the replay speed, so feed rows keep their read time.
  //  (2) DWELL_FLOOR_MS -- a beat's on-screen hold has a wall-clock minimum.
  var ANIM_MAX_FACTOR = 2;
  var DWELL_FLOOR_MS = { feed: 2600, banner: 1900, curtain: 2400, read: 600 };
  function animFactor() {
    var sp = (lastState && lastState.sp) || 1;
    return Math.min(sp, ANIM_MAX_FACTOR);
  }
  function dwellFloor(kind) {
    return DWELL_FLOOR_MS[kind] || DWELL_FLOOR_MS.read;
  }
  var beatPulseTimer = null;
  function beatPulse() {
    stage.classList.add('beat-active');
    if (beatPulseTimer) clearTimeout(beatPulseTimer);
    beatPulseTimer = setTimeout(function () {
      stage.classList.remove('beat-active');
      beatPulseTimer = null;
    }, dwellFloor('read'));
  }

  var $ = C.$;
  var viewport = $('viewport');
  var stage = $('stage');
  var canvas = $('board');
  var statusEl = $('status');

  // ---- pre-load curtain: the muster room -----------------------------------
  // The stage opens on this scene while the wasm sim boots. The art frames are
  // wired here (their base path is delivery-mode dependent); the first
  // ingested frame calls dismissLockerRoom(), which fades the room out after a
  // short minimum dwell -- a sub-second load would otherwise flash the scene
  // like a glitch.
  var lockerEl = $('lockerroom');
  var LOCKER_MIN_DWELL_MS = 900;
  var lockerShownAt = Date.now();
  var lockerCapTimer = null, lockerGone = false;
  (function buildLockerRoom() {
    var artBase = ART_BASE + '/art/lockerroom';
    $('lk-bg').src = artBase + '/bg.jpg';
    // Sprite geometry baked by the extraction script: ax/ay anchor each cog's
    // bottom-center on the plate, w/h size each pose -- all in % of the plate,
    // so everything scales together. Two armies here, not four teams, so the
    // two anchors are the plate's outer thirds.
    var LK_BOTS = {
      red:  { ax: 30.0, ay: 77.0, cyc: 4.1,
        poses: [{ f: 1, w: 18.15, h: 18.79 }, { f: 2, w: 15.93, h: 20.19 },
                { f: 3, w: 15.52, h: 19.87 }, { f: 5, w: 15.83, h: 20.63 },
                { f: 6, w: 16.73, h: 21.06 }] },
      blue: { ax: 70.0, ay: 76.67, cyc: 3.8,
        poses: [{ f: 1, w: 16.63, h: 18.25 }, { f: 2, w: 14.92, h: 21.6 },
                { f: 3, w: 15.83, h: 21.81 }, { f: 5, w: 16.63, h: 20.63 },
                { f: 6, w: 14.62, h: 22.68 }] }
    };
    var spritesEl = $('lk-sprites');
    ['red', 'blue'].forEach(function (bot) {
      var b = LK_BOTS[bot];
      var maxW = 0, maxH = 0;
      b.poses.forEach(function (p) {
        maxW = Math.max(maxW, p.w);
        maxH = Math.max(maxH, p.h);
      });
      var wrap = document.createElement('div');
      wrap.className = 'lk-boto';
      wrap.style.left = (b.ax - maxW / 2) + '%';
      wrap.style.top = (b.ay - maxH) + '%';
      wrap.style.width = maxW + '%';
      wrap.style.height = maxH + '%';
      b.poses.forEach(function (p, ix) {
        var img = document.createElement('img');
        img.alt = '';
        img.src = artBase + '/' + bot + '_' + p.f + '.webp';
        img.style.width = (p.w / maxW * 100) + '%';
        img.style.setProperty('--cyc', b.cyc + 's');
        img.style.animationDelay = (ix * b.cyc / b.poses.length) + 's';
        wrap.appendChild(img);
      });
      spritesEl.appendChild(wrap);
    });

    var bgImg = $('lk-bg');
    function fitLockerSprites() {
      spritesEl.style.left = bgImg.offsetLeft + 'px';
      spritesEl.style.top = bgImg.offsetTop + 'px';
      spritesEl.style.width = bgImg.offsetWidth + 'px';
      spritesEl.style.height = bgImg.offsetHeight + 'px';
    }
    bgImg.addEventListener('load', fitLockerSprites);
    if (window.ResizeObserver) new ResizeObserver(fitLockerSprites).observe(bgImg);
    window.addEventListener('resize', fitLockerSprites);
    fitLockerSprites();

    // rotating prep-talk line under the scene
    var lines = [
      'Forming up on the line\u2026',
      'Dressing the ranks\u2026',
      'Sergeants counting off by squad\u2026',
      'Nine squads, one order each\u2026',
      'Sizing up the open ground\u2026',
      'Checking the wings\u2026'
    ];
    var capEl = $('lk-cap'), capIx = 0;
    lockerCapTimer = setInterval(function () {
      capEl.classList.add('swap');
      setTimeout(function () {
        capIx = (capIx + 1) % lines.length;
        capEl.textContent = lines[capIx];
        capEl.classList.remove('swap');
      }, 180);
    }, 2600);
  })();
  function dismissLockerRoom() {
    if (lockerGone) return;
    lockerGone = true;
    var wait = Math.max(0, LOCKER_MIN_DWELL_MS - (Date.now() - lockerShownAt));
    setTimeout(function () {
      lockerEl.classList.add('gone');
      setTimeout(function () {
        lockerEl.style.display = 'none';
        if (lockerCapTimer) { clearInterval(lockerCapTimer); lockerCapTimer = null; }
      }, 650);
    }, wait);
  }

  // ---- embed mode ----------------------------------------------------------
  // When loaded inside a shell (?embed=1) this client renders ONLY the board
  // (its own scorebug/transport/feed chrome is hidden by CSS via
  // body[data-embed]) and streams each parsed state frame up to the parent
  // shell over postMessage.
  var EMBED = false;
  try { EMBED = new URLSearchParams(location.search).get('embed') === '1'; } catch (e) {}
  if (EMBED) document.body.setAttribute('data-embed', '1');

  // Tick deep-link (?t=<tick>): seek there on load via the same s: command the
  // scrubber uses. One-shot, fired on the first ingested frame so the replay
  // runtime is ready.
  var SEEK_T = null;
  try {
    var seekRaw = new URLSearchParams(location.search).get('t');
    if (seekRaw != null && /^\d+$/.test(seekRaw)) SEEK_T = parseInt(seekRaw, 10);
  } catch (e) {}

  function postToShell(type, payload) {
    if (!EMBED || window.parent === window) return;
    try { window.parent.postMessage({ src: 'magent-replay', type: type, data: payload }, '*'); } catch (e) {}
  }

  // The whole replay is ONE fixed-aspect composition locked to the board's
  // native size. The board is a SQUARE integer grid, so the aspect is 1:1 at
  // every mapSize and never changes mid-episode -- which is the reason the
  // zoom bar and minimap are gone: relayout() fits the whole board at every
  // width, and at the 360 px featured-match embed each of 45 cells is 8 px.
  var BOARD_ASPECT = 1;

  // ---- core (board renderer + WS) ----
  var lastState = null;
  var MG_CTX = null;             // filled at the end of this IIFE (hoisted)
  // A scrubber click that arrives before the first chrome frame is REMEMBERED
  // and resolved on the first frame that carries the axis -- the same one-shot
  // shape as ?t=.
  var SEEK_FRAC = null;
  var replayAdapter = window.MagentStaticReplay || null;
  var coreConfig = {
    canvas: canvas,
    websocket: replayAdapter ? false : websocketUrl(),
    onText: function (txt) { onFrame(txt); },
    onStatus: function (st) { onStatus(st); },
    onFirstFrame: function () { core.setViewportFit(); }
  };
  var core = replayAdapter
    ? replayAdapter.createCore(coreConfig)
    : window.BroadcastCore.create(coreConfig);

  function websocketUrl() {
    var scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    var prefix = location.pathname.replace(/\/clients?\/[^/]*$/, '');
    return scheme + '//' + location.host + prefix + '/global';
  }

  postToShell('boot');

  function send(cmd) { core.sendCommand(cmd); }

  if (EMBED) {
    window.addEventListener('message', function (ev) {
      var m = ev.data;
      if (!m || m.src !== 'magent-shell') return;
      if (m.type === 'cmd' && typeof m.cmd === 'string') send(m.cmd);
      else if (m.type === 'seek' && m.tick != null) send('s:' + m.tick);
    });
  }

  function onStatus(st) {
    statusEl.textContent = st;
    statusEl.classList.toggle('show', st !== 'open');
  }

  // ============================================================
  //  Frame ingest
  // ============================================================
  var lastTick = -1;
  var lastFf = false;   // previous frame's fast-forward state (jump detection)
  // (beat markers, lull spans, beats timeline and momentum state live in the
  // shared chrome closure -- see chrome_common.js)

  function onFrame(txt) {
    var s;
    try { s = JSON.parse(txt); } catch (e) { return; }
    if (!s || !s.mg) return;
    lastState = s;
    dismissLockerRoom();

    // A backward jump (a seek, or a loop restart) clears everything that
    // accumulates forward, so the chrome never shows a stale future.
    var jumped = (s.t < lastTick) || (lastFf && !s.ff);
    if (jumped) { clearFeed(); clearBanners(); }
    lastTick = s.t;
    lastFf = !!s.ff;

    ingestLullSpans(s);
    ingestBeats(s);
    ingestLeadSeries(s);
    recordMomentum(s);
    renderTransport(s);
    renderScorebug(s);
    renderClockLine(s);
    renderMismatch(s);
    renderEndcard(s);
    if (window.MagentChrome) window.MagentChrome.frame(s, MG_CTX, jumped);

    if (SEEK_T != null && s.en) { var t = SEEK_T; SEEK_T = null; send('s:' + t); }
    if (SEEK_FRAC != null && s.en) {
      var frac = SEEK_FRAC; SEEK_FRAC = null; seekToFraction(s, frac);
    }
    postToShell('frame', s);
  }

  // ---------- scorebug ----------
  // Two plates: the seat's REAL policy name (spectator side only), its in-game
  // alias, a small side chip showing which colour it holds this game, the ALIVE
  // count as the big numeral and kills as the small one, and a fallback glyph on
  // any seat that has taken one.
  var sbBuilt = false;
  function ensureScorebug() {
    if (sbBuilt) return;
    sbBuilt = true;
    [['plates-l', 0], ['plates-r', 1]].forEach(function (pair) {
      var host = $(pair[0]);
      host.innerHTML =
        '<div class="plate' + (pair[1] === 1 ? ' side-r' : '') + '" id="plate-' + pair[1] + '">' +
        '<span class="side-chip" id="side-' + pair[1] + '"></span>' +
        '<span class="plate-name" id="pname-' + pair[1] + '"></span>' +
        '<span class="plate-alias" id="palias-' + pair[1] + '"></span>' +
        '<span class="alive-label">Alive</span>' +
        '<span class="alive-num" id="palive-' + pair[1] + '"></span>' +
        '<span class="kill-num" id="pkills-' + pair[1] + '"></span>' +
        '<span class="fb-glyph" id="pfb-' + pair[1] + '"></span>' +
        '</div>';
    });
  }
  function renderScorebug(s) {
    ensureScorebug();
    var seats = s.mg.seats || [];
    for (var i = 0; i < 2; i++) {
      var seat = seats[i] || {};
      var plate = $('plate-' + i);
      if (plate) plate.style.color = seat.side === 'red' ? RED : BLUE;
      var chip = $('side-' + i);
      if (chip) {
        chip.textContent = seat.side === 'red' ? 'red' : 'blue';
        chip.style.background = seat.side === 'red' ? RED : BLUE;
      }
      setName('pname-' + i, teamHeadline(seat.name || ''));
      setName('palias-' + i, seat.alias || '');
      setName('palive-' + i, String(seat.alive != null ? seat.alive : 0));
      setName('pkills-' + i, String(seat.kills != null ? seat.kills : 0));
      setName('pfb-' + i, (seat.fallbacks > 0) ? '\u21af' : '');
    }
  }

  // ---------- clock ----------
  // #clock-time reads the pair and the command turn; #clock-caption reads the
  // tick and the live count. renderClock (chrome_common) is deliberately not
  // called: its captions are for a single-game match with a countdown, and this
  // is a two-game pair scored on soldiers standing.
  function renderClockLine(s) {
    var mg = s.mg;
    setName('clock-time',
      'game ' + mg.game + '/' + mg.games + ' \u00b7 turn ' +
      Math.max(1, mg.turn) + '/' + mg.turns);
    setName('clock-caption',
      'tick ' + mg.tick + '/' + mg.maxTicks + ' \u00b7 ' +
      mg.alive[0] + ' v ' + mg.alive[1]);
  }

  function renderMismatch(s) {
    var el = $('mmwarn');
    var tick = s.mg.mismatchTick;
    if (tick != null && tick >= 0) {
      el.textContent = 'Replay hash mismatch at tick ' + tick +
        ' \u2014 showing recorded orders';
      el.classList.add('show');
    } else {
      el.classList.remove('show');
    }
  }

  // ---------- match feed ----------
  var feedEl = $('killfeed');
  var MAX_FEED = 4;
  function pushFeed(row) {
    feedEl.insertBefore(row, feedEl.firstChild);
    while (feedEl.children.length > MAX_FEED) feedEl.removeChild(feedEl.lastChild);
    // Dwell floor (lever 2): a wall-clock minimum so the row reads even at 8x.
    var hold = dwellFloor('feed');
    // animFactor cap (lever 1): the slide-in duration never dips below its
    // read-time, so the row still overshoots-and-settles legibly at high speed.
    row.style.animationDuration = (250 / animFactor()) + 'ms';
    setTimeout(function () {
      if (row.parentNode) { row.classList.add('leaving'); setTimeout(function () { if (row.parentNode) row.parentNode.removeChild(row); }, 300); }
    }, hold);
  }
  function clearFeed() { feedEl.innerHTML = ''; }

  // ---------- banner lane queue (one at a time, min hold) ----------
  var bannerEl = $('bannerlane');
  var bannerQueue = [];
  var bannerBusy = false;
  function banner(text, cls) {
    bannerQueue.push({ text: text, cls: cls });
    pumpBanner();
  }
  function pumpBanner() {
    if (bannerBusy || !bannerQueue.length) return;
    bannerBusy = true;
    var b = bannerQueue.shift();
    var chip = document.createElement('div');
    chip.className = 'banner-chip ' + b.cls;
    chip.textContent = b.text;
    bannerEl.appendChild(chip);
    chip.style.animationDuration = (300 / animFactor()) + 'ms';
    var hold = dwellFloor('banner');
    setTimeout(function () {
      chip.classList.add('leaving');
      setTimeout(function () {
        if (chip.parentNode) chip.parentNode.removeChild(chip);
        bannerBusy = false;
        pumpBanner();
      }, 260);
    }, hold);
  }
  function clearBanners() {
    bannerQueue = [];
    bannerEl.innerHTML = '';
    bannerBusy = false;
  }

  // ============================================================
  //  End-card -- the END SEGMENT: verdict, win condition and match stats.
  //  It stops at var(--band) so the scrubber stays clickable underneath, and
  //  every seek dismisses it (both the starter's rules, kept).
  // ============================================================
  var ecBuilt = false;
  function ensureEndcardTeams() {
    if (ecBuilt) return;
    ecBuilt = true;
    var host = $('ec-teams');
    host.innerHTML =
      '<div class="ec-team" id="ec-team-0"></div>' +
      '<div class="ec-team" id="ec-team-1"></div>';
  }
  function renderEndcardRows(s, slot) {
    var card = s.mg.endcard;
    var seat = (s.mg.seats || [])[slot] || {};
    var alias = seat.alias || ('SEAT ' + slot);
    return '' +
      '<div class="ec-tname" style="color:' +
        (seat.side === 'red' ? RED : BLUE) + '">' + esc(alias) +
        ' <span class="side-chip" style="background:' +
        (seat.side === 'red' ? RED : BLUE) + '">' + esc(seat.side || '') +
        '</span></div>' +
      '<div class="ec-thead"><span>Commander</span><span>Kills</span>' +
        '<span>Lost</span><span>Alive</span><span>Reward</span></div>' +
      '<div class="ec-trow"><span>' + esc(teamHeadline(seat.name || '')) +
        '</span><span>' + card.kills[slot] + '</span><span>' +
        card.lost[slot] + '</span><span>' + card.survivors[slot] +
        '</span><span>' + esc(card.reward[slot]) + '</span></div>' +
      '<div class="ec-tfoot"><span class="fl-cap">Troops left</span>' +
        '<span class="fl-num">' + card.survivors[slot] + '</span></div>';
  }
  function renderEndcard(s) {
    var card = s.mg.endcard;
    var el = $('endcard');
    if (!card || s.ph !== 'gameover' || !card.complete) {
      el.classList.remove('on');
      return;
    }
    ensureEndcardTeams();
    var seats = s.mg.seats || [];
    var lead = card.scores[0] >= card.scores[1] ? 0 : 1;
    var other = 1 - lead;
    var aliasLead = (seats[lead] || {}).alias || 'ALPHA';
    var headline = card.scores[lead] === card.scores[other]
      ? 'THE PAIR IS DRAWN \u2014 ' + card.survivors[0] + ' TO ' + card.survivors[1]
      : aliasLead + ' TAKES THE PAIR ' + card.gameWins[lead] + '\u2013' +
        card.gameWins[other] + ' \u2014 ' + card.survivors[lead] +
        ' SURVIVORS TO ' + card.survivors[other];
    setName('ec-headline', headline);
    setName('ec-wincond',
      'SCORE ' + (card.scores[0] > 0 ? '+' : '') + card.scores[0] + ' / ' +
      (card.scores[1] > 0 ? '+' : '') + card.scores[1]);
    var how = [];
    for (var g = 0; g < card.games.length; g++) {
      var game = card.games[g];
      how.push('game ' + game.game + ': ' + game.survivors[0] + '\u2013' +
        game.survivors[1] + ' (' + game.endRule + ', ' + game.ticks + ' ticks)');
    }
    setName('ec-how', how.join(' \u00b7 ') + ' \u00b7 ' + card.reason);
    $('ec-team-0').innerHTML = renderEndcardRows(s, 0);
    $('ec-team-1').innerHTML = renderEndcardRows(s, 1);
    setName('ec-replay', '');
    el.classList.add('on');
    // The shared chrome's winner cap (#scrub-win) and WINS chip (#win-chip)
    // are fed by ingestBeats' `gameover` kind, which this game never emits --
    // so both ids stayed empty for the whole replay. Feed them here instead,
    // through the chrome's own documented fallback path ("older servers that
    // ship no beats still get the verdict once playback reaches the end"), in
    // this game's vocabulary: the ALIAS takes the pair, never a colour.
    // setVerdict is idempotent and spoiler-gated by the chrome.
    setVerdict(card.scores[lead] === card.scores[other]
      ? { draw: true, t: s.t }
      : { winner: aliasLead, t: s.t });
  }

  // ============================================================
  //  Transport wiring -- DOM controls emit the chat chars plus the
  //  whole-string s: seek command.
  // ============================================================
  function togglePlay() { send(' '); }
  // (speed chips + their speed->command map live in the shared chrome)
  $('btn-play').addEventListener('click', togglePlay);
  $('btn-restart').addEventListener('click', function () { send(','); });
  $('btn-back').addEventListener('click', function () { send('b'); });
  $('btn-fwd').addEventListener('click', function () { send('.'); });
  $('btn-end').addEventListener('click', function () { send('e'); });
  $('btn-loop').addEventListener('click', function () { send('r'); });
  $('btn-skip').addEventListener('click', function () { send('f'); });

  // click-to-seek: map x-fraction to a tick and send s:<tick>
  function seekToFraction(s, frac) {
    var st = Math.max(0, s.st || 0);
    var mx = Math.max(st + 1, s.mx || 1);
    send('s:' + (st + Math.round(frac * (mx - st))));
    var card = $('endcard');
    if (card) card.classList.remove('on');
  }

  $('scrub').addEventListener('click', function (ev) {
    var rect = this.getBoundingClientRect();
    var frac = Math.min(1, Math.max(0, (ev.clientX - rect.left) / rect.width));
    // The axis lives on the frame, so a click before the first frame cannot be
    // mapped yet -- QUEUE it rather than dropping it. A dropped first click is
    // invisible: the board is already drawn and the viewer just does not move.
    if (!lastState || !lastState.en) { SEEK_FRAC = frac; return; }
    seekToFraction(lastState, frac);
  });

  // keyboard shortcuts mirror the transport
  window.addEventListener('keydown', function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    var k = ev.key;
    if (k === ' ') { ev.preventDefault(); togglePlay(); }
    else if (k === ',' || k === '<') send(',');
    else if (k === '.' || k === '>') send('.');
    else if (k === 'b') send('b');
    else if (k === 'e') send('e');
    else if (k === 'r') send('r');
    else if (k === 'f') send('f');
    else if (k === 'o') {
      setSpoilers(!getSpoilers());
      // the appended block gates its own markers -- and a toggle while paused
      // has no frame coming to do it
      if (window.MagentChrome && window.MagentChrome.applySpoilers) {
        window.MagentChrome.applySpoilers(lastState);
      }
    }
    else if (k === 'h' && window.MagentChrome) window.MagentChrome.toggleHeat();
    else if (k >= '1' && k <= '9') send(k);
    else if (k === 'Escape') postToShell('esc');
  });

  // ============================================================
  //  Fixed-aspect fit: size the composition to the board's native aspect
  //  inside the embed box, then scale the whole thing (board + overlays) as
  //  one unit. Chrome sizes off the STAGE width, so overlays stay locked to
  //  the graphics at any container shape.
  // ============================================================
  function relayout() {
    var boxW = viewport.clientWidth, boxH = viewport.clientHeight;
    if (!boxW || !boxH) return;
    // The board region fits the board aspect into the box BETWEEN a reserved
    // top band (the scorebug) and bottom band (the transport), so neither ever
    // sits over play. Each band's pixel height depends on --hudscale (-> board
    // width) and the board fit depends on the bands, so iterate to a FIXED
    // POINT: stop as soon as a pass measures the same bands it was laid out
    // with.
    var scorebug = document.getElementById('scorebug');
    var transport = document.getElementById('transport');
    var root = document.documentElement;
    var topBand = parseFloat(getComputedStyle(root).getPropertyValue('--topband')) || 0;
    var band = parseFloat(getComputedStyle(root).getPropertyValue('--band')) || 0;
    var stageW = 0, stageH = 0;
    for (var pass = 0; pass < 4; pass++) {
      var prevTop = topBand, prevBand = band;
      var availH = Math.max(1, boxH - topBand - band);
      var boardW, boardH;
      if (boxW / availH > BOARD_ASPECT) {
        boardH = availH; boardW = Math.round(availH * BOARD_ASPECT);
      } else {
        boardW = boxW; boardH = Math.round(boxW / BOARD_ASPECT);
      }
      stageW = boardW; stageH = boardH + topBand + band;
      stage.style.width = stageW + 'px';
      stage.style.height = stageH + 'px';
      // One scale for the whole composition: chrome was authored against a
      // ~760px-wide reference board, so --hudscale is the board's on-screen
      // width over that reference (clamped so a huge featured embed doesn't
      // bloat the chrome and a tiny 360px floor stays legible).
      var scale = Math.max(0.5, Math.min(1.6, boardW / 760));
      root.style.setProperty('--hudscale', scale.toFixed(3));
      stage.classList.toggle('tiny', boardW <= 620);
      // Measure each band's natural height -> reserve exactly that.
      topBand = scorebug ? scorebug.offsetHeight : 0;
      band = transport ? transport.offsetHeight : 0;
      root.style.setProperty('--topband', topBand + 'px');
      root.style.setProperty('--band', band + 'px');
      if (Math.abs(topBand - prevTop) < 0.5 && Math.abs(band - prevBand) < 0.5) break;
    }
    core.setViewportFit();
  }
  var ro = new ResizeObserver(relayout);
  ro.observe(viewport);
  window.addEventListener('resize', relayout);

  // The context the appended MAGENT-BATTLE block reads the inherited chrome
  // through. Declared here (hoisted `var`, so onFrame sees it however early
  // the first frame lands) rather than duplicating any of it: the game block
  // must not re-implement naming, escaping, feed insertion or the transport.
  MG_CTX = {
    $: $, C: C, esc: esc, fmt: fmt, send: send,
    teamCol: teamCol, teamHeadline: teamHeadline,
    pushFeed: pushFeed, banner: banner, beatPulse: beatPulse,
    core: core,
    getState: function () { return lastState; }
  };
  if (window.MagentChrome) window.MagentChrome.install(MG_CTX);
  // Exposed for tools/ci/renderer_fixture.html ONLY: the worst-case text
  // fixture drives the SHIPPED page's own feed path rather than
  // re-implementing it (the particle-worlds 2026-08-26 scar), and it needs the
  // same context object the game block is installed with.
  window.MAGENT_CTX = MG_CTX;

  relayout();
  core.start();
})();
