/* ============================================================================
   发条屋 · 生灵层  (resources/alive.js)
   ----------------------------------------------------------------------------
   把「死板的静态界面」变成「有生命体征的机器」。

   A. 发条机芯   侧栏底部的三只咬合齿轮，随 AI 运转状态改变转速；
                 空闲时怠速常转（生命体征），思考时加速，完成时「上弦」回弹。
                 仪表上显示的是 **真实 token**，不是估算：
                   · 主源 dsh 自己的统计胶囊 [data-composer-stats]（会话累计 / 缓存命中 / TPS）
                   · 辅源 传输层嗅探：WebSocket / fetch 帧里出现 {outputTokens} 就记账
                        → 拿到逐 step 的精确用量，用来算「本轮 +N tok」
   B. 小鲸鱼     在界面上游动的桌宠：可拖拽可甩出去、会躲鼠标、会好奇凑过来看、
                 会睡觉冒泡、被点会吐泡泡；AI 完成时替你冒一串泡泡庆祝。
   C. 设置入口   从侧栏底行搬到主区标题栏右上角（图标按钮 + 点击转发），
                 侧栏底部完整让给机芯，避免两个「条状控制区」叠在一起互相打架。
   D. 机械音效   Web Audio 程序化合成（不引入任何音频文件）：
                 一次上弦回弹 = 噪声瞬态 + 低频体 + 金属余韵「咔哒」。

   运转状态引擎刻意不依赖 dsh 的 CSS-Module 类名：
     · 主判据：页面出现「停止生成」按钮（dsh i18n 的 input.stop）
     · 兜底：  全局 DOM 活动率 + 新增字符数
   偏好存在 localStorage，设置面板「生灵」栏目可开关。
   ============================================================================ */
(function () {
  'use strict';
  if (window.__ftAliveLoaded) return;
  window.__ftAliveLoaded = true;

  // ── 0. 偏好 ──────────────────────────────────────────────────────────────
  var LS_KEY = 'ft-alive-prefs';
  // drowsyMs：没人打扰多久之后开始打盹（自己去睡 / 安静玩耍，且**完全静音**）。
  // 0 = 从不打盹。它是「生灵音效抢麦克风」的正解：人一走开，屋子自己安静下来。
  var prefs = { clock: true, pet: true, sound: true, zen: false, drowsyMs: 45000 };
  var reduced = false;
  try {
    reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  } catch (e) {}
  if (reduced) { prefs.clock = false; prefs.pet = false; }
  try {
    var raw = localStorage.getItem(LS_KEY);
    if (raw) {
      var o = JSON.parse(raw);
      if (o && typeof o === 'object') {
        if (typeof o.clock === 'boolean') prefs.clock = o.clock;
        if (typeof o.pet === 'boolean') prefs.pet = o.pet;
        if (typeof o.sound === 'boolean') prefs.sound = o.sound;
        if (typeof o.zen === 'boolean') prefs.zen = o.zen;
        if (typeof o.drowsyMs === 'number') prefs.drowsyMs = Math.max(0, o.drowsyMs);
      }
    }
  } catch (e) {}
  function savePrefs() { try { localStorage.setItem(LS_KEY, JSON.stringify(prefs)); } catch (e) {} }
  window.__ftAlive = {
    prefs: prefs,
    save: savePrefs,
    set: function (k, v) { prefs[k] = !!v; savePrefs(); applyPrefs(); },
    // 诊断/回归用：让验证台能确定性地检查「没碰它就会静下来」
    dozing: function () { return dozing(); },
    shush: function () { return shush(); },
    audioLive: function () { return !!audioReady(); },   // 假 = 现在一个音都发不出来
    markActive: markActive,
    idleForMs: function () { return now() - activeAt; }
  };

  var $ = function (id) { return document.getElementById(id); };
  function now() { return performance.now(); }

  // ── 1. 运转状态引擎 ──────────────────────────────────────────────────────
  // mode: idle(怠速) | busy(运转) | done(刚完成，短促回弹)
  var st = { mode: 'idle', cps: 0, doneAt: 0, forced: null, reserve: 0.45 };
  var mutTimes = [];      // 最近 1s 的 mutation 时间戳
  var charTimes = [];     // 最近 1s 的 {t, n}
  var lastBusyAt = 0;
  var bootAt = now();     // 启动宽限期起点（见 evaluateAlive）
  var clockRoot = null, petRoot = null, petLayer = null;

  // 过滤掉自己制造的 DOM 变动，否则状态文字每帧变化 → 判定为「一直在运转」→ 死循环
  function isOurs(node) {
    if (!node) return false;
    if (clockRoot && clockRoot.contains(node)) return true;
    if (petLayer && petLayer.contains(node)) return true;
    return false;
  }

  var STOP_SEL = 'button[aria-label*="停止"],button[title*="停止"],' +
                 'button[aria-label*="Stop generating"],button[title*="Stop generating"],' +
                 '[role="button"][aria-label*="停止"],[role="button"][title*="停止"]';
  var stopCached = false, lastStopCheck = -1e9;
  function hasStopButton(t) {
    // querySelector 全文档扫描不便宜，200ms 一次足够
    if (t - lastStopCheck > 200) {
      lastStopCheck = t;
      try { stopCached = !!document.querySelector(STOP_SEL); } catch (e) { stopCached = false; }
    }
    return stopCached;
  }

  if (window.MutationObserver && document.documentElement) {
    var mo = new MutationObserver(function (muts) {
      var t = now(), added = 0, counted = false;
      for (var i = 0; i < muts.length; i++) {
        var m = muts[i];
        if (isOurs(m.target)) continue;
        counted = true;
        if (m.type === 'characterData') {
          var nl = m.target.data ? m.target.data.length : 0;
          var ol = m.oldValue ? m.oldValue.length : 0;
          if (nl > ol) added += nl - ol;
        } else if (m.type === 'childList') {
          for (var j = 0; j < m.addedNodes.length; j++) {
            var nn = m.addedNodes[j];
            if (nn.nodeType === 3) added += nn.data.length;
            else if (nn.nodeType === 1 && !nn.id) added += (nn.textContent || '').length > 0 ? 1 : 0;
          }
        }
      }
      if (!counted) return;
      mutTimes.push(t);
      if (added > 0) charTimes.push({ t: t, n: added });
      if (mutTimes.length > 500) mutTimes.splice(0, mutTimes.length - 500);
      if (charTimes.length > 500) charTimes.splice(0, charTimes.length - 500);
    });
    mo.observe(document.documentElement, {
      subtree: true, childList: true, characterData: true, characterDataOldValue: true
    });
  }

  function evaluateAlive(dt) {
    var t = now(), cut = t - 1000;
    while (mutTimes.length && mutTimes[0] < cut) mutTimes.shift();
    while (charTimes.length && charTimes[0].t < cut) charTimes.shift();

    var activity = mutTimes.length;
    var chars = 0;
    for (var i = 0; i < charTimes.length; i++) chars += charTimes[i].n;

    // 自检用：强制指定状态（正常运行时 st.forced 恒为 null）
    var busy;
    if (st.forced) {
      st.mode = st.forced;
      if (st.forced === 'busy') { st.cps += (Math.max(chars, 42) - st.cps) * 0.35; busy = true; }
      else { busy = false; st.cps *= 0.86; }
    } else {
      // 主判据（停止按钮）可信度最高；无按钮时用活动率兜底。
      // bootAt 宽限：页面首屏 React 渲染本身会产生上千次 mutation，不设宽限会被误判成「一直在运转」。
      busy = hasStopButton(t) || (t - bootAt > 3000 && activity >= 12);

      if (busy) {
        lastBusyAt = t;
        st.mode = 'busy';
        // 平滑：新值占 35%，避免数字乱跳
        st.cps += (chars - st.cps) * 0.35;
      } else if (st.mode === 'busy' && t - lastBusyAt > 480) {
        st.mode = 'done';
        st.doneAt = t;
        onRunComplete();
      } else if (st.mode === 'done' && t - st.doneAt > 950) {
        st.mode = 'idle';
      }
      if (!busy) { st.cps *= 0.86; if (st.cps < 0.4) st.cps = 0; }
    }

    // 动力储备：**一个真实 token 就是一格弦**（有真实用量时），没有就退回活跃度
    if (busy) {
      st.reserve = Math.min(1, st.reserve + (0.30 + Math.min(chars, 170) / 170 * 0.85) * dt);
    } else {
      st.reserve = Math.max(0.12, st.reserve - dt / 240);
    }
  }

  // ── 1.5 真实 token 遥测 ──────────────────────────────────────────────────
  // 两个来源，互为补充：
  //   ① dsh 统计胶囊 [data-composer-stats]（会话累计 / 缓存命中 / TPS）—— 权威且稳定
  //   ② 传输层嗅探：WebSocket / fetch 帧内出现 outputTokens 就记账 —— 拿到逐 step 精确量
  var tele = {
    ok: false, src: '', total: 0, tps: 0, cache: null, turns: 0, steps: 0,
    out: 0, input: 0, cacheRead: 0, reasoning: 0,
    liveRate: 0, liveAt: 0, steps: 0,
    turnStart: 0, turnDelta: 0, frames: 0, hits: 0
  };
  var usageLedger = {};     // "turn:step" -> usage（真实用量账本，去重靠它）
  var ledgerN = 0;
  var outSamples = [];      // [{t, out}] 用于算实时 tok/s

  function normalizeCount(numText, suffix) {
    var v = parseFloat(String(numText).replace(/,/g, ''));
    if (!isFinite(v)) return null;
    var s = (suffix || '').toLowerCase();
    if (s === 'k') v *= 1e3;
    else if (s === 'm') v *= 1e6;
    else if (s === '万') v *= 1e4;
    return v;
  }

  // 读 dsh 自己的统计胶囊：aria-label 里就是格式化好的真实数字
  function readPills() {
    var root = document.querySelector('[data-composer-stats]');
    if (!root) return;
    var nodes = root.querySelectorAll('[aria-label]');
    for (var i = 0; i < nodes.length; i++) {
      var lb = nodes[i].getAttribute('aria-label') || '';
      var mt = lb.match(/([\d.,]+)\s*([kKmM])?\s*tok\/s/);
      if (mt) { var v = normalizeCount(mt[1], mt[2]); if (v !== null) { tele.tps = v; tele.ok = true; tele.src = tele.src || 'pill'; } }
      var mc = lb.match(/([\d.,]+)\s*([kKmM])?\s*tok(?!\/)/);
      if (mc) { var w = normalizeCount(mc[1], mc[2]); if (w !== null) { tele.total = w; tele.ok = true; tele.src = tele.src || 'pill'; } }
      var mh = lb.match(/缓存命中\s*([\d.]+)%|Cache hit\s*([\d.]+)%/);
      if (mh) { var c = parseFloat(mh[1] || mh[2]); if (isFinite(c)) tele.cache = c; }
      var mr = lb.match(/(\d+)\s*轮\s*(\d+)\s*步|(\d+)\s*turns?\s*(\d+)\s*steps?/);
      if (mr) { tele.turns = +(mr[1] || mr[3]); tele.steps = +(mr[2] || mr[4]); }
    }
  }

  function recomputeTele() {
    var out = 0, inp = 0, cr = 0, rs = 0, n = 0;
    for (var k in usageLedger) {
      var u = usageLedger[k];
      out += u.o; inp += u.i; cr += u.c; rs += u.r; n++;
    }
    if (out !== tele.out) {
      outSamples.push({ t: now(), out: out });
      if (outSamples.length > 40) outSamples.shift();
    }
    tele.out = out; tele.input = inp; tele.cacheRead = cr; tele.reasoning = rs; tele.steps = n;
  }

  function absorbUsage(u, turn, step) {
    if (!u || typeof u.outputTokens !== 'number') return;
    var key = (turn === undefined || turn === null ? '?' : turn) + ':' +
              (step === undefined || step === null ? '?' : step);
    usageLedger[key] = {
      o: u.outputTokens || 0,
      i: (u.uncachedInputTokens !== undefined ? u.uncachedInputTokens : (u.inputTokens || 0)),
      c: u.cacheReadTokens || 0,
      r: u.reasoningTokens || 0
    };
    ledgerN++;
    tele.ok = true; tele.hits++;
    if (tele.src !== 'stream') tele.src = 'stream';
    if (ledgerN > 20000) { usageLedger = {}; ledgerN = 0; }   // 兜底防止无限增长
    recomputeTele();
  }

  // 深度扫描：不假设帧格式（mux 包了几层都无所谓），只认「带 outputTokens 的对象」
  function scanValue(v, depth) {
    if (!v || typeof v !== 'object' || depth > 7) return;
    if (typeof v.outputTokens === 'number') return;
    var u = v.usage;
    if (u && typeof u === 'object' && typeof u.outputTokens === 'number') {
      absorbUsage(u, v.turn, v.step);
      return;
    }
    for (var k in v) {
      var c = v[k];
      if (c && typeof c === 'object') scanValue(c, depth + 1);
    }
  }
  function scanFrame(data) {
    tele.frames++;
    if (typeof data !== 'string') return;
    if (data.indexOf('outputTokens') === -1) return;   // 便宜的前置过滤：流式正文不会命中
    var obj;
    try { obj = JSON.parse(data); } catch (e) { return; }
    scanValue(obj, 0);
  }

  (function hookTransport() {
    try {
      var Native = window.WebSocket;
      if (Native && !Native.__ftPatched) {
        var Patched = function (url, protocols) {
          var ws = protocols === undefined ? new Native(url) : new Native(url, protocols);
          try { ws.addEventListener('message', function (ev) { scanFrame(ev.data); }); } catch (e) {}
          return ws;
        };
        Patched.prototype = Native.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { Patched[k] = Native[k]; });
        Patched.__ftPatched = true;
        window.WebSocket = Patched;
      }
    } catch (e) {}
    try {
      var nf = window.fetch;
      if (nf && !nf.__ftPatched) {
        var pf = function () {
          return nf.apply(this, arguments).then(function (res) {
            try {
              var ct = res.headers && res.headers.get ? (res.headers.get('content-type') || '') : '';
              if (ct.indexOf('json') !== -1) {
                res.clone().text().then(scanFrame)['catch'](function () {});
              }
            } catch (e) {}
            return res;
          });
        };
        pf.__ftPatched = true;
        window.fetch = pf;
      }
    } catch (e) {}
  })();

  function fmtTok(v) {
    if (!isFinite(v) || v <= 0) return '0';
    if (v < 1000) return String(Math.round(v));
    if (v < 1e6) { var k = v / 1e3; return (k >= 100 ? Math.round(k) : Math.round(k * 10) / 10) + 'k'; }
    var m = v / 1e6; return (m >= 100 ? Math.round(m) : Math.round(m * 10) / 10) + 'M';
  }
  // 会话累计：优先精确账本，其次 dsh 胶囊（胶囊是同一个值，只是被缩写过）
  function sessionTokens() { return tele.out > 0 ? tele.out : tele.total; }

  // 实时速度：① 账本滑动窗口的 Δ；② 窗口内无新账 → 用 dsh 自算的 TPS
  function updateLiveRate() {
    var t = now();
    if (outSamples.length >= 2) {
      var cut = t - 2600;
      var first = null;
      for (var i = 0; i < outSamples.length; i++) { if (outSamples[i].t < cut) first = outSamples[i]; }
      if (!first) first = outSamples[0];
      var last = outSamples[outSamples.length - 1];
      var span = (last.t - first.t) / 1000;
      if (span > 0.6) {
        tele.liveRate = Math.max(0, (last.out - first.out) / span);
        tele.liveAt = last.t;
      }
    }
  }

  // 自检钩子（同时供自动化截图回归使用，不影响正常逻辑）
  window.__ftAliveDebug = {
    // 测试钩子：让自动化能**确定性地**打到每一个分支（尤其彩蛋、以及「腻了会挣脱」的拒绝路径），
    // 不必靠等随机数撞上。
    petAct: function (m) { if (petLayer) startAct(m, now()); },
    petSet: function (o) {
      o = o || {};
      if (o.mood) petApi.mood = o.mood;
      if (typeof o.stamina === 'number') petApi.stamina = o.stamina;
      if (typeof o.tame === 'number') petApi.tame = o.tame;
      if (typeof o.bored === 'number') petApi.bored = o.bored;
    },
    petFeed: function (x, y) { feedAt(x, y); },
    petPick: function () { return pickPlay(now()); },
    petPhases: function () { return [petApi.phBreath, petApi.phSway, petApi.phDrift, petApi.phIdle]; },
    state: function () {
      return {
        mode: st.mode,
        cps: Math.round(st.cps),
        activity: mutTimes.length,
        gearSpeed: Math.round(clockApi.speed),
        mainAngle: Math.round(clockApi.angle.main || 0),
        reserve: Math.round(st.reserve * 100),
        mounted: !!clockRoot,
        mount: clockRoot ? clockRoot.getAttribute('data-ft-mounted') : null,
        text: clockApi.text ? clockApi.text.textContent : null,
        title: clockRoot ? String(clockRoot.title || '').slice(0, 120) : null,
        pet: !!petLayer,
        petPos: petLayer ? [Math.round(petApi.x), Math.round(petApi.y)] : null,
        petHeading: Math.round(petApi.heading * 57.3),
        petMode: petApi.mode,
        petEye: Math.round(petApi.blink * 100) / 100,
        petRipples: document.querySelectorAll('.ft-ripple').length,
        petJelly: Math.round(petApi.jelly * 1000) / 1000,
        petPlay: petApi.lastPlay,
        petTarget: [Math.round(petApi.tx), Math.round(petApi.ty)],
        petSpeed: Math.round(petApi.speed),
        petActUntil: Math.round(petApi.actUntil),
        // v4 活体层探针：四个相位是否真的各走各的、内部状态是否在动
        petPhases: [petApi.phBreath, petApi.phSway, petApi.phDrift, petApi.phIdle]
          .map(function (v) { return Math.round(v * 100) / 100; }),
        petMood: petApi.mood,
        petStamina: Math.round(petApi.stamina * 100) / 100,
        petTame: Math.round(petApi.tame * 100) / 100,
        petArousal: Math.round(petApi.arousal * 100) / 100,
        petAttn: petApi.attn,
        petBored: Math.round(petApi.bored * 100) / 100,
        petPetting: !!petApi.petting,
        petChewing: !!petApi.chewing,
        petFood: !!petApi.eatTarget,
        petGaze: [Math.round(petApi.gazeX * 100) / 100, Math.round(petApi.gazeY * 100) / 100],
        petTwitch: Math.round(petApi.twitchK * 100) / 100,
        petDlen: petApi.dLen || 0,
        // 着色自检：渐变有没有建出来、CSS 的 fill 到底解析成了什么
        petSvgKids: petApi.svg
          ? Array.prototype.slice.call(petApi.svg.children).map(function (n) {
              return n.tagName.replace(/^.*:/, '') + (n.getAttribute('class') ? '.' + n.getAttribute('class') : '');
            }).join(' ')
          : null,
        petGradIds: petApi.svg
          ? Array.prototype.slice.call(petApi.svg.querySelectorAll('linearGradient,radialGradient'))
              .map(function (n) { return n.id; }).join(',')
          : null,
        petFill: (function () {
          if (!petApi.svg) return null;
          var k = petApi.svg.querySelector('.ft-pet-key');
          if (!k) return 'no-key-node';
          var c = getComputedStyle(k).fill || '';
          var m = /url\(["']?#([^"')]+)/.exec(c);
          return c.slice(0, 40) + (m ? '|exists=' + !!document.getElementById(m[1]) : '|no-url');
        })(),
        petScale: Math.round(petApi.scale * 100) / 100,
        petBubs: petApi.playBubs.length,
        petHome: petApi.home
          ? [Math.round(petApi.home.l), Math.round(petApi.home.t), Math.round(petApi.home.r), Math.round(petApi.home.b)]
          : null,
        sfxPlayed: Object.keys(sfxLast).length,
        tele: {
          ok: tele.ok, src: tele.src, frames: tele.frames, hits: tele.hits,
          out: tele.out, total: tele.total, tps: Math.round(tele.tps * 10) / 10,
          cache: tele.cache, steps: tele.steps,
          liveRate: Math.round(tele.liveRate * 10) / 10, turnDelta: tele.turnDelta
        },
        sound: audio.ctx ? audio.ctx.state : 'none',
        settingsMoved: !!($('ft-settings-btn') && $('ft-settings-btn').parentNode),
        settingsHidden: !!document.querySelector('[class$="_triggerRow"][data-ft-hidden]'),
        // 真实布局几何：决定「窝」与巡游带放哪里（改桌宠活动区前先看这个）
        geom: (function () {
          function R(sel) {
            var e = document.querySelector(sel);
            if (!e) return null;
            var r = e.getBoundingClientRect();
            return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
          }
          var out = {
            win: [window.innerWidth, window.innerHeight],
            side: R('[class*="_hHd"][class*="_root"]'),
            composer: R('[class*="_composer"]'),
            clock: R('#ft-clock')
          };
          var cands = document.querySelectorAll('[class$="_scroll"],[class$="_body"],[class*="_ChatView"],[class$="_list"]');
          var best = null, bw = 0;
          for (var i = 0; i < cands.length; i++) {
            var rr = cands[i].getBoundingClientRect();
            if (rr.left > 200 && rr.width > bw && rr.height > 200) { bw = rr.width; best = rr; }
          }
          out.col = best ? [Math.round(best.left), Math.round(best.top), Math.round(best.width), Math.round(best.height)] : null;
          var hb = homeNow();
          out.home = [Math.round(hb.l), Math.round(hb.t), Math.round(hb.r), Math.round(hb.b)];
          return out;
        })()
      };
    },
    force: function (m) { st.forced = (m === 'idle' || m === 'busy' || m === 'done') ? m : null; },
    // 桌宠自检：play(mode) 直接拉一个节目，jolt(v) 给一记挤压
    play: function (m) { if (!petLayer) return 'no-pet'; startAct(m || 'spout', now()); return petApi.mode; },
    jolt: function (v) { jolt(v === undefined ? 6 : v); return Math.round(petApi.jelly * 1000) / 1000; },
    cheer: function () { if (petLayer) petApi.celebrate(); return 'ok'; },
    wind: function () { windUp(true); },
    tele: function () { return JSON.stringify(tele); },
    pill: function () {
      var r = document.querySelector('[data-composer-stats]');
      if (!r) return 'no-pill';
      var out = [];
      var ns = r.querySelectorAll('[aria-label]');
      for (var i = 0; i < ns.length; i++) out.push(ns[i].getAttribute('aria-label'));
      return JSON.stringify(out);
    },
    clack: function () { playClack(0); },
    // 合成用量样本：验证「实时速率 → 转速 → 本轮增量」这条链路（不触碰真实会话）
    feed: function (n, gapMs) {
      var cnt = n || 4, i = 0, seed = (tele.steps || 0) + 900;
      (function step() {
        if (i >= cnt) return;
        absorbUsage({ outputTokens: 70 + Math.round(Math.random() * 60), uncachedInputTokens: 260,
                      cacheReadTokens: 9000, reasoningTokens: 24 }, 99, seed + i);
        i++;
        if (i < cnt) setTimeout(step, gapMs || 480);
      })();
      return 'feeding';
    }
  };

  // ── 「没人打扰」：静置一段时间后打盹（自己去睡 / 安静玩耍），并且**完全不出声** ──
  // 这条不是装饰。生灵的音效是从扬声器出来的，而语音识别听着同一个扬声器：
  // 你没在碰它、它还自顾自地响，麦克风里就全是它自己的声音 ——
  // 表现成「第一轮能发、之后怎么都叫不醒」（2026-09-20 用户实证）。
  // 所以「没碰它」必须是真的安静：不只是动作变小，而是**一个音都不出**。
  var activeAt = now();            // 最近一次「有人在场」的时刻
  var voiceNow = 'off';            // 语音层状态（由 __ftAliveReact 写入）
  function markActive() { activeAt = now(); }
  function dozing() {
    if (!prefs.drowsyMs) return false;         // 0 = 从不打盹
    return now() - activeAt > prefs.drowsyMs;
  }
  function voiceBusy() {
    return voiceNow === 'awake' || voiceNow === 'hearing' || voiceNow === 'sending' ||
           voiceNow === 'thinking' || voiceNow === 'speaking';
  }
  /// 这会儿不该发出任何声音：不打扰模式、没人搭理、或者语音正在工作
  function shush() { return !!prefs.zen || dozing() || voiceBusy(); }

  // ---------- 语音层联动（voice.js 在状态变化时调 window.__ftAliveReact(state)）──────
  // 鲸鱼因此「在场」：你唤醒它时它会醒过来、抖一下；harness 被朗读时它跟着动嘴。
  // 依赖是单向的：alive.js 不认识 voice.js，只暴露这个入口；voice.js 不在时毫无影响。
  window.__ftAliveReact = function (s) {
    voiceNow = s || 'off';
    if (!petLayer) return;
    petApi.voiceState = s || 'off';
    if (s === 'awake') {
      markActive();                 // 有人开口 = 有人在场，别在这时候打盹
      if (petApi.mode === 'sleep') { wake('voice'); petApi.nextPlay = now() + 1600; }
      petApi.lastInteract = now();
      jolt(-2.0);
    }
  };

  // ── 2. 机械音效（Web Audio 程序化合成，零音频文件）────────────────────────
  var audio = { ctx: null, master: null, noise: null, lastAt: 0 };
  function initAudio() {
    if (audio.ctx) return audio.ctx;
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    try {
      audio.ctx = new AC();
      audio.master = audio.ctx.createGain();
      audio.master.gain.value = 0.55;
      audio.master.connect(audio.ctx.destination);
    } catch (e) { audio.ctx = null; }
    return audio.ctx;
  }
  function unlockAudio() {
    if (!prefs.sound) return;
    var c = initAudio();
    if (c && c.state === 'suspended') { try { c.resume(); } catch (e) {} }
  }
  function noiseBuffer() {
    var c = audio.ctx;
    if (audio.noise) return audio.noise;
    var n = Math.max(1, Math.floor(c.sampleRate * 0.07));
    var b = c.createBuffer(1, n, c.sampleRate);
    var d = b.getChannelData(0);
    for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / n, 1.7);
    audio.noise = b;
    return b;
  }
  function audioReady() {
    // 一处封死所有发声：tone/breath/clack 全都经过这里。
    // 打盹、不打扰、语音工作中 —— 任何一种都直接不给 AudioContext。
    if (!prefs.sound || shush()) return null;
    var c = initAudio();
    if (!c || c.state !== 'running') return null;
    return c;
  }
  // 一次「上弦回弹」：噪声瞬态（咔嚓）+ 低频体（机箱闷响）+ 两个金属分音（余韵）
  function clack(when, pitch, level) {
    var c = audioReady();
    if (!c) return;
    pitch = pitch || 1; level = level === undefined ? 1 : level;
    var t0 = c.currentTime + (when || 0);
    var src = c.createBufferSource();
    src.buffer = noiseBuffer();
    src.playbackRate.value = 0.9 + Math.random() * 0.2;
    var bp = c.createBiquadFilter();
    bp.type = 'bandpass'; bp.frequency.value = 2350 * pitch; bp.Q.value = 1.1;
    var g = c.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.linearRampToValueAtTime(level * 0.15, t0 + 0.002);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.055);
    src.connect(bp); bp.connect(g); g.connect(audio.master);
    src.start(t0); src.stop(t0 + 0.08);

    var o = c.createOscillator();
    o.type = 'sine';
    o.frequency.setValueAtTime(155 * pitch, t0);
    o.frequency.exponentialRampToValueAtTime(72 * pitch, t0 + 0.05);
    var og = c.createGain();
    og.gain.setValueAtTime(level * 0.10, t0);
    og.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.075);
    o.connect(og); og.connect(audio.master); o.start(t0); o.stop(t0 + 0.1);

    var partials = [3160, 4712];
    for (var i = 0; i < partials.length; i++) {
      var p = c.createOscillator();
      p.type = 'sine'; p.frequency.value = partials[i] * pitch;
      var pg = c.createGain();
      pg.gain.setValueAtTime(level * (i ? 0.015 : 0.022), t0);
      pg.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.15);
      p.connect(pg); pg.connect(audio.master); p.start(t0); p.stop(t0 + 0.17);
    }
  }
  function playClack(kind) {
    if (shush()) return;                         // 打盹/语音工作中：机芯也不许响
    var t = now();
    if (t - audio.lastAt < 500) return;          // 限流：连点不要连环炸
    audio.lastAt = t;
    if (kind === 1) {                            // 手动上弦：三连棘轮
      clack(0, 1.0, 0.8); clack(0.042, 1.13, 0.66); clack(0.088, 1.27, 0.52);
    } else {
      clack(0, 1.0, 1.0); clack(0.055, 1.22, 0.42);   // 完成：主击 + 轻回弹
    }
  }

  // ── 2b. 桌宠动作音效（同样程序合成，零音频文件）──────────────────────────
  // 三条纪律：① 逐类限流 ② 全局限流（近同时只响一个）③ 音量压得很低，
  // 它们是「动作的质感」不是「BGM」，安静模式下完全不发声。
  var sfxLast = {}, sfxGlobalAt = 0;
  function sfxGate(kind, gap, minGlobal) {
    if (!prefs.sound || shush()) return false;
    var t = now();
    if (sfxLast[kind] && t - sfxLast[kind] < gap) return false;
    if (minGlobal && t - sfxGlobalAt < minGlobal) return false;
    sfxLast[kind] = t; sfxGlobalAt = t;
    return true;
  }
  // 通用音：可滑频振荡器 + 指数衰减包络
  function tone(type, f0, f1, dur, level, when, atk) {
    var c = audioReady();
    if (!c) return;
    var t0 = c.currentTime + (when || 0);
    var o = c.createOscillator();
    o.type = type || 'sine';
    o.frequency.setValueAtTime(f0, t0);
    if (f1 && f1 !== f0) o.frequency.exponentialRampToValueAtTime(Math.max(20, f1), t0 + dur);
    var g = c.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.linearRampToValueAtTime(level, t0 + (atk || 0.008));
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    o.connect(g); g.connect(audio.master);
    o.start(t0); o.stop(t0 + dur + 0.03);
  }
  // 通用噪声：滤波扫频 + 衰减包络（水声/风声/撞击的骨架）
  function breath(type, f0, f1, dur, level, q, when, atk) {
    var c = audioReady();
    if (!c) return;
    var t0 = c.currentTime + (when || 0);
    var src = c.createBufferSource();
    src.buffer = noiseBuffer();
    src.playbackRate.value = 0.85 + Math.random() * 0.3;
    var f = c.createBiquadFilter();
    f.type = type; f.Q.value = q === undefined ? 1.0 : q;
    f.frequency.setValueAtTime(f0, t0);
    if (f1 && f1 !== f0) f.frequency.exponentialRampToValueAtTime(Math.max(60, f1), t0 + dur);
    var g = c.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.linearRampToValueAtTime(level, t0 + (atk || 0.006));
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    src.connect(f); f.connect(g); g.connect(audio.master);
    src.start(t0); src.stop(t0 + dur + 0.03);
  }
  // 气泡破：短促上滑 + 一点水膜噪声
  function sfxBlip(p) {
    if (!sfxGate('blip', 120, 60)) return;
    p = p || 1;
    tone('sine', 520 * p, 1240 * p, 0.055, 0.040);
    breath('highpass', 2200, 3600, 0.03, 0.016, 0.8);
  }
  // 喷水：向上的一束水花 + 落回
  function sfxSplash() {
    if (!sfxGate('splash', 700)) return;
    breath('highpass', 900, 2600, 0.26, 0.045, 0.9, 0, 0.02);
    tone('sine', 430, 150, 0.2, 0.026, 0.03);
  }
  // 招呼 / 兴奋：两音小叫，上行=开心，下行=受惊
  function sfxChirp(up, base) {
    if (!sfxGate('chirp', 260, 90)) return;
    base = base || 690;
    var a = up ? base : base * 0.9, b = up ? base * 1.28 : base * 0.7;
    tone('triangle', a, a * 1.04, 0.085, 0.042);
    tone('triangle', b, b * 1.03, 0.11, 0.034, 0.075);
    if (up) tone('triangle', b * 1.34, b * 1.35, 0.12, 0.022, 0.15);
  }
  // 甩尾 / 冲刺：一道短风
  function sfxWhoosh(p) {
    if (!sfxGate('whoosh', 500)) return;
    breath('bandpass', 300 * (p || 1), 1700 * (p || 1), 0.26, 0.038, 1.5, 0, 0.05);
  }
  // 落地 / 撞墙：低频闷响，level 用撞击力度调
  function sfxThud(level) {
    if (!sfxGate('thud', 90, 50)) return;
    level = Math.max(0.25, Math.min(1.4, level || 1));
    tone('sine', 118, 46, 0.11, 0.032 * level);
    breath('lowpass', 700, 220, 0.06, 0.022 * level, 0.7, 0, 0.003);
  }
  // 睡觉打呼：极低极轻的一口气
  function sfxSnore() {
    if (!sfxGate('snore', 2200)) return;
    tone('triangle', 68, 52, 0.62, 0.018, 0, 0.16);
  }
  // 完成庆祝：三个上行音 + 一个高光
  function sfxChime() {
    if (!sfxGate('chime', 1200)) return;
    var ns = [660, 880, 1320];
    for (var i = 0; i < ns.length; i++) tone('triangle', ns[i], ns[i] * 1.005, 0.3, 0.030, i * 0.075, 0.01);
    tone('sine', 2640, 2640, 0.5, 0.010, 0.19, 0.02);
  }

  // 撸的呼噜：低频滤波噪声 —— 要的是「一口气的震动」而不是一个音调
  function sfxPurr(level) {
    if (!sfxGate('purr', 620)) return;
    level = Math.max(0.2, Math.min(1, level || 0.6));
    breath('lowpass', 210, 130, 0.40, 0.030 * level, 3.4, 0, 0.14);
    tone('triangle', 74, 62, 0.34, 0.014 * level, 0, 0.10);
  }
  // 咀嚼：两下轻脆的闷响
  function sfxMunch() {
    if (!sfxGate('munch', 380)) return;
    tone('sine', 330, 170, 0.05, 0.024);
    breath('lowpass', 900, 320, 0.05, 0.018, 0.9, 0.06, 0.004);
    tone('sine', 250, 140, 0.05, 0.019, 0.13);
  }

  // ── 3. 发条机芯 ──────────────────────────────────────────────────────────
  // 齿形：极坐标下按齿数生成方波半径（占空比 0.44，边缘 smoothstep 平滑）
  function gearPath(cx, cy, teeth, rOut, rIn, samples) {
    var N = samples || teeth * 26, d = '';
    for (var i = 0; i <= N; i++) {
      var th = i / N * Math.PI * 2;
      var phase = (th * teeth / (Math.PI * 2)) % 1;
      if (phase < 0) phase += 1;
      var duty = 0.44, edge = 0.115, v;
      if (phase < duty - edge) v = 1;
      else if (phase < duty) v = 1 - (phase - (duty - edge)) / edge;
      else if (phase < 1 - edge) v = 0;
      else v = (phase - (1 - edge)) / edge;
      v = v * v * (3 - 2 * v);                       // smoothstep：齿根齿顶别太方
      var r = rIn + (rOut - rIn) * v;
      var x = cx + Math.cos(th) * r, y = cy + Math.sin(th) * r;
      d += (i === 0 ? 'M' : 'L') + x.toFixed(2) + ' ' + y.toFixed(2);
    }
    return d + 'Z';
  }

  // 三只齿轮：主轮（上弦）+ 两只咬合卫星轮
  var GEARS = [
    { id: 'main', cx: 16.0, cy: 25.0, teeth: 12, rOut: 11.4, rIn: 8.9, ratio: 1 },
    { id: 'up',   cx: 30.0, cy: 13.5, teeth: 8,  rOut: 6.2,  rIn: 4.6, ratio: -1.5 },
    { id: 'dn',   cx: 30.0, cy: 34.5, teeth: 7,  rOut: 5.3,  rIn: 3.9, ratio: -12 / 7 }
  ];

  function buildClock() {
    if (clockRoot) return;
    var root = document.createElement('div');
    root.id = 'ft-clock';
    root.setAttribute('data-ft-own', '1');

    var sv = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(sv, 'svg');
    svg.setAttribute('viewBox', '0 0 46 46');
    svg.setAttribute('width', '42');
    svg.setAttribute('height', '42');
    svg.id = 'ft-clock-svg';

    var pulse = document.createElementNS(sv, 'circle');
    pulse.setAttribute('cx', '16'); pulse.setAttribute('cy', '25');
    pulse.setAttribute('r', '12'); pulse.setAttribute('class', 'ft-clock-pulse');

    var groups = {};
    for (var i = 0; i < GEARS.length; i++) {
      var g = GEARS[i];
      var el = document.createElementNS(sv, 'g');
      el.setAttribute('class', 'ft-gear ft-gear-' + g.id);
      el.setAttribute('transform', 'rotate(0 ' + g.cx + ' ' + g.cy + ')');
      var p = document.createElementNS(sv, 'path');
      p.setAttribute('d', gearPath(g.cx, g.cy, g.teeth, g.rOut, g.rIn));
      el.appendChild(p);
      var hub = document.createElementNS(sv, 'circle');
      hub.setAttribute('cx', g.cx); hub.setAttribute('cy', g.cy);
      hub.setAttribute('r', (g.rIn * 0.34).toFixed(2));
      hub.setAttribute('class', 'ft-gear-hub');
      el.appendChild(hub);
      svg.appendChild(el);
      groups[g.id] = el;
    }
    svg.appendChild(pulse);
    root.appendChild(svg);

    var side = document.createElement('div');
    side.className = 'ft-clock-side';
    var txt = document.createElement('div');
    txt.className = 'ft-clock-text';
    txt.textContent = '待机';
    side.appendChild(txt);
    var ticks = document.createElement('div');
    ticks.className = 'ft-clock-ticks';
    for (var k = 0; k < 12; k++) {
      var sp = document.createElement('span');
      sp.className = 'ft-tick';
      sp.style.height = (3 + k * 0.62).toFixed(2) + 'px';   // 阶梯状 → 读起来像仪表而不是虚线
      ticks.appendChild(sp);
    }
    side.appendChild(ticks);
    root.appendChild(side);

    root.style.pointerEvents = 'auto';
    root.style.cursor = 'pointer';
    root.addEventListener('click', function () { windUp(true); });

    clockRoot = root;
    clockApi.groups = groups;
    clockApi.pulse = pulse;
    clockApi.text = txt;
    clockApi.ticks = ticks;
  }

  var clockApi = { groups: null, pulse: null, text: null, ticks: null, angle: {}, speed: 0 };

  function windUp(byUser) {
    st.reserve = 1;                     // 手动上弦：动力储备回满
    clockApi.boost = 1;
    clockApi.boostAt = now();
    if (clockApi.pulse) {
      clockApi.pulse.style.animation = 'none';
      void clockApi.pulse.getBoundingClientRect();
      clockApi.pulse.style.animation = 'ft-clock-ping .9s ease-out';
    }
    if (byUser) {
      playClack(1);
      if (prefs.pet && petApi.cheer) petApi.cheer(1);   // 上弦了，鲸鱼也跟着精神一振
    }
  }

  function onRunComplete() {
    var tok = sessionTokens();
    tele.turnDelta = Math.max(0, tok - (tele.turnStart || 0));
    windUp(false);
    playClack(0);
    if (prefs.pet && petApi.celebrate) petApi.celebrate();   // 任务完成，鲸鱼替你庆祝
  }

  // 侧栏挂载：插在 .footArea 之前。设置入口已搬到主区标题栏，底部整条归机芯。
  function mountClock() {
    if (!prefs.clock) { if (clockRoot) { clockRoot.remove(); clockRoot = null; } return; }
    if (!clockRoot) buildClock();
    if (!clockRoot.parentNode) {
      var foot = document.querySelector('[class$="_footArea"]');
      if (foot && foot.parentNode) {
        foot.parentNode.insertBefore(clockRoot, foot);
        clockRoot.setAttribute('data-ft-mounted', 'sidebar');
        return;
      }
      var root = document.querySelector('[class*="_hHd"][class*="_root"]') ||
                 document.querySelector('[class$="_regionArea"]');
      if (root) { root.appendChild(clockRoot); clockRoot.setAttribute('data-ft-mounted', 'root'); }
    }
  }

  // ── 4. 小鲸鱼桌宠 v3 ─────────────────────────────────────────────────────
  // v3 按用户反馈重做：
  //   ① 不再在聊天窗口飘 → 改成「侧栏住客」：活动区被限制在侧栏内的空白带，
  //      正文列零遮挡；它偶尔会从侧栏边缘探个头，但绝不游到文字上。
  //   ② 不再像纸片 → 对姿态做「先倾斜、再上光」：体积径向渐变 + 底部遮挡叠加 +
  //      背部镜面高光 + 腹部透光 + 轮廓收边 + 地面接触阴影（随高度缩放淡出），
  //      再加一套弹簧阻尼的「体积守恒挤压拉伸」= Q 弹。
  //   ③ 行为丰富 → 伸懒腰 / 喷水 / 原地转圈 / 追自己吐的泡泡 / 游到机芯看齿轮 /
  //      探头张望 / 受惊 / 打招呼 / 完成庆祝 / 睡觉打呼；动力储备低时会蔫。
  //   ④ 动作音效 → 全部程序合成（气泡/水花/叫声/风/闷响/呼噜/和弦），逐类限流。
  //      甩出去会惯性滑行，然后自己游回窝。
  var WHALE_FALLBACK = 'M22.9168 1.43018C22.6713 1.31018 22.5658 1.53918 22.4223 1.65519C22.3733 1.69269 22.3318 1.74169 22.2903 1.78669C21.9317 2.1697 21.5127 2.42121 20.9657 2.39121C20.1657 2.34621 19.4827 2.59771 18.8787 3.20973C18.7502 2.45521 18.3236 2.0047 17.6746 1.71569C17.3351 1.56568 16.9916 1.41518 16.7536 1.08867C16.5876 0.856163 16.5421 0.597155 16.4591 0.341647C16.4061 0.187643 16.3536 0.0301382 16.1761 0.00363739C15.9836 -0.0263635 15.9081 0.135141 15.8326 0.270145C15.5306 0.822162 15.4136 1.43018 15.4251 2.0462C15.4516 3.43174 16.0366 4.53527 17.1991 5.3203C17.3311 5.4103 17.3651 5.5003 17.3236 5.63181C17.2441 5.90231 17.1501 6.16482 17.0671 6.43533C17.0141 6.60784 16.9351 6.64584 16.7501 6.57033C16.1121 6.30383 15.5611 5.90931 15.074 5.4328C14.2475 4.63328 13.5 3.75075 12.568 3.05973C12.349 2.89822 12.13 2.74822 11.9034 2.60522C10.9524 1.68169 12.028 0.923165 12.277 0.833162C12.5375 0.739159 12.3675 0.41615 11.5259 0.42015C10.6844 0.42365 9.91439 0.705658 8.93286 1.08117C8.78935 1.13767 8.63835 1.17867 8.48384 1.21267C7.59332 1.04367 6.66829 1.00617 5.70226 1.11517C3.88321 1.31768 2.43016 2.1777 1.36213 3.64575C0.0790928 5.4103 -0.222916 7.41536 0.146595 9.50642C0.535106 11.7105 1.66014 13.535 3.38869 14.9616C5.18125 16.4406 7.24581 17.1657 9.60138 17.0266C11.0319 16.9441 12.6245 16.7526 14.421 15.2321C14.874 15.4576 15.3496 15.5476 16.1381 15.6151C16.7456 15.6716 17.3306 15.5851 17.7836 15.4911C18.4931 15.3411 18.4441 14.6841 18.1876 14.5636C16.1081 13.595 16.5646 13.9891 16.1496 13.67C17.2061 12.42 18.8202 10.1979 19.3182 7.17235C19.3672 6.83834 19.4297 6.36783 19.4222 6.09732C19.4182 5.93231 19.4562 5.86831 19.6447 5.84931C20.1657 5.78931 20.6712 5.64681 21.1357 5.3913C22.4833 4.65528 23.0268 3.44624 23.1548 1.9972C23.1738 1.77569 23.1508 1.54668 22.9168 1.43018Z';

  // 鲸鱼路径实测 bbox: x 0~23.16, y 0~17.04（朝左、尾鳍在右上、胸鳍在右下 15.2~17.7）
  // ↑ 这是品牌复合路径的**第 1 段（外轮廓）**；后 3 段是镂空，见 whaleD() 上方说明。
  var VB = { x: -1.8, y: -1.8, w: 26.8, h: 20.6 };
  var PET_W = 76, PET_H = 58;
  var HOP_G = 1250;     // 跳跃重力 px/s²（v2 的 hopY 是「每帧累加 hopV」，会飞出屏幕，
                        // 这里改成正经物理：顶点 ≈ 44px、滞空 ≈ 0.53s）
  var HOP_V0 = 330;
  var TAU = Math.PI * 2;
  // 四个动作的目标频率（Hz）。取**非整数倍**比例（0.34 : 0.78 : 0.148 ≈ 2.3× / 5.3×），
  // 否则每几秒就会锁相回同一步调，又变回「整块橡皮」。运行时各自还叠了速度项与兴奋度，
  // 实际相位差持续漂移，不会长期停在同一比值上。
  var HZ_BREATH = 0.34, HZ_SWAY = 0.78, HZ_DRIFT = 0.148;
  var TAME_KEY = 'ft-alive-tame';       // 熟人度落盘（按天衰减，跨会话保留关系）

  var petApi = {
    x: 0, y: 0, vx: 0, vy: 0, heading: 0, speed: 0, targetSpeed: 0,
    tx: 0, ty: 0, restUntil: 0, mode: 'roam', spin: 0, hopY: 0, hopV: 0,
    blink: 1, nextBlink: 0, roll: 0, t: 0, tailPh: 0,
    drag: false, grabX: 0, grabY: 0, lastX: 0, lastY: 0, downAt: 0, moved: 0,
    lastInteract: 0, sleepAt: 0, zAt: 0, rippleAt: 0, curiousUntil: 0,
    mouseIdle: 0, mouseLast: 0, mouseStopX: 0, mouseStopY: 0,
    // ── v3 ──
    jelly: 0, jellyV: 0,                // 挤压量 / 挤压速度（弹簧阻尼）
    actUntil: 0, nextPlay: 0, lastPlay: '',
    playBubs: [],                       // 追着玩的泡泡
    scale: 1, home: null,               // 窝（每帧刷新）
    lastGreet: 0, mouseFast: 0, lastStartle: 0,
    // ── v4「活体层」────────────────────────────────────────────────────────
    // 核心：**四个动作各自一个相位**。v3 里呼吸/摆尾/浮沉/侧倾共用 sin(ph*1.35)，
    // 峰谷垂直对齐 → 被读成「一整块橡皮在缩放」，而不是「各部位各自动」。
    phBreath: 0, phSway: 0, phDrift: 0, phIdle: 0,
    driftX: 0, driftY: 0, driftTx: 0, driftTy: 0, driftNext: 0,   // 噪声漂移
    twitchAt: 0, twitchK: 0, twitchDir: 1,      // 偶发抽动（低频短促）
    voiceState: 'off',                          // 语音层状态（由 __ftAliveReact 写入）
    gazeX: 0, gazeY: 0,                          // 眼珠偏移（svg 用户单位）
    attn: 0, attnAt: 0, attnHold: 260, attnPlan: '',   // 注意力：0 无 / 1 注意到 / 2 判断
    // 内部状态（性格取向 = 有个性：会累、会腻）
    stamina: 1, tame: 0, arousal: 0.28, mood: 'curious',
    groom: 0, petting: false, petRefuseUntil: 0, bored: 0,
    eatTarget: null, chew: 0, chewAt: 0, chewing: false, crumbed: false, yawnAt: 0,
    purrAt: 0, heartAt: 0, tameSaveAt: 0,
    eggAt: 0, dashUntil: 0, moodAt: 0, tameAt: 0
    // 注：原 lightFacing（光照轴向随朝向翻转）已随「高光焊死在图上」一并移除
  };
  var mouse = { x: -9999, y: -9999, active: false, vx: 0, vy: 0 };

  // 品牌 mark 的那条 path 是**复合路径**，实测（dsh 0.1.5）共 4 段：
  //   #0 外轮廓 1789 字符（= WHALE_FALLBACK）
  //   #1 身体暗部 689 字符（x1.5~14.1, y6.1~15.2）← 大面积
  //   #2 眼窝 ~0.6×0.6 单位（x12.1~12.7, y8.0~8.6）← 很小
  //   #3 胸鳍线 672 字符（x12.0~15.5, y6.7~10.0）
  // 后 3 段是**镂空**（露出侧栏底色），是品牌 logo 的明暗设计。
  // 但桌宠要自己画眼睛和嘴 —— 整条一起填充会把身体挖空，我们画的眼嘴正好落在
  // 挖空区上，深色图形压在深色背景里 → 看起来「眼睛和嘴坏了」（2026-09-19 用户报障）。
  // 所以桌宠**只取外轮廓**，立体暗部交给形体阴影渐变承担。
  function outerOnly(d) {
    var i = d.search(/[Mm]/);
    if (i < 0) return d;
    var j = d.slice(i + 1).search(/[Mm]/);
    if (j < 0) return d;                        // 本来就是单段路径
    var out = d.slice(0, i + 1 + j).replace(/[\s,]+$/, '');
    if (!/[Zz]$/.test(out)) out += 'Z';
    return out;
  }

  function whaleD() {
    // 优先复用品牌区的鲸鱼路径 → 外形永远跟 dsh 版本一致；拿不到再用内置副本
    try {
      var p = document.querySelector('[class$="_brandMark"] svg path, [class$="_brandMark"] path');
      var d = p && p.getAttribute('d');
      if (d && d.length > 200) return outerOnly(d);
    } catch (e) {}
    return WHALE_FALLBACK;
  }

  // ── 4.1 活动空间：它是「侧栏的住客」，不压正文 ───────────────────────────
  // 实测（dsh 0.1.5）：侧栏**没有**一个统一高度的根元素，是「品牌行 / 会话区
  // (regionArea) / 底部 footArea」拼起来的。所以先试祖先盒（万一以后有），
  // 拿不到就把已知部件并起来 —— 全程只认本地名后缀，不依赖哈希前缀。
  function sidebarBox() {
    var sel = ['[class*="_logoRow"]', '[class*="regionArea"]', '[class$="_footArea"]', '[class*="listArea"]'];
    var seed = document.querySelector(sel[0]) || document.querySelector(sel[1]) || null;
    var best = null, n = seed;
    for (var i = 0; i < 7 && n; i++) {
      var r = n.getBoundingClientRect();
      if (r.height > window.innerHeight * 0.7 && r.width > 30 && r.width < window.innerWidth * 0.5) {
        best = { l: r.left, t: r.top, w: r.width, h: r.height };
      }
      n = n.parentElement;
    }
    if (!best) {
      var parts = [];
      for (var j = 0; j < sel.length; j++) {
        var e = document.querySelector(sel[j]);
        if (!e) continue;
        var rr = e.getBoundingClientRect();
        if (rr.width > 40 && rr.height > 4) parts.push(rr);
      }
      if (clockRoot) {
        var cr = clockRoot.getBoundingClientRect();
        if (cr.width > 40) parts.push(cr);
      }
      if (!parts.length) return null;
      var L = 1e9, T = 1e9, R = -1e9, B = -1e9;
      for (var k = 0; k < parts.length; k++) {
        L = Math.min(L, parts[k].left); T = Math.min(T, parts[k].top);
        R = Math.max(R, parts[k].right); B = Math.max(B, parts[k].bottom);
      }
      best = { l: L, t: T, w: R - L, h: B - T };
    }
    return best;
  }

  function blockBottom(sel, minH, maxH, limit) {
    // 这些容器（会话列表）本身可能很高，但内容只占顶部一小段 → 取内容的实际底部
    var mb = 0;
    try {
      var es = document.querySelectorAll(sel);
      for (var i = 0; i < es.length; i++) {
        var r = es[i].getBoundingClientRect();
        if (r.height < minH || r.height > maxH || r.width < 60) continue;
        if (r.bottom > mb && r.bottom < limit) mb = r.bottom;
      }
    } catch (e) {}
    return mb;
  }

  function homeRect() {
    var W = window.innerWidth, H = window.innerHeight;
    var sb = sidebarBox();
    if (!sb) {
      // 认不出侧栏（dsh 大改布局）：退化成右下角一个小窝，依然不压正文
      return { l: W - PET_W - 34, r: W - PET_W - 34, t: H - 330, b: H - 214, scale: 1, sb: null };
    }
    var bot = sb.t + sb.h - 74;                 // 机芯（底部约 65px）以上
    var cs = clockSpot();
    if (cs) bot = Math.min(bot, cs.top - 10);

    var top = sb.t + 112;                        // 品牌行以下
    var hdr = document.querySelector('[class*="sectionHeader"]');   // 「工作区」表头
    if (hdr) {
      var hr = hdr.getBoundingClientRect();
      if (hr.width > 60 && hr.bottom + 10 > top) top = hr.bottom + 10;
    }
    var mb = blockBottom('[class*="listArea"] [class*="item"], [class*="listArea"] [role="option"], ' +
                         '[class*="listArea"] button, [class*="listArea"] a, [class*="listArea"] [class*="row"]',
                         18, 96, bot);
    if (mb) top = Math.max(top, mb + 12);

    var scale = 1;
    if (sb.w < 150) scale = Math.max(0.46, (sb.w - 14) / PET_W);   // 折叠态：整只缩小
    var w = PET_W * scale, h = PET_H * scale;
    if (bot - h < top + 4) bot = top + h + 4;    // 实在挤：允许压到列表上沿，也不出侧栏
    var l = Math.round(sb.l + 18), r = Math.round(sb.l + sb.w - w - 17);
    if (r < l) l = r = Math.round(sb.l + Math.max(4, (sb.w - w) / 2));
    return { l: l, r: r, t: Math.round(top), b: Math.round(bot - h), scale: scale, sb: sb };
  }

  var homeTriedAt = 0;
  function homeNow() {
    // 坑：React 首屏比我们的 boot 晚 —— 侧栏还没渲染时 homeRect() 只能给退化窝，
    // 一旦缓存住就永远在右下角。所以：拿到退化窝时每 1.5s 重试；拿到真侧栏后
    // 每 4s 复算一次（会话变多/侧栏折叠都能跟上），越界由主循环自己拉回。
    var p = petApi, t = now();
    if (p.home) {
      if (p.home.sb && t - homeTriedAt < 4000) return p.home;
      if (!p.home.sb && t - homeTriedAt < 1500) return p.home;
    }
    homeTriedAt = t;
    p.home = homeRect();
    return p.home;
  }
  function clockSpot() {
    if (!clockRoot) return null;
    var r = clockRoot.getBoundingClientRect();
    if (!r.width) return null;
    return { cx: r.left + r.width * 0.32, top: r.top };
  }
  function peekOver() { return 12 * petApi.scale; }
  function peekX() {
    // 探头：让「头」探出侧栏右缘一点点（约 12px），不是整只游到正文上
    var s = homeNow();
    return s.sb ? Math.round(s.sb.l + s.sb.w - PET_W * petApi.scale + peekOver()) : s.r;
  }
  function clampToSafe() {
    var s = homeNow(), p = petApi;
    p.x = Math.min(s.r, Math.max(s.l, p.x));
    p.y = Math.min(s.b, Math.max(s.t, p.y));
  }
  function inHome() {
    var s = homeNow(), p = petApi, pad = 18;
    return p.x > s.l - pad && p.x < s.r + pad && p.y > s.t - pad && p.y < s.b + pad;
  }
  function clampToWindow() {
    var p = petApi;
    p.x = Math.min(window.innerWidth - PET_W - 6, Math.max(6, p.x));
    p.y = Math.min(window.innerHeight - PET_H - 6, Math.max(6, p.y));
  }
  function pickTarget() {
    var s = homeNow(), p = petApi;
    p.tx = s.l + Math.random() * Math.max(0, s.r - s.l);
    p.ty = s.t + Math.random() * Math.max(0, s.b - s.t);
    clampToSafe();
  }
  function fleeFrom(x, y, dur) {
    var p = petApi;
    p.mode = 'flee';
    p.restUntil = now() + (dur || 1.2) * 1000;
    var ang = Math.atan2(p.y - y, p.x - x) + (Math.random() - 0.5) * 0.9;
    var dist = 120 + Math.random() * 140;
    p.tx = p.x + Math.cos(ang) * dist;
    p.ty = p.y + Math.sin(ang) * dist;
    clampToSafe();
  }
  // 本地单位 → 世界坐标（考虑朝向与缩放）。lx/ly 是 viewBox 单位。
  // 缩放/翻转都发生在「固定尺寸的盒子内部、且以盒子中心为原点」，所以基准是盒子中心。
  function toWorld(lx, ly) {
    var p = petApi;
    var facing = Math.cos(p.heading) < 0 ? -1 : 1;
    var px = (lx - VB.x) * (PET_W / VB.w) * p.scale;
    var py = (ly - VB.y) * (PET_H / VB.h) * p.scale;
    return { x: p.x + PET_W / 2 + facing * (px - PET_W * p.scale / 2),
             y: p.y + PET_H / 2 + (py - PET_H * p.scale / 2) };
  }
  function petCenter() {
    var p = petApi;
    return { x: p.x + PET_W / 2, y: p.y + PET_H / 2 };
  }

  // ── 4.2 搭建：立体化 + 分层（升力 / 挤压 / 姿态各占一层，互不干扰）────────
  function buildPet() {
    if (petLayer) return;
    var sv = 'http://www.w3.org/2000/svg';
    var layer = document.createElement('div');
    layer.id = 'ft-pet-layer';
    layer.setAttribute('data-ft-own', '1');

    var pet = document.createElement('div');
    pet.id = 'ft-pet';

    // 地面接触阴影：贴在世界坐标上，宠物跳起来时它缩小变淡 → 立体感的主要来源
    var shadow = document.createElement('div');
    shadow.id = 'ft-pet-shadow';

    // 升力层：跳跃/浮沉只作用于它，阴影留在「地面」
    var lift = document.createElement('div');
    lift.id = 'ft-pet-lift';
    // 挤压层：体积守恒的 Q 弹缩放，原点压在下腹，像果冻一样往地上摊
    var squash = document.createElement('div');
    squash.id = 'ft-pet-squash';
    // 姿态层：侧倾 + 摆尾
    var roll = document.createElement('div');
    roll.id = 'ft-pet-roll';

    var svg = document.createElementNS(sv, 'svg');
    svg.setAttribute('viewBox', VB.x + ' ' + VB.y + ' ' + VB.w + ' ' + VB.h);
    svg.setAttribute('width', PET_W);
    svg.setAttribute('height', PET_H);

    var defs = document.createElementNS(sv, 'defs');

    // 建一个渐变（否则每个 stop 三次 setAttribute，铺满整屏）
    function mkGrad(id, tag, attrs, stops) {
      var g = document.createElementNS(sv, tag);
      g.setAttribute('id', id);
      for (var k in attrs) g.setAttribute(k, attrs[k]);
      for (var n = 0; n < stops.length; n++) {
        var st = document.createElementNS(sv, 'stop');
        for (var k2 in stops[n]) st.setAttribute(k2, stops[n][k2]);
        g.appendChild(st);
      }
      defs.appendChild(g);
      return g;
    }
    var ACC = 'var(--ft-accent)', ACCS = 'var(--ft-accent-strong)';

    // ── 立体着色：光从「左上·前方」来（头朝左）───────────────────────────
    // 拆成 底(中间调) → 主光 → 形体阴影 → 触地暗部 四层，而不是全塞进一个径向渐变：
    // 旧写法有两个毛病 —— ① 渐变外圈 50% 是同一个 flat 色，身体中下部完全平；
    // ② 另贴了一块白色「腹部透光」，正好落在嘴下方，是一坨没形状的光斑，
    //    读起来是贴纸而不是体积（用户 2026-09-19 指出）。
    var LX1 = -1, LY1 = -2, LX2 = 20, LY2 = 16;        // 光轴：左上 → 右下（viewBox 单位）

    // ① 主光：亮度还是 accent-strong 本身，只降 stop-opacity → 换皮肤不会串色
    var gKey = mkGrad('ft-pet-key', 'linearGradient',
      { gradientUnits: 'userSpaceOnUse', x1: LX1, y1: LY1, x2: LX2, y2: LY2 },
      [{ offset: '0', 'stop-color': ACCS, 'stop-opacity': '1' },
       { offset: '0.30', 'stop-color': ACCS, 'stop-opacity': '0.80' },
       { offset: '0.62', 'stop-color': ACCS, 'stop-opacity': '0.24' },
       { offset: '1', 'stop-color': ACCS, 'stop-opacity': '0' }]);

    // ①b 皮下透光：迎光一侧从内部透出暖光，让厚实身体读成有体积的实体而非涂色片
    // ⚠️ 颜色一律走皮肤变量（ACCS），不能用写死的暖白 —— 写死的话换皮肤就串色
    mkGrad('ft-pet-sss', 'radialGradient', { cx: '0.5', cy: '0.32', r: '0.70' },
      [{ offset: '0', 'stop-color': ACCS, 'stop-opacity': '0.42' },
       { offset: '0.45', 'stop-color': ACCS, 'stop-opacity': '0.13' },
       { offset: '1', 'stop-color': ACCS, 'stop-opacity': '0' }]);
    // ② 形体阴影：**必须沿光轴做线性**，不能用径向。
    //    试过径向（中心放身体外下方）：光只够到头前那一块，尾鳍在光轴远端
    //    仍然和身体中段一样亮 → 整只还是平的（实测动态范围只有 82）。
    //    改成沿光轴线性后，尾巴、下腹、右下轮廓会一起依次压暗，才读得成球。
    var gForm = mkGrad('ft-pet-form', 'linearGradient',
      { gradientUnits: 'userSpaceOnUse', x1: LX1, y1: LY1, x2: LX2, y2: LY2 },
      [{ offset: '0', 'stop-color': 'rgba(8,10,16,0)' },
       { offset: '0.36', 'stop-color': 'rgba(8,10,16,0.06)' },
       { offset: '0.66', 'stop-color': 'rgba(8,10,16,0.22)' },
       { offset: '1', 'stop-color': 'rgba(8,10,16,0.46)' }]);

    // ③ 下腹再补一层径向：把暗部往腹部收，补出下半个球的转折
    var gForm2 = mkGrad('ft-pet-form2', 'radialGradient', { cx: '0.52', cy: '0.98', r: '0.58' },
      [{ offset: '0', 'stop-color': 'rgba(8,10,16,0.46)' },
       { offset: '0.55', 'stop-color': 'rgba(8,10,16,0.12)' },
       { offset: '1', 'stop-color': 'rgba(8,10,16,0)' }]);

    // ④ 触地暗部：只吃最下面一条，给「坐在那儿」的重量
    mkGrad('ft-pet-gnd', 'linearGradient', { x1: '0', y1: '0.72', x2: '0', y2: '1' },
      [{ offset: '0', 'stop-color': 'rgba(6,8,14,0)' },
       { offset: '1', 'stop-color': 'rgba(6,8,14,0.13)' }]);

    // ④ 高光两层：大的一层铺开读作弧面，小的一层钉一个亮点读作镜面
    mkGrad('ft-pet-sheen', 'radialGradient', {},
      [{ offset: '0', 'stop-color': 'rgba(255,255,255,0.74)' },
       { offset: '0.55', 'stop-color': 'rgba(255,255,255,0.16)' },
       { offset: '1', 'stop-color': 'rgba(255,255,255,0)' }]);
    mkGrad('ft-pet-spec', 'radialGradient', {},
      [{ offset: '0', 'stop-color': 'rgba(255,255,255,1)' },
       { offset: '0.5', 'stop-color': 'rgba(255,255,255,0.6)' },
       { offset: '1', 'stop-color': 'rgba(255,255,255,0)' }]);

    // ⑤ 轮廓光：旧版是一圈均匀白描边（读作剪刀边）→ 改成方向性，
    //    迎光的上左轮廓亮、背光的下右轮廓压暗。用 userSpaceOnUse + 显式坐标，
    //    不依赖 bbox 语义，渲染引擎之间最确定。
    var gRim = mkGrad('ft-pet-rim', 'linearGradient',
      { gradientUnits: 'userSpaceOnUse', x1: LX1, y1: LY1, x2: LX2, y2: LY2 },
      [{ offset: '0', 'stop-color': 'rgba(255,255,255,0.88)' },
       { offset: '0.34', 'stop-color': 'rgba(255,255,255,0.44)' },
       { offset: '0.72', 'stop-color': 'rgba(255,255,255,0.10)' },
       { offset: '1', 'stop-color': 'rgba(255,255,255,0)' }]);
    var gEdge = mkGrad('ft-pet-edge', 'linearGradient',
      { gradientUnits: 'userSpaceOnUse', x1: LX1, y1: LY1, x2: LX2, y2: LY2 },
      [{ offset: '0', 'stop-color': 'rgba(0,0,0,0)' },
       { offset: '0.55', 'stop-color': 'rgba(0,0,0,0.10)' },
       { offset: '1', 'stop-color': 'rgba(0,0,0,0.34)' }]);


    // ⑦ 柔化滤镜：两层高光的模糊半径不同（大的更散）
    var filt = document.createElementNS(sv, 'filter');
    filt.setAttribute('id', 'ft-pet-soft');
    filt.setAttribute('x', '-60%'); filt.setAttribute('y', '-80%');
    filt.setAttribute('width', '220%'); filt.setAttribute('height', '260%');
    var blur = document.createElementNS(sv, 'feGaussianBlur');
    blur.setAttribute('stdDeviation', '0.5');
    filt.appendChild(blur);
    defs.appendChild(filt);

    var filt2 = document.createElementNS(sv, 'filter');
    filt2.setAttribute('id', 'ft-pet-soft2');
    filt2.setAttribute('x', '-60%'); filt2.setAttribute('y', '-80%');
    filt2.setAttribute('width', '220%'); filt2.setAttribute('height', '260%');
    var blur2 = document.createElementNS(sv, 'feGaussianBlur');
    blur2.setAttribute('stdDeviation', '0.86');
    filt2.appendChild(blur2);
    defs.appendChild(filt2);

    svg.appendChild(defs);

    var d = whaleD();
    petApi.dLen = d.length;   // 外轮廓 ≈1789；若误抓成完整品牌路径会是 ≈3448（脸上被挖空）
    function mkShape(cls, parent) {
      var el = document.createElementNS(sv, 'path');
      el.setAttribute('d', d);
      el.setAttribute('class', cls);
      (parent || svg).appendChild(el);
      return el;
    }

    // 叠放顺序＝受光顺序：底色 → 主光 → 形体阴影×2 → 触地暗 → 高光×2 → 轮廓光×2
    // ⚠️ **顺序不能错**：SVG 按文档顺序绘制，底板是不透明的，着色层必须排在它后面。
    //    之前把着色层容器建在底板之前 → 阴影高光全被底板盖住，屏幕上只剩一块平色
    //    （2026-09-19 踩过：探针里 DOM 顺序 `g.ft-pet-shade` 排在 `path.ft-pet-body` 前面）。
    mkShape('ft-pet-body');                    // drop-shadow 只挂在底色这一层（跟着身体镜像）

    // 着色层容器：整只宠物会被 scaleX(±1) 镜像（左右游动）。高光层**不做任何朝向补偿**，
    // 跟着身体一起镜像（用户要的「焊死在图上」，见下方注释）。
    var shade = document.createElementNS(sv, 'g');
    shade.setAttribute('class', 'ft-pet-shade');
    svg.appendChild(shade);
    petApi.shade = shade;

    mkShape('ft-pet-key', shade);
    mkShape('ft-pet-sss', shade);              // 皮下透光（迎光一侧透暖光）
    mkShape('ft-pet-form', shade);
    mkShape('ft-pet-form2', shade);
    mkShape('ft-pet-gnd', shade);

    var sheen = document.createElementNS(sv, 'ellipse');   // 大高光：沿背线铺开
    sheen.setAttribute('cx', '7.9'); sheen.setAttribute('cy', '3.7');
    sheen.setAttribute('rx', '4.9'); sheen.setAttribute('ry', '1.42');
    sheen.setAttribute('transform', 'rotate(-13 7.9 3.7)');
    sheen.setAttribute('class', 'ft-pet-sheen');
    shade.appendChild(sheen);

    var spec = document.createElementNS(sv, 'ellipse');    // 小高光：镜面亮点
    spec.setAttribute('cx', '6.4'); spec.setAttribute('cy', '3.1');
    spec.setAttribute('rx', '2.05'); spec.setAttribute('ry', '0.62');
    spec.setAttribute('transform', 'rotate(-15 6.4 3.1)');
    spec.setAttribute('class', 'ft-pet-spec');
    shade.appendChild(spec);

    var specDot = document.createElementNS(sv, 'circle');  // 湿亮镜面点（软胶玩具质感）
    specDot.setAttribute('cx', '6.0'); specDot.setAttribute('cy', '2.6');
    specDot.setAttribute('r', '0.52');
    specDot.setAttribute('class', 'ft-pet-specdot');
    shade.appendChild(specDot);
    petApi.specDot = specDot;

    mkShape('ft-pet-rim', shade);              // 迎光轮廓（左上亮）
    mkShape('ft-pet-edge', shade);             // 背光轮廓（右下暗）

    // ── 高光「焊死」在图上（2026-09-19 用户决定）─────────────────────────────
    // 旧方案：整只宠物会被 scaleX(±1) 镜像，所以把光的轴向翻回来，让高光永远来自
    // 世界坐标的左上方。用户否了这套「光照逻辑」—— 翻转瞬间高光横跳到另一侧，比不翻更假。
    // 现在**不做任何补偿**：高光就是画在鲸鱼身上的，跟着身体一起镜像，像手绘图/贴纸。
    // 立体感成立就够了。着色层不再持有任何与朝向相关的状态。

    // 胸鳍：**整层已删除**（2026-09-19 用户报「下面还有一层鱼鳍」）。
    // 本体外轮廓右下自带一片鳍的走势；另外贴的那个椭圆鳍落在轮廓外，
    // 和本体自己的鳍叠成「两层鳍」。要一层就只留轮廓自带的那层，不再另画。

    // 脸：眼 + 高光 + 嘴（朝左，眼睛放在头部上前方）
    var face = document.createElementNS(sv, 'g');
    face.setAttribute('class', 'ft-pet-face');
    var eye = document.createElementNS(sv, 'ellipse');
    eye.setAttribute('cx', '5.0'); eye.setAttribute('cy', '7.5');
    eye.setAttribute('rx', '0.66'); eye.setAttribute('ry', '0.72');
    eye.setAttribute('class', 'ft-pet-eye');
    var glint = document.createElementNS(sv, 'circle');
    glint.setAttribute('cx', '4.78'); glint.setAttribute('cy', '7.24');
    glint.setAttribute('r', '0.21');
    glint.setAttribute('class', 'ft-pet-glint');
    var mouth = document.createElementNS(sv, 'path');
    mouth.setAttribute('d', 'M2.5 10.4 Q3.9 11.9 6.0 11.1');
    mouth.setAttribute('class', 'ft-pet-mouth');
    face.appendChild(eye); face.appendChild(glint); face.appendChild(mouth);
    svg.appendChild(face);
    petApi.face = face;
    petApi.eye = eye; petApi.glint = glint; petApi.mouth = mouth;

    roll.appendChild(svg);
    squash.appendChild(roll);
    lift.appendChild(squash);
    pet.appendChild(shadow);
    pet.appendChild(lift);
    layer.appendChild(pet);

    pet.title = '拖我 · 点我 · 长按撸我 · 双击喂我';
    pet.addEventListener('pointerdown', onPetDown);
    pet.addEventListener('pointerenter', function () { petApi.lastInteract = now(); });
    // 单击 = 正向招呼（它看你一眼），不再是「吐个泡泡就完事」
    pet.addEventListener('click', function (e) {
      if (petApi.moved > 6) return;              // 是拖拽不是点击
      e.stopPropagation();
      var p = petApi, t0 = now();
      if (t0 - (p.lastClickAt || 0) < 320) { p.lastClickAt = t0; return; }  // 双击的第一下：不庆祝，等 dblclick 投食
      p.lastClickAt = t0;
      p.lastInteract = t0;
      p.attn = 0;
      p.tame = Math.min(1, p.tame + 0.006);
      p.arousal = Math.min(1, p.arousal + 0.22);
      blow(5);
      p.spin = 1;
      p.hopV = HOP_V0 * 0.82;
      jolt(6.5);
      if (!prefs.zen) { sfxBlip(1.15); sfxChirp(true, 640); }
    });
    // 双击 = 投食（原来这里只是「喷水」，喷水本来就在节目池里能自己触发）
    pet.addEventListener('dblclick', function (e) {
      e.stopPropagation();
      feedAt(e.clientX, e.clientY);
    });

    petLayer = layer;
    petRoot = pet;
    petApi.el = pet;
    petApi.roll_el = roll;
    petApi.lift_el = lift;
    petApi.squash_el = squash;
    petApi.shadow_el = shadow;
    petApi.svg = svg;
  }

  // 弹簧阻尼：挤压量 j 与速度 jv 互相反馈，体积守恒（sx≈1+j*0.9 / sy≈1-j）
  function jolt(v) { petApi.jellyV += v; }
  petApi.hop = function (v) { petApi.hopV = v || HOP_V0; };
  petApi.cheer = function () {                       // 手动上弦：它也精神一振
    petApi.hopV = HOP_V0 * 0.72;
    jolt(-5.2);
    petApi.spin = 0.8;
    sfxChirp(true, 760);
  };
  petApi.celebrate = function () {                    // 任务完成：三连跳 + 星光 + 泡泡
    var p = petApi;
    p.lastInteract = now();
    p.hopV = HOP_V0 * 0.9; jolt(-6.2); p.spin = 1;
    blow(6); sfxChime();
    var i = 1;
    (function again() {
      if (i > 2) return;
      i++;
      setTimeout(function () {
        p.hopV = HOP_V0 * 0.8; jolt(-5.4);
        var c = petCenter();
        sparkle(7, c.x, c.y);
        sfxBlip(1.05 + i * 0.16);
        again();
      }, 420 * i);
    })();
  };

  function onPetDown(e) {
    e.preventDefault();
    var p = petApi;
    p.drag = true;
    p.mode = 'drag';
    p.moved = 0;
    p.downAt = now();
    p.lastInteract = now();
    p.restUntil = 0;
    var r = p.el.getBoundingClientRect();
    p.grabX = e.clientX - r.left;
    p.grabY = e.clientY - r.top;
    p.lastX = e.clientX; p.lastY = e.clientY;
    p.vx = 0; p.vy = 0;
    p.petting = false; p.attn = 0;              // 重新按下 → 「撸」与「注意」的状态清零
    clearFood();                                 // 抓到它就把嘴边的食物收掉
    try { p.el.setPointerCapture(e.pointerId); } catch (err) {}
    sfxBlip(0.85);
    attachDrag();
  }
  // 拖拽期挂在 window 上（指针可能已经移出宠物）。**成对装卸** ——
  // 「撸腻了挣脱」那条路也要摘掉，否则监听器会泄漏。
  function attachDrag() {
    window.addEventListener('pointermove', onPetMove);
    window.addEventListener('pointerup', onPetUp);
    window.addEventListener('pointercancel', onPetUp);
  }
  function detachDrag() {
    window.removeEventListener('pointermove', onPetMove);
    window.removeEventListener('pointerup', onPetUp);
    window.removeEventListener('pointercancel', onPetUp);
  }
  function onPetMove(e) {
    var p = petApi;
    if (!p.drag) return;
    var t = now();
    var nx = e.clientX - p.grabX, ny = e.clientY - p.grabY;
    p.moved += Math.hypot(e.clientX - p.lastX, e.clientY - p.lastY);
    var dt = Math.max(0.008, (t - (p.vt || t)) / 1000);
    p.vx = p.vx * 0.6 + ((e.clientX - p.lastX) / dt) * 0.4;
    p.vy = p.vy * 0.6 + ((e.clientY - p.lastY) / dt) * 0.4;
    p.vt = t;
    p.lastX = e.clientX; p.lastY = e.clientY;
    // 被拎着走：竖向加速度直接喂给果冻，它跟着甩
    jolt(-p.vy * 0.0032 * p.scale);
    p.x = nx; p.y = ny;
    p.lastInteract = t;
  }
  function onPetUp() {
    var p = petApi;
    if (!p.drag) return;
    p.drag = false;
    detachDrag();
    // 撸完的满足反应：先抖一下再往上弹，熟人度上涨
    if (p.petting) {
      p.petting = false;
      p.mode = 'roam';
      p.tame = Math.min(1, p.tame + 0.02);
      p.lastInteract = now();
      p.nextPlay = now() + 1500;
      p.restUntil = 0;
      jolt(-3.4);
      p.hopV = HOP_V0 * 0.34;
      if (!prefs.zen) sfxChirp(true, 860);
      pickTarget();
      return;
    }
    if (p.moved > 6) {                       // 甩出去 → 惯性滑行（可以在整窗飞）
      p.mode = 'throw';
      p.vx = Math.max(-1400, Math.min(1400, p.vx)) * 0.5;
      p.vy = Math.max(-1400, Math.min(1400, p.vy)) * 0.5;
      p.speed = Math.hypot(p.vx, p.vy);
      if (p.speed > 220) { sfxWhoosh(Math.min(1.6, p.speed / 420)); jolt(-Math.min(6, p.speed * 0.006)); }
    } else {
      p.mode = 'roam';
      pickTarget();
    }
    p.restUntil = 0;
  }

  // ── 4.3 特效粒子 ────────────────────────────────────────────────────────
  function blow(n) {
    if (!petLayer || !petRoot) return;
    var p = petApi, r = petRoot.getBoundingClientRect();
    if (!r.width) return;
    var c = petCenter();
    for (var i = 0; i < n; i++) {
      (function (i) {
        var b = document.createElement('span');
        b.className = 'ft-bubble';
        var sz = (3 + Math.random() * 4) * p.scale;
        b.style.width = sz + 'px';
        b.style.height = sz + 'px';
        b.style.left = (c.x - 10 + Math.random() * 20) + 'px';
        b.style.top = (c.y - 6 + Math.random() * 12) + 'px';
        b.style.animationDelay = (i * 90) + 'ms';
        b.style.setProperty('--ft-drift', ((Math.random() - 0.5) * 34).toFixed(1) + 'px');
        petLayer.appendChild(b);
        setTimeout(function () { if (b.parentNode) b.parentNode.removeChild(b); }, 2600 + i * 90);
        if (i === 0 || Math.random() < 0.3) setTimeout(function () { sfxBlip(0.95 + Math.random() * 0.5); }, i * 90);
      })(i);
    }
  }
  petApi.blow = blow;

  // 爱心：撸出来的正反馈标记（比星光慢、比泡泡柔）
  function heart(n) {
    if (!petLayer || !petRoot) return;
    var c = petCenter();
    for (var i = 0; i < n; i++) {
      (function (i) {
        var el = document.createElement('span');
        el.className = 'ft-heart';
        el.style.left = (c.x - 7 + (Math.random() - 0.5) * 24) + 'px';
        el.style.top = (c.y - PET_H * 0.3) + 'px';
        el.style.setProperty('--ft-hx', ((Math.random() - 0.5) * 26).toFixed(1) + 'px');
        el.style.animationDelay = (i * 90) + 'ms';
        petLayer.appendChild(el);
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 1300 + i * 90);
      })(i);
    }
  }

  // ── 投食：双击它 → 在落点放一颗食物，它会游过去吃掉 ──────────────────────
  // 交互之所以「没乐趣」，根因是它此前所有反应都是**躲你**（纯负反馈）。
  // 喂食是第一个「它主动想要的东西」—— 有了目标，交互才有来回。
  function feedAt(cx, cy) {
    var p = petApi, s = homeNow();
    if (!petLayer || !petRoot) return;
    clearFood();
    var x = Math.min(s.r - PET_W * 0.32, Math.max(s.l + PET_W * 0.32, cx));
    var y = Math.min(s.b - PET_H * 0.42, Math.max(s.t + PET_H * 0.5, cy));
    var sz = 9 * p.scale;
    var el = document.createElement('span');
    el.className = 'ft-food';
    el.style.width = sz + 'px'; el.style.height = sz + 'px';
    el.style.left = (x - sz / 2).toFixed(1) + 'px';
    el.style.top = (y - sz / 2).toFixed(1) + 'px';
    petLayer.appendChild(el);
    p.eatTarget = { el: el, x: x, y: y };
    p.chewing = false; p.crumbed = false;
    p.attn = 0; p.petting = false;
    p.mode = 'eat';
    p.actUntil = 0;      // ⚠️ 必须清：残留的节目计时器会在半路把进食态踢回 roam，留下孤儿食物
    p.tx = x - PET_W * 0.5; p.ty = y - PET_H * 0.5;
    clampToSafe();
    p.arousal = Math.min(1, p.arousal + 0.35);
    if (!prefs.zen) sfxBlip(0.95);
  }
  function clearFood() {
    var p = petApi;
    if (p.eatTarget && p.eatTarget.el && p.eatTarget.el.parentNode) {
      p.eatTarget.el.parentNode.removeChild(p.eatTarget.el);
    }
    p.eatTarget = null; p.chewing = false; p.crumbed = false;
  }

  // 喷水：气孔（头顶偏前）朝上抛一小束水花
  function spray(n) {
    if (!petLayer) return;
    var p = petApi;
    var w = toWorld(6.2, 1.1);
    for (var i = 0; i < n; i++) {
      (function (i) {
        var el = document.createElement('span');
        el.className = 'ft-droplet';
        var sz = (3 + Math.random() * 3.4) * p.scale;
        el.style.width = sz + 'px'; el.style.height = sz + 'px';
        el.style.left = (w.x - sz / 2) + 'px';
        el.style.top = w.y + 'px';
        var ang = -Math.PI / 2 + (Math.random() - 0.5) * 1.5;
        var sp = 46 + Math.random() * 62;
        el.style.setProperty('--ft-dx', (Math.cos(ang) * sp * 0.7).toFixed(1) + 'px');
        el.style.setProperty('--ft-dy', (Math.sin(ang) * sp).toFixed(1) + 'px');
        el.style.animationDelay = (i * 24) + 'ms';
        petLayer.appendChild(el);
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 1000 + i * 24);
      })(i);
    }
  }

  // 完成庆祝的小星光（四角星，撒在头顶四周）
  function sparkle(n, cx, cy) {
    if (!petLayer) return;
    for (var i = 0; i < n; i++) {
      (function (i) {
        var el = document.createElement('span');
        el.className = 'ft-spark';
        var a = -Math.PI / 2 + (i / n - 0.5) * 2.4;
        el.style.left = (cx + Math.cos(a) * (26 + Math.random() * 16)) + 'px';
        el.style.top = (cy + Math.sin(a) * (20 + Math.random() * 12) - 10) + 'px';
        el.style.animationDelay = (i * 70) + 'ms';
        petLayer.appendChild(el);
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 1100 + i * 70);
      })(i);
    }
  }

  function ripple() {
    if (!petLayer || !petRoot) return;
    var p = petApi;
    if (document.querySelectorAll('.ft-ripple').length > 7) return;
    var w = toWorld(21, 3);
    var el = document.createElement('span');
    el.className = 'ft-ripple';
    el.style.left = w.x.toFixed(1) + 'px';
    el.style.top = w.y.toFixed(1) + 'px';
    el.style.setProperty('--ft-rx', (Math.random() * 20 - 10).toFixed(1) + 'px');
    petLayer.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 1100);
  }

  function sleepBubble() {
    if (!petRoot || !petLayer) return;
    var p = petApi, r = petRoot.getBoundingClientRect();
    var el = document.createElement('span');
    el.className = 'ft-z';
    el.textContent = 'z';
    el.style.left = (r.left + r.width * 0.74) + 'px';
    el.style.top = (r.top + 4) + 'px';
    petLayer.appendChild(el);
    if (Math.random() < 0.34) sfxSnore();
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 2200);
  }

  // ── 4.4 追着玩的泡泡（会飘、能被戳破）──────────────────────────────────
  function spawnPlayBub() {
    if (!petLayer) return null;
    var s = homeNow(), p = petApi;
    var el = document.createElement('span');
    el.className = 'ft-playbub';
    var sz = 9 + Math.random() * 5;
    el.style.width = sz + 'px'; el.style.height = sz + 'px';
    var b = {
      el: el, r: sz / 2,
      x: s.l + 10 + Math.random() * Math.max(10, s.r - s.l + PET_W - 20),
      y: s.t + 24 + Math.random() * Math.max(10, s.b - s.t),
      vx: (Math.random() - 0.5) * 16,
      vy: -9 - Math.random() * 9,
      ph: Math.random() * 6.3, life: 5.6
    };
    el.style.left = b.x + 'px'; el.style.top = b.y + 'px';
    petLayer.appendChild(el);
    p.playBubs.push(b);
    sfxBlip(1.25);
    return b;
  }
  function popBub(b) {
    var p = petApi, i = p.playBubs.indexOf(b);
    if (i >= 0) p.playBubs.splice(i, 1);
    if (b.el.parentNode) b.el.parentNode.removeChild(b.el);
    blow(1); jolt(2.6); sfxBlip(1.5 + Math.random() * 0.3);
  }
  function clearPlayBubs() {
    var p = petApi;
    for (var i = 0; i < p.playBubs.length; i++) {
      var e = p.playBubs[i].el;
      if (e.parentNode) e.parentNode.removeChild(e);
    }
    p.playBubs = [];
  }
  function tickPlayBubs(dt) {
    var p = petApi, s = homeNow();
    for (var i = p.playBubs.length - 1; i >= 0; i--) {
      var b = p.playBubs[i];
      b.life -= dt;
      b.ph += dt * 1.7;
      b.vy += 6 * dt;                                  // 泡泡「浮力」快到头就往下沉
      b.x += (b.vx + Math.sin(b.ph) * 9) * dt;
      b.y += b.vy * dt;
      if (b.x < s.l) { b.x = s.l; b.vx = Math.abs(b.vx); }
      if (b.x > s.r + PET_W - b.r * 2) { b.x = s.r + PET_W - b.r * 2; b.vx = -Math.abs(b.vx); }
      if (b.y < s.t - 10) b.vy = Math.abs(b.vy) * 0.6;
      if (b.y > s.b + PET_H) b.vy = -Math.abs(b.vy) * 0.6;
      b.el.style.left = b.x.toFixed(1) + 'px';
      b.el.style.top = b.y.toFixed(1) + 'px';
      if (b.life <= 0) {
        if (b.el.parentNode) b.el.parentNode.removeChild(b.el);
        p.playBubs.splice(i, 1);
      }
    }
  }

  // ── 4.5 行为调度 ────────────────────────────────────────────────────────
  // 每个「节目」持续 actUntil 那么久；结束后回 roam。zen（不打扰）时只在原地
  // 做小动作，不发声、不乱跑。
  function startAct(m, t) {
    var p = petApi, s = homeNow();
    p.mode = m;
    p.lastPlay = m;
    p.lastInteract = t;
    p.tx = p.x; p.ty = p.y;                   // 默认原地表演
    if (m === 'stretch') {
      p.actUntil = t + 1500;
      jolt(-5.6);
      if (!prefs.zen) setTimeout(function () { jolt(3.6); }, 520);
    } else if (m === 'spout') {
      p.actUntil = t + 1150;
      jolt(2.4);
      p.hopV = HOP_V0 * 0.3;
      setTimeout(function () { spray(9); sfxSplash(); }, 220);
    } else if (m === 'spin') {
      p.actUntil = t + 1050;
      p.spin = 1;
      sfxWhoosh(1.2);
      jolt(-2.4);
    } else if (m === 'chase') {
      p.actUntil = t + 4600;
      clearPlayBubs();
      spawnPlayBub();
      setTimeout(function () { if (petApi.mode === 'chase') spawnPlayBub(); }, 380);
      setTimeout(function () { if (petApi.mode === 'chase') spawnPlayBub(); }, 760);
    } else if (m === 'peek') {
      p.actUntil = t + 4600;                   // 走一段 + 探头停一会儿，别刚到就结束
      p.tx = peekX(); p.ty = s.t + (s.b - s.t) * (0.3 + Math.random() * 0.5);
      sfxChirp(true, 620);
    } else if (m === 'visitClock') {
      p.actUntil = t + 5600;
      var cs = clockSpot();
      if (cs) { p.tx = cs.cx - PET_W / 2; p.ty = cs.top - PET_H * 0.72; }
      clampToSafe();
      sfxChirp(true, 560);
    } else if (m === 'leap') {
      p.actUntil = t + 1400;                    // 彩蛋：跃出水面（大跳 + 水花 + 两圈涟漪）
      p.hopV = HOP_V0 * 1.62;
      jolt(-7.2);
      setTimeout(function () { spray(11); ripple(); if (!prefs.zen) sfxSplash(); }, 90);
      setTimeout(function () { ripple(); }, 520);
    } else if (m === 'tailChase') {
      p.actUntil = t + 2200;                    // 彩蛋：追自己的尾巴，转完有点晕
      p.spin = 2.6;
      if (!prefs.zen) sfxWhoosh(1.4);
      setTimeout(function () {
        if (petApi.mode === 'tailChase') { petApi.spin = 1.6; blow(3); }
      }, 900);
    } else if (m === 'dash') {
      p.actUntil = t + 1200;                    // 彩蛋：突然冲向窝的另一头，一路水痕
      p.tx = (p.x < (s.l + s.r) * 0.5) ? s.r - PET_W : s.l;
      p.ty = s.t + (s.b - s.t) * (0.25 + Math.random() * 0.5);
      p.arousal = Math.min(1, p.arousal + 0.3);
      if (!prefs.zen) sfxWhoosh(1.5);
    }
  }

  // 彩蛋池：**独立于常规节目池**，只在精力足时以小概率插入 —— 这样才叫「彩蛋」。
  var EGG_POOL = ['leap', 'tailChase', 'dash'];
  function pickPlay(t) {
    var p = petApi;
    var busy = st.mode === 'busy';

    // 彩蛋：只在精力足、心情不差时以低概率插入（约每 2~3 分钟一次）
    if (!prefs.zen && p.stamina > 0.5 && p.mood !== 'tired' && p.mood !== 'annoyed' &&
        Math.random() < 0.07) {
      var egg = EGG_POOL[Math.floor(Math.random() * EGG_POOL.length)];
      startAct(egg, t);
      p.nextPlay = t + 14000 + Math.random() * 16000;
      p.restUntil = 0;
      return egg;                       // 返回抽到的动作：让自动化能断言「池子」而不是猜
    }

    // v4：行为池**按心情过滤**。v3 是七个节目等概率随机抽 → 读起来像随机播放动画；
    // 现在每个行为都能追溯到「它这会儿是什么状态」，才有动机感。
    var pool;
    if (dozing()) {
      // 没人搭理：一半概率自己去睡，否则只在窝边做不出声的小动作（安静玩耍）。
      // 关键是「不出声」——音效闸门（shush）此时是关着的，动作再大也不会响。
      pool = (Math.random() < 0.45) ? ['sleepy'] : ['stretch', 'spin', 'stretch'];
    } else if (prefs.zen) {
      pool = ['stretch', 'spin', 'stretch'];                       // 不打扰：只在窝里做小动作
    } else if (p.mood === 'tired') {
      pool = ['stretch', 'stretch', 'sleepy'];                      // 累了只伸懒腰，还想睡
    } else if (p.mood === 'annoyed') {
      pool = ['stretch', 'spin'];                                   // 闹脾气：不表演
    } else if (p.mood === 'playful') {
      pool = busy ? ['chase', 'spin', 'spout', 'visitClock', 'chase']
                  : ['chase', 'spin', 'spout', 'visitClock', 'chase'];
    } else if (p.mood === 'attached') {
      pool = ['peek', 'chase', 'visitClock', 'spin', 'spout', 'peek'];
    } else {
      pool = busy ? ['spin', 'chase', 'spout', 'visitClock']
                  : ['stretch', 'spout', 'chase', 'peek', 'visitClock', 'spin', 'stretch', 'peek'];
    }

    var m = pool[Math.floor(Math.random() * pool.length)];
    if (m === p.lastPlay && Math.random() < 0.6) m = pool[Math.floor(Math.random() * pool.length)];
    if (m === 'sleepy') {                       // 累了会自己找地方睡
      p.mode = 'sleep'; p.sleepAt = t; p.zAt = t + 900;
      p.tx = p.x; p.ty = p.y; p.actUntil = 0;
      p.nextPlay = t + 30000;
      return 'sleepy';
    }
    startAct(m, t);
    // 越兴奋越爱动；体力低 / 刚被揉腻了 → 间隔拉长（它需要缓一缓）
    var gap = busy ? 3.2 : 6.5;
    gap *= (1.35 - p.arousal * 0.5) * (1 + (1 - p.stamina) * 0.5);
    p.nextPlay = t + (gap + Math.random() * gap * 1.6) * 1000;
    p.restUntil = 0;
    return m;
  }

  function mountPet() {
    if (!prefs.pet) {
      clearPlayBubs();
      clearFood();
      if (petLayer) { petLayer.remove(); petLayer = null; petRoot = null; }
      petApi.home = null;
      return;
    }
    // 侧栏还没被 React 渲染出来 → 先别建，否则会先落在退化窝上、然后当着你面跳回侧栏
    if (!petLayer && !sidebarBox()) {
      if (!petApi.waiting) {
        petApi.waiting = true;
        setTimeout(function () { petApi.waiting = false; mountPet(); }, 400);
      }
      return;
    }
    petApi.home = null;
    if (!petLayer) {
      buildPet();
      var s = homeNow();
      petApi.scale = s.scale;
      petApi.x = s.l + (s.r - s.l) * 0.4;
      petApi.y = s.b;
      petApi.heading = Math.PI;
      petApi.lastInteract = now();
      petApi.nextPlay = now() + 5200;
      petApi.hopV = HOP_V0 * 0.7;
      jolt(-4.4);
      pickTarget();
    }
    if (!petLayer.parentNode) document.body.appendChild(petLayer);
  }

  function wake(why) {
    var p = petApi;
    p.lastInteract = now();
    if (p.mode === 'sleep') { p.mode = 'roam'; p.sleepAt = 0; p.nextPlay = now() + 2400; pickTarget(); }
  }

  petApi.greet = function () {
    var p = petApi, t = now();
    if (!petLayer || prefs.zen) return;
    if (t - p.lastGreet < 45000) return;
    p.lastGreet = t;
    p.hopV = HOP_V0 * 0.5;
    jolt(-3.6);
    blow(2);
    sfxChirp(true, 700);
  };

  // ── 4.5 内部状态：体力 / 兴奋度 / 熟人度 / 心情 ────────────────────────────
  // 「有个性」的落点：它会累、会腻，所以**不是有求必应的按钮**。
  // 心情同时决定 pickPlay 的行为池 —— 于是每个行为都有「理由」，不再是随机抽签。
  function loadTame() {
    try {
      var raw = localStorage.getItem(TAME_KEY);
      if (!raw) return;
      var o = JSON.parse(raw);
      if (typeof o.tame !== 'number') return;
      var days = Math.max(0, (Date.now() - (o.at || Date.now())) / 86400000);
      petApi.tame = Math.max(0, Math.min(1, o.tame - days * 0.045));   // 每天淡忘 ~4.5%
    } catch (e) {}
  }
  function saveTame(nowMs) {
    try {
      localStorage.setItem(TAME_KEY, JSON.stringify({ tame: petApi.tame, at: Date.now() }));
      petApi.tameSaveAt = nowMs;
    } catch (e) {}
  }

  function updatePetState(dt, t) {
    var p = petApi;
    var active = p.petting || p.mode === 'drag' || p.mode === 'throw' || p.mode === 'flee' ||
                 p.mode === 'stretch' || p.mode === 'spout' || p.mode === 'spin' ||
                 p.mode === 'chase' || p.mode === 'eat' || p.mode === 'dash';

    // 体力：运动与互动消耗，窝着 / 睡觉时慢慢回
    var rate = active ? 0.055 : (p.mode === 'sleep' ? -0.024 : -0.006);
    p.stamina = Math.max(0, Math.min(1, p.stamina - rate * dt));

    // 兴奋度：交互与速度拉高，自然回落（驱动瞳孔、游速、各动作频率）
    var want = 0.16 + Math.min(0.45, p.speed / 460) + (active ? 0.22 : 0);
    if (t - p.lastInteract < 1600) want += 0.32;
    p.arousal += (Math.min(1, want) - p.arousal) * Math.min(1, dt * 0.7);

    // 腻：连续被揉会涨、闲置会散 —— 涨满它就会挣脱（「会腻」的个性）
    if (p.petting) p.bored = Math.min(1, p.bored + dt * 0.145);
    else p.bored = Math.max(0, p.bored - dt * 0.055);

    if (t - (p.tameSaveAt || 0) > 60000) saveTame(t);    // 每分钟落一次盘，别每帧写 localStorage

    // 心情
    var mood;
    if (p.stamina < 0.26) mood = 'tired';
    else if (t < p.petRefuseUntil) mood = 'annoyed';
    else if (active || (t - p.lastInteract < 9000 && p.arousal > 0.45)) mood = 'playful';
    else if (p.tame > 0.4 && t - p.lastInteract < 26000) mood = 'attached';
    else mood = 'curious';
    if (mood !== p.mood) { p.mood = mood; p.moodAt = t; }
  }

  function tickPet(dt, t) {
    if (!petLayer) return;
    var p = petApi, s = homeNow();
    var ph = t / 1000;
    var aiBusy = st.mode === 'busy';
    var lowPow = st.reserve < 0.3;                 // 动力储备见底 → 它也蔫
    if (p.scale !== s.scale) p.scale = s.scale;

    tickPlayBubs(dt);
    updatePetState(dt, t);
    // 食物兜底：只要不再是进食态，就别留一颗孤儿食物挂在侧栏里
    if (p.eatTarget && p.mode !== 'eat') clearFood();

    // 鼠标：活动 / 静止 / 高速掠过（受惊）
    if (mouse.active) {
      var mv = Math.hypot(mouse.vx || 0, mouse.vy || 0);
      p.mouseFast = p.mouseFast * 0.82 + mv * 0.18;
      if (Math.abs(mouse.x - p.mouseStopX) + Math.abs(mouse.y - p.mouseStopY) > 6) {
        p.mouseStopX = mouse.x; p.mouseStopY = mouse.y; p.mouseLast = t;
      }
      p.mouseIdle = t - (p.mouseLast || t);
    }
    var dm = mouse.active ? Math.hypot(p.x - mouse.x, p.y - mouse.y) : 1e9;

    // 受惊：鼠标高速掠过 + 离得近（每个 3.5s 最多一次）
    if (mouse.active && p.mouseFast > 900 && dm < 210 && p.mode !== 'drag' &&
        t - p.lastStartle > 3500 && !prefs.zen) {
      p.lastStartle = t;
      p.mode = 'startle';
      p.actUntil = t + 520;
      jolt(5.4);
      p.blink = 0.06;
      sfxChirp(false, 620);
      clampToSafe();
      p.tx = p.x; p.ty = p.y;
    }

    // ① 拖拽中：位置由指针直接驱动，这里只负责朝向、残影、姿态
    if (p.drag) {
      var dx = p.x - (p.prevX === undefined ? p.x : p.prevX);
      var dy = p.y - (p.prevY === undefined ? p.y : p.prevY);
      if (Math.hypot(dx, dy) > 1.4) p.heading = Math.atan2(dy, dx);
      p.prevX = p.x; p.prevY = p.y;
      p.speed = Math.min(900, Math.hypot(p.vx, p.vy));
      p.lastInteract = t;
      if (t - p.rippleAt > 150 && p.speed > 200) { p.rippleAt = t; ripple(); }

      // ── 撸：按住不动 620ms 才成立（用位移区分「抚摸」与「搬运」）───────────
      if (!p.petting && p.moved < 6 && t - p.downAt > 620) {
        if (p.bored > 0.62 || p.stamina < 0.2) {
          // 会腻 / 会累 → 挣脱，几秒内不再接受抚摸（这就是「有个性」）
          p.petRefuseUntil = t + 4200;
          p.bored = 0.18;
          p.drag = false;
          detachDrag();
          p.mode = 'roam';
          jolt(4.4); p.spin = 0.55;
          if (!prefs.zen) sfxChirp(false, 470);
          pickTarget();
          renderPet(t, ph, 1, dt);
          return;
        }
        p.petting = true;
        p.purrAt = 0; p.heartAt = 0;
        if (!prefs.zen) sfxChirp(true, 880);
      }
      if (p.petting) {
        // 抚摸的持续反馈：手底下轻轻下沉 + 间隔的呼噜声与爱心 + 熟人度上涨 + 掉体力
        var kk = Math.min(1, (t - p.downAt - 620) / 1100);
        p.jellyV += (8.0 * kk) * dt;
        if (t - p.purrAt > 820) { p.purrAt = t; if (!prefs.zen) sfxPurr(0.5 + kk * 0.35); }
        if (t - p.heartAt > 440) { p.heartAt = t; heart(1); }
        p.tame = Math.min(1, p.tame + dt * 0.014);
        p.stamina = Math.max(0, p.stamina - dt * 0.022);
      }

      renderPet(t, ph, 1, dt);
      return;
    }

    // ② 甩出去：整窗惯性滑行 + 撞墙弹回（撞墙会「咚」一下再抖）
    if (p.mode === 'throw') {
      p.x += p.vx * dt; p.y += p.vy * dt;
      p.vx *= Math.pow(0.14, dt); p.vy *= Math.pow(0.14, dt);
      p.speed = Math.hypot(p.vx, p.vy);
      if (p.speed > 2) p.heading = Math.atan2(p.vy, p.vx);
      if (t - p.rippleAt > 120 && p.speed > 260) { p.rippleAt = t; ripple(); }
      var hit = 0;
      if (p.x < 6 || p.x > window.innerWidth - PET_W - 6) { p.vx *= -0.5; hit = Math.abs(p.vx); }
      if (p.y < 6 || p.y > window.innerHeight - PET_H - 6) { p.vy *= -0.5; hit = Math.max(hit, Math.abs(p.vy)); }
      clampToWindow();
      if (hit > 90) { jolt(Math.min(6, hit * 0.012)); sfxThud(Math.min(1.2, hit / 500)); }
      if (p.speed < 52) { p.mode = 'home'; p.speed = 0; }
      renderPet(t, ph, 1, dt);
      return;
    }

    // ③ 回家：被甩到哪儿都会自己游回侧栏的窝
    if (p.mode === 'home') {
      if (inHome()) { p.mode = 'roam'; p.nextPlay = t + 1800; pickTarget(); }
      else {
        var hs = homeNow();
        p.tx = hs.l + (hs.r - hs.l) * 0.5;
        p.ty = hs.t + (hs.b - hs.t) * 0.5;
      }
    }

    // ④ 注意力：**先注意到 → 再判断 → 最后才行动**。
    // v3 是「进 92px 立刻 flee」，零延迟的应答等于按钮，不是生物。
    // 那个 0.4~0.8 秒的停顿，恰恰是「活的」证据。
    if (mouse.active && p.mode === 'sleep' && dm < 170) wake();
    var attnOK = mouse.active && p.mode !== 'sleep' && p.mode !== 'drag' && p.mode !== 'flee' &&
                 p.mode !== 'spout' && p.mode !== 'eat' && !p.petting &&
                 p.mode !== 'leap' && p.mode !== 'tailChase' && p.mode !== 'dash' &&
                 p.mode !== 'home';
    if (p.attn && (!attnOK || dm > 190)) p.attn = 0;           // 走远了 → 收回注意
    if (attnOK) {
      if (!p.attn && dm < 118) {
        p.attn = 1; p.attnAt = t;
        p.attnHold = 230 + Math.random() * 170;
        p.tx = p.x; p.ty = p.y;                                 // 先停住
        if (!prefs.zen) sfxChirp(true, 700);                    // 轻轻一声「嗯？」
      } else if (p.attn === 1 && t - p.attnAt > p.attnHold) {
        // 判断：熟人度 / 心情 / 体力一起决定它凑近看还是躲开（有个性 → 会拒绝你）
        var pr = 0.26 + p.tame * 0.52 - (p.mood === 'annoyed' ? 0.5 : 0) - (p.mood === 'tired' ? 0.2 : 0);
        p.attn = 2; p.attnAt = t;
        p.attnPlan = Math.random() < pr ? 'approach' : 'away';
      } else if (p.attn === 2 && t - p.attnAt > 140) {
        if (p.attnPlan === 'away') {
          fleeFrom(mouse.x, mouse.y, 1.0);
          if (!prefs.zen) sfxChirp(false, 560);
        } else {
          // 凑近看你：目标点取鼠标位置（鼠标在正文里时会被夹到侧栏边缘 → 就是「探头」）
          var s0 = homeNow();
          p.mode = 'roam';
          p.tx = Math.min(s0.r - PET_W, Math.max(s0.l, mouse.x - PET_W * 0.5));
          p.ty = Math.min(s0.b - PET_H, Math.max(s0.t, mouse.y - PET_H * 0.5));
          p.restUntil = t + 1200;
          p.nextPlay = t + 2400;
          p.arousal = Math.min(1, p.arousal + 0.16);
          if (!prefs.zen) sfxChirp(true, 780);
        }
        p.tx = p.tx || p.x; p.ty = p.ty || p.y;
        p.attn = 0;
      }
    }

    // ⑤ 睡觉：几乎不动，周期性冒 z + 极轻的呼噜，靠慢呼吸维持「活着」
    if (p.mode === 'sleep') {
      p.speed += (0 - p.speed) * Math.min(1, dt * 1.2);
      if (t - p.zAt > 2400) { p.zAt = t; sleepBubble(); }
      renderPet(t, ph, 0.5, dt);
      return;
    }

    if (p.mode === 'flee' && t > p.restUntil) { p.mode = 'roam'; pickTarget(); }
    if (p.mode === 'startle' && t > p.actUntil) { p.mode = 'roam'; pickTarget(); }

    // 节目结束 → 回 roam（进食态除外：吃饭不该被节目计时器打断）
    if (p.actUntil && t > p.actUntil && p.mode !== 'roam' && p.mode !== 'eat') {
      clearPlayBubs();
      p.mode = 'roam';
      p.actUntil = 0;
      pickTarget();
    }

    // 挑节目：只在 roam、且没有正在「注意你」的时候
    if (p.mode === 'roam' && t > p.nextPlay && !p.drag && !p.attn) {
      pickPlay(t);
    }

    // ⑥ 各节目的目标点
    if (p.mode === 'peek') {
      // 注意：这里不能用 clampToSafe()，它会把 x 拽回窝的右界 → 永远探不出去
      p.tx = peekX();
      var ty = (mouse.active && p.mouseIdle > 900) ? (mouse.y - PET_H / 2) : p.ty;
      p.ty = Math.min(s.b, Math.max(s.t, ty));
    } else if (p.mode === 'visitClock') {
      var cs2 = clockSpot();
      if (cs2) {
        p.tx = cs2.cx - PET_W * 0.5;
        p.ty = cs2.top - PET_H * 0.68;
        clampToSafe();
      }
    } else if (p.mode === 'eat') {
      // 进食：游到食物跟前 → 咀嚼 → 满足。这是第一个「它主动想要的东西」。
      var f = p.eatTarget;
      if (!f) { p.mode = 'roam'; pickTarget(); }
      else {
        p.tx = f.x - PET_W * 0.5; p.ty = f.y - PET_H * 0.5;
        clampToSafe();
        var pc = petCenter();
        if (!p.chewing && Math.hypot(f.x - pc.x, f.y - pc.y) < 20) {
          p.chewing = true; p.chew = 0; p.chewAt = t;
          if (f.el) { f.el.style.width = '4px'; f.el.style.height = '4px'; }
          if (!prefs.zen) sfxMunch();
        }
        if (p.chewing) {
          p.chew += dt * 2.1;                                   // 咀嚼 → 嘴跟着开合
          if (t - p.chewAt > 340 && !p.crumbed) { p.crumbed = true; sparkle(2, pc.x, pc.y); }
          if (t - p.chewAt > 1000) {
            clearFood();
            p.stamina = Math.min(1, p.stamina + 0.3);
            p.tame = Math.min(1, p.tame + 0.025);
            p.lastInteract = t;
            p.mode = 'roam'; p.nextPlay = t + 1600;
            jolt(2.2);
            if (!prefs.zen) { sfxChirp(true, 900); sfxBlip(1.3); }
            pickTarget();
          }
        }
      }
    } else if (p.mode === 'chase') {
      var b = p.playBubs[0];
      if (b) {
        var c = petCenter();
        p.tx = b.x - PET_W * 0.42;
        p.ty = b.y - PET_H * 0.5;
        if (Math.hypot(b.x - c.x, b.y - c.y) < 26 + b.r) popBub(b);
      }
    } else if (p.mode === 'roam') {
      var d = Math.hypot(p.tx - p.x, p.ty - p.y);
      if (d < 26) {
        if (!p.restUntil) p.restUntil = t + 900 + Math.random() * 2600;
        if (t > p.restUntil) { p.restUntil = 0; pickTarget(); }
      } else {
        p.restUntil = 0;
      }
      // 长时间没人搭理 → 睡觉（阈值由「没人打扰多久打盹」决定，默认 45 秒）
      if (dozing() && t > p.restUntil && d < 40) {
        p.mode = 'sleep'; p.sleepAt = t; p.zAt = t + 900;
        p.tx = p.x; p.ty = p.y; p.actUntil = 0;
      }
      // 鼠标停在正文里不动 → 游到侧栏边上探头看你（不会进正文）
      if (mouse.active && !aiBusy && !dozing() && p.mouseIdle > 1600 && t - p.lastInteract > 7000 &&
          dm > 120 && t - p.lastStartle > 6000) {
        startAct('peek', t);
      }
    }

    // 目标速度：怠速慢悠悠；去机芯/探头要快点（不然还没走到节目就结束了）；
    // AI 运转时它也跟着兴奋；动力见底时蔫
    var base = 58;
    if (p.mode === 'flee') base = 200;
    else if (p.mode === 'chase') base = 118;
    else if (p.mode === 'peek') base = 98;
    else if (p.mode === 'visitClock') base = 122;
    else if (p.mode === 'home') base = 155;
    else if (p.mode === 'eat') base = 134;          // 去吃东西要快点，别磨蹭到「凉了」
    else if (p.mode === 'dash') base = 238;
    if (aiBusy) base *= 1.55;
    if (lowPow) base *= 0.62;
    if (p.stamina < 0.3) base *= 0.72;              // 累了就游不动（会累的个性）
    if (prefs.zen) base *= 0.6;
    // 路远就游快一点（短程仍慢悠悠 → 长程不会「还没走到节目就结束了」）
    var far = Math.hypot(p.tx - p.x, p.ty - p.y);
    if (far > 150) base *= 1.55;
    if (far > 320) base *= 1.5;
    var hold = (p.mode === 'stretch' || p.mode === 'spout' || p.mode === 'spin' || p.mode === 'startle');
    p.targetSpeed = (hold || p.attn === 1 || Math.hypot(p.tx - p.x, p.ty - p.y) < 26) ? 0 : base;
    p.speed += (p.targetSpeed - p.speed) * Math.min(1, dt * 2.4);

    // 「注意到」的那 0.25 秒：身体停住，但**转过头来看着你**。
    // 速度是 0 时 heading 不会自己更新，所以这里要单独把它转向鼠标。
    if (p.attn === 1 && mouse.active) {
      var wantA = Math.atan2(mouse.y - (p.y + PET_H * 0.5), mouse.x - (p.x + PET_W * 0.5));
      var dA = wantA - p.heading;
      while (dA > Math.PI) dA -= TAU;
      while (dA < -Math.PI) dA += TAU;
      p.heading += dA * Math.min(1, dt * 6.5);
    }

    if (p.speed > 2) {
      var want = Math.atan2(p.ty - p.y, p.tx - p.x);
      var diff = want - p.heading;
      while (diff > Math.PI) diff -= Math.PI * 2;
      while (diff < -Math.PI) diff += Math.PI * 2;
      p.heading += diff * Math.min(1, dt * 3.4);       // 平滑转向 → 自然是弧线游动
      p.x += Math.cos(p.heading) * p.speed * dt;
      p.y += Math.sin(p.heading) * p.speed * dt;
    }

    // 越界回拉：余量收到 10px（探头时允许探出侧栏，但不许压到正文列）
    var pad = 10;
    var rb = (p.mode === 'peek') ? Math.max(s.r, peekX()) : s.r;
    if (p.x < s.l - pad || p.x > rb + pad || p.y < s.t - pad || p.y > s.b + pad) {
      p.x = Math.min(rb, Math.max(s.l, p.x));
      p.y = Math.min(s.b, Math.max(s.t, p.y));
      if (p.mode !== 'peek') pickTarget();
    }

    if (t - p.rippleAt > 200 && p.speed > 150) { p.rippleAt = t; ripple(); }
    renderPet(t, ph, lowPow ? 0.7 : 1, dt);
  }

  // ── 4.6 姿态渲染：朝向翻转 / 侧倾 / 摆尾 / Q 弹挤压 / 跳跃 / 呼吸 / 眨眼 ──
  // transform 数字的唯一出口。CSSOM 对非法值（如 rotate(NaNdeg)）是**静默丢弃**：
  // 不抛异常、style 属性保持为空 → 整层动画凭空消失，而所有 DOM 探针读到的只是空串，
  // 连 NaN 都扫不出来（2026-09-19 就是这么让尾摆层假死了一整轮）。
  // 走这里把非有限值降级成 0，让故障表现为「动作变僵」而不是「整套隐身」。
  function fx(v, d) { return (isFinite(v) ? v : 0).toFixed(d === undefined ? 2 : d); }

  function renderPet(t, ph, liveliness, dt) {
    var p = petApi;
    if (!p.el) return;
    dt = dt || 0.016;
    var facing = Math.cos(p.heading) < 0 ? -1 : 1;
    var moving = p.speed > 14;
    var speedK = Math.min(1, p.speed / 220);

    // ── 偶发抽动：真实动物从不完全规律。每 5~16 秒来一下 100~160ms 的小事件 ──
    // （甩头 / 单侧抖 / 哆嗦）—— 最廉价也最有效的「活着」信号。
    // ⚠️ 这段的位置是**功能性的**，不是风格问题：`var tw` 会提升到 renderPet 顶部，
    //    所以只要声明出现在任何使用点之后，前面的 `tilt += tw * 3.2` 就会读到
    //    undefined → tilt=NaN → p.roll=NaN → 最终拼出 'rotate(NaNdeg)'。
    //    而 CSSOM 对非法 transform 是**静默丢弃**的：不抛异常、style 属性保持为空，
    //    于是整层尾摆/侧倾/翻滚/抽动完全不渲染却零报错。
    //    （2026-09-19 无头实证查出：当时全页面没有任何元素带 rotate/skew。
    //      教训：NaN 走到 CSS 边界就隐身了，DOM 探针读不出 NaN，只会读到空串。）
    if (p.twitchK <= 0 && t > p.twitchAt) {
      p.twitchAt = t + 5000 + Math.random() * 11000;
      if (liveliness > 0.55 && p.mode !== 'sleep' && !p.petting) {
        p.twitchK = 1; p.twitchDir = Math.random() < 0.5 ? -1 : 1;
      }
    }
    if (p.twitchK > 0) {
      p.twitchK = Math.max(0, p.twitchK - dt * 7.5);
      if (p.twitchK <= 0) p.twitchAt = t + 5200 + Math.random() * 11000;
    }
    var tw = p.twitchK * p.twitchK * p.twitchDir;      // 平方衰减 → 急起缓落

    // 侧倾：航向的竖直分量 + 被点时的翻滚；静止时走自己的慢相位（不再跟呼吸同频）
    var tilt = moving ? Math.sin(p.heading) * 14 * facing + Math.sin(p.phIdle * TAU) * 2.6
                      : Math.sin(p.phIdle * TAU) * 3.4 * liveliness;
    tilt += tw * 3.2;
    if (p.spin > 0) {
      p.spin = Math.max(0, p.spin - dt * 2.2);
      tilt += Math.sin(p.spin * Math.PI) * -34 * facing;
    }
    // 防线：roll 是低通滤波的累积量，一旦被 NaN 污染就**永远出不来**
    // （NaN - NaN 还是 NaN）。历史上正是这个原因让尾摆层从 v4 上线起静默死掉。
    // 任何原因导致 tilt 变 NaN，这里下一帧就能自愈，而不是永久卡死。
    if (!isFinite(tilt)) tilt = 0;
    if (!isFinite(p.roll)) p.roll = 0;
    p.roll += (tilt - p.roll) * Math.min(1, dt * 8);

    // 跳跃（正经物理）——落地那一下会「啪」地压扁
    if (p.hopV !== 0 || p.hopY > 0) {
      var was = p.hopY;
      p.hopY += p.hopV * dt;
      p.hopV -= HOP_G * dt;
      if (p.hopY <= 0) {
        p.hopY = 0;
        if (p.hopV < -60) { jolt(Math.min(7, Math.abs(p.hopV) * 0.011)); sfxThud(Math.min(1, Math.abs(p.hopV) / 420)); }
        p.hopV = 0;
      } else if (was <= 0) {
        jolt(-2.2);                                   // 离地那一下先拉长
      }
    }

    // Q 弹：弹簧阻尼（ω≈13rad/s、ζ≈0.48 → 抖两下就停）
    p.jellyV += (-p.jelly * 165 - p.jellyV * 12.4) * dt;
    p.jelly = Math.max(-0.38, Math.min(0.38, p.jelly + p.jellyV * dt));
    if (p.jelly > 0.3795 || p.jelly < -0.3795) p.jellyV *= 0.4;

    // ── v4 四个独立相位：呼吸 / 尾摆 / 漂移 / 静止微摆 ─────────────────────
    // 这一段是「活鱼感」的地基：四个动作各走各的节奏，不再共用 sin(ph*1.35)。
    p.phBreath += dt * (HZ_BREATH + speedK * 2.2 + p.arousal * 0.30);
    p.phSway   += dt * (HZ_SWAY + speedK * 2.6 + p.arousal * 1.10);
    p.phDrift  += dt * HZ_DRIFT;
    p.phIdle   += dt * 0.52;

    // 漂移：极慢的噪声目标（每 1.8~4.4 秒换一次）+ 一个正弦。
    // 固定正弦一眼就看穿是程序；噪声目标才像「被水流推着」。
    if (t > p.driftNext) {
      p.driftNext = t + 1800 + Math.random() * 2600;
      p.driftTx = (Math.random() - 0.5) * 5.2;
      p.driftTy = (Math.random() - 0.5) * 4.2;
    }
    p.driftX += (p.driftTx - p.driftX) * Math.min(1, dt * 0.85);
    p.driftY += (p.driftTy - p.driftY) * Math.min(1, dt * 0.85);

    // 呼吸（果冻感来自压扁幅度而非整体缩放）+ 游动拉伸
    var breathe = Math.sin(p.phBreath * TAU) * (moving ? 0.024 : 0.018) * (0.6 + liveliness * 0.4);
    var sxs = 1 + p.jelly * 0.88 + breathe + tw * 0.013;
    var sys = 1 - p.jelly - breathe * 0.72 - tw * 0.011;
    if (moving) {
      // ⚠️ 这里**绝不能叫 `st`**：`var` 会提升到函数顶部，把模块级的「运转状态」对象 `st`
      // 在整个 renderPet 里遮蔽掉。静止时本行不执行 → 局部 st 保持 undefined →
      // 下面眨眼那行读 st.reserve 直接抛异常，而且异常点在 nextBlink 赋值之前，
      // 于是「静止时每帧抛一次」，嘴部渲染也永远轮不到（2026-09-19 无头实证查出）。
      var stretchK = Math.min(0.12, p.speed / 1600);
      sxs *= 1 + stretchK; sys *= 1 - stretchK * 0.85;
    }
    if (p.squash_el) p.squash_el.style.transform = 'scale(' + fx(sxs, 3) + ',' + fx(sys, 3) + ')';

    // 位姿：朝向翻转在固定尺寸的盒子里做 → 不会因为缩放/翻转漂移
    p.el.style.transform = 'translate3d(' + fx(p.x, 1) + 'px,' + fx(p.y, 1) + 'px,0) scaleX(' + facing + ')';
    if (p.el.getAttribute('data-pet-mode') !== p.mode) p.el.setAttribute('data-pet-mode', p.mode);

    // 升力：跳跃只抬「车身」，地面阴影留在原处 → 立体感来源
    if (p.lift_el) {
      p.lift_el.style.transform = 'translateY(' + fx(-p.hopY) + 'px) scale(' + fx(p.scale, 3) + ')';
    }
    if (p.shadow_el) {
      var k = Math.max(0, Math.min(1, 1 - p.hopY / 150));
      p.shadow_el.style.transform = 'scale(' + fx(1.14 - k * 0.28, 3) + ',' + fx(1.06 - k * 0.34, 3) + ')';
      p.shadow_el.style.opacity = fx(0.10 + k * 0.30, 3);
    }

    // 摆尾：整体 rotate + 轻微 skew（本体路径含尾，靠这两个合成「摆动」感）。
    // v4 给尾部一个 **0.12 周期的相位滞后** —— 摆动的「波」从身体传向尾巴，而不是整只硬转。
    // 这是鱼类游动最核心的读信号。
    var swayAmp = moving ? (2.2 + speedK * 3.4) : 1.5 * liveliness;
    var sway    = Math.sin(p.phSway * TAU) * swayAmp;
    var swayLag = Math.sin((p.phSway - 0.12) * TAU) * swayAmp * 1.3;
    var rollT = 'rotate(' + fx(p.roll) + 'deg) skewX(' + fx(sway * 0.22 + swayLag * 0.33 + tw * 1.5) + 'deg)';
    if (p.mode === 'sleep') rollT += ' translateY(1.5px)';
    if (p.mode === 'startle') rollT += ' scale(1.06,0.94)';
    p.roll_el.style.transform = rollT;

    // 浮沉：以噪声漂移为主（低频、不规则），叠一点正弦；游泳时再叠尾摆节奏
    var bobY = p.driftY + Math.sin(p.phDrift * TAU * 1.7) * 1.2
             + (moving ? Math.sin(p.phSway * TAU) * 1.5 * speedK : 0) + tw * 1.6;
    p.svg.style.transform = 'translateY(' + fx(bobY) + 'px)';

    // 眨眼：随机间隔；睡觉保持闭眼；受惊瞪大；被撸到舒服得眯眼
    if (p.mode === 'sleep') {
      p.blink = 0.06;
    } else if (p.petting) {
      p.blink += (0.42 - p.blink) * Math.min(1, dt * 6);
    } else {
      if (t > p.nextBlink) { p.blink = 0.06; p.nextBlink = t + (st.reserve < 0.3 ? 3600 : 2200) + Math.random() * 3600; }
      else if (p.blink < 1) p.blink = Math.min(1, p.blink + dt * 9);
    }
    var eyeK = p.mode === 'startle' ? 1.22 : 1;

    // 眼珠：**会看东西**。生物的眼睛一直在追踪；眼睛不动，一眼就被判定成玩具。
    // 眼和身体一起被 scaleX(±1) 镜像，所以「朝屏幕方向」的偏移要乘 facing 才是看对了方向。
    var gtx = 0, gty = 0;
    if (mouse.active) {
      gtx = Math.max(-1, Math.min(1, (mouse.x - (p.x + PET_W * 0.5)) / 115));
      gty = Math.max(-1, Math.min(1, (mouse.y - (p.y + PET_H * 0.5)) / 95));
    }
    p.gazeX += (gtx - p.gazeX) * Math.min(1, dt * 4.5);
    p.gazeY += (gty - p.gazeY) * Math.min(1, dt * 4.5);
    if (p.eye) {
      var gx = p.gazeX * facing * 0.44, gy = p.gazeY * 0.32;
      var dil = 1 + p.arousal * 0.10;                   // 兴奋 → 瞳孔放大
      p.eye.setAttribute('cx', (5.0 + gx).toFixed(3));
      p.eye.setAttribute('cy', (7.5 + gy).toFixed(3));
      p.eye.setAttribute('rx', (0.66 * dil).toFixed(3));
      p.eye.setAttribute('ry', (0.72 * p.blink * eyeK * dil).toFixed(3));
      p.glint.setAttribute('cx', (4.78 + gx).toFixed(3));
      p.glint.setAttribute('cy', (7.24 + gy).toFixed(3));
      p.glint.setAttribute('opacity', p.blink > 0.7 ? '1' : '0');
    }

    // 嘴：不再只在喷水时张开。**常驻的极小开合**是「活体」的第一读信号 ——
    // 让它跟着呼吸相位走；进食时随咀嚼张得最大。
    if (p.mouth) {
      var mOpen;
      // 语音层正在朗读 → 嘴跟着「朗读」走（约 1.4 音节/秒 + 一点抖动，不是整块匀开合）
      if (p.voiceState === 'speaking') {
        mOpen = 0.24 + 0.62 * Math.abs(Math.sin(t * 0.0092 + Math.sin(t * 0.0031) * 1.5));
        if (p.mode === 'sleep') p.mode = 'roam';         // 有人在说话，它不该睡着
      }
      else if (p.mode === 'eat') mOpen = 0.35 + 0.65 * Math.abs(Math.sin(p.chew * TAU));
      else if (p.mode === 'spout' || p.mode === 'chase') mOpen = 1;
      else mOpen = (0.5 + 0.5 * Math.sin(p.phBreath * TAU - 0.5)) * 0.55;
      p.mouth.style.strokeWidth = (0.30 + mOpen * 0.16).toFixed(3);
      var open1 = mOpen > 0.6 ? 1 : 0;
      if (p.mouth.getAttribute('data-open') !== String(open1)) p.mouth.setAttribute('data-open', String(open1));
    }
  }

  // ── 5. 设置入口搬迁：侧栏底行 → 主区标题栏右上角 ─────────────────────────
  var setBtn = null, setReal = null;
  function relocateSettings() {
    var area = document.querySelector('[class$="_settingsArea"]');
    if (!area) return;
    var real = area.querySelector('button');
    if (!real) return;
    setReal = real;
    if (!setBtn) {
      setBtn = document.createElement('button');
      setBtn.id = 'ft-settings-btn';
      setBtn.type = 'button';
      setBtn.title = '设置';
      setBtn.setAttribute('aria-label', '设置');
      setBtn.addEventListener('pointerdown', function (e) { e.stopPropagation(); });
      setBtn.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        if (setReal) setReal.click();          // 转发给 dsh 原生触发器（节点还在，只是被藏起来）
      });
      var icon = real.querySelector('svg');
      if (icon) {
        var c = icon.cloneNode(true);
        c.removeAttribute('width'); c.removeAttribute('height');
        setBtn.appendChild(c);
      } else {
        var sp = document.createElement('span');
        sp.className = 'ft-settings-glyph';
        sp.textContent = '⚙';
        setBtn.appendChild(sp);
      }
    }
    if (!setBtn.parentNode) {
      var host = document.querySelector('[class$="_headerUtilities"]') ||
                 document.querySelector('[class$="_headerCorner"]');
      if (!host) return;                        // 找不到宿主就先不藏原入口，避免设置彻底消失
      host.insertBefore(setBtn, host.firstChild);
    }
    // 只藏「触发那一行」，绝不能藏整个 settingsArea：
    // dsh 的设置面板浮层（.VOzbGW_overlay，position:fixed）是挂在 settingsArea 内部的，
    // 一旦对祖先 display:none，面板会跟着一起消失（这个坑踩过一次）。
    var row = area.querySelector('[class$="_triggerRow"]');
    if (row && !row.hasAttribute('data-ft-hidden')) row.setAttribute('data-ft-hidden', '1');
    // 镜像原生触发器的展开态，样式上给个反馈
    var open = real.getAttribute('aria-expanded') === 'true' ||
               real.getAttribute('data-state') === 'open' ||
               real.getAttribute('aria-pressed') === 'true';
    if (setBtn.getAttribute('data-on') !== (open ? '1' : '0')) setBtn.setAttribute('data-on', open ? '1' : '0');
  }

  // ── 6. 主循环 ────────────────────────────────────────────────────────────
  var lastT = 0, textAcc = 0, lastText = '', pillAcc = 0;
  function loop(t) {
    requestAnimationFrame(loop);
    if (document.hidden) { lastT = t; return; }
    var dt = lastT ? Math.min(0.05, (t - lastT) / 1000) : 0;
    var wasMode = st.mode;
    lastT = t;

    evaluateAlive(dt);
    if (wasMode === 'idle' && st.mode === 'busy') tele.turnStart = sessionTokens();

    // 真实用量：dsh 统计胶囊 400ms 轮询一次（它就是权威数字，只是被缩写过）
    pillAcc += dt;
    if (pillAcc > 0.4) { pillAcc = 0; readPills(); updateLiveRate(); }

    // ── 机芯：角度连续累加 + 速度平滑插值（避免直接改 duration 造成跳变）
    if (clockRoot && clockApi.groups) {
      var target;
      var live = (tele.liveAt && t - tele.liveAt < 3200) ? tele.liveRate : 0;
      if (st.mode === 'busy') {
        // 有真实 token 速率就用真实速率驱动，没有才退回字符速率估算
        target = 42 + (live > 0.5 ? live * 3.0 : Math.min(st.cps, 150) * 1.5);
      } else if (st.mode === 'done') target = 150;
      else target = 7;                                  // 怠速常转 = 生命体征
      if (target > 215) target = 215;                   // 再快就成糊了，只表达「在拼命」为止
      if (clockApi.boost > 0) {
        var bt = (t - clockApi.boostAt) / 1000;
        target += 420 * Math.max(0, 1 - bt / 0.85);     // 上弦：短促加速再回落
        if (bt > 0.9) clockApi.boost = 0;
      }
      clockApi.speed += (target - clockApi.speed) * Math.min(1, dt * 3.2);
      for (var i = 0; i < GEARS.length; i++) {
        var g = GEARS[i];
        var key = g.id;
        clockApi.angle[key] = (clockApi.angle[key] || 0) + clockApi.speed * g.ratio * dt * 4.5;
        clockApi.groups[key].setAttribute('transform',
          'rotate(' + clockApi.angle[key].toFixed(2) + ' ' + g.cx + ' ' + g.cy + ')');
      }
      if (clockRoot.getAttribute('data-mode') !== st.mode) {
        clockRoot.setAttribute('data-mode', st.mode);
      }
      // 状态文字：限流到 ~5Hz，且值不变就不写 DOM（否则自己触发自己）
      textAcc += dt;
      if (textAcc > 0.2) {
        textAcc = 0;
        var tok = sessionTokens();
        var real = tele.ok;
        var txt;
        if (st.mode === 'busy') {
          var liveNow = (tele.liveAt && t - tele.liveAt < 3200) ? tele.liveRate : 0;
          if (liveNow > 1) txt = '生成中 · ' + (Math.round(liveNow * 10) / 10) + ' tok/s';
          else if (real) txt = '生成中 · 累计 ' + fmtTok(tok) + ' tok';
          else txt = '运转中 · ' + Math.max(1, Math.round(st.cps)) + ' 字/秒';
        } else if (st.mode === 'done') {
          txt = (real && tele.turnDelta > 0) ? ('完成 · 本轮 +' + fmtTok(tele.turnDelta) + ' tok')
                                             : '完成';
        } else {
          txt = real ? ('待机 · 累计 ' + fmtTok(tok) + ' tok') : '待机';
        }
        if (txt !== lastText) {
          lastText = txt;
          clockApi.text.textContent = txt;
        }
        // 明细挂在 title 上：悬停可看真实明细
        var det = [];
        if (real) {
          det.push('本次输出 ' + fmtTok(tok) + ' tok');
          if (tele.input) det.push('输入 ' + fmtTok(tele.input + tele.cacheRead));
          if (tele.cache !== null) det.push('缓存命中 ' + tele.cache + '%');
          if (tele.tps) det.push('输出速度 ' + (Math.round(tele.tps * 10) / 10) + ' tok/s');
          if (tele.reasoning) det.push('思考 ' + fmtTok(tele.reasoning));
        } else {
          det.push('未能读到 dsh 用量统计，当前按字符速率估算');
        }
        det.push('点一下手动上弦');
        var ttl = det.join(' · ');
        if (clockRoot.title !== ttl) clockRoot.title = ttl;

        var lit = Math.round(st.reserve * 12);
        if (clockApi.lit !== lit) {
          clockApi.lit = lit;
          var cells = clockApi.ticks.children;
          for (var c = 0; c < cells.length; c++) cells[c].setAttribute('data-on', c < lit ? '1' : '0');
        }
      }
    }

    if (petLayer) tickPet(dt, t);
  }

  // ── 7. 挂载 + 设置面板栏目 ───────────────────────────────────────────────
  function applyPrefs() {
    mountClock();
    mountPet();
    if (setBtn) relocateSettings();
  }

  function injectStyle() {
    if ($('ft-alive-style')) return;
    var s = document.createElement('style');
    s.id = 'ft-alive-style';
    s.textContent = [
      /* ── 发条机芯 ── */
      '#ft-clock{box-sizing:border-box;flex:none;display:flex;align-items:center;gap:10px;padding:10px 8px 12px;margin-top:4px;border-top:1px solid var(--ft-accent-bg);transition:opacity .3s;}',
      '#ft-clock:hover{opacity:1;}',
      '#ft-clock svg{flex:none;overflow:visible;display:block;}',
      '.ft-gear path{fill:var(--ft-accent-bg);stroke:var(--ft-accent-softer);stroke-width:1;transition:stroke .35s ease,fill .35s ease;}',
      '.ft-gear-hub{fill:none;stroke:var(--ft-accent-softer);stroke-width:1;transition:stroke .35s ease;}',
      '#ft-clock[data-mode="busy"] .ft-gear path{stroke:var(--ft-accent);fill:var(--ft-accent-bg);}',
      '#ft-clock[data-mode="busy"] .ft-gear-hub{stroke:var(--ft-accent-soft);}',
      '#ft-clock[data-mode="busy"] svg{filter:drop-shadow(0 0 5px var(--ft-accent-bg));}',
      '#ft-clock[data-mode="done"] .ft-gear path{stroke:var(--ft-accent-strong);}',
      '.ft-clock-pulse{fill:none;stroke:var(--ft-accent-soft);stroke-width:1;opacity:0;transform-box:fill-box;transform-origin:center;}',
      '@keyframes ft-clock-ping{0%{opacity:.75;transform:scale(.62);}100%{opacity:0;transform:scale(2.1);}}',
      '.ft-clock-side{display:flex;flex-direction:column;gap:6px;min-width:0;flex:1;}',
      '.ft-clock-text{font-size:11px;line-height:14px;letter-spacing:.2px;color:var(--ft-status);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:color .3s;font-variant-numeric:tabular-nums;}',
      '#ft-clock[data-mode="busy"] .ft-clock-text{color:var(--ft-accent);}',
      '#ft-clock[data-mode="done"] .ft-clock-text{color:var(--ft-accent-strong);}',
      '.ft-clock-ticks{display:flex;gap:4px;align-items:flex-end;height:12px;transition:opacity .3s;}',
      '#ft-clock[data-mode="idle"] .ft-clock-ticks{opacity:.62;}',
      '.ft-tick{flex:none;width:4px;border-radius:1px;background:var(--ft-accent-bg);transition:background .25s ease,box-shadow .25s ease;}',
      '.ft-tick[data-on="1"]{background:var(--ft-accent-soft);}',
      '#ft-clock[data-mode="busy"] .ft-tick[data-on="1"]{background:var(--ft-accent);box-shadow:0 0 4px var(--ft-accent-bg);}',
      '#ft-clock[data-mode="done"] .ft-tick[data-on="1"]{background:var(--ft-accent-strong);}',
      '[class*="_collapsed"] #ft-clock{flex-direction:column;gap:4px;padding:8px 0 10px;align-items:center;}',
      '[class*="_collapsed"] .ft-clock-side{display:none;}',
      /* ── 小鲸鱼 v3：立体 + Q 弹（升力/挤压/姿态三层分离）── */
      '#ft-pet-layer{position:fixed;inset:0;pointer-events:none;z-index:880;overflow:hidden;}',
      '#ft-pet{position:absolute;left:0;top:0;width:' + PET_W + 'px;height:' + PET_H + 'px;pointer-events:auto;cursor:grab;will-change:transform;opacity:.8;transition:opacity .35s ease;}',
      '#ft-pet:hover{opacity:1;}',
      '#ft-pet[data-pet-mode="drag"]{cursor:grabbing;opacity:1;}',
      '#ft-pet[data-pet-mode="sleep"]{opacity:.46;}',
      // 地面接触阴影：跳起来时由 JS 缩小淡出 → 立体感的主要来源
      '#ft-pet-shadow{position:absolute;left:50%;top:100%;width:58px;height:13px;margin:-7px 0 0 -29px;border-radius:50%;background:radial-gradient(ellipse at 50% 50%,rgba(0,0,0,.58) 0%,rgba(0,0,0,.30) 44%,rgba(0,0,0,0) 72%);filter:blur(1.8px);pointer-events:none;transform-origin:50% 50%;}',
      // 升力层：跳跃只抬「车身」；深色皮肤下补一层同色环境光
      '#ft-pet-lift{position:absolute;inset:0;will-change:transform;transform-origin:50% 50%;filter:drop-shadow(0 0 6px var(--ft-accent-bg));}',
      // 挤压层：体积守恒缩放，原点压在下腹 → 像果冻往地上摊
      '#ft-pet-squash{position:absolute;inset:0;will-change:transform;transform-origin:50% 78%;}',
      '#ft-pet-roll{position:absolute;inset:0;will-change:transform;transform-origin:50% 55%;}',
      '#ft-pet svg{display:block;overflow:visible;transition:transform .12s linear;}',
      // 立体着色链：底色(中间调) → 主光 → 形体阴影 → 触地暗 → 高光×2 → 方向性轮廓光×2
      '.ft-pet-body{fill:var(--ft-accent);filter:drop-shadow(0 2px 4px rgba(0,0,0,.42));}',
      '.ft-pet-key{fill:url(#ft-pet-key);pointer-events:none;}',
      '.ft-pet-form{fill:url(#ft-pet-form);pointer-events:none;}',
      '.ft-pet-form2{fill:url(#ft-pet-form2);pointer-events:none;}',
      '.ft-pet-gnd{fill:url(#ft-pet-gnd);pointer-events:none;}',
      // ⚠️ 必须给 fill：SVG path 默认填充是黑色，漏了这条 = 整只鲸鱼被不透明黑盖住
      '.ft-pet-sss{fill:url(#ft-pet-sss);pointer-events:none;}',
      '.ft-pet-sheen{fill:url(#ft-pet-sheen);filter:url(#ft-pet-soft2);pointer-events:none;}',
      '.ft-pet-spec{fill:url(#ft-pet-spec);filter:url(#ft-pet-soft);opacity:.92;pointer-events:none;}',
      '.ft-pet-specdot{fill:rgba(255,255,255,.96);filter:url(#ft-pet-soft);pointer-events:none;}',
      '.ft-pet-rim{fill:none;stroke:url(#ft-pet-rim);stroke-width:.32;stroke-linejoin:round;pointer-events:none;}',
      '.ft-pet-edge{fill:none;stroke:url(#ft-pet-edge);stroke-width:.34;stroke-linejoin:round;pointer-events:none;}',
      '#ft-pet:hover .ft-pet-body{filter:drop-shadow(0 3px 6px rgba(0,0,0,.44)) drop-shadow(0 0 9px var(--ft-accent-soft));}',
      '.ft-pet-eye{fill:rgba(12,16,26,.86);}',
      '.ft-pet-glint{fill:rgba(255,255,255,.9);}',
      '.ft-pet-mouth{fill:none;stroke:rgba(12,16,26,.45);stroke-width:.3;stroke-linecap:round;}',
      '.ft-pet-mouth[data-open="1"]{stroke-width:.44;}',
      '#ft-pet[data-pet-mode="sleep"] .ft-pet-mouth{opacity:.45;}',
      // 吐出来的泡泡：做成有高光的水球（不是空心圆环）
      '.ft-bubble{position:absolute;border-radius:50%;border:1px solid var(--ft-accent-soft);background:radial-gradient(circle at 34% 30%,rgba(255,255,255,.85) 0%,var(--ft-accent-bg) 58%,rgba(255,255,255,.06) 100%);animation:ft-bubble-up 2.2s ease-out forwards;}',
      '@keyframes ft-bubble-up{0%{opacity:0;transform:translate(0,0) scale(.5);}18%{opacity:.92;}100%{opacity:0;transform:translate(var(--ft-drift,0),-46px) scale(1.15);}}',
      // 追着玩的泡泡：有体积、可以被戳破
      '.ft-playbub{position:absolute;border-radius:50%;border:1px solid var(--ft-accent-soft);background:radial-gradient(circle at 32% 28%,rgba(255,255,255,.92) 0%,var(--ft-accent-bg) 55%,rgba(255,255,255,.05) 100%);box-shadow:0 0 7px var(--ft-accent-bg);}',
      '.ft-ripple{position:absolute;width:16px;height:7px;margin:-3px 0 0 -8px;border-radius:50%;border:1px solid var(--ft-accent-soft);opacity:0;animation:ft-ripple-out 1.05s ease-out forwards;}',
      '@keyframes ft-ripple-out{0%{opacity:.5;transform:scale(.35);}100%{opacity:0;transform:translate(var(--ft-rx,0),6px) scale(1.5);}}',
      // 喷水的水花：抛物线（先上后落）
      '.ft-droplet{position:absolute;border-radius:50%;background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.95),var(--ft-accent-soft));opacity:0;animation:ft-drop .95s cubic-bezier(.28,.72,.6,1) forwards;}',
      '@keyframes ft-drop{0%{opacity:0;transform:translate(0,0) scale(.4);}14%{opacity:.95;}54%{opacity:.9;transform:translate(var(--ft-dx,0px),var(--ft-dy,0px)) scale(1);}100%{opacity:0;transform:translate(calc(var(--ft-dx,0px) * 1.7),24px) scale(.7);}}',
      // 完成庆祝的星光（四角星：两条渐变细线交叉，比圆点更像「闪」）
      '.ft-spark{position:absolute;width:15px;height:15px;margin:-7.5px 0 0 -7.5px;opacity:0;animation:ft-spark-out 1s ease-out forwards;}',
      '.ft-spark::before,.ft-spark::after{content:"";position:absolute;left:50%;top:50%;border-radius:2px;background:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,.96) 50%,rgba(255,255,255,0) 100%);}',
      '.ft-spark::before{width:15px;height:1.5px;margin:-0.75px 0 0 -7.5px;}',
      '.ft-spark::after{width:1.5px;height:15px;margin:-7.5px 0 0 -0.75px;background:linear-gradient(180deg,rgba(255,255,255,0) 0%,rgba(255,255,255,.96) 50%,rgba(255,255,255,0) 100%);}',
      '@keyframes ft-spark-out{0%{opacity:0;transform:scale(.25) rotate(0deg);}25%{opacity:1;}100%{opacity:0;transform:scale(1.35) rotate(120deg) translateY(-10px);}}',
      '.ft-z{position:absolute;font-size:10px;line-height:10px;font-weight:600;color:var(--ft-accent-soft);opacity:0;animation:ft-z-out 2.1s ease-out forwards;pointer-events:none;}',
      '@keyframes ft-z-out{0%{opacity:0;transform:translate(0,0) scale(.7);}25%{opacity:.85;}100%{opacity:0;transform:translate(12px,-26px) scale(1.25);}}',
      // 爱心：两个圆角块交叉 45° 拼出来（不用 emoji）
      '.ft-heart{position:absolute;width:11px;height:10px;opacity:0;animation:ft-heart-up 1.25s ease-out forwards;pointer-events:none;}',
      '.ft-heart::before,.ft-heart::after{content:"";position:absolute;top:0;width:5.5px;height:9px;border-radius:5.5px 5.5px 0 0;background:var(--ft-accent-soft);}',
      '.ft-heart::before{left:5.5px;transform-origin:0 100%;transform:rotate(-45deg);}',
      '.ft-heart::after{left:0;transform-origin:100% 100%;transform:rotate(45deg);}',
      '@keyframes ft-heart-up{0%{opacity:0;transform:translate(0,0) scale(.35);}22%{opacity:.92;}100%{opacity:0;transform:translate(var(--ft-hx,0),-30px) scale(1.05);}}',
      // 食物：一颗会轻轻发光的颗粒（投食的目标物）
      '.ft-food{position:absolute;border-radius:50%;background:radial-gradient(circle at 34% 30%,#fff6dc 0%,var(--ft-accent) 62%,rgba(0,0,0,.22) 100%);box-shadow:0 0 8px var(--ft-accent-soft);animation:ft-food-bob 1.6s ease-in-out infinite;}',
      '@keyframes ft-food-bob{0%,100%{transform:translateY(0);}50%{transform:translateY(-2.5px);}}',
      /* ── 设置入口（搬到主区标题栏后长得像原生图标按钮）── */
      '[class$="_triggerRow"][data-ft-hidden]{display:none !important;}',
      '#ft-settings-btn{flex:none;width:28px;height:28px;display:inline-flex;align-items:center;justify-content:center;padding:0;margin:0;border:1px solid transparent;border-radius:8px;background:transparent;color:var(--dsw-alias-label-secondary);cursor:pointer;transition:background .15s ease,border-color .15s ease,color .15s ease;}',
      '#ft-settings-btn svg{width:16px;height:16px;display:block;}',
      '#ft-settings-btn:hover{background:var(--ft-accent-bg);border-color:var(--ft-accent-softer);color:var(--ft-accent);}',
      '#ft-settings-btn[data-on="1"]{border-color:var(--ft-accent-soft);color:var(--ft-accent);}',
      '.ft-settings-glyph{font-size:15px;line-height:1;}'
    ].join('\n');
    (document.head || document.documentElement).appendChild(s);
  }

  /// 与 switchRow 同一套皮肤的下拉行（「没人打扰时」要选时长，开关表达不了）
  function selectRow(label, desc, options, get, set) {
    var row = document.createElement('div');
    row.style.cssText = 'display:flex;align-items:center;gap:10px;width:100%;padding:10px 12px;border-radius:12px;border:1px solid var(--ft-accent-softer);background:transparent;';
    var txt = document.createElement('div');
    txt.style.cssText = 'flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;';
    var t1 = document.createElement('div');
    t1.style.cssText = 'font-size:13px;line-height:20px;color:var(--dsw-alias-label-primary);';
    t1.textContent = label;
    var t2 = document.createElement('div');
    t2.style.cssText = 'font-size:11px;line-height:16px;color:var(--dsw-alias-label-tertiary);';
    t2.textContent = desc;
    txt.appendChild(t1); txt.appendChild(t2);
    var sel = document.createElement('select');
    sel.style.cssText = 'flex:none;width:96px;box-sizing:border-box;padding:5px 8px;border-radius:8px;font-size:12px;' +
      'background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);border:1px solid var(--ft-accent-softer);outline:none;';
    options.forEach(function (o) {
      var op = document.createElement('option');
      op.value = String(o.v); op.textContent = o.t;
      sel.appendChild(op);
    });
    sel.value = String(get());
    sel.addEventListener('change', function () { set(sel.value); });
    row.appendChild(txt); row.appendChild(sel);
    return row;
  }

  function switchRow(key, label, desc) {
    var row = document.createElement('button');
    row.type = 'button';
    row.style.cssText = 'display:flex;align-items:center;gap:10px;width:100%;padding:10px 12px;border-radius:12px;border:1px solid var(--ft-accent-softer);background:transparent;cursor:pointer;text-align:left;transition:border-color .15s,background .15s;';
    var txt = document.createElement('div');
    txt.style.cssText = 'flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;';
    var t1 = document.createElement('div');
    t1.style.cssText = 'font-size:13px;line-height:20px;color:var(--dsw-alias-label-primary);';
    t1.textContent = label;
    var t2 = document.createElement('div');
    t2.style.cssText = 'font-size:11px;line-height:16px;color:var(--dsw-alias-label-tertiary);';
    t2.textContent = desc;
    txt.appendChild(t1); txt.appendChild(t2);
    var sw = document.createElement('span');
    sw.style.cssText = 'flex:none;width:34px;height:20px;border-radius:10px;position:relative;transition:background .18s;';
    var knob = document.createElement('span');
    knob.style.cssText = 'position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:#fff;transition:transform .18s;box-shadow:0 1px 3px rgba(0,0,0,.4);';
    sw.appendChild(knob);
    row.appendChild(txt); row.appendChild(sw);

    function paint() {
      var on = prefs[key];
      sw.style.background = on ? 'var(--ft-accent)' : 'var(--ft-accent-bg)';
      sw.style.border = on ? '1px solid var(--ft-accent)' : '1px solid var(--ft-accent-softer)';
      knob.style.transform = on ? 'translateX(14px)' : 'translateX(0)';
      row.style.borderColor = on ? 'var(--ft-accent-soft)' : 'var(--ft-accent-softer)';
    }
    row.__ftPaint = paint;
    row.addEventListener('click', function () {
      prefs[key] = !prefs[key];
      savePrefs();
      paint();
      applyPrefs();
      if (key === 'sound' && prefs.sound) {          // 打开时依次试听「机械 + 生灵」
        unlockAudio(); playClack(1);
        setTimeout(function () { sfxBlip(1.1); }, 240);
        setTimeout(function () { sfxChirp(true, 700); }, 400);
      }
    });
    paint();
    return row;
  }

  function ensureAliveSection() {
    var content = document.querySelector('[class$="_content"]');
    if (!content || $('ft-alive-section')) return;
    var sec = document.createElement('div');
    sec.id = 'ft-alive-section';
    sec.style.cssText = 'flex-direction:column;gap:12px;padding:18px 14px;display:flex;border-bottom:1px solid var(--dsw-alias-border-l2);';
    var head = document.createElement('div');
    head.style.cssText = 'display:flex;align-items:center;gap:8px;color:var(--dsw-alias-label-primary);font-size:15px;font-weight:500;line-height:22px;';
    var dot = document.createElement('span');
    dot.style.cssText = 'width:6px;height:6px;border-radius:50%;background:var(--ft-accent);flex:none;';
    head.appendChild(dot);
    head.appendChild(document.createTextNode('生灵'));
    sec.appendChild(head);
    var hint = document.createElement('div');
    hint.style.cssText = 'color:var(--dsw-alias-label-tertiary);font-size:12px;line-height:18px;';
    hint.textContent = '让这间屋子动起来。小鲸鱼住在侧栏里，不挡正文；关掉就是安静模式。';
    sec.appendChild(hint);
    var list = document.createElement('div');
    list.style.cssText = 'display:flex;flex-direction:column;gap:8px;';
    list.appendChild(switchRow('clock', '发条机芯', '侧栏齿轮随 AI 运转转速变化，仪表显示真实 token；点一下手动上弦'));
    list.appendChild(switchRow('pet', '小鲸鱼', '住在侧栏的空白带里；可拖拽/甩出去、会自己游回窝、会追泡泡、会去看齿轮'));
    list.appendChild(switchRow('sound', '音效', '全部程序合成、不引入音频文件：上弦的「咔哒」+ 鲸鱼的吐泡/水花/叫声'));
    list.appendChild(switchRow('zen', '不打扰', '小鲸鱼只在窝里做小动作，不探头、不发声'));
    list.appendChild(selectRow('没人打扰时', '静置这么久它就去睡觉或安静玩耍，并且一个音都不出（生灵的音效会和语音识别抢麦克风）', [
      { t: '15 秒', v: 15000 }, { t: '45 秒', v: 45000 }, { t: '2 分钟', v: 120000 }, { t: '从不打盹', v: 0 }
    ], function () { return prefs.drowsyMs; }, function (v) {
      prefs.drowsyMs = Math.max(0, +v || 0); savePrefs(); markActive();
    }));
    sec.appendChild(list);

    // 紧跟在「皮肤」栏目之后
    var skin = $('ft-skin-section');
    if (skin && skin.parentNode) skin.parentNode.insertBefore(sec, skin.nextSibling);
    else if (content.firstChild) content.insertBefore(sec, content.firstChild);
    else content.appendChild(sec);
  }

  function boot() {
    injectStyle();
    applyPrefs();
    ensureAliveSection();
    readPills();
    requestAnimationFrame(loop);

    // 侧栏 / 设置面板都是 React 后渲染的，用 observer 等它们出现
    if (window.MutationObserver) {
      var pending = false;
      new MutationObserver(function () {
        if (pending) return;
        pending = true;
        setTimeout(function () {
          pending = false;
          mountClock();
          relocateSettings();
          ensureAliveSection();
        }, 220);
      }).observe(document.documentElement, { childList: true, subtree: true });
    }
    // 鼠标位置（被动监听，不干扰页面）
    window.addEventListener('mousemove', function (e) {
      mouse.vx = e.clientX - mouse.x; mouse.vy = e.clientY - mouse.y;
      mouse.x = e.clientX; mouse.y = e.clientY; mouse.active = true;
    }, { passive: true });
    window.addEventListener('mouseleave', function () { mouse.active = false; }, { passive: true });
    window.addEventListener('resize', function () {
      if (!petLayer) return;
      petApi.home = null;            // 侧栏几何变了 → 重新算窝
      clampToSafe(); pickTarget();
    }, { passive: true });
    // 「有人在场」的判定：动鼠标、敲键盘、点一下、滚一下都算。
    // 只要这些动作停了足够久，屋子就自己睡过去 —— 静音也跟着生效。
    var actLast = 0;
    var onAct = function () {
      var t = now(); if (t - actLast < 250) return; actLast = t;
      markActive();
      if (petLayer && petApi.mode === 'sleep') wake('active');   // 人回来了就醒，别赖着睡
    };
    // mousemove 和 pointermove 都听：不同来源（真机 / 自动化）不一定两套都派发，
    // 漏掉任何一种都会让它误以为「人走了」，在有人用的时候睡过去。
    ['pointerdown', 'pointermove', 'mousemove', 'keydown', 'wheel', 'touchstart'].forEach(function (ev) {
      window.addEventListener(ev, onAct, { passive: true });
    });
    window.addEventListener('focus', function () { markActive(); if (petLayer) petApi.greet(); }, { passive: true });
    setTimeout(function () { if (petLayer) petApi.greet(); }, 2600);
    // 音效解锁：WKWebView 需要一次用户手势才能出声
    window.addEventListener('pointerdown', unlockAudio, { passive: true });
    window.addEventListener('keydown', unlockAudio, { passive: true });
    // 打字也算「有人在」→ 鲸鱼醒着
    window.addEventListener('keydown', function () { if (petLayer) wake(); }, { passive: true });
  }

  loadTame();                                 // 载入熟人度（按天衰减：隔几天不理它会淡）
  if (document.body) boot();
  else document.addEventListener('DOMContentLoaded', boot);
})();
