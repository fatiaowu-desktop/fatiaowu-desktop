// 发条屋 · 语音层（voice.js）
// 与生灵层（alive.js）同一套约定：独立 WKUserScript、无构建步骤、无外部依赖。
//
// 分工（重要）：
//   原生 VoiceEngine 负责「听」—— 麦克风采集、电平分桶、SFSpeechRecognizer 识别、
//                             能量门控、唤醒词匹配、判停。
//   本文件负责「看」和「送」—— 波形动画、状态机、把文字写进 harness 的输入框并发送、
//                             监听回复完成、用 Web speechSynthesis 朗读出来。
//
// 为什么 STT 不在这里做：WKWebView 的 webkitSpeechRecognition 是半死实现
// （实测 start() 不抛异常、start/audiostart 触发，然后 12s 内既无 result 也无 error）。
// 为什么 TTS 在这里做：Web speechSynthesis 在 WKWebView 里**可用**（实测 75 音色、zh-CN 婷婷、
// onstart+onend 均触发），比再写一套原生合成器便宜得多。
//
// 波形数据来自原生（30fps 推 28 段 RMS），所以「波形在动」与「识别到字」永远同源同步，
// 不会出现「有波形没文字」的错位。
(function () {
  'use strict';
  if (window.__ftVoice) return;

  var BANDS = 28;                 // 与原生 VoiceEngine.bands 一致
  var PKEY = 'ft-voice-prefs';

  // ── 双页模式 ──
  // 同一份 voice.js 注入两个 WebView：dsh 主页（127.0.0.1:3080）与 DeepSeek 网页版
  // （chat.deepseek.com）。「听」（识别/电平/唤醒/判停）全在原生引擎里，与页面无关；
  // 只有「送到哪儿、怎么插入、怎么发送、怎么发现回复结束」是页面相关的 —— 收进适配层。
  // 原生引擎同一时刻只归属一个页面（voicePage），切页时由 suspend/resume 交接。
  var MODE = /(^|\.)deepseek\.com$/i.test(location.hostname) ? 'chat' : 'dsh';

  // ---------- 偏好 ----------
  var prefs = {
    on: false,           // 语音总开关
    ambient: true,       // 常驻监听（唤醒词）
    wake: '小鲸鱼',
    autoSend: true,      // 说完自动发送
    pauseMs: 1200,       // 停顿多久算说完
    speak: true,         // 自动朗读回复
    voiceURI: '',        // 音色
    rate: 1.05,          // 语速
    bargeIn: true,       // 说话时打断朗读
    // 外放消音（AEC）三档：
    //   auto → 只在「它在说话/刚放完声音」那段时间开（默认，灵敏度和免疫兼得）
    //   on   → 一直开着（页面音效持续不断时选它；代价是整体灵敏度下降）
    //   off  → 完全不消
    echoMode: 'auto',
    forcePath: 'auto',   // 识别通路：auto / network / device
    // 接续窗口：一轮回复结束后这么久内开口，不用再喊唤醒词、也不用点按钮。
    // 没有它就会出现「第一句发出去了，第二句怎么说都没反应」——
    // 因为第二轮系统确实听见了（HUD 上在跳、日志里有字），但只认唤醒词才肯送。
    followMs: 8000,      // 0 = 关闭（每句都要唤醒词）
    cap: 600             // 朗读长度上限（超长的回复只念开头，避免念三分钟）
  };
  function loadPrefs() {
    try {
      var o = JSON.parse(localStorage.getItem(PKEY) || '{}');
      for (var k in prefs) if (o[k] !== undefined && o[k] !== null) prefs[k] = o[k];
      // 旧的布尔 echoCancel 迁到三档 echoMode（老配置 true→常开，false→不消）
      if (typeof o.echoCancel === 'boolean') prefs.echoMode = o.echoCancel ? 'on' : 'off';
      if (prefs.echoMode !== 'auto' && prefs.echoMode !== 'on' && prefs.echoMode !== 'off') prefs.echoMode = 'auto';
    } catch (e) {}
  }
  function savePrefs() {
    try { localStorage.setItem(PKEY, JSON.stringify(prefs)); } catch (e) {}
    // 跨页同步：两个 WebView 的 localStorage 互不相通，偏好统一存到原生，
    // 新页面启动时用 prefsGet 取回（syncPrefs）。语音是全局一份，两页必须同装。
    cmd('prefsPush', { json: JSON.stringify(prefs) });
  }

  // ---------- 状态机 ----------
  // off → 关
  // ambient → 常驻监听，等唤醒词
  // hearing → 电平/识别听到人声，但还没出现唤醒词
  // awake   → 已唤醒，正在捕捉你说的内容（含判停读秒）
  // sending → 收拢中，正在把文字写进输入框并点发送
  // thinking→ 已送出，等 harness 回复
  // speaking→ 正在朗读回复
  // error   → 可恢复的「没听清」或致命错误（VS.fatal 区分）
  //
  // 为什么要分这么细：此前 sending 与 thinking 是同一个态，界面在「还在一遍遍
  // 重试点击发送」的时候就写着「在想」——标签撒了谎，用户自然会觉得不同步。
  // 每一步有独立文案，界面才不会与真实进度错位。
  var VS = {
    state: 'off',
    tgt: new Float32Array(BANDS),
    cur: new Float32Array(BANDS),
    partial: '',
    lastReply: '',
    lastSendAt: 0,
    replyAt: 0,          // 最近一次「回复答完」的时刻：接续窗口的起点
    hearingUntil: 0,
    errorMsg: '',
    fatal: false,
    prevRunning: false,
    pendingDirect: false,
    // ── 视觉相位（都是给渲染用的，不参与逻辑判定）──
    flash: 0,           // 唤醒闪光：0…1，衰减
    fold: 0,            // 收拢：0=展开 1=收成一条线
    quiet: 0,           // 判停读秒进度 0…1（由原生锚点 + 本帧插值得到）
    qAnchorP: 0, qAnchorAt: 0, qHas: false,
    loud: false,        // 真实电平判定「有人在说话」（不等识别出字）
    loudAt: 0,
    sendStep: '', sentText: '', sentAt: 0,
    thinkStartAt: 0, thinkSec: 0,
    speakStartAt: 0, speakEst: 0, speakProg: 0,
    paintTag: '',
    wakeTimer: null,
    busySent: false,        // 已告知原生「AI 在发声」—— 幂等用，避免重复发命令
    guardSent: false,       // 已告知原生「这段时间是外放在响」—— 同样幂等
    suspended: false,       // 页面被切走（原生 toggleChatMode）：只记录状态，不驱动引擎
    lastVoiceAt: 0,         // 最近一次语音活动（出字/唤醒/人声）—— 卡死看门狗的时钟源
    edit: null,             // 本句的「口语自纠」判定（见 spokenEdit）：显示与发送同看这一份
    editOff: false,         // 用户点过「还原原话」→ 本句不再改写
    editForce: '',          // 'cut' = 用户在 suggest 下手动选了「改用后半句」
    editSent: null,         // 已按更正送出的留痕 {raw, out, cut}：thinking 态显示给用户看
    dark: true,             // 主题深浅（原生 setTheme 推送，换肤的唯一真相源）
    status: { running: false, onDevice: false, wakeWords: [] }
  };

  function setState(s, why) {
    if (VS.state === s) return;
    var prev = VS.state;
    VS.state = s;
    if (s !== 'error') VS.fatal = false;   // 离开错误态就别再记着「致命」
    if (prev === 'awake' && s !== 'awake') { VS.quiet = 0; VS.qHas = false; }
    if (s === 'awake') VS.lastVoiceAt = Date.now();   // 看门狗从进捕捉这一刻起算
    if (s === 'thinking') VS.thinkStartAt = Date.now();
    VS.paintTag = '';                      // 强制下一次帧循环重刷文案
    frameStart();                          // 状态一变就确保帧循环在跑（2.23.0 门控的唤醒点）
    paint();
    if (why) log('状态 → ' + s + '（' + why + '）');
    // 「AI 在发声」这个暂停必须跟着状态一起收。
    // 只靠朗读回调解除是不够的：onend 有可能不来（被打断、音色被卸载、页面切走），
    // 一旦漏掉，原生那边 paused 永久为 true，能量上沿直接被丢弃 ——
    // 表现就是「第一轮能发，之后怎么都不识别，只能点按钮」。
    if (s !== 'speaking') setBusyNative(false);
    // 外放守护：它自己要发声（送出、思考、朗读）以及刚发完声的一小段里，
    // 把 AEC 打开，免得这些声音从扬声器绕回麦克风、被当成下一轮的人声。
    // 回 ambient 不立刻关：提示音/朗读的尾巴往往在状态切换之后才响完，多守 2.2 秒。
    if (s === 'sending' || s === 'thinking' || s === 'speaking') guardOn(); else guardOffLater();
    // 生灵层联动：让鲸鱼也知道现在在听/在想/在说
    try { if (window.__ftAliveReact) window.__ftAliveReact(s); } catch (e) {}
  }

  /// 外放守护（对应原生 setEchoGuard）：只在这三档里的 auto 档起作用。
  /// 开的时候会重建采集（约 0.3 秒静默），所以必须幂等，只在跨越边界时真正发命令。
  var guardTimer = null;
  function guardOn() {
    if (guardTimer) { clearTimeout(guardTimer); guardTimer = null; }
    if (VS.guardSent) return;
    VS.guardSent = true;
    cmd('echoGuard', { value: true });
  }
  function guardOffLater() {
    if (guardTimer) clearTimeout(guardTimer);
    guardTimer = setTimeout(function () {
      guardTimer = null;
      if (!VS.guardSent) return;
      VS.guardSent = false;
      cmd('echoGuard', { value: false });
    }, 2200);
  }

  /// 统一的「AI 正在发声」开关：幂等，重复调用不会刷命令。
  function setBusyNative(v) {
    v = !!v;
    if (VS.busySent === v) return;
    VS.busySent = v;
    cmd('busy', { value: v });
  }

  function log(m) {
    try { window.webkit.messageHandlers.fatiaowuLog.postMessage('[voice] ' + m); } catch (e) {}
  }
  function cmd(name, extra) {
    var o = { cmd: name };
    if (extra) for (var k in extra) o[k] = extra[k];
    try { window.webkit.messageHandlers.fatiaowuVoice.postMessage(o); } catch (e) {}
  }
  function cut(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, n) + '…' : s; }

  // ---------- 样式 ----------
  function injectStyle() {
    if (document.getElementById('ft-voice-style')) return;
    var s = document.createElement('style');
    s.id = 'ft-voice-style';
    s.textContent = [
      // 颜色令牌：皮肤层给就用皮肤层的强调色，取不到给一个同色系兜底
      '#ft-vhud,#ft-mic-btn{--ftv-a:var(--ft-accent,#d9a441);',
      '--ftv-a-soft:var(--ft-accent-soft,rgba(217,164,65,.55));',
      '--ftv-a-bg:var(--ft-accent-bg,rgba(217,164,65,.12));}',

      // ── HUD 外壳 ──
      // 尺寸档全部由 data-state 决定，而 width/padding/圆角/画布高度都参与过渡 ——
      // 那个过渡本身就是「收拢 / 张开」动画，不需要另外写一套关键帧去假装。
      // 外壳用「不透明毛玻璃」：blur 负责质感，底色接近不透明保证转写文字任何
      // 背景下都读得清（半透明面板在浅色聊天记录上会糊成一团 —— 实测教训）。
      '#ft-vhud{position:fixed;left:50%;bottom:200px;transform:translateX(-50%);z-index:900;pointer-events:none;',
      'width:min(460px,calc(100vw - 80px));box-sizing:border-box;padding:12px 14px 11px;border-radius:16px;',
      'background:rgba(26,30,42,.94);',
      '-webkit-backdrop-filter:blur(24px) saturate(1.4);backdrop-filter:blur(24px) saturate(1.4);',
      'border:1px solid rgba(255,255,255,.09);',
      'box-shadow:0 10px 34px rgba(0,0,0,.38),inset 0 1px 0 rgba(255,255,255,.05);opacity:0;visibility:hidden;overflow:hidden;',
      'transition:opacity .26s ease,visibility .26s ease,transform .3s cubic-bezier(.22,.9,.3,1),',
      'left .34s cubic-bezier(.22,.9,.3,1),bottom .34s ease,',
      'width .36s cubic-bezier(.22,.9,.3,1),padding .36s cubic-bezier(.22,.9,.3,1),',
      'border-radius .36s ease,border-color .2s ease;',
      'font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;}',
      // 浅色皮肤（翡翠·晨光）的外壳：同样「不透明毛玻璃」的思路，换成暖纸白底。
      // 深浅由原生 setTheme 推送（换肤的唯一真相源），挂成 .ft-light 类。
      // 文字色走 --dsw-alias-label-* 令牌，皮肤本来就按深浅发了两套，不用另配。
      '#ft-vhud.ft-light{background:rgba(248,250,246,.96);border-color:rgba(20,60,40,.16);',
      'box-shadow:0 10px 34px rgba(30,60,45,.16),inset 0 1px 0 rgba(255,255,255,.65);}',
      '#ft-vhud.ft-light .ft-vclose{background:rgba(20,60,40,.08);}',
      '#ft-vhud.ft-light .ft-vclose:hover{background:rgba(20,60,40,.16);}',
      '#ft-vhud[data-state="ambient"],#ft-vhud[data-state="hearing"],#ft-vhud[data-state="awake"],',
      '#ft-vhud[data-state="sending"],#ft-vhud[data-state="thinking"],#ft-vhud[data-state="speaking"],',
      '#ft-vhud[data-state="error"]{opacity:1;visibility:visible;}',

      // 待唤醒：最窄的一条带，够让人知道「它在听」，又不抢注意力
      '#ft-vhud[data-state="ambient"]{padding:8px 12px 7px;width:min(280px,calc(100vw - 80px));}',
      '#ft-vhud[data-state="ambient"] canvas{height:24px;}',
      // 听见人声：张开一点，作为「我听见了」的即时回执
      '#ft-vhud[data-state="hearing"]{padding:9px 13px 9px;width:min(360px,calc(100vw - 80px));',
      'border-color:var(--ftv-a-soft);}',
      '#ft-vhud[data-state="hearing"] canvas{height:34px;}',
      // 送出中 / 在想：收成一颗小药丸，只留一条细波 + 一行字（这就是「收起」的终点）
      '#ft-vhud[data-state="sending"],#ft-vhud[data-state="thinking"]{padding:9px 13px 9px;',
      'width:min(300px,calc(100vw - 80px));border-radius:14px;}',
      '#ft-vhud[data-state="sending"] canvas,#ft-vhud[data-state="thinking"] canvas{height:15px;}',
      // 已唤醒：边框点出强调色，一眼能分出「在捕捉」与「只是在听」
      '#ft-vhud[data-state="awake"]{border-color:var(--ftv-a-soft);}',
      '#ft-vhud[data-state="off"]{opacity:0;visibility:hidden;transform:translateX(-50%) translateY(6px);}',

      // ── 行与文字 ──
      '#ft-vhud .ft-vrow{display:flex;align-items:center;gap:8px;margin-bottom:7px;transition:margin .3s ease;}',
      '#ft-vhud .ft-vdot{width:7px;height:7px;border-radius:50%;background:var(--ftv-a);flex:none;',
      'transition:background .2s ease,box-shadow .2s ease;}',
      '#ft-vhud .ft-vlab{font-size:12px;font-weight:500;color:var(--dsw-alias-label-primary);letter-spacing:.2px;}',
      '#ft-vhud .ft-vhint{font-size:11px;color:var(--dsw-alias-label-tertiary);margin-left:auto;white-space:nowrap;',
      'overflow:hidden;text-overflow:ellipsis;transition:opacity .2s ease,color .2s ease;}',
      // 主动关闭钮：HUD 整体 pointer-events:none，按钮必须单独放开才能点
      '#ft-vhud .ft-vclose{flex:none;width:18px;height:18px;margin-left:6px;border:0;border-radius:50%;',
      'background:rgba(255,255,255,.07);color:var(--dsw-alias-label-tertiary);pointer-events:auto;cursor:pointer;',
      'display:inline-flex;align-items:center;justify-content:center;padding:0;',
      'transition:background .18s ease,color .18s ease,transform .18s ease;}',
      '#ft-vhud .ft-vclose:hover{background:rgba(255,255,255,.16);color:var(--dsw-alias-label-primary);transform:scale(1.12);}',
      '#ft-vhud .ft-vclose:active{transform:scale(.94);}',
      '#ft-vhud canvas{display:block;width:100%;height:52px;transition:height .34s cubic-bezier(.22,.9,.3,1);}',
      // 转写文字同样参与收拢：高度与内边距一起缩到 0，读起来像面板被折起来
      '#ft-vhud .ft-vtx{margin-top:7px;font-size:12px;line-height:17px;color:var(--dsw-alias-label-secondary);',
      'max-height:51px;overflow:hidden;white-space:pre-wrap;word-break:break-word;',
      'transition:max-height .34s cubic-bezier(.22,.9,.3,1),opacity .2s ease,margin .34s ease;}',
      '#ft-vhud[data-state="ambient"] .ft-vtx,#ft-vhud[data-state="hearing"] .ft-vtx,',
      '#ft-vhud[data-state="sending"] .ft-vtx,#ft-vhud[data-state="thinking"] .ft-vtx{max-height:0;opacity:0;margin-top:0;}',
      // ── 口语自纠：划掉重说 ──
      // 撤回段要「看得见但已经作废」：所以是删除线 + 变灰，而不是红色 ——
      // 红代表出错，这个只是你自己的改口。它可点（点 = 按原话发送），是发送前唯一的后悔药。
      '#ft-vhud .ft-vtx .ft-cut{color:var(--dsw-alias-label-tertiary);opacity:.75;',
      'text-decoration:line-through;text-decoration-thickness:1px;pointer-events:auto;cursor:pointer;',
      'transition:opacity .15s ease,color .15s ease;}',
      '#ft-vhud .ft-vtx .ft-cut:hover{opacity:1;color:var(--dsw-alias-label-primary);}',
      // 更正段：送出去的就是这一段，用强调色标出来
      '#ft-vhud .ft-vtx .ft-fix{color:var(--ftv-a);font-weight:500;}',
      '#ft-vhud .ft-vtx .ft-arrow{color:var(--ftv-a);opacity:.7;margin:0 1px;}',
      // 「改用后半句」：辨认出改口、却拆不出撤回范围时的唯一出口
      '#ft-vhud .ft-vtx .ft-ask{pointer-events:auto;cursor:pointer;border:0;background:transparent;padding:0;',
      'font:inherit;color:var(--ftv-a);text-decoration:underline;text-underline-offset:2px;}',
      '#ft-vhud .ft-vtx .ft-ask:hover{opacity:.75;}',
      '#ft-vhud[data-state="ambient"] .ft-vhint{opacity:0;}',
      // 接续窗口里 ambient 也要把提示亮出来：这条提示正是「第二句怎么说」的答案
      '#ft-vhud[data-follow="1"] .ft-vhint{opacity:1;color:var(--ftv-a);}',

      // 状态色：错=危险色
      '#ft-vhud[data-state="error"]{border-color:var(--dsw-alias-border-danger);}',
      '#ft-vhud[data-state="error"] .ft-vdot{background:var(--dsw-alias-label-danger);}',
      // 读秒时提示文字变成强调色：眼睛不用读字也知道「它在倒计时」
      '#ft-vhud[data-prog="quiet"] .ft-vhint{color:var(--ftv-a);}',

      // ── 状态点（每态一个不同的「活法」）──
      // 待唤醒：慢慢呼吸；听见人声：急促闪跳；已唤醒：常亮 + 一圈外辉
      '#ft-vhud[data-state="ambient"] .ft-vdot{animation:ftv-breathe 2.6s ease-in-out infinite;}',
      '@keyframes ftv-breathe{0%,100%{transform:scale(.72);opacity:.4;}50%{transform:scale(1);opacity:1;}}',
      '#ft-vhud[data-state="hearing"] .ft-vdot{animation:ftv-blip .46s ease-out infinite;}',
      '@keyframes ftv-blip{0%{transform:scale(1);opacity:1;}100%{transform:scale(2.4);opacity:0;}}',
      '#ft-vhud[data-state="awake"] .ft-vdot{box-shadow:0 0 0 3px var(--ftv-a-bg),0 0 10px var(--ftv-a-soft);}',

      // ── 唤醒动画（三层叠加：光扫 + 环扩散 + 整块弹一下）──
      // 唤醒是「从被动变主动」的那一刻，必须有一个明确的门槛感。没有它，
      // 用户根本不知道自己有没有喊中，只会反复喊 —— 这也是「不同步」的一种。
      '#ft-vhud .ft-vburst{position:absolute;inset:0;pointer-events:none;opacity:0;}',
      '#ft-vhud.ft-wake .ft-vburst{opacity:1;}',
      '#ft-vhud .ft-vburst i{position:absolute;display:block;}',
      // ① 横向光扫：一条亮线从中心向两侧铺满
      '#ft-vhud .ft-vscene{left:0;right:0;top:50%;height:1.5px;transform:scaleX(0);opacity:0;',
      'background:linear-gradient(90deg,transparent,var(--ftv-a) 40%,#fff 50%,var(--ftv-a) 60%,transparent);}',
      '#ft-vhud.ft-wake .ft-vscene{animation:ftv-sweep .74s cubic-bezier(.2,.7,.25,1);}',
      '@keyframes ftv-sweep{0%{transform:scaleX(0);opacity:0;}16%{opacity:1;}100%{transform:scaleX(1);opacity:0;}}',
      // ② 环：从面板边缘往外扩一圈，像「醒了」的那一下心跳
      '#ft-vhud .ft-vring{inset:0;border-radius:16px;border:1.5px solid var(--ftv-a);opacity:0;}',
      '#ft-vhud.ft-wake .ft-vring{animation:ftv-ring .8s cubic-bezier(.2,.7,.25,1);}',
      '@keyframes ftv-ring{0%{transform:scale(.9);opacity:.85;}70%{transform:scale(1.14);opacity:.12;}100%{transform:scale(1.2);opacity:0;}}',
      // ③ 整块弹一下：克制的小回弹，只为了给一个「重量」
      '#ft-vhud.ft-wake{animation:ftv-pop .5s cubic-bezier(.2,1.5,.35,1);}',
      '@keyframes ftv-pop{0%{transform:translateX(-50%) scale(.985);}45%{transform:translateX(-50%) scale(1.022);}100%{transform:translateX(-50%) scale(1);}}',

      // ── 进度线 ──
      // 读秒时从中心向两侧长出来（与镜像柱同源美学）；朗读时从左往右走（那是「读到哪了」）
      '#ft-vhud .ft-vprog{position:absolute;left:0;right:0;bottom:0;height:2px;opacity:0;',
      'transition:opacity .2s ease;}',
      '#ft-vhud .ft-vprog i{display:block;height:100%;width:100%;transform-origin:50% 50%;transform:scaleX(0);',
      'background:linear-gradient(90deg,transparent,var(--ftv-a) 28%,var(--ftv-a) 72%,transparent);}',
      // 送出成功的确认：整条亮一下再淡掉，给「已经交出去了」一个落点
      '#ft-vhud[data-prog="sent"] .ft-vprog{opacity:1;}',
      '#ft-vhud[data-prog="sent"] .ft-vprog i{background:var(--ftv-a);}',
      '#ft-vhud[data-prog="quiet"] .ft-vprog,#ft-vhud[data-prog="speak"] .ft-vprog,',
      '#ft-vhud[data-prog="sent"] .ft-vprog{opacity:1;}',
      '#ft-vhud[data-prog="speak"] .ft-vprog i{transform-origin:0% 50%;',
      'background:linear-gradient(90deg,var(--ftv-a-soft),var(--ftv-a));}',

      // ── 在想 / 送出中：药丸上扫过一道微光，表示「它在动，不是卡住」──
      '#ft-vhud .ft-vscan{position:absolute;inset:0;opacity:0;pointer-events:none;',
      'background:linear-gradient(100deg,transparent 30%,var(--ftv-a-bg) 46%,rgba(255,255,255,.09) 52%,transparent 70%);',
      'transition:opacity .25s ease;}',
      '#ft-vhud[data-state="thinking"] .ft-vscan,#ft-vhud[data-state="sending"] .ft-vscan{opacity:1;',
      'animation:ftv-scan 1.5s linear infinite;}',
      '@keyframes ftv-scan{0%{transform:translateX(-100%);}100%{transform:translateX(100%);}}',
      // 麦克风按钮：插在发送键左边，尺寸与同级按钮一致
      '#ft-mic-btn{flex:none;width:28px;height:28px;border-radius:8px;cursor:pointer;padding:0;',
      'display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;',
      'border:1px solid var(--dsw-alias-border-l2);background:transparent;color:var(--dsw-alias-label-secondary);',
      'transition:background .16s,border-color .16s,color .16s,transform .12s;}',
      '#ft-mic-btn:hover{background:var(--ftv-a-bg);border-color:var(--ftv-a-soft);color:var(--ftv-a);}',
      '#ft-mic-btn:active{transform:scale(.94);}',
      '#ft-mic-btn[data-on="1"]{border-color:var(--ftv-a-soft);background:var(--ftv-a-bg);color:var(--ftv-a);}',
      // 实时态（在听）：一圈外扩的脉冲，与 HUD 说的是同一件事
      '#ft-mic-btn[data-live="1"]{border-color:var(--ftv-a);}',
      '#ft-mic-btn[data-live="1"]::after{content:"";position:absolute;width:28px;height:28px;border-radius:8px;',
      'border:1px solid var(--ftv-a);opacity:.55;animation:ft-mic-pulse 1.9s ease-out infinite;}',
      '@keyframes ft-mic-pulse{0%{transform:scale(1);opacity:.5;}70%{transform:scale(1.5);opacity:0;}100%{opacity:0;}}',
      // 忙态（送出/在想/在说）：转一圈。让按钮本身也在回答「进行到哪一步了」，
      // 不必让用户的视线每次都回到 HUD 上找答案。
      '#ft-mic-btn[data-busy="1"]::after{content:"";position:absolute;inset:-2px;border-radius:9px;',
      'border:1.5px solid transparent;border-top-color:var(--ftv-a);border-right-color:var(--ftv-a);',
      'animation:ftv-spin .9s linear infinite;}',
      '@keyframes ftv-spin{to{transform:rotate(360deg);}}',
      '#ft-mic-btn[data-err="1"]{border-color:var(--dsw-alias-border-danger);color:var(--dsw-alias-label-danger);}',
      // ── chat 页专用：独立悬浮钮（锚在输入框上方右侧，见 placeMicBtnChat） ──
      // 为什么不再嵌进 DeepSeek 的输入框工具行：那行是 React 管的，位置不可控、
      // 还会在会话重渲染时把外来按钮一起撕走（实测「聊完一轮按钮失踪」）。
      // 独立挂在 body 下 + fixed 定位 = 位置稳定、永不被摘。
      // 动效是功能性的，不是装饰：环脉冲的频率/颜色直接表示「说话会被听到吗」。
      '#ft-mic-btn[data-float="1"]{position:fixed;z-index:901;pointer-events:auto;',
      'width:40px;height:40px;border-radius:50%;padding:0;',
      'border:1px solid var(--ftv-a-soft);background:rgba(26,30,42,.94);color:var(--ftv-a);',
      '-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px);',
      'box-shadow:0 8px 24px rgba(0,0,0,.34);',
      'transition:transform .16s ease,background .2s ease,border-color .2s ease,color .2s ease;',
      'animation:ft-mic-in .42s cubic-bezier(.22,1.25,.36,1) both;}',
      // 提示环：关闭态慢（3.6s，弱）→ 开启态快（2.2s）→ 在听态最快（1.6s）。
      // 环色走 currentColor：灰 = 没开，皮肤强调色 = 开着，用户不必读文字就知道状态。
      '#ft-mic-btn[data-float="1"]::before{content:"";position:absolute;inset:-2px;border-radius:50%;',
      'border:1.5px solid currentColor;opacity:0;animation:ft-mic-ring 3.6s ease-out infinite;}',
      '#ft-mic-btn[data-float="1"].ft-light{background:rgba(250,252,248,.97);color:#1f4d3a;',
      'border-color:rgba(20,60,40,.26);box-shadow:0 8px 24px rgba(30,60,45,.18);}',
      '#ft-mic-btn[data-float="1"][data-on="0"]{color:var(--dsw-alias-label-secondary);}',
      '#ft-mic-btn[data-float="1"][data-on="1"]{border-color:var(--ftv-a);background:var(--ftv-a-bg);}',
      '#ft-mic-btn[data-float="1"][data-on="1"]::before{animation-duration:2.2s;}',
      '#ft-mic-btn[data-float="1"][data-live="1"]{border-color:var(--ftv-a);}',
      '#ft-mic-btn[data-float="1"][data-live="1"]::before{animation-duration:1.6s;opacity:.66;}',
      '#ft-mic-btn[data-float="1"][data-busy="1"]::after{inset:-3px;border-radius:50%;}',
      '#ft-mic-btn[data-float="1"]:hover{transform:scale(1.1);}',
      '#ft-mic-btn[data-float="1"]:active{transform:scale(.96);}',
      '@keyframes ft-mic-ring{0%{transform:scale(1);opacity:.5;}70%{transform:scale(1.65);opacity:0;}100%{opacity:0;}}',
      '@keyframes ft-mic-in{from{transform:scale(.4);opacity:0;}to{transform:scale(1);opacity:1;}}'
    ].join('');
    document.head.appendChild(s);
  }

  // ---------- HUD ----------
  var hud = null, canvas = null, cx2d = null, lab = null, hint = null, vtx = null, closeBtn = null;
  var burstEl = null, scanEl = null, progWrap = null, progFill = null;
  var cw = 0, ch = 0;

  function buildHud() {
    if (hud) return;
    hud = document.createElement('div');
    hud.id = 'ft-vhud';
    hud.setAttribute('data-ft-own', '1');
    hud.setAttribute('data-state', 'off');

    // 覆盖层（绝对定位、不吃事件）：在想/送出的扫描微光、唤醒的光扫与环。
    // 放在内容之前，静态内容才画在它们上面。
    scanEl = document.createElement('div');
    scanEl.className = 'ft-vscan';
    burstEl = document.createElement('div');
    burstEl.className = 'ft-vburst';
    var scene = document.createElement('i'); scene.className = 'ft-vscene';
    var ring = document.createElement('i'); ring.className = 'ft-vring';
    burstEl.appendChild(scene); burstEl.appendChild(ring);

    var row = document.createElement('div');
    row.className = 'ft-vrow';
    var dot = document.createElement('span');
    dot.className = 'ft-vdot';
    lab = document.createElement('span');
    lab.className = 'ft-vlab';
    hint = document.createElement('span');
    hint.className = 'ft-vhint';
    // 主动关闭钮：任何时候（听/想/说）点一下都能把语音整个关掉。
    // 长按麦克风关闭太隐蔽，用户找不到就只好等它自己一直听着。
    closeBtn = document.createElement('button');
    closeBtn.className = 'ft-vclose';
    closeBtn.type = 'button';
    closeBtn.title = '关闭语音';
    closeBtn.setAttribute('aria-label', '关闭语音');
    closeBtn.innerHTML = '<svg width="9" height="9" viewBox="0 0 10 10"><path d="M1 1 L9 9 M9 1 L1 9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
    closeBtn.addEventListener('pointerdown', function (e) { e.stopPropagation(); });
    closeBtn.addEventListener('click', function (e) {
      e.preventDefault(); e.stopPropagation();
      log('已主动关闭语音');
      disableVoice();
    });
    row.appendChild(dot); row.appendChild(lab); row.appendChild(hint); row.appendChild(closeBtn);

    canvas = document.createElement('canvas');
    vtx = document.createElement('div');
    vtx.className = 'ft-vtx';

    // 进度线：读秒（从中心向两侧）或朗读进度（从左往右），两种模式共用一条
    progWrap = document.createElement('div');
    progWrap.className = 'ft-vprog';
    progFill = document.createElement('i');
    progWrap.appendChild(progFill);

    hud.appendChild(scanEl);
    hud.appendChild(row);
    hud.appendChild(canvas);
    hud.appendChild(vtx);
    hud.appendChild(burstEl);
    hud.appendChild(progWrap);
    document.body.appendChild(hud);
    cx2d = canvas.getContext('2d');
    resizeCanvas();
    placeHud();
  }

  function resizeCanvas() {
    if (!canvas || !hud) return;
    var dpr = window.devicePixelRatio || 1;
    var w = canvas.clientWidth || 420;
    var h = canvas.clientHeight || 52;
    if (w === cw && h === ch && canvas.width === Math.round(w * dpr)) return;
    cw = w; ch = h;
    canvas.width = Math.max(1, Math.round(w * dpr));
    canvas.height = Math.max(1, Math.round(h * dpr));
    cx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  // 贴在输入框正上方居中；输入框是框架渲染的，位置会变，所以每帧校正一次
  function placeHud() {
    if (!hud) return;
    if (MODE === 'chat') { placeHudChat(); return; }
    var el = composer();                 // 适配层给当前页的输入框
    if (!el) return;
    var r = el.getBoundingClientRect();
    if (!r.width) return;
    var cx = r.left + r.width / 2;
    var bottom = Math.max(120, window.innerHeight - r.top + 16);
    if (hud.style.left !== cx + 'px') hud.style.left = cx + 'px';
    if (hud.style.bottom !== bottom + 'px') hud.style.bottom = bottom + 'px';
  }
  // chat 页：听/唤醒时面板钉在输入框正上方；送出/等待/朗读时整体滑到**右下角**，
  // 别盖住刚生成的会话内容（用户实测：朗读面板正好挡住正在念的那段回答）。
  // 位置随状态平滑滑动（left/bottom 已加进 HUD 的 transition）。
  // 麦克风钮的定位：锚在输入框卡片的**上方右侧**（右边缘对齐输入框右边）。
  // 那儿是纯空白区：输入框内部的附件/深度搜索/发送键都在卡片里碰不到，
  // 会话内容在更上方也够不着 —— 固定、显眼、且不挡任何东西。
  // 与 HUD 同处一条水平线，视觉上是一件控件组（HUD 居中、钮在右端）。
  // 找不到输入框时退到右下角（绝不隐形：语音关着时它就是开启入口）。
  function placeMicBtnChat() {
    if (!micBtn || micBtn.getAttribute('data-float') !== '1') return;
    var W = 40, GAP = 12, EDGE = 20;
    var left = window.innerWidth - W - EDGE;
    var bottom = EDGE;
    var anchor = '右下角(未命中输入框)';
    var el = composer();
    if (el) {
      var r = el.getBoundingClientRect();
      if (r.width > 0) {
        left = r.right - W;                          // 右对齐输入框右边缘
        bottom = window.innerHeight - r.top + GAP;   // 落在输入框上沿之上
        anchor = '输入框上方右侧';
      }
    }
    // 与居中的 HUD 同一水平线时，若横向上会叠上就让开（HUD 是信息面板，优先）
    var busy = VS.state === 'sending' || VS.state === 'thinking' || VS.state === 'speaking';
    if (!busy && hud && hud.offsetWidth) {
      var hudRight = window.innerWidth / 2 + hud.offsetWidth / 2;
      if (left < hudRight + 10) left = hudRight + 10;
    }
    left = Math.max(EDGE, Math.min(window.innerWidth - W - EDGE, left));
    bottom = Math.max(EDGE, Math.min(window.innerHeight - W - 120, bottom));
    if (micBtn.style.left !== left + 'px') micBtn.style.left = left + 'px';
    if (micBtn.style.bottom !== bottom + 'px') micBtn.style.bottom = bottom + 'px';
    if (micBtn.style.right) micBtn.style.right = '';
    if (micBtn.style.top) micBtn.style.top = '';
    // 一次性定位诊断：真机上「位置对不对」只看这一行 ——
    // 命中输入框则钮落在它上方右侧；写成「右下角」就是选择器没命中（该补 chatComposer 的判据）。
    if (!placeMicBtnChat.logged) {
      placeMicBtnChat.logged = true;
      log('chat 麦克风钮定位: ' + anchor + ' left=' + Math.round(left) + ' bottom=' + Math.round(bottom) +
          ' 视口=' + window.innerWidth + 'x' + window.innerHeight);
    }
  }

  function placeHudChat() {
    placeMicBtnChat();
    var busy = VS.state === 'sending' || VS.state === 'thinking' || VS.state === 'speaking';
    if (busy) {
      // 右下角：HUD 仍是 left + translateX(-50%) 语义，左坐标 = 视口宽 - 半宽 - 边距
      var half = (hud.offsetWidth || 460) / 2;
      var cx = window.innerWidth - half - 16;
      if (hud.style.left !== cx + 'px') hud.style.left = cx + 'px';
      if (hud.style.bottom !== '24px') hud.style.bottom = '24px';
      return;
    }
    var bottom = 24;
    var el = composer();
    if (el) {
      var r = el.getBoundingClientRect();
      if (r.width > 0) bottom = Math.max(24, Math.min(260, window.innerHeight - r.top + 14));
    }
    if (hud.style.left !== '50%') hud.style.left = '50%';
    if (hud.style.bottom !== bottom + 'px') hud.style.bottom = bottom + 'px';
  }

  /// 每一步都要有自己那句话 —— 界面上写什么，就等于系统在做什么。
  /// 「在想」曾经也用来表示「还在重试点发送」，那次撒谎直接被用户读成了「不同步」。
  function paint() {
    if (!hud) return;
    hud.setAttribute('data-state', VS.state);
    var s = VS.state, ht = '';
    var fu = followLeft();
    hud.setAttribute('data-follow', fu > 0 ? '1' : '0');
    if (s === 'ambient') {
      // 接续窗口内必须说清楚「现在直接说就行」，否则用户会一直等一个并不需要的唤醒词
      lab.textContent = fu > 0 ? '接着说' : '在听';
      ht = fu > 0 ? '直接说 · ' + Math.ceil(fu / 1000) + ' 秒内免唤醒'
                  : '说「' + prefs.wake + '」或点麦克风';
    } else if (s === 'hearing') {
      lab.textContent = fu > 0 ? '接着说' : '听见了';
      ht = fu > 0 ? '直接说就行'
                  : '说「' + prefs.wake + '」才发送·也可点麦克风';
    } else if (s === 'awake') {
      lab.textContent = VS.loud ? '在听你说' : '听到了';
      // 判停的这一秒多必须**看得见在数秒**，否则就是纯黑箱 —— 「说完没反应」的来源
      ht = VS.quiet > 0.04
        ? '停一下就好… ' + Math.round(VS.quiet * 100) + '%'
        : '说完停 ' + (prefs.pauseMs / 1000).toFixed(1) + ' 秒自动发送';
    } else if (s === 'sending') {
      lab.textContent = VS.sendStep || '正在送出';
      ht = VS.sentText ? cut(VS.sentText, 18) : '';
    } else if (s === 'thinking') {
      lab.textContent = '在想';
      ht = VS.thinkSec ? '已送出 · ' + VS.thinkSec + ' 秒' : '已送出';
    } else if (s === 'speaking') {
      lab.textContent = '在说'; ht = prefs.bargeIn ? '直接开口可以打断' : '';
    } else if (s === 'error') {
      // 必须显示真实原因。曾经的「语音不可用 / 设置里看详情」把一次
      // 「识别器没吃进音频」藏了整整一轮排查 —— 笼统的错误文案是有代价的。
      lab.textContent = VS.fatal ? '语音不可用' : '没听清';
      ht = VS.errorMsg ? cut(VS.errorMsg, 60) : '设置里看详情';
    } else { lab.textContent = '语音'; ht = ''; }
    hint.textContent = ht;
    if (vtx) {
      if (s === 'thinking') {
        // 改写过就必须说清楚「送出去的是哪一版」—— 用户刚被改过稿，得有据可查
        if (VS.editSent) paintEdit(vtx, null, '已按更正送出：' + VS.editSent.out);
        else vtx.textContent = VS.partial || '已送出，等 harness 回复…';
      } else if (s === 'speaking') {
        vtx.textContent = VS.lastReply ? VS.lastReply.slice(0, 120) : '';
      } else {
        // 划掉重说：一边说一边把改口的痕迹划出来（见 spokenEdit）
        paintEdit(vtx, VS.editOff ? null : VS.edit, VS.partial || '');
      }
    }
    paintMic();
  }

  // ---------- 波形渲染 ----------
  // 三种驱动源：真实电平（听）/ 扫描（想）/ 程序化语音包络（说）。
  // 「说」这一步是合成的、不是真实音频 —— Web speechSynthesis 拿不到输出电平。
  // 所以它走的是「音节节奏 + 会移动的共振峰」，看起来像在说话，但不是真的在分析。
  function synthIdle(t) {
    for (var b = 0; b < BANDS; b++) {
      var x = b / (BANDS - 1);
      VS.tgt[b] = 0.055 + 0.045 * (0.5 + 0.5 * Math.sin(t * 1.15 + x * 3.4));
    }
  }
  function synthThink(t) {
    var sweep = (t * 0.42) % 1.35;                       // 来回扫的亮区
    for (var b = 0; b < BANDS; b++) {
      var x = b / (BANDS - 1);
      var d = Math.abs(x - (sweep < 0.675 ? sweep / 0.675 : 2 - sweep / 0.675) * 0.0 + (0.5 + 0.5 * Math.sin(t * 2.6)) * 0.86);
      var glow = Math.exp(-d * d * 26);
      VS.tgt[b] = 0.07 + 0.10 * Math.sin(t * 3.1 + x * 5.2) * 0.5 + glow * 0.62;
    }
  }
  function synthSpeak(t) {
    for (var b = 0; b < BANDS; b++) {
      var x = b / (BANDS - 1);
      var syl = 0.5 + 0.5 * Math.sin(t * 8.1 + Math.sin(t * 1.3) * 1.4);          // 音节节奏
      var f1 = Math.exp(-Math.pow((x - (0.30 + 0.20 * Math.sin(t * 1.9))) * 3.0, 2));
      var f2 = Math.exp(-Math.pow((x - (0.72 + 0.16 * Math.cos(t * 2.7))) * 3.6, 2)) * 0.55;
      var grain = 0.5 + 0.5 * Math.sin(t * 27 + b * 1.9);
      VS.tgt[b] = Math.min(1, (0.16 + 0.62 * syl) * (0.42 + 0.7 * f1 + f2) * (0.6 + 0.4 * grain));
    }
  }

  function draw() {
    if (!cx2d) return;
    var W = cw, H = ch, mid = H / 2;
    cx2d.clearRect(0, 0, W, H);

    // 收拢进度：柱高整体压向中心线。面板在缩小的同时柱子也在「折起来」，
    // 而不是被容器生生裁掉 —— 差别就是「收拢」和「消失」。
    var fold = VS.fold;
    var flat = 1 - fold * 0.9;

    // 中心线：镜像柱的对称轴。已唤醒时更亮一点，作为「它在等你说话」的底噪。
    // 颜色跟主题走：深色壳上白线，浅色壳（.ft-light）上墨绿线 —— 白线在纸白底上会消失。
    var light = hud && hud.classList.contains('ft-light');
    cx2d.fillStyle = (VS.state === 'awake'
      ? (light ? 'rgba(20,50,35,.32)' : 'rgba(255,255,255,.20)')
      : (light ? 'rgba(20,50,35,.15)' : 'rgba(255,255,255,.10)'));
    cx2d.fillRect(0, mid - 0.5, W, 1);

    var slot = W / BANDS;
    var bw = Math.max(1.6, slot - 2.6);           // 柱宽（留缝）
    var maxH = mid - 3.5;
    var accent = getComputedStyle(document.documentElement).getPropertyValue('--ft-accent').trim() || '#d9a441';
    var rgb = accent.replace('#', '');
    if (rgb.length === 3) rgb = rgb[0] + rgb[0] + rgb[1] + rgb[1] + rgb[2] + rgb[2];
    var R = parseInt(rgb.slice(0, 2), 16) || 217, G = parseInt(rgb.slice(2, 4), 16) || 164, Bc = parseInt(rgb.slice(4, 6), 16) || 65;

    for (var b = 0; b < BANDS; b++) {
      var v = VS.cur[b] * flat;
      var h = Math.max(1.1, v * maxH);             // 永远留一点高度，静下来也是「活」的
      var x = b * slot + (slot - bw) / 2;
      // 越靠中心越亮：上下两端淡出 → 有「能量从中间辐射」的感觉，比单色柱高级
      var g = cx2d.createLinearGradient(0, mid - h, 0, mid + h);
      g.addColorStop(0, 'rgba(' + R + ',' + G + ',' + Bc + ',.26)');
      g.addColorStop(0.5, 'rgba(' + R + ',' + G + ',' + Bc + ',.95)');
      g.addColorStop(1, 'rgba(' + R + ',' + G + ',' + Bc + ',.26)');
      cx2d.fillStyle = g;
      var top = mid - h, hh = h * 2, rr = Math.min(bw / 2, 3);
      cx2d.beginPath();
      if (cx2d.roundRect) cx2d.roundRect(x, top, bw, hh, rr);
      else cx2d.rect(x, top, bw, hh);
      cx2d.fill();
    }

    // 唤醒闪光：中心那根线先亮一下再退回常态。与 CSS 的光扫同一时刻发生，
    // 一个在画板上、一个在面板上，合起来才有「醒过来」的整体感。
    if (VS.flash > 0.01) {
      var a = VS.flash * VS.flash;                  // 平方衰减：亮得急、退得干净
      var lg = cx2d.createLinearGradient(0, 0, W, 0);
      lg.addColorStop(0, 'rgba(' + R + ',' + G + ',' + Bc + ',0)');
      lg.addColorStop(0.5, 'rgba(255,255,255,' + a.toFixed(3) + ')');
      lg.addColorStop(1, 'rgba(' + R + ',' + G + ',' + Bc + ',0)');
      cx2d.fillStyle = lg;
      cx2d.fillRect(0, mid - 1 - a * 1.6, W, 2 + a * 3.2);
    }
  }

  /// 收拢目标：送出中 / 在想是「收起来的」，其余是「张开的」。
  /// 从 thinking 回到 speaking 时它会自己张开 —— 那一开一合就是这层界面的节奏。
  function foldTarget() { return (VS.state === 'sending' || VS.state === 'thinking') ? 1 : 0; }

  // ---------- 帧循环门控（2.23.0 能耗）--------------------------------------------
  // 实测背景：主窗口那个 WebContent 静止时仍占 **48% 单核**，sample 栈是整棵 layer 树
  // 每帧重绘 + 字形查找。查到源头就在这个帧循环 —— 它**没有任何门控**，语音关着
  // （state=off，HUD 是 visibility:hidden）也照样每帧 draw() 画 canvas、placeHud()
  // 写 left/bottom，等于每秒 60 次绘制一块看不见的 HUD（还带文字，于是走字形查找）。
  // 现在：需要时才续帧；不需要时延迟 800ms 收工（等 HUD 淡出落定），改由 500ms
  // 心跳承担兜底 —— 原来那些「靠帧循环总在跑」的兜底（chat 页 mic 钮重挂）挪进心跳。
  // 注意：hearing/awake 的自愈判据本身只在非 off 态才有意义，所以停表不会漏它们。
  var FQ = { queued: false, stopT: 0, hb: 0 };

  function needFrames() {
    return !!(VS.state && VS.state !== 'off');
  }
  function armFrame() {
    if (FQ.queued) return;
    FQ.queued = true;
    requestAnimationFrame(frame);
  }
  function frameStart() {
    if (FQ.stopT) { clearTimeout(FQ.stopT); FQ.stopT = 0; }
    if (FQ.hb) { clearInterval(FQ.hb); FQ.hb = 0; }
    armFrame();
  }
  function frameStop() {
    if (FQ.stopT) return;
    FQ.stopT = setTimeout(function () {
      FQ.stopT = 0;
      if (needFrames()) { armFrame(); return; }   // 延迟期里又被唤醒：继续跑
      if (!FQ.hb) FQ.hb = setInterval(idleBeat, 500);
    }, 800);
  }
  function idleBeat() {
    if (MODE === 'chat') ensureMicButtonChat();   // React 重渲染摘件兜底（原来挂在帧循环里）
    if (needFrames()) frameStart();
  }

  function frame(tsMs) {
    FQ.queued = false;                       // 本帧在执行 → 队列空（门控状态维护）
    var t = tsMs * 0.001;
    var now = Date.now();

    // ── 电平活跃度的滞回落幕 ──
    // 放在帧循环里而不是 levels() 里：万一电平停止推送（引擎暂停、页面切后台），
    // 这里仍然会把它判成「安静」，不会永远挂在「听见了」。
    if (VS.loud && now - VS.loudAt > 900) VS.loud = false;

    // ── 「听见了」的收回 ──
    // 放在帧循环里而不是 DOM 扫描里：扫描靠 MutationObserver 驱动，
    // 界面一旦没有别的动静它就停摆，提示会永远挂着（实测踩到过）。
    // 只要还在出声就一直挂着，安静约 0.9 秒后自己收 —— 不是固定 2.5 秒的死定时，
    // 那会让你明明还在说话，界面却已经缩回去。
    if (VS.state === 'hearing' && !VS.loud && now > VS.hearingUntil) {
      setState('ambient', '安静下来');
    }

    // ── 卡死自愈：在 awake 却 8 秒没有任何语音活动 ──
    // 正常捕捉里 partial / 电平 / 唤醒会不断刷新 lastVoiceAt；全停说明事件链断了
    //（空收句漏发、重建吞事件、任何未来的失同步）。停在 awake 是灾难性的：
    // setState 对同态直接跳过，后续唤醒连动画都不播、说话全被吞 ——
    // 用户看到的就是「永远不再发送」。宁可偶尔错杀一次回 ambient，重新喊就醒。
    if (VS.state === 'awake' && VS.lastVoiceAt > 0 && now - VS.lastVoiceAt > TUNE.stuckMs) {
      setState('ambient', '捕捉超时');
    }

    // ── 判停读秒 ──
    // 原生每 100ms 给一个真值锚点（它才是真正决定「什么时候算说完」的一方），
    // 这里按帧补插值 → 进度条平滑，而判据与原生同源，不会出现「条走完了还没发」。
    if (VS.qHas) {
      var q = Math.min(1, VS.qAnchorP + (now - VS.qAnchorAt) / Math.max(200, prefs.pauseMs));
      // 麦克风里还有明显电平 → 你还在说，读秒必须退回。
      // 少了这一条，识别慢半秒就会让进度条先跑满、再被真实的判停打回去 —— 正是「不同步」。
      if (VS.loud) q = 0;
      VS.quiet = q;
    } else if (VS.quiet > 0) { VS.quiet *= 0.82; if (VS.quiet < 0.01) VS.quiet = 0; }

    // ── 视觉相位 ──
    if (VS.flash > 0) { VS.flash *= 0.87; if (VS.flash < 0.01) VS.flash = 0; }
    VS.fold += (foldTarget() - VS.fold) * 0.16;

    if (VS.state === 'speaking') {
      synthSpeak(t);
      VS.speakProg = VS.speakEst > 0 ? Math.min(1, (now - VS.speakStartAt) / VS.speakEst) : 0;
    } else if (VS.state === 'thinking') {
      synthThink(t);
      VS.thinkSec = Math.floor((now - VS.thinkStartAt) / 1000);
    } else if (VS.state === 'sending') {
      synthThink(t);
    } else if (VS.state === 'off') { /* 关着就不用动 */ }
    else if (VS.state === 'error') synthIdle(t);
    else {
      // 听：真实电平打底，静音时叠一点呼吸基线，免得看着像死机
      for (var b = 0; b < BANDS; b++) {
        var br = 0.045 + 0.035 * (0.5 + 0.5 * Math.sin(t * 1.05 + b * 0.42));
        VS.tgt[b] = Math.max(VS.tgt[b], br);
      }
    }
    // 插值：起快落慢 → 像真实的电平表，不会闪
    for (var i = 0; i < BANDS; i++) {
      var k = VS.tgt[i] > VS.cur[i] ? 0.46 : 0.17;
      VS.cur[i] += (VS.tgt[i] - VS.cur[i]) * k;
      if (!(VS.cur[i] >= 0)) VS.cur[i] = 0;      // 防线：NaN 一行代码就能让整条波形消失
    }
    draw();
    paintTick();                                  // 读秒百分比 / 在想秒数这类连续量
    placeHud();
    // chat 页麦克风钮的兜底重挂：React 重渲染/隐藏发送区可能把钮摘走，MutationObserver
    // 扫描有 200ms 去抖、且可能在界面彻底安静后停摆 —— 帧循环每 700ms 亲自看一眼，
    // 断连或不可见就地重挂（ensureMicButtonChat 内部有 inPlace 短路，常态零开销）。
    if (MODE === 'chat' && now - frame.micAt > 700) {
      frame.micAt = now;
      ensureMicButtonChat();
    }
    // 按需续帧（2.23.0）：不需要动就停止排队，800ms 后由 frameStop 收工。
    if (needFrames()) armFrame();
    else frameStop();
  }
  frame.micAt = 0;

  /// 帧末刷新：进度线 + 只在文案真的变了时才碰 DOM（每帧写 textContent 太浪费）
  function paintTick() {
    if (!hud) return;
    var pmode = '', pval = 0, now = Date.now();
    if (VS.state === 'thinking' && VS.sentAt && now - VS.sentAt < 320) { pmode = 'sent'; pval = 1; }
    else if (VS.state === 'awake' && VS.quiet > 0.02) { pmode = 'quiet'; pval = VS.quiet; }
    else if (VS.state === 'speaking') { pmode = 'speak'; pval = VS.speakProg; }
    if (hud.getAttribute('data-prog') !== pmode) hud.setAttribute('data-prog', pmode);
    if (progFill) progFill.style.transform = 'scaleX(' + pval.toFixed(3) + ')';

    var tag = VS.state + '|' + (VS.quiet > 0.02 ? Math.round(VS.quiet * 20) : 0) + '|' +
      VS.thinkSec + '|' + (VS.loud ? 1 : 0) + '|' + VS.sendStep + '|' +
      (followLeft() > 0 ? Math.ceil(followLeft() / 1000) : 0);   // 接续倒计时也要每秒重刷
    if (tag !== VS.paintTag) { VS.paintTag = tag; paint(); }
  }

  // ---------- 麦克风按钮 ----------
  var micBtn = null;
  function micIcon() {
    return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
      '<path d="M12 3.6a2.6 2.6 0 0 1 2.6 2.6v5.4a2.6 2.6 0 0 1-5.2 0V6.2A2.6 2.6 0 0 1 12 3.6Z" ' +
      'stroke="currentColor" stroke-width="1.5"/>' +
      '<path d="M5.6 11.2a6.4 6.4 0 0 0 12.8 0M12 17.6V20.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
  }
  function makeMicBtn() {
    if (micBtn) return micBtn;
    micBtn = document.createElement('button');
    micBtn.id = 'ft-mic-btn';
    micBtn.type = 'button';
    micBtn.innerHTML = micIcon();
    micBtn.style.position = 'relative';
    // 长按 700ms = 关闭语音（点按永远是「我要说话」）
    var longFired = false, pressTimer = null;
    var cancelPress = function () { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } };
    micBtn.addEventListener('pointerdown', function (e) {
      e.stopPropagation();
      if (!prefs.on) return;                    // 关着的时候没有「长按关闭」这回事
      cancelPress();
      pressTimer = setTimeout(function () {
        pressTimer = null; longFired = true;
        disableVoice();
        log('长按关闭语音');
      }, 700);
    });
    ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (ev) {
      micBtn.addEventListener(ev, function () { cancelPress(); });
    });
    micBtn.addEventListener('click', function (e) {
      e.preventDefault(); e.stopPropagation();
      if (longFired) { longFired = false; return; }   // 这次是长按的尾巴，别再当点击
      cancelPress();
      onMicClick();
    });
    return micBtn;
  }
  function ensureMicButton() {
    if (MODE === 'chat') { ensureMicButtonChat(); return; }
    var trailing = document.querySelector('.uV2eYG_trailing');
    var send = document.querySelector('.uV2eYG_primary');
    if (!trailing || !send) return;
    makeMicBtn();
    if (micBtn.parentNode !== trailing) trailing.insertBefore(micBtn, send);
    paintMic();
  }
  // chat 页的麦克风钮：**独立悬浮圆钮**，挂 body 下、fixed 锚在输入框上方右侧。
  // 为什么不嵌进 DeepSeek 的输入框工具行（那版已废）：那行是 React 管的 ——
  // 位置不可控（用户实测「位置还是不对」），且会话重渲染会把外来按钮一起撕走
  // （实测「聊完一轮按钮失踪」）。挂 body 之后两件事同时消失：React 碰不到它，
  // 位置由 placeMicBtnChat 每帧按输入框矩形算。帧循环另有 700ms 兜底重挂。
  function ensureMicButtonChat() {
    makeMicBtn();
    micBtn.style.position = '';              // 清掉 dsh 内嵌用的内联 relative，让 CSS 的 fixed 生效
    micBtn.setAttribute('data-float', '1');
    micBtn.classList.toggle('ft-light', !VS.dark);   // 懒创建可能晚于 setTheme，补挂当前主题
    if (micBtn.parentNode !== document.body) document.body.appendChild(micBtn);
    paintMic();
  }
  function paintMic() {
    if (!micBtn) return;
    micBtn.setAttribute('data-on', prefs.on ? '1' : '0');
    var live = VS.state === 'ambient' || VS.state === 'hearing' || VS.state === 'awake';
    micBtn.setAttribute('data-live', live ? '1' : '0');
    var busy = VS.state === 'sending' || VS.state === 'thinking' || VS.state === 'speaking';
    micBtn.setAttribute('data-busy', busy ? '1' : '0');
    micBtn.setAttribute('data-err', VS.state === 'error' ? '1' : '0');
    var step = { ambient: '在听', hearing: '听见人声', awake: '在捕捉', sending: '正在送出',
      thinking: '已送出·等回复', speaking: '在朗读', error: '有问题' }[VS.state] || '';
    micBtn.title = prefs.on
      ? '语音已开 · ' + step + (VS.state === 'ambient' || VS.state === 'hearing'
          ? (inFollowUp() ? '（直接说就行）' : '（说「' + prefs.wake + '」或点一下就开始听）') : '')
        + ' · 点击开始听 · 长按关闭'
      : '语音关闭 · 点击开启';
    micBtn.setAttribute('aria-label', micBtn.title);
  }
  /// 麦克风按钮的语义是「我要说话」，不是「开关语音」。
  ///
  /// 之前它是个开关：开一次 → 直接进捕捉（所以第一句能发出去）→ 说完回到常驻。
  /// 用户想说第二句时再点一下，等于把语音**关了**；不点则要走唤醒词。
  /// 两种走法的观感都是「第二句没反应」。现在点按永远是「我要说话」，
  /// 关闭改成长按 —— 语音开着的时候，谁会想一下把它关掉呢。
  function onMicClick() {
    if (!prefs.on) { enableVoice(); return; }
    if (VS.state === 'speaking') { stopSpeaking(true); armCapture('打断朗读'); return; }
    if (VS.state === 'awake') { cmd('manualStop'); setState('ambient', '取消这一句'); return; }
    armCapture('直接聆听');
  }

  // ---------- 开关 ----------
  function enableVoice(direct) {
    prefs.on = true; savePrefs();
    // 点麦克风就是「我现在要说话」→ 开启后立刻进入捕捉态，不必先喊唤醒词。
    // 否则用户点一下按钮、说了整句、只因为没喊「小鲸鱼」而毫无反应，
    // 感受就是「这个语音输入分了两步、不是直接识别的」。
    VS.pendingDirect = direct !== false;
    cmd('enable', {
      wakeWords: wakeList(), ambient: prefs.ambient, pauseMs: prefs.pauseMs,
      sensitivity: 1.0, echoMode: prefs.echoMode, forcePath: prefs.forcePath
    });
    setState('ambient', '开启');
    log('开启语音（常驻=' + prefs.ambient + ' 唤醒词=' + wakeList().join('/') + ' 外放消音=' + prefs.echoMode + '）');
  }
  function disableVoice() {
    prefs.on = false; savePrefs();
    stopSpeaking(true);
    cmd('disable');
    setState('off', '关闭');
  }
  /// 唤醒动画：光扫 + 环扩散 + 整块回弹，三层同时起。
  /// 唤醒是「被动听」变「主动捕捉」的分界，必须有一个看得见的门槛 ——
  /// 没有它，用户不知道自己喊中了没有，只会反复喊，最后读成「这东西反应不一样步」。
  function burst() {
    if (!hud) return;
    hud.classList.remove('ft-wake');
    void hud.offsetWidth;                       // 强制重排，否则第二次唤醒不会重放
    hud.classList.add('ft-wake');
    if (VS.wakeTimer) clearTimeout(VS.wakeTimer);
    VS.wakeTimer = setTimeout(function () {
      if (hud) hud.classList.remove('ft-wake');
    }, 820);
    VS.flash = 1;                               // 画板上的那一闪（与 CSS 光扫同一时刻）
  }

  /// 进入捕捉态（免唤醒）。点麦克风、接续窗口、打断朗读三条路都汇到这里。
  /// 与 wake 回调唯一的区别是不需要剥唤醒词 —— 因为这条路上本来就没有唤醒词。
  function armCapture(why) {
    if (!prefs.on) return false;
    var s = VS.state;
    if (s === 'awake' || s === 'sending' || s === 'thinking' || s === 'speaking') return false;
    cmd('manualStart');
    setState('awake', why);
    burst();                    // 与唤醒同一套动画：进捕捉这件事必须看得见
    return true;
  }

  /// 接续窗口：一轮回复答完后这么久内开口，直接接上，不用再喊唤醒词、也不用点按钮。
  /// 少了这个，「第一句发出去、第二句怎么说都没反应」就是必然：
  /// 第二轮系统其实听见了（波形在跳、日志里有字），只是没等到唤醒词就不肯送。
  function inFollowUp() {
    return prefs.followMs > 0 && VS.replyAt > 0 &&
      (Date.now() - VS.replyAt) < prefs.followMs;
  }
  function followLeft() {
    if (!inFollowUp()) return 0;
    return Math.max(0, prefs.followMs - (Date.now() - VS.replyAt));
  }

  function wakeList() {
    // 识别常把昵称听成近音字。小鲸鱼的变体组是本机实测攒的；其它自定义昵称
    // 不需要手写变体 —— 原生侧的拼音匹配层（字面认不出时比读音）会兜住。
    var w = (prefs.wake || '小鲸鱼').trim();
    var list = [w];
    if (w === '小鲸鱼' || w === '小金鱼') {
      // 这台机器的识别器稳定把「小鲸鱼」听成「小金鱼」（jīng→jīn），
      // 只认正字的结果就是：喊了十几次一次都唤不醒，最后只能去点按钮。
      list = list.concat(['小金鱼', '嗨小鲸鱼', '嗨小金鱼', '小鲸', '小金']);
    }
    // 「嗨 + 昵称」是自然的喊法，任何昵称都带一个
    list.push('嗨' + w);
    return list.filter(function (x, i, a) { return x && a.indexOf(x) === i; });
  }

  // ---------- DOM 适配层：dsh 主页 ⇄ DeepSeek 网页版 ----------
  // dsh：composer 是 DIV[contenteditable]（.uV2eYG_input）。
  // chat：composer 是 <textarea>（#chat-input，兜底找视口下部的可见输入框）。
  var chatComposerLogged = false;
  function chatComposer() {
    var el = document.querySelector('#chat-input') || document.querySelector('textarea');
    if (!(el && el.getBoundingClientRect().height > 0)) {
      // 兜底：视口下半部的可见 contenteditable（登录页没有输入框 → 返回 null 即可）
      var ces = document.querySelectorAll('[contenteditable="true"]');
      el = null;
      for (var i = 0; i < ces.length; i++) {
        var r = ces[i].getBoundingClientRect();
        if (r.height > 0 && r.top > window.innerHeight * 0.4 && (!el || r.top > el.getBoundingClientRect().top)) el = ces[i];
      }
    }
    if (!chatComposerLogged) {
      chatComposerLogged = true;
      log('chat composer: ' + (el ? el.tagName + (el.id ? '#' + el.id : '') + ' class=' + String(el.className || '').slice(0, 40) : '未找到（可能在登录页）'));
    }
    return el;
  }
  function composer() {
    if (MODE === 'chat') return chatComposer();
    return document.querySelector('.uV2eYG_input');
  }
  function composerText() {
    var e = composer();
    if (!e) return '';
    return e.tagName === 'TEXTAREA' ? (e.value || '') : (e.textContent || '');
  }

  // 实测结论（2026-09-19）：composer 是 DIV[contenteditable] 而非 textarea。
  // 写入：focus() + execCommand('insertText') 可行。
  // 清空：execCommand('selectAll') 对这类编辑器**无效**，必须逐个合成 keydown Backspace。
  // 读取：编辑器异步 reconcile，改完立刻同步读 DOM 会读到旧值 → 判定必须延时后再读。
  // 把光标收到末尾再插入 —— 否则 focus() 后没有选区，execCommand 会插到**开头**，
  // 用户本来写了一半的草稿就被顶到后面去了（实测：语音文字跑到「我自己写的草稿」前面）。
  function caretToEnd(el) {
    try {
      var sel = window.getSelection();
      if (!sel) return;
      var r = document.createRange();
      r.selectNodeContents(el);
      r.collapse(false);
      sel.removeAllRanges();
      sel.addRange(r);
    } catch (e) {}
  }
  function insertText(text) {
    var el = composer();
    if (!el) return false;
    try { el.focus(); } catch (e) {}
    if (el.tagName === 'TEXTAREA') {
      // React 受控 textarea：普通赋值会被状态回滚，必须走原型 setter + input 事件
      try {
        var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
        setter.call(el, (el.value || '') + text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
      } catch (e2) { return false; }
    }
    caretToEnd(el);
    var ok = false;
    try { ok = document.execCommand('insertText', false, text); } catch (e) {}
    return ok;
  }
  // chat 的发送键：DeepSeek 网页版是一个 div[role=button]，禁用时带 aria-disabled，
  // 没有稳定类名/文案可抓 —— 用「带 aria-disabled 的 role=button」找它，取最靠下的可见者。
  var chatSendLogged = false;
  function chatSendEl(includeDisabled) {
    var list = document.querySelectorAll('div[role="button"][aria-disabled]');
    var pick = null;
    for (var i = list.length - 1; i >= 0; i--) {
      var r = list[i].getBoundingClientRect();
      if (r.width > 0 && r.height > 0 &&
          (includeDisabled || list[i].getAttribute('aria-disabled') !== 'true')) { pick = list[i]; break; }
    }
    if (!pick) {
      var alt = document.querySelectorAll('[aria-label*="发送"],[aria-label*="Send" i]');
      // 兜底路径也必须可见：隐藏的发送键会把麦克风钮引进隐藏容器（「聊完一轮按钮失踪」的帮凶）
      for (var j = alt.length - 1; j >= 0; j--) {
        var ar = alt[j].getBoundingClientRect();
        if (ar.width > 0 && ar.height > 0) { pick = alt[j]; break; }
      }
    }
    if (!chatSendLogged) {
      chatSendLogged = true;
      log('chat 发送键: ' + (pick ? '找到（aria-disabled=' + pick.getAttribute('aria-disabled') + '）' : '未找到'));
    }
    return pick;
  }
  function sendButton() {
    if (MODE === 'chat') return chatSendEl(false);
    // 优先按语义找，再退回类名。只认「按钮」——类名选择器可能先命中别的容器元素。
    return document.querySelector('button[aria-label="发送消息"]') ||
      document.querySelector('button[aria-label*="发送"]') ||
      document.querySelector('button.uV2eYG_primary') ||
      document.querySelector('.uV2eYG_primary');
  }
  function sendReady() {
    var b = sendButton();
    if (!b) return null;
    var dead = b.disabled || b.getAttribute('aria-disabled') === 'true';
    return dead ? null : b;
  }
  function sendMessage() { var b = sendReady(); if (!b) return false; b.click(); return true; }

  /// 插入 → 等按钮真的可点 → 点击 → 核对输入框已清空。
  ///
  /// 为什么不能插入后立刻点：Lexical/React 要等一次 input 事件渲染完，发送按钮才会从
  /// disabled 变可点。同步点击会点在禁用态上、**静默不发送**——而旧代码返回的 ok 只是
  /// 「找到了按钮」，于是日志写着 send=true，实际什么都没发生，表现就是「说完了没发出去」。
  function waitAndSend(text, n) {
    if (MODE === 'chat') { chatSendFlow(text, n); return; }
    if (n === 0) waitAndSend.enterTried = false;
    var b = sendReady();
    if (b) {
      b.click();
      var cleared = composerText().trim() === '';
      log('送出：' + text + '（清空=' + cleared + '）');
      if (!cleared) {
        // 点了但输入框还在 → 没真的发出去，别假装成功
        setState('error', '发送没生效'); VS.errorMsg = '点了发送但输入框没清空';
        return;
      }
      VS.sentAt = Date.now();                 // 进度线整条亮一下 =「已经交出去了」
      setState('thinking', '已发送');
      watchReply();
      return;
    }
    if (n >= 15) {
      // chat 兜底：发送键一直找不到/不可用 → 给 composer 派发一次回车
      //（DeepSeek 网页版回车即发送），再给 7 次机会核对输入框被清空。
      if (MODE === 'chat' && !waitAndSend.enterTried) {
        waitAndSend.enterTried = true;
        log('发送键一直不可用 → 兜底派发回车');
        var ec = composer();
        if (ec) {
          var eo = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          ec.dispatchEvent(new KeyboardEvent('keydown', eo));
          ec.dispatchEvent(new KeyboardEvent('keyup', eo));
        }
        setTimeout(function () { waitAndSend(text, n + 1); }, 300);
        return;
      }
      log('发送失败：发送按钮一直不可用（' + (sendButton() ? 'disabled' : '没找到按钮') + '）');
      VS.errorMsg = '发送按钮不可用';
      setState('error', VS.errorMsg);
      return;
    }
    // 重试期间把「还在试」如实说出来：0.4 秒与 1 秒各换一次措辞。
    // 那段时间界面上如果一句话都不动，看着就跟卡住一样。
    if (n === 4) { VS.sendStep = '等待发送键就绪…'; VS.paintTag = ''; }
    if (n === 10) { VS.sendStep = '再试一次…'; VS.paintTag = ''; }
    setTimeout(function () { waitAndSend(text, n + 1); }, 100);
  }

  // ---------- chat 页发送流 ----------
  // 与 dsh 的同步核对根本不同：DeepSeek 点发送/回车后清空输入框是**异步**的，
  // 同步读 value 必然读到旧值 → 误判「发送没生效」；而误判留下两条祸根：
  // ① 那条消息其实发出去了，界面却报错；② 残留文本让下一句走进「草稿保护」
  // 变成只插入不发送 —— 正是「第一条能发、后面全不自动发」的完整因果链。
  // 所以始终以「输入框真的清空了」为唯一成功判据。
  //
  // **顺序改成「回车优先、点击兜底」（2026-09-21 日志铁证）**：
  // 旧流程是「点击 → 等 2.4 秒验证 → 回车」，而实测**每一句**都是
  //「点击未生效（输入框未清空）→ 兜底回车」，三次发送三次如此，日志里还出现过
  //「chat 发送键: 未找到」。原因很实在：DeepSeek 的发送键是个 div[role=button]，
  // 由 React 受控、可用状态飘忽；而回车是编辑器自己的 keydown 处理，原子、不依赖按钮状态，
  // 实测每次都发得出去 —— 也就是说旧流程让每一句都白等 2.4 秒去试那个必败的招。
  // 现在：回车 → 0.18 秒确认清空 → 没清空再点按钮 → 再确认。
  // 快路径 0.2 秒（旧流程 2.6 秒），慢路径与旧流程等长。不会重复发送：
  // 回车成功后输入框已空，此时点那个按钮是 no-op（没有内容可发）。
  function chatPressEnter() {
    var ec = composer();
    if (!ec) return;
    try { ec.focus(); } catch (e) {}
    var eo = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
    ec.dispatchEvent(new KeyboardEvent('keydown', eo));
    ec.dispatchEvent(new KeyboardEvent('keyup', eo));
  }
  function chatClearComposer() {
    var el = composer();
    if (!el || el.tagName !== 'TEXTAREA') return;
    try {
      var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      setter.call(el, '');
      el.dispatchEvent(new Event('input', { bubbles: true }));
    } catch (e) {}
  }
  function chatSendFlow(text, n) {
    if (n === 0) {
      chatSendFlow.stage = 0;
      chatSendFlow.actedAt = 0;
      // 预存发送前的回复块数：watchReply 的基线必须早于发送动作（见 watchReply 注释）
      waitAndSend.chatBaseRows = assistantRows().length;
    }
    if (n > 90) { chatSendFail(text); return; }        // 兜底上限（约 11 秒）
    if (composerText().trim() === '') { chatSent(text); return; }
    var st = chatSendFlow.stage;
    var since = Date.now() - (chatSendFlow.actedAt || 0);

    if (st === 0) {
      log('chat 发送：按下回车…');
      chatPressEnter();
      chatSendFlow.stage = 1; chatSendFlow.actedAt = Date.now();
      setTimeout(function () { chatSendFlow(text, n + 1); }, 180);
      return;
    }
    if (st === 1 && since > 700) {                    // 回车 0.7 秒没生效 → 换下手
      var b = sendReady();
      if (b) {
        log('chat 发送：回车未生效 → 点击发送键');
        b.click();
      } else {
        log('chat 发送：回车未生效且发送键不可用 → 再回车一次');
        chatPressEnter();
      }
      chatSendFlow.stage = 2; chatSendFlow.actedAt = Date.now();
      setTimeout(function () { chatSendFlow(text, n + 1); }, 200);
      return;
    }
    if (st === 2 && since > 2400) { chatSendFail(text); return; }
    if (n === 8) { VS.sendStep = '正在送出…'; VS.paintTag = ''; }
    setTimeout(function () { chatSendFlow(text, n + 1); }, 120);
  }

  /// 发送成功：唯一判据是「输入框真的清空了」—— 点没点过、按没按过都不算数。
  function chatSent(text) {
    log('送出：' + text);
    VS.ourDraft = '';
    VS.sentAt = Date.now();
    setState('thinking', '已发送');
    watchReply();
  }

  function chatSendFail(text) {
    log('发送失败：回车与点击都未生效（输入框未清空），已清空残留');
    chatClearComposer();
    VS.ourDraft = '';
    VS.errorMsg = '发送没生效，请再试一次';
    setState('error', VS.errorMsg);
    setTimeout(function () { if (VS.state === 'error' && prefs.on) setState('ambient', '恢复'); }, 3500);
  }

  function deliver(text) {
    if (!text) return;
    // 口语自纠：把「说出去的话」变成「想说的话」。显示与发送同源 ——
    // 划掉的绝不送出、没划掉的一个不丢；判不准时（suggest）原话照发，绝不自作主张。
    var ed = spokenEdit(text);
    VS.edit = ed;
    var how = '';
    if (ed && !VS.editOff) {
      if (VS.editForce === 'cut' && ed.cutText) { text = ed.cutText; how = '手动改用更正段'; }
      else if (ed.mode === 'applied' && ed.text) { text = ed.text; how = '自动撤回'; }
    }
    if (how) {
      var cuts = [];
      for (var q = 0; q < ed.segs.length; q++) if (ed.segs[q].retract) cuts.push(ed.segs[q].retract);
      var cutSum = cuts.join('｜') || '(整段)';
      log('口语自纠[' + ed.rule + '/' + ed.conf + '/' + ed.cue + '/' + how + ']：撤回「' +
          cutSum + '」→ 送出「' + text + '」');
      VS.editSent = { raw: ed.raw, out: text, cut: cutSum };
    } else {
      if (ed && ed.mode === 'suggest') {
        log('口语自纠[' + ed.cue + ']：认出改口但撤回范围看不准 → 原话送出，HUD 留一键出口');
      }
      VS.editSent = null;
    }
    var existing = composerText().trim();
    // chat 页：残留的若是我们自己上次没送出去的识别稿，清掉照常发送，
    // 绝不能误入下面的「草稿保护」—— 那会把后续每一句都拦成只插入不发送。
    if (existing && MODE === 'chat' && VS.ourDraft &&
        existing === String(VS.ourDraft).trim()) {
      log('清掉上次发送失败的残留识别稿，重新走发送');
      chatClearComposer();
      existing = '';
    }
    if (existing) {
      // 输入框里有你写的东西 → 绝不自动发送（否则会把你的草稿一起发出去）
      insertText((composerText() && !/\s$/.test(composerText()) ? ' ' : '') + text);
      log('输入框已有内容「' + existing.slice(0, 30) + '」→ 语音只插入、不发送');
      VS.partial = '输入框里已有内容，语音已接在后面（没有发送）';
      setState('awake', '输入框非空，改为插入');
      paint();
      // 不要卡在捕捉态：几秒后回到常驻监听，免得继续堆积识别结果
      setTimeout(function () {
        if (VS.state === 'awake' && prefs.on) setState('ambient', '草稿保护：回到监听');
      }, 3500);
      return;
    }
    insertText(text);
    if (MODE === 'chat') VS.ourDraft = text;   // 记下这是我们插的稿：发送验证/残留清理都以它为准
    VS.lastSendAt = Date.now();
    VS.sentText = text;
    if (!prefs.autoSend) { setState('awake', '已插入待确认'); return; }
    // 收拢与送出同时进行：面板折起来的那一刻就是「已经交出去了」。
    // 早先这里是直接跳到 thinking（标签写着「在想」），而那一刻其实还在等发送按钮
    // 从 disabled 变可点 —— 界面说的和它做的不一致，用户当然会觉得慢半拍。
    VS.sendStep = '正在送出…';
    setState('sending', '收拢并送出');
    waitAndSend(text, 0);
  }

  // ---------- 回复：等生成结束 → 读文本 → 朗读 ----------
  var replyWatch = null;
  function assistantRows() {
    if (MODE === 'chat') {
      // DeepSeek 网页版的回答块：ds-markdown 是它的设计系统类名；带 --block 的更精确。
      var a = document.querySelectorAll('.ds-markdown--block');
      if (a.length) return a;
      a = document.querySelectorAll('.ds-markdown');
      if (a.length) return a;
      return document.querySelectorAll('[class*="markdown" i]');
    }
    // 助手回答块：先认当前 UI 的类名，再兜底到常见的 markdown 容器命名。
    // hash 前缀随版本变，只认一个迟早会失效。
    var r = document.querySelectorAll('.hWmORq_root');
    if (r.length) return r;
    r = document.querySelectorAll('[class*="AssistantMarkdown"],[class*="Markdown"],' +
      '[class*="markdown_"]');
    return r;
  }
  // 「正在生成」的多路判别：只认 aria-label 太脆 —— i18n 换词、改成 title、
  // 或元素根本不是 button，都会漏判，于是明明在生成却被判成「没发出去」。
  var STOP_SEL = '[aria-label*="停止"],[aria-label*="Stop" i],[title*="停止"],[title*="Stop" i],' +
    '[data-state="streaming"],[data-state="generating"]';
  function generating() {
    return !!document.querySelector(STOP_SEL);
  }

  function watchReply() {
    if (replyWatch) { clearInterval(replyWatch); replyWatch = null; }
    // 基线优先用发送动作前预存的快照（chatSendFlow.baseRows）：点击发送到启动监视
    // 有几百毫秒间隙，真实页面回复块可能在这间隙里就渲染出来了 —— 快照取晚了
    // 会把新回复算进基线，漏掉「增长」信号，只能干等生成钮或超时报错。
    var baseCount = (typeof waitAndSend.chatBaseRows === 'number')
      ? waitAndSend.chatBaseRows : assistantRows().length;
    waitAndSend.chatBaseRows = null;
    var startedAt = Date.now();
    // dsh 侧是「agent 干活」而不是「网页一问一答」：首字可能要等几十秒，
    // 9 秒就判死会把正常等待误报成「没发送成功」。分模式给窗口。
    var waitMs = (MODE === 'chat') ? 20000 : 90000;
    var sawGen = generating();
    var stableAt = 0;
    // 基线记「当前末块文本长度」：新回复若流式长在旧块后，靠长度变化也能发现；
    // 若新增了回答块，则由 grew 发现。两者任一成立即视为回复已开始。
    var baseRows0 = assistantRows();
    var lastLen = baseRows0.length ? (baseRows0[baseRows0.length - 1].textContent || '').length : -1;
    replyWatch = setInterval(function () {
      var gen = generating();
      var rows = assistantRows();
      var grew = rows.length > baseCount;
      var lastTxt = rows.length ? (rows[rows.length - 1].textContent || '') : '';
      var len = lastTxt.length;
      var changed = (len !== lastLen);
      // 末尾这块若就是我们刚发出去的那句（回显），不能当「回复开始」：
      // 否则它稳定 1 秒后就会触发朗读，而 replyText() 会往前退一块 → 念出上一轮旧回复。
      var head = String(VS.sentText || '').trim().slice(0, 20);
      var isOurs = !!(head && lastTxt.trim().indexOf(head) === 0);
      if (gen) { sawGen = true; stableAt = 0; lastLen = len; return; }
      if (isOurs) { lastLen = len; stableAt = 0; return; }
      if (!sawGen && (grew || changed)) sawGen = true;
      if (sawGen) {
        if (changed) { lastLen = len; stableAt = Date.now(); return; }
        // 文本稳定 1 秒 → 认为这一轮答完了
        if (stableAt && Date.now() - stableAt > 1000) {
          clearInterval(replyWatch); replyWatch = null;
          var text = replyText();
          VS.lastReply = text;
          // 接续窗口从这里起算：答完之后的这几十秒里，用户多半还要接着说
          VS.replyAt = Date.now();
          log('回复已就绪 ' + text.length + ' 字：' + text.slice(0, 40));
          if (prefs.speak && text) speak(text);
          else setState(prefs.on ? 'ambient' : 'off', '不朗读');
        }
        return;
      }
      if (Date.now() - startedAt > waitMs) {
        // 既没看到生成按钮也没多出消息 → 多半没发出去。chat 页顺手做一次结构诊断，
        // 选择器对不上时日志能直接指出该换成什么。
        log('回复检测超时诊断: MODE=' + MODE +
            ' 助手块=' + assistantRows().length + '(基数' + baseCount + ')' +
            ' ds-markdown=' + document.querySelectorAll('.ds-markdown').length +
            ' markdown*=' + document.querySelectorAll('[class*="markdown" i]').length +
            ' 停止钮=' + generating() +
            ' textarea=' + document.querySelectorAll('textarea').length);
        clearInterval(replyWatch); replyWatch = null;
        VS.errorMsg = '没等到回复（可能没发出去，也可能 agent 还在忙）';
        setState('error', VS.errorMsg);
        setTimeout(function () { if (VS.state === 'error' && prefs.on) setState('ambient', '恢复'); }, 3500);
      }
    }, 250);
  }

  function replyText() {
    var rows = assistantRows();
    if (!rows.length) return '';
    var idx = rows.length - 1;
    // chat 页：用户消息也可能走同一套 markdown 渲染 —— 最后一块若就是刚发出去的那句，
    // 往前退一块，别把自己的提问念出来。
    if (MODE === 'chat' && VS.sentText && idx > 0 &&
        (rows[idx].textContent || '').trim().indexOf(String(VS.sentText).trim()) === 0) {
      idx--;
    }
    var clone = rows[idx].cloneNode(true);
    // 去掉代码块与工具条：念代码没有意义，按钮文字（复制/重新生成）也不该念
    var junk = clone.querySelectorAll('pre,code,button,svg,script,style,textarea,input,' +
      '[class*="toolbar"],[class*="Toolbar"],[class*="action"],[class*="Action"],[class*="footer"],[class*="Footer"]');
    for (var i = 0; i < junk.length; i++) junk[i].remove();
    return cleanForSpeech(clone.innerText || clone.textContent || '');
  }

  function cleanForSpeech(t) {
    t = String(t || '');
    t = t.replace(/\r/g, '');
    t = t.replace(/```[\s\S]*?```/g, '（代码略）');
    t = t.replace(/`([^`]*)`/g, '$1');
    t = t.replace(/https?:\/\/\S+/g, '链接');
    t = t.replace(/!\[[^\]]*\]\([^)]*\)/g, '');
    t = t.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    t = t.replace(/^[ \t]*[-*+]\s+/gm, '');
    t = t.replace(/^[ \t]*#{1,6}\s*/gm, '');
    t = t.replace(/[|>]/g, ' ');
    t = t.replace(/[*_~]/g, '');
    // 去掉 emoji 与符号图形：TTS 会把它们念成奇怪的东西
    t = t.replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2190}-\u{21FF}]/gu, '');
    t = t.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
    if (t.length > prefs.cap) {
      var cut = t.slice(0, prefs.cap);
      var p = Math.max(cut.lastIndexOf('。'), cut.lastIndexOf('！'), cut.lastIndexOf('？'), cut.lastIndexOf('\n'));
      if (p > prefs.cap * 0.5) cut = cut.slice(0, p + 1);
      t = cut + '……后面的内容我放在屏幕上了。';
    }
    return t;
  }

  // ---------- 朗读 ----------
  var tts = window.speechSynthesis;
  var zhVoices = [];
  // 内部可调参数集中一处（不落盘、不进设置面板）：
  // 看门狗要能在无头实证里几百毫秒内验出来，而不是真等两分钟。
  // stuckMs：捕捉态「完全没有任何语音活动」多久算卡死（帧循环里的自愈看门狗用）。
  // **这个默认值以前是缺的**（2026-09-21 查出）：`TUNE.stuckMs` 从未定义，
  // 于是 `now - lastVoiceAt > undefined` 恒为 false —— 自愈看门狗在生产里一次都没生效过，
  // 只有回归台临时 tune({stuckMs:300}) 时才活。补上真实默认值，让线上也有这条路。
  var TUNE = { msPerChar: 230, minSpeakMs: 4000, speakGraceMs: 3500, restartDelayMs: 60, stuckMs: 6000 };
  function refreshVoices() {
    if (!tts) return;
    var all = tts.getVoices() || [];
    zhVoices = all.filter(function (v) { return /zh|Chinese|中文/i.test(v.lang + v.name); });
  }
  function pickVoice() {
    if (!tts) return null;
    if (!zhVoices.length) refreshVoices();
    if (prefs.voiceURI) {
      for (var i = 0; i < zhVoices.length; i++) if (zhVoices[i].voiceURI === prefs.voiceURI) return zhVoices[i];
    }
    // 默认挑一个 zh-CN：优先「婷婷」这类系统自带女声，念得最稳
    for (var j = 0; j < zhVoices.length; j++) {
      if (zhVoices[j].lang === 'zh-CN' && /婷婷|Tingting/i.test(zhVoices[j].name)) return zhVoices[j];
    }
    for (var k = 0; k < zhVoices.length; k++) if (zhVoices[k].lang === 'zh-CN') return zhVoices[k];
    return zhVoices[0] || null;
  }
  // 朗读看门狗 —— 这不是锦上添花，是必需的安全网。
  // WebKit 的 speechSynthesis 在个别情况下不触发 onend（被 cancel 之后、或长句末尾）。
  // 一旦漏掉，状态永远停在「在说」：常驻监听的人声提示、自动朗读、麦克风实时态会一起哑掉，
  // 只能靠打断解除。所以按文本长度估一个宽裕时长，超时即强制收尾。
  var speakTimer = null, speakDeadline = 0;
  function disarmWatchdog() {
    if (speakTimer) { clearTimeout(speakTimer); speakTimer = null; }
    speakDeadline = 0;
  }
  function armWatchdog(text) {
    disarmWatchdog();
    var est = Math.max(TUNE.minSpeakMs, (String(text).length * TUNE.msPerChar) / Math.max(0.5, prefs.rate)) + TUNE.speakGraceMs;
    // 同一个估值也用来画「读到哪了」的进度线：它是估计值，但至少与时间轴同步，
    // 比「界面什么都不动、让人猜还要念多久」强得多。
    VS.speakEst = est;
    VS.speakStartAt = Date.now();
    VS.speakProg = 0;
    speakDeadline = Date.now() + est;
    speakTimer = setTimeout(function () {
      speakTimer = null; speakDeadline = 0;
      if (VS.state !== 'speaking') return;
      log('朗读看门狗兜底：' + Math.round(est) + 'ms 没等到结束回调');
      try { tts.cancel(); } catch (e) {}
      setBusyNative(false);
      setState(prefs.on ? 'ambient' : 'off', '朗读超时兜底');
    }, est);
  }
  function endSpeak(why) {
    disarmWatchdog();
    VS.speakProg = 0;
    VS.speakEst = 0;
    setBusyNative(false);
    if (VS.state === 'speaking') setState(prefs.on ? 'ambient' : 'off', why);
  }
  function utter(text) {
    if (!tts) return;
    armWatchdog(text);
    setState('speaking', '朗读中');
    // 整段发声都包在防线内：u.voice 是**强类型**属性（必须是真 SpeechSynthesisVoice），
    // 而 getVoices() 到赋值之间系统音色可能已被卸载（下载中／被移除），赋值会抛。
    // 抛在这里就等于这一句根本没念、状态却卡在「在说」—— 实测在验证台上就是这么炸的。
    try {
      var u = new SpeechSynthesisUtterance(text);
      u.lang = 'zh-CN';
      u.rate = prefs.rate;
      var v = pickVoice();
      if (v) {
        try { u.voice = v; u.lang = v.lang || u.lang; }
        catch (e2) { log('音色不可用，退回系统默认：' + (v && v.name)); }
      }
      u.onstart = function () { setState('speaking', '开始朗读'); setBusyNative(true); };
      u.onend = function () { endSpeak('读完'); };
      u.onerror = function () { endSpeak('朗读出错'); };
      tts.speak(u);
    } catch (e) {
      disarmWatchdog();
      log('朗读失败：' + e);
      setState('error', '朗读失败');
    }
  }
  function speak(text) {
    if (!tts || !text) { setState(prefs.on ? 'ambient' : 'off', '无可朗读'); return; }
    // 上一句还没念完 → 必须先 cancel；而 WebKit 里 cancel 紧跟 speak 有概率把新句吞掉
    // （新句永远不 onstart）。所以这种情形多等一拍再开口。
    // 常见路径（没人抢麦）仍是同步发声、零延迟。
    var busy = !!(tts.speaking || tts.pending);
    try { tts.cancel(); } catch (e) {}
    disarmWatchdog();
    if (busy) { setTimeout(function () { utter(text); }, TUNE.restartDelayMs); return; }
    utter(text);
  }
  function stopSpeaking(quiet) {
    disarmWatchdog();
    if (!tts) return;
    try { tts.cancel(); } catch (e) {}
    setBusyNative(false);
    if (!quiet && VS.state === 'speaking') setState(prefs.on ? 'ambient' : 'off', '停止朗读');
  }

  // ---------- 口语自纠：划掉重说 ----------
  // 人说话会改口：「周三……不对，周四」。识别器只会把整句老实交上来 —— 每个字都对，
  // 意思却是错的。这是「响应不准确」里最冤的一种：不是它听错，是它太老实。
  //
  // 这里做的是**忠实撤回**，不是「智能改写」：把被改口撤回的那一段划掉、留下更正后的
  // 说法，并且永远留一个「还原原话」的出口。两条铁律：
  //   ① 显示必须等于发送 —— 划过删除线的字绝不会出现在送出去的稿里，没划掉的一个不丢；
  //   ② 猜不准宁可不改 —— 撤回范围不确定时只提示（suggest）、按原话发送，绝不偷偷改写。
  // 每次判定都留日志（线索/规则/置信度），好按真人语料回头调规则。

  // 线索分强弱。「不对，是…」也用于陈述（「这个不对，是那个」），所以它必须配上
  // 高置信的撤回方案才敢动；强线索（犹豫音+不对、重说、更正…）才是明确的改口。
  var EDIT_CUES = [
    { tag: '犹豫音', strong: true, re: /(?:啊|呃|嗯|哦|哎|诶|唉)\s*[，,]?\s*不对/ },
    { tag: '重复', strong: true, re: /不对\s*[，,]?\s*不对/ },
    { tag: '重说', strong: true, re: /(?:(?:不对|不是)\s*[，,]?\s*)?(?:我)?重(?:新)?说(?:一遍|一下|一次)?/ },
    { tag: '更正', strong: true, re: /(?:更正|纠正|订正)(?:一下|一遍)?/ },
    { tag: '我说的是', strong: true, re: /(?:^|[，,。；;、\s])我(?:说|讲)的是/ },
    { tag: '英文改口', strong: true, re: /\b(?:no|wait|sorry)\s*[,，]?\s*i\s+(?:mean|meant)\b/i },
    { tag: '改口是', strong: false, re: /不对\s*[，,]?\s*(?:我(?:说|讲)的?是|我是说|应该是|是叫|是|改成|改为|换成)/ },
    // 最常见的形态其实最朴素：「不对，<直接重说>」。它也最容易和「陈述性否定」撞车，
    // 所以只算弱线索 —— 必须配上高置信的撤回方案（R1/R2 那种「确实在重述」的证据）
    // 才敢自动改，配上中等置信的从句撤回都要退回 suggest。
    { tag: '不对重述', strong: false, re: /不对\s*[，,]?/ }
  ];

  // 同类槽位：改口最常换的就是「时间 / 数量 / 语言」。两侧命中同一类才做局部替换 ——
  // 这类撤回几乎不会错，是整张规则表里最靠得住的一条。
  var EDIT_SLOTS = [
    { cls: 'time', re: /(?:今天|明天|后天|大后天|昨天|前天|今晚|明晚|今早|明早)?(?:上午|下午|晚上|早上|中午|凌晨|傍晚)?(?:\d{1,2}|[一二三四五六七八九十两])[点时](?:\d{1,2}|[一二三四五六七八九十]+)?分?/ },
    { cls: 'time', re: /(?:这|本|下|上|明|后)(?:周|星期|礼拜)/ },
    { cls: 'time', re: /(?:这|本|下|上|明|后)?(?:周|星期|礼拜)[一二三四五六日天末]/ },
    { cls: 'time', re: /(?:今天|明天|后天|大后天|昨天|前天|今晚|明晚|今早|明早)/ },
    { cls: 'time', re: /(?:\d{1,2}|[一二三四五六七八九十]+)月(?:\d{1,2}|[一二三四五六七八九十]+)[日号]/ },
    { cls: 'lang', re: /(?:中文|英文|日文|韩文|法文|德文|俄文|西班牙文|日语|英语|汉语|繁体|简体)/ },
    { cls: 'num',  re: /(?:\d+|[一二三四五六七八九十百千万几两]+)(?:个|条|份|次|遍|页|行|块|元|人|天|小时|分钟|秒|字|篇|张|台|件|封|支|根|瓶|杯|岁|年|度|米|斤|克)/ }
  ];

  function trimEdges(s) {
    return String(s == null ? '' : s)
      .replace(/^[\s，,。.、；;：:！!？?…—\-~]+/, '')
      .replace(/[\s，,。.、；;：:]+$/, '');
  }
  // 更正段常以「是 / 应该是 / 改成 / 翻成」起头 —— 那是连接词，不是内容
  function stripLead(s) {
    return trimEdges(s).replace(/^(?:就是|应该是|是叫|说的是|我说的是|是|改成|改为|换成|翻成|译成|变成|变为)\s*/, '');
  }
  function commonPrefixLen(a, b) {
    var n = Math.min(a.length, b.length), i = 0;
    while (i < n && a.charAt(i) === b.charAt(i)) i++;
    return i;
  }
  /// 取「头部末尾」或「更正段起头」的同类槽位（最长者优先）
  function slotEdge(s, atEnd) {
    var best = null;
    for (var i = 0; i < EDIT_SLOTS.length; i++) {
      var m;
      try { m = new RegExp((atEnd ? '' : '^') + EDIT_SLOTS[i].re.source + (atEnd ? '$' : '')).exec(s); }
      catch (e) { continue; }
      if (m && m[0] && (!best || m[0].length > best.text.length)) {
        best = { cls: EDIT_SLOTS[i].cls, text: m[0] };
      }
    }
    return best;
  }
  /// 「同一句重述」：更正段与头部末尾对得上（「发给李四」vs「…发给张三」）。
  /// 至少两个字逐字相同才算证据 —— 够强，才敢把对齐的那一段整段撤回。
  function boundaryAlign(head, tail) {
    var maxK = Math.min(head.length, tail.length);
    for (var k = maxK; k >= 2; k--) {
      if (commonPrefixLen(head.slice(head.length - k), tail) >= 2) return k;
    }
    return 0;
  }
  /// 撤回方案。返回 null = 不敢拆（宁可不改）。
  /// keep=留在稿里的前缀，retract=被划掉的段，fix=接在后面的更正文本，
  /// drop=整句重述（前面攒的保留段一并作废）。
  function retractPlan(head, tail) {
    if (!head || !tail) return null;
    // R1 整句重述：更正段自己把前半句又说了一遍 → 前文全撤
    var k = commonPrefixLen(head, tail);
    if (k >= 3) return { keep: '', retract: head, fix: tail, drop: true, rule: 'R1重述', conf: 'high' };
    // R2 边界对齐：头部末尾与更正段起头对上 ≥2 字 → 撤回对齐的那一段
    var bk = boundaryAlign(head, tail);
    if (bk > 0) {
      return {
        keep: head.slice(0, head.length - bk), retract: head.slice(head.length - bk),
        fix: tail, drop: false, rule: 'R2对齐', conf: 'high'
      };
    }
    // R3 同类槽位：末尾一个「时间/数量/语言」换成同类的另一个。
    // 只在更正段「基本就是那个值」时用（免得把一次整句重述误当成换个词），
    // 槽位不在更正段开头时只取那个值 —— 否则会把「翻成」这类连接词重复接一遍。
    var a = slotEdge(head, true), b = slotEdge(tail, false) || slotEdge(tail, true);
    if (a && b && a.cls === b.cls && tail.length <= b.text.length + 4) {
      var fixT = b.at > 0 ? (b.text + tail.slice(b.at + b.text.length)) : tail;
      return {
        keep: head.slice(0, head.length - a.text.length), retract: a.text,
        fix: fixT, drop: false, rule: 'R3同类', conf: 'high'
      };
    }
    // R4 从句撤回：从头部最后一个标点之后算起（撤掉一整个小句）
    var cut = Math.max(head.lastIndexOf('，'), head.lastIndexOf(','), head.lastIndexOf('。'),
                       head.lastIndexOf('；'), head.lastIndexOf(';'), head.lastIndexOf('、'),
                       head.lastIndexOf('！'), head.lastIndexOf('？'));
    if (cut >= 0 && cut + 1 < head.length) {
      return {
        keep: head.slice(0, cut + 1), retract: head.slice(cut + 1),
        fix: tail, drop: false, rule: 'R4从句', conf: 'mid'
      };
    }
    return null;
  }
  /// 找最靠前的那条改口线索（同位置时强线索优先）
  function findCue(s) {
    var best = null;
    for (var i = 0; i < EDIT_CUES.length; i++) {
      var m = EDIT_CUES[i].re.exec(s);
      if (!m || !m[0]) continue;
      var at = m.index, end = m.index + m[0].length;
      if (!best || at < best.at || (at === best.at && EDIT_CUES[i].strong && !best.strong)) {
        best = { at: at, end: end, tag: EDIT_CUES[i].tag, strong: EDIT_CUES[i].strong };
      }
    }
    return best;
  }

  /// 把一句话拆成「撤回 + 更正」。返回 null 表示没有改口（绝大多数情况）。
  /// mode='applied' → text 就是送出的稿；mode='suggest' → 不敢改，送原话，cutText 是手动候选。
  function spokenEdit(raw) {
    var s = String(raw || '');
    if (!s) return null;
    var segs = [], comp = [], rest = s, tailText = '', tag = '', strong = false;
    var minConf = 'high', bailed = false, guard = 0, rules = [];
    while (guard++ < 4) {                        // 连改两次口就折两轮（最多 4 轮防失控）
      var c = findCue(rest);
      if (!c) break;
      var head = trimEdges(rest.slice(0, c.at));
      var tail = stripLead(rest.slice(c.end));
      // 「不对，我重说，X」：两个线索之间一个字都没有，前一个只是作废声明 → 直接跳过。
      // 更正段里若还有一次改口（「周三不对周四，啊不对是周五」），本轮只针对它之前那一段 ——
      // 否则撤回目标会被后面那次改口的内容稀释，短句替换就判不出来了。
      var sk = 0, nx = null;
      while (sk++ < 3 && tail) {
        var c2 = findCue(tail);
        if (!c2) { nx = null; break; }
        if (c2.at > 0) { nx = c2; break; }
        tail = stripLead(tail.slice(c2.end));
      }
      // 没有前文就没有「撤回」可言 ——「不对，是周四」是回答，不是改口
      if (!head || !tail) break;
      if (!tag) { tag = c.tag; strong = c.strong; }
      var cueTail = nx ? trimEdges(tail.slice(0, nx.at)) : tail;
      if (!cueTail) break;
      var plan = retractPlan(head, cueTail);
      if (!plan) { bailed = true; tailText = tail; break; }
      // 弱线索 + 中等置信的撤回（R4 从句）→ 证据不够，退回「只提示不改写」
      if (!c.strong && plan.conf !== 'high') { bailed = true; tailText = tail; break; }
      if (plan.conf === 'mid') minConf = 'mid';
      rules.push(plan.rule);
      segs.push({ keep: plan.keep, retract: plan.retract });
      if (plan.drop) comp.length = 0; else comp.push(plan.keep);
      rest = tail; tailText = tail;
    }
    if (!segs.length) {
      // 认出了改口、却拆不出撤回范围：只有强线索才值得提示（弱线索多半是陈述）
      if (bailed && strong && tailText) {
        return {
          hit: true, mode: 'suggest', raw: s, cue: tag, rule: 'R5未定', conf: 'low',
          cutText: trimEdges(comp.join('') + tailText), segs: [], fix: ''
        };
      }
      return null;
    }
    var fixed = trimEdges(comp.join('') + rest);
    if (!fixed) return null;
    return {
      hit: true, mode: 'applied', raw: s, cue: tag, rule: rules.join('+'), conf: minConf,
      segs: segs, fix: rest, text: fixed, cutText: fixed
    };
  }

  /// 渲染一句话：撤回段划掉、更正段点亮。用 DOM 节点而不是拼 HTML ——
  /// 这是用户自己说的话，任何字符串拼 HTML 都是注入面。
  function paintEdit(el, ed, raw) {
    el.textContent = '';
    if (!ed || !ed.hit) { el.textContent = raw; return; }
    if (ed.mode === 'suggest') {
      el.appendChild(document.createTextNode(raw + '  '));
      var ask = document.createElement('button');
      ask.className = 'ft-ask';
      ask.type = 'button';
      ask.textContent = '改用后半句';
      ask.title = '像是改口，但撤回范围看不准 · 点一下只用更正的那半句';
      ask.onclick = function () { VS.editForce = 'cut'; VS.paintTag = ''; paint(); };
      el.appendChild(ask);
      return;
    }
    for (var i = 0; i < ed.segs.length; i++) {
      if (ed.segs[i].keep) el.appendChild(document.createTextNode(ed.segs[i].keep));
      if (ed.segs[i].retract) {
        var cut = document.createElement('span');
        cut.className = 'ft-cut';
        cut.textContent = ed.segs[i].retract;
        cut.title = '这段被你的改口撤回了 · 点一下改成按原话发送';
        cut.onclick = revertEdit;
        el.appendChild(cut);
      }
      var ar = document.createElement('span');
      ar.className = 'ft-arrow';
      ar.textContent = '\u21e2';
      el.appendChild(ar);
    }
    var fx = document.createElement('span');
    fx.className = 'ft-fix';
    fx.textContent = ed.fix;
    el.appendChild(fx);
  }
  /// 「还原原话」：只对这一句生效（下一句重新按规则来）。
  /// 它是发送前唯一的后悔药，所以必须立刻反映到显示上 —— 显示即承诺。
  function revertEdit() {
    if (!VS.edit) return;
    VS.editOff = true; VS.editForce = '';
    log('口语自纠：用户还原原话（本句不再改写）');
    VS.paintTag = '';
    paint();
  }

  // ---------- 原生回调（window.__ftVoice.*）----------
  window.__ftVoice = {
    levels: function (arr) {
      if (!arr || !arr.length) return;
      var n = Math.min(BANDS, arr.length);
      var mx = 0;
      for (var i = 0; i < n; i++) {
        var v = +arr[i];
        VS.tgt[i] = (v >= 0 && v <= 1) ? v : (v > 1 ? 1 : 0);   // 防线：非有限值一律归零
        if (VS.tgt[i] > mx) mx = VS.tgt[i];
      }
      // 「有人在说话」取自真实电平，而不是等识别出字 —— 识别要慢半秒到一秒，
      // 等它才有反应，就是「嘴动了、界面没动」的那种不同步。
      if (mx > 0.18) {
        VS.loud = true; VS.loudAt = Date.now();
        VS.hearingUntil = Date.now() + 900;
        if (VS.state === 'awake') VS.lastVoiceAt = Date.now();
      }
      if (VS.loud && VS.state === 'ambient') setState('hearing', '电平觉察到人声');
      // 接续窗口里一有人声就接上：等到识别出字再动，慢的那半秒就是「不同步」的观感
      if (VS.loud && inFollowUp()) armCapture('接着说');
    },
    partial: function (text, isFinal) {
      VS.partial = text || '';
      // 口语自纠：一边说一边就把改口的痕迹划出来（见 spokenEdit）。
      // 定稿还会在 deliver() 里重算一次 —— partial 是会抖的中间产物，
      // 只有最终稿作数，所以这里算出来纯粹是为了让用户「看得见」。
      if (!VS.editOff) VS.edit = spokenEdit(VS.partial);
      // 空收句：原生的「白听了」信号（isFinal 且没字，捕捉里只有唤醒词残渣）。
      // 必须回 ambient —— 少了这句，状态机卡死在 awake，而 setState 对同态是
      // 直接跳过的：之后所有唤醒命中连动画都不播，说话自然永远不再发送
      // （2026-09-20 实测「第一轮能发，之后全哑」的根因）。
      if (isFinal && !(text && text.trim())) {
        // 提示复用 setState 的第二参（HUD 文案），不要另造通知函数 ——
        // 早先这里写了个未定义的 notice()，异常抛在原生回调链里：解卡这句
        // 自己先炸了，状态机照样停在 awake，且异常在宿主里几乎无声。
        var why = VS.state === 'awake' ? '没听清，再喊我一声' : '空句子';
        setState(prefs.on ? 'ambient' : 'off', why);
        return;
      }
      VS.lastVoiceAt = Date.now();
      if (VS.state === 'ambient') setState('hearing', '听见人声');
      // 电平没够（说话轻、离麦远）但确实出字了，同样接上
      if (text && inFollowUp()) armCapture('接着说');
      VS.hearingUntil = Date.now() + 2500;        // 有字就有理由再挂一会儿
      VS.paintTag = '';
      paint();
    },
    /// 判停读秒（原生每 100ms 一个真值锚点）。这里只负责记锚点，
    /// 平滑插值在帧循环里做 —— 让进度条与真正决定「什么时候算说完」的一方同源。
    pause: function (p, hasText) {
      var v = +p;
      if (!(v >= 0 && v <= 1)) v = 0;
      VS.qAnchorP = v;
      VS.qAnchorAt = Date.now();
      VS.qHas = hasText === true || hasText === 'true';
      if (!VS.qHas) VS.quiet = 0;
      VS.paintTag = '';
    },
    wake: function (word) {
      VS.partial = '';
      // 新的一句，自纠判定与「已还原」一起归零 —— 上一句的选择不该粘到这一句
      VS.edit = null; VS.editOff = false; VS.editForce = ''; VS.editSent = null;
      VS.lastVoiceAt = Date.now();
      if (Date.now() - VS.lastSendAt < 1500) return;     // 刚说完一句，别被尾音二次触发
      // 顺序要紧：先把 HUD 撑到「已唤醒」的尺寸，再放光扫/环/回弹。
      // 反过来做的话，三层动画是播在一条窄带上的 —— 尺寸过渡和动画互相抢，
      // 视觉上等于没播，正是「明明唤醒了却看不到动画」的来源。
      setState('awake', '唤醒词「' + word + '」');
      burst();                                           // 再给反馈：唤醒必须看得见
    },
    final: function (text) {
      if (!text) { setState(prefs.on ? 'ambient' : 'off', '空句子'); return; }
      // 定稿重算：partial 是易变的中间产物，只有最终稿作数（送出去的按这一份）
      VS.edit = VS.editOff ? null : spokenEdit(text);
      deliver(text);
    },
    bargeIn: function () {
      if (VS.state !== 'speaking' || !prefs.bargeIn) return;
      stopSpeaking(true);
      VS.partial = '';
      setState('awake', '你开口了，打断朗读');
      cmd('manualStart');
    },
    error: function (msg) {
      VS.errorMsg = msg || '未知错误';
      VS.fatal = true;
      if (VS.state === 'error') paint(); else setState('error', VS.errorMsg);
    },
    // 可恢复的小状况（一次没听清之类）：短暂提示后自己回到监听。
    // 不与 error 共用一个「永久错误」状态 —— 那正是上一轮把真相藏起来的地方。
    notice: function (msg) {
      VS.errorMsg = msg || '没听清';
      if (!prefs.on) return;
      // 正在等回复/朗读时别被一次「没听清」打断流程
      if (VS.state === 'thinking' || VS.state === 'speaking') return;
      VS.fatal = false;
      VS.state = 'error';
      paint();
      setTimeout(function () {
        if (VS.state === 'error' && prefs.on) setState('ambient', '继续听');
      }, 2200);
    },
    status: function (jsonStr) {
      // 解析失败必须留痕：曾经原生吐的是单引号 JS 字面量（非法 JSON），
      // 这里一句 catch(e){} 就把「唤醒词永远同步不过来」吞成了哑巴故障。
      try { VS.status = JSON.parse(jsonStr); }
      catch (e) { log('原生状态不是合法 JSON，已忽略：' + jsonStr); }
      log('原生状态: ' + jsonStr);
      // 挂起中的页面只记录、不反应：引擎归当前活动页管。
      // 少了这道闸，切页时旧引擎停止的 running=false 会被这里读成「引擎掉了」，
      // 把自己的 prefs.on 关掉 —— 两页的语音状态从此各奔东西。
      if (VS.suspended) { VS.prevRunning = !!VS.status.running; paint(); return; }
      // 只有「本来在跑、现在不跑了」才算引擎掉了。
      // 旧写法只要收到 running=false 就自动关语音 —— 启动期的正常状态推送
      // 会被当成故障，语音自己把自己关掉。
      var wasRunning = VS.prevRunning === true;
      VS.prevRunning = !!VS.status.running;
      if (!VS.status.running && wasRunning && prefs.on) {
        prefs.on = false; savePrefs();
        VS.fatal = true; VS.errorMsg = '引擎未运行';
        if (VS.state === 'error') paint(); else setState('error', '引擎未运行');
      }
      // 刚开启 → 立刻开始听：点麦克风就能直接说，不必先喊唤醒词
      if (VS.status.running && VS.pendingDirect) {
        VS.pendingDirect = false;
        setTimeout(function () {
          if (!prefs.on) return;
          cmd('manualStart');
          setState('awake', '直接聆听');
          burst();                                  // 与唤醒同样的门槛感：现在开始捕捉
        }, 300);
      }
      paint();
    },
    // 供菜单/调试调用
    toggle: function () { if (prefs.on) disableVoice(); else enableVoice(); },
    /// 主题深浅（原生在换肤/页面就绪时推送）。挂 .ft-light 类给 CSS，
    /// 画板上的中心线/闪光也读它 —— 深色壳上白线、纸白壳上墨线，各得其所。
    setTheme: function (dark) {
      VS.dark = !(dark === false || dark === 'false');
      if (hud) hud.classList.toggle('ft-light', !VS.dark);
      if (micBtn) micBtn.classList.toggle('ft-light', !VS.dark);   // 悬浮钮也要跟着换装
      return VS.dark;
    },
    /// 页面切走（原生 toggleChatMode 调）：停朗读、清守护、把引擎交出去。
    /// 用独立命令 suspend 而不是 disable：disable 会推状态，把到达页吓出「引擎掉了」误判。
    suspend: function () {
      VS.suspended = true;
      stopSpeaking(true);
      if (guardTimer) { clearTimeout(guardTimer); guardTimer = null; }
      VS.guardSent = false;
      cmd('suspend');
      setState('off', '页面切走');
      return VS.state;
    },
    /// 页面回来：按自己的偏好接上。prefs.on 才重新 enable；direct=false 不抢进捕捉态。
    /// 引擎若已在跑（enable 幂等），状态不被动过。
    resume: function () {
      VS.suspended = false;
      if (!prefs.on) return VS.state;
      if (VS.state === 'off') enableVoice(false);
      return VS.state;
    },
    /// 原生侧统一存偏好 → 页面启动时取回。两页的 localStorage 互不相通，
    /// 没有这一步，主页开好的语音在聊天页就是「从没开过」。
    syncPrefs: function (json) {
      try {
        var o = JSON.parse(json);
        for (var k in o) if (o[k] !== undefined && o[k] !== null) prefs[k] = o[k];
      } catch (e) { log('偏好同步失败：' + e); return prefs; }
      savePrefs();
      paint();
      // 聊天页初次挂载就带着「开」状态 → 直接接上。
      // 主页不这样做：启动是否自动开语音是主页自己既有行为，不在这改。
      if (MODE === 'chat' && prefs.on && VS.state === 'off' && !VS.suspended) enableVoice(false);
      return prefs;
    },
    listenOnce: function () {
      if (!prefs.on) {
        enableVoice();
        setTimeout(function () { cmd('manualStart'); setState('awake', '免唤醒聆听'); burst(); }, 700);
        return;
      }
      cmd('manualStart'); setState('awake', '免唤醒聆听'); burst();
    },
    state: function () { return VS.state; }
  };

  // ---------- 设置栏目 ----------
  function rowShell(label, desc) {
    var row = document.createElement('div');
    row.style.cssText = 'display:flex;align-items:center;gap:10px;padding:9px 10px;border-radius:10px;' +
      'border:1px solid var(--dsw-alias-border-l2);cursor:pointer;user-select:none;';
    var txt = document.createElement('div');
    txt.style.cssText = 'flex:1;min-width:0;';
    var t1 = document.createElement('div');
    t1.style.cssText = 'font-size:13px;line-height:20px;color:var(--dsw-alias-label-primary);';
    t1.textContent = label;
    var t2 = document.createElement('div');
    t2.style.cssText = 'font-size:11px;line-height:16px;color:var(--dsw-alias-label-tertiary);';
    t2.textContent = desc;
    txt.appendChild(t1); txt.appendChild(t2);
    row.appendChild(txt);
    return { row: row, txt: txt, t1: t1, t2: t2 };
  }

  function switchRow(key, label, desc, after) {
    var s = rowShell(label, desc);
    var sw = document.createElement('span');
    sw.style.cssText = 'flex:none;width:34px;height:20px;border-radius:10px;position:relative;transition:background .18s;';
    var knob = document.createElement('span');
    knob.style.cssText = 'position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:#fff;' +
      'transition:transform .18s;box-shadow:0 1px 3px rgba(0,0,0,.4);';
    sw.appendChild(knob);
    s.row.appendChild(sw);
    function paint2() {
      var on = !!prefs[key];
      sw.style.background = on ? 'var(--ft-accent)' : 'var(--ft-accent-bg)';
      sw.style.border = on ? '1px solid var(--ft-accent)' : '1px solid var(--ft-accent-softer)';
      knob.style.transform = on ? 'translateX(14px)' : 'translateX(0)';
      s.row.style.borderColor = on ? 'var(--ft-accent-soft)' : 'var(--dsw-alias-border-l2)';
    }
    s.row.addEventListener('click', function () {
      prefs[key] = !prefs[key];
      savePrefs(); paint2();
      if (key === 'on') { if (prefs.on) enableVoice(); else disableVoice(); }
      else if (key === 'speak' && !prefs.speak) stopSpeaking(true);
      else pushConfig();
      if (after) after();
    });
    paint2();
    return s.row;
  }

  function textRow(label, desc, get, set) {
    var s = rowShell(label, desc);
    s.row.style.cursor = 'default';
    var input = document.createElement('input');
    input.type = 'text';
    input.value = get();
    input.style.cssText = 'flex:none;width:104px;box-sizing:border-box;padding:5px 8px;border-radius:8px;font-size:12px;' +
      'background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);' +
      'border:1px solid var(--dsw-alias-border-l2);outline:none;';
    input.addEventListener('click', function (e) { e.stopPropagation(); });
    input.addEventListener('change', function () { set(input.value.trim()); });
    s.row.appendChild(input);
    return s.row;
  }

  function selectRow(label, desc, options, get, set) {
    var s = rowShell(label, desc);
    s.row.style.cursor = 'default';
    var sel = document.createElement('select');
    sel.style.cssText = 'flex:none;width:118px;box-sizing:border-box;padding:5px 8px;border-radius:8px;font-size:12px;' +
      'background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);' +
      'border:1px solid var(--dsw-alias-border-l2);outline:none;';
    options.forEach(function (o) {
      var op = document.createElement('option');
      op.value = String(o.v); op.textContent = o.t;
      sel.appendChild(op);
    });
    sel.value = String(get());
    sel.addEventListener('click', function (e) { e.stopPropagation(); });
    sel.addEventListener('change', function () { set(sel.value); });
    s.row.appendChild(sel);
    return s.row;
  }

  function pushConfig() {
    if (!prefs.on) return;
    cmd('config', {
      wakeWords: wakeList(), ambient: prefs.ambient, pauseMs: prefs.pauseMs,
      sensitivity: 1.0, echoMode: prefs.echoMode, forcePath: prefs.forcePath
    });
    paint();
  }

  function voiceRows() {
    var out = [];
    out.push(switchRow('on', '语音对话', '开启后可用语音和 harness 说话；关掉即完全静音（麦克风会关闭）'));
    out.push(switchRow('ambient', '常驻监听（唤醒词）', '一直听着，说「' + prefs.wake + '」才开始收音。关掉则必须手动点麦克风按钮'));
    out.push(selectRow('识别通路', '设备端=离线不出本机；网络=更准。自动：设备端失败一次后记住改走网络', [
      { t: '自动', v: 'auto' }, { t: '始终网络', v: 'network' }, { t: '始终设备端', v: 'device' }
    ], function () { return prefs.forcePath; }, function (v) {
      prefs.forcePath = v; savePrefs();
      if (v === 'device') cmd('config', { resetPath: true });   // 给它一次重新验证的机会
      pushConfig();
    }));
    out.push(textRow('唤醒词', '说得清楚一点、2~4 个字最好认；近音变体会自动一并匹配', function () { return prefs.wake; },
      function (v) { if (!v) return; prefs.wake = v; savePrefs(); pushConfig(); rebuildSection(); }));
    out.push(selectRow('接续窗口', '回复答完后这么久内开口，不用再喊唤醒词、也不用点按钮。' +
      '关掉则每一句都要先喊「' + prefs.wake + '」', [
      { t: '关（每句都唤醒）', v: 0 }, { t: '8 秒', v: 8000 }, { t: '20 秒', v: 20000 }, { t: '1 分钟', v: 60000 }
    ], function () { return prefs.followMs; }, function (v) { prefs.followMs = +v; savePrefs(); paint(); }));
    out.push(switchRow('autoSend', '说完自动发送', '停顿后直接把识别结果发出去，不自动发送则只落进输入框'));
    out.push(selectRow('停顿时长', '说完之后停顿这么久就算一句结束', [
      { t: '0.8 秒', v: 800 }, { t: '1.2 秒', v: 1200 }, { t: '1.8 秒', v: 1800 }, { t: '2.5 秒', v: 2500 }
    ], function () { return prefs.pauseMs; }, function (v) { prefs.pauseMs = +v; savePrefs(); pushConfig(); }));
    out.push(switchRow('speak', '自动朗读回复', '回复生成完自动念出来；朗读时直接开口就能打断'));
    out.push(selectRow('音色', zhVoices.length ? '系统里的中文音色' : '尚未读到音色（点一下刷新）', zhVoices.length ? zhVoices.map(function (v) {
      return { t: (v.name || '音色') + ' · ' + v.lang, v: v.voiceURI };
    }) : [{ t: '默认', v: '' }], function () { return prefs.voiceURI; }, function (v) { prefs.voiceURI = v; savePrefs(); }));
    out.push(selectRow('语速', '念得快一点还是慢一点', [
      { t: '慢 0.9×', v: 0.9 }, { t: '正常 1.05×', v: 1.05 }, { t: '快 1.2×', v: 1.2 }, { t: '很快 1.35×', v: 1.35 }
    ], function () { return prefs.rate; }, function (v) { prefs.rate = +v; savePrefs(); }));
    out.push(switchRow('bargeIn', '说话时打断朗读', '它正在念的时候你开口，它立刻停下来听你说（外放消音开着的那几秒会稍迟钝）'));
    out.push(selectRow('外放消音（AEC）', '任何从扬声器出来的声音（提示音、朗读、页面音效）都会被自己的麦克风捡回去，' +
      '于是第二轮开始它听到的全是自己的声音。自动=只在它自己发声那段时间消掉；常开=一直消但灵敏度会降', [
      { t: '自动', v: 'auto' }, { t: '常开', v: 'on' }, { t: '关', v: 'off' }
    ], function () { return prefs.echoMode; }, function (v) {
      prefs.echoMode = v; savePrefs();
      if (v !== 'auto') cmd('echoGuard', { value: false });   // 离开自动档，清掉守护态
      pushConfig();
    }));
    return out;
  }

  var secEl = null;
  function rebuildSection() {
    if (secEl && secEl.parentNode) secEl.parentNode.removeChild(secEl);
    secEl = null;
    ensureSection();
  }

  function ensureSection() {
    if (MODE !== 'dsh') return;          // 设置面板只在 dsh 主页；聊天页共用同一份偏好
    var content = document.querySelector('[class$="_content"]');
    if (!content || document.getElementById('ft-voice-section')) return;
    refreshVoices();
    var sec = document.createElement('div');
    sec.id = 'ft-voice-section';
    sec.style.cssText = 'flex-direction:column;gap:12px;padding:18px 14px;display:flex;border-bottom:1px solid var(--dsw-alias-border-l2);';
    var head = document.createElement('div');
    head.style.cssText = 'display:flex;align-items:center;gap:8px;color:var(--dsw-alias-label-primary);font-size:15px;font-weight:500;line-height:22px;';
    var dot = document.createElement('span');
    dot.style.cssText = 'width:6px;height:6px;border-radius:50%;background:var(--ft-accent);flex:none;';
    head.appendChild(dot);
    head.appendChild(document.createTextNode('语音'));
    sec.appendChild(head);
    var hint = document.createElement('div');
    hint.style.cssText = 'color:var(--dsw-alias-label-tertiary);font-size:12px;line-height:18px;';
    hint.textContent = '识别在这台 Mac 上离线完成（设备端 zh-CN），音频不出本机。首次开启会向系统申请麦克风与语音识别权限。';
    sec.appendChild(hint);
    var list = document.createElement('div');
    list.style.cssText = 'display:flex;flex-direction:column;gap:8px;';
    var rows = voiceRows();
    for (var i = 0; i < rows.length; i++) list.appendChild(rows[i]);
    sec.appendChild(list);

    // 紧跟在「生灵」栏目之后（没有就接在「皮肤」后）
    var prev = document.getElementById('ft-alive-section') || document.getElementById('ft-skin-section');
    if (prev && prev.parentNode) prev.parentNode.insertBefore(sec, prev.nextSibling);
    else if (content.firstChild) content.insertBefore(sec, content.firstChild);
    else content.appendChild(sec);
    secEl = sec;
  }

  // ---------- 自检 ----------
  window.__ftVoiceDebug = {
    state: function () {
      return {
        mode: MODE, dark: VS.dark, suspended: VS.suspended,
        state: VS.state, prefs: prefs, status: VS.status, partial: VS.partial,
        lastReply: VS.lastReply, hud: !!hud, hudState: hud ? hud.getAttribute('data-state') : null,
        micBtn: !!document.getElementById('ft-mic-btn'),
        // 视觉相位（验证台靠这几项断言动画真的在跑，而不是只看状态名）
        fold: Math.round(VS.fold * 1000) / 1000,
        flash: Math.round(VS.flash * 1000) / 1000,
        quiet: Math.round(VS.quiet * 1000) / 1000,
        loud: !!VS.loud,
        speakProg: Math.round(VS.speakProg * 1000) / 1000,
        wakeClass: hud ? hud.classList.contains('ft-wake') : false,
        progMode: hud ? hud.getAttribute('data-prog') : null,
        sendStep: VS.sendStep,
        editMode: VS.edit ? VS.edit.mode : null,
        editRule: VS.edit ? VS.edit.rule : null,
        editOff: VS.editOff, editForce: VS.editForce,
        editSent: VS.editSent,
        followLeft: followLeft(), inFollowUp: inFollowUp(),
        bands: Array.prototype.slice.call(VS.cur).map(function (v) { return Math.round(v * 1000) / 1000; }),
        voices: zhVoices.length, error: VS.errorMsg
      };
    },
    // 无头实证用：伪造「回复刚答完」，用来验证接续窗口确实会免唤醒接上
    markReply: function () { VS.replyAt = Date.now(); return VS.replyAt; },
    followLeft: function () { return followLeft(); },
    // 无头实证用：模拟原生推来的判停进度锚点
    pause: function (p, hasText) { window.__ftVoice.pause(p, hasText); return VS.quiet; },
    burst: function () { burst(); return true; },
    // 无头实证用：不经过麦克风，直接把文字喂进最后的「送出」环节
    feed: function (text) { deliver(text); return VS.state; },
    /// 无头实证用：直接问「口语自纠」引擎这句话会怎么处理。
    /// 语法门靠它做表驱动穷举 —— 尤其要盯住「陈述性否定」的假阳性
    /// （「这个不对，是那个」是人话，不是改口）。
    spokenEdit: function (t) {
      var ed = spokenEdit(t);
      if (!ed) return null;
      return {
        hit: ed.hit, mode: ed.mode, rule: ed.rule, conf: ed.conf, cue: ed.cue,
        text: ed.text || '', cutText: ed.cutText || '', fix: ed.fix || '',
        segs: (ed.segs || []).map(function (g) { return { keep: g.keep, retract: g.retract }; })
      };
    },
    // 真机诊断用：读/清输入框（清空只在「内容确实是上次遗留的测试句」时才做）
    composer: function () { return composerText(); },
    clearComposer: function () {
      var el = composer();
      if (!el) return null;
      try { el.focus(); } catch (e) {}
      caretToEnd(el);
      var n = (el.textContent || '').length + 8;
      for (var i = 0; i < n; i++) {
        el.dispatchEvent(new KeyboardEvent('keydown', {
          key: 'Backspace', code: 'Backspace', keyCode: 8, which: 8, bubbles: true, cancelable: true
        }));
      }
      return composerText();
    },
    /// 回环诊断前调用：输入框里如果只剩测试句（上一轮遗留下来），就清掉；
    /// 其他内容一律不动 —— 那是用户自己的草稿。
    prepareLoopback: function () {
      // 页面/输入框还没渲染出来时必须回空串：否则会被当成「输入框是空的」而不再重试，
      // 然后等页面加载完、遗留草稿出现，正好把这一轮发送挡住（已经踩过一次）。
      if (!composer()) return '';
      var s = composerText().trim();
      if (!s) return '输入框是空的';
      // 只清「完全由测试句、可能重复若干次组成」的内容（逐词比对，保守）
      var parts = s.split(/\s+/);
      var isMine = parts.length > 0 && parts.every(function (w) { return w === '帮我看看今天有什么新消息'; });
      if (isMine) {
        var after = window.__ftVoiceDebug.clearComposer();
        return '已清掉 ' + parts.length + ' 份遗留测试句，现在=' + JSON.stringify(after);
      }
      return '输入框有内容，未动：' + s.slice(0, 40);
    },
    setPartial: function (t) { VS.partial = t; paint(); },
    setState: function (s, why) { setState(s, why || '诊断'); return VS.state; },
    setLevels: function (arr) { window.__ftVoice.levels(arr); },
    wake: function (w) { window.__ftVoice.wake(w || prefs.wake); return VS.state; },
    speak: function (t) { speak(t || '测试朗读'); return VS.state; },
    stop: function () { stopSpeaking(true); return VS.state; },
    reply: function () { return replyText(); },
    setPrefs: function (o) { for (var k in o) prefs[k] = o[k]; savePrefs(); paint(); return prefs; },
    // 帧循环门控快照（2.23.0 能耗诊断）：off 且 hb=true 表示已停表、只走 500ms 心跳
    frameState: function () { return { state: VS.state, queued: FQ.queued, hb: !!FQ.hb, stopPending: !!FQ.stopT, need: needFrames() }; },
    // 只改内存、不落 localStorage：诊断期间临时静音用，不动用户的偏好
    setPrefsVolatile: function (o) { for (var k in o) prefs[k] = o[k]; paint(); return prefs; },
    // 无头实证用：把看门狗的时间参数调小，几百毫秒内就能验出兜底路径
    tune: function (o) { for (var k in o) if (o[k] != null) TUNE[k] = o[k]; return TUNE; },
    watchdog: function () { return { armed: !!speakTimer, deadlineInMs: speakDeadline ? speakDeadline - Date.now() : 0, tune: TUNE }; }
  };

  // ---------- 启动 ----------
  function boot() {
    loadPrefs();
    injectStyle();
    buildHud();
    // 向原生要全局偏好（另一页存的那份）。原生没有存过就静默：首次启动本来就没有。
    cmd('prefsGet');
    if (window.speechSynthesis) {
      refreshVoices();
      window.speechSynthesis.addEventListener('voiceschanged', function () { refreshVoices(); });
    }
    setState('off');
    paintMic();
    frameStart();                          // 门控启动（2.23.0）

    var pending = false;
    function sweep() {
      if (pending) return;
      pending = true;
      setTimeout(function () {
        pending = false;
        ensureMicButton();
        ensureSection();
        // 注意：这里只管挂件与设置栏目。「听见了」的收回不能放在本扫描里 ——
        // 本扫描靠 MutationObserver 触发，界面一旦没有别的动静它就停摆了，
        // 提示会永远挂着收不回去（实测踩到）。收回放在帧循环里，那里总是会跑。
      }, 200);
    }
    sweep();
    if (window.MutationObserver) {
      new MutationObserver(sweep).observe(document.documentElement, { childList: true, subtree: true });
    }
    window.addEventListener('resize', function () { resizeCanvas(); placeHud(); }, { passive: true });
    // 用户开始打字 → 立刻收掉朗读与提示，别抢注意力
    window.addEventListener('keydown', function (e) {
      if (VS.state === 'speaking' && !e.metaKey && !e.ctrlKey) stopSpeaking(false);
    }, { passive: true });
  }

  if (document.body) boot();
  else document.addEventListener('DOMContentLoaded', boot);
})();
