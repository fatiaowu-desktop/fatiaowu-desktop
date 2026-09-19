// 发条屋 - DeepSeek Harness 原生独立窗口
// 用系统 WebKit 渲染，不依赖任何浏览器；服务未就绪时自动重连
import Cocoa
import CryptoKit
import WebKit
import Speech
import AVFoundation

// 内置浏览器「用默认浏览器打开」按钮（带回调的轻量子类）
final class BrowserOpenButton: NSButton {
    var onOpen: (() -> Void)?
    override func performClick(_ sender: Any?) {
        onOpen?()
        super.performClick(sender)
    }
}


// ==================== 语音引擎 ====================
// 职责：麦克风采集 → ① 电平分桶（驱动波形动画）② 送 SFSpeechRecognizer（设备端离线识别）
//      ③ 能量门控 + 唤醒词匹配 ④ 判停（停顿 N 毫秒算一句说完）
//
// 为什么 STT 必须走原生：WKWebView 里的 webkitSpeechRecognition 是**半死实现** —— 实测
// start() 不抛异常、start/audiostart 都触发，然后 12 秒内既无 result 也无 error。所以
// 走原生 SFSpeechRecognizer（zh-CN 设备端，离线、免费、隐私留在本机）。
//
// 为什么波形也由这里驱动、而不是让 JS 再开一路 getUserMedia：
// 识别与电平共用**同一条**音频链路，于是「波形在动」与「识别到字」永远同源同步，
// 不会出现「有波形却没文字」的错位；也避免两个客户端同时抓麦克风。
//
// 线程模型：音频 tap 在实时线程上跑，它**只做三件廉价的事** —— 算电平、跑 VAD、
// 把 buffer 追加给识别请求；所有请求生命周期与回调都回到主线程。跨线程只传
// 「上沿/下沿」这类瞬时事件，不共享可变状态。
//
// 送识别前**必须降成单声道**（2026-09-19 实测）：这台机器的内置 3 麦阵列在开启回声消除后，
// 输入节点给出的是 9 声道 buffer。把多声道 buffer 原样丢给 SFSpeechRecognizer，它拿到的
// 样本布局是错的，于是每次都回「No speech detected」——对外表现成「说完没反应 + 提示语音
// 不可用」，而权限、识别器、电平、唤醒词匹配全都是好的，极易被误判成权限问题。
final class VoiceEngine {
    static let bands = 28

    // ── 配置（主线程写、音频线程只读，均为字长类型，竞争后果可忽略）──
    /// 默认唤醒词。带「小金鱼」这类变体不是凑数：实测这台机器的识别器稳定把
    /// 「小鲸鱼」听成「小金鱼」（jīng→jīn），只认正字就永远唤不醒。
    var wakeWords: [String] = ["小鲸鱼", "小金鱼", "嗨小鲸鱼", "嗨小金鱼", "小鲸", "小金"]
    var ambientEnabled = true          // 常驻监听（能量门控）
    var pauseMs: Double = 1200         // 停顿多久算说完
    var sensitivity: Float = 1.0       // 灵敏度倍率
    /// 回声消除（原意：朗读时防止扬声器自激）。
    ///
    /// 2026-09-19 实测（回声自检，flag: /tmp/ft-voice-aec.flag）：
    /// 同一段外放音频放两遍——关 AEC 时峰值电平 0.0502、识别出「今天天气怎么样」；
    /// 开 AEC 时峰值塌到 0.0064、一个字都没认出来。也就是说 AEC 在这台机器上**确实生效**，
    /// 能把扬声器那一路减掉约 8 倍。
    /// 代价也有：`setVoiceProcessingEnabled(true)` 会把输入节点从 1 声道变成 **9 声道**
    /// （9 条内容相同，降混取第 0 条即可，这条路已经打通），且整体电平压得很低——
    /// 长时间常开会削弱灵敏度。所以做成三档，默认「自动」：只在它自己发声的那段时间开。
    var echoCancel = false
    /// 三档：off（不消）/ on（一直消）/ auto（只在「它在说话/刚放完声音」那段时间消）
    var echoMode = "auto"
    /// auto 档下的实时开关：true 表示此刻正处于「外放守护」中（AEC 实际开启）
    private(set) var echoGuard = false
    /// 捕捉中推迟的守护关闭：撞上 awake/活跃请求时先记账，tick 里等捕捉结束再补
    private var pendingGuard: Bool?
    /// 识别通路：auto（设备端优先，失败自动转网络并记住）/ network / device
    var forcePath = "auto"

    // ── 对外回调（一律在主线程触发）──
    var onLevels: (([Float]) -> Void)?
    var onPartial: ((String, Bool) -> Void)?
    var onWake: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onBargeIn: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 一次「没听清」这类可恢复的小状况：界面短暂提示后自己回到监听，
    /// 不该像致命错误那样把 HUD 永久钉在「语音不可用」。
    var onNotice: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// 判停进度（progress 0…1，hasText 表示「确实有内容、数秒才有意义」）。
    ///
    /// 存在的理由不是装饰：界面上必须**看得见它在读秒**。此前停顿的这一秒多是纯黑箱，
    /// 用户说完最后一句后界面毫无变化，只会得到「说完没反应」的观感——哪怕一秒钟后
    /// 一切如期发生。这个信号把「它还活着、正在倒计时」变成可见的。
    var onPause: ((Double, Bool) -> Void)?
    private var lastPausePush: Double = -1

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var running = false
    private(set) var onDeviceOK = false
    /// 是否已从「设备端识别」退到「网络识别」（设备端连续失败时自救，见 noteFailure）
    private(set) var usingNetwork = false
    var onModeChange: (() -> Void)?

    // ── 送识别用的单声道缓冲 ──
    // 必须有：多声道 buffer 直接交给 SFSpeechRecognizer 会被判成「没听到人声」。
    /// 采集端实际声道数（诊断用：开回声消除后 tap 会变成多声道，要看清是哪几条）
    private(set) var inputChannels = 0
    private var monoFormat: AVAudioFormat?
    private var monoBuf: AVAudioPCMBuffer?
    // 预卷缓冲：常驻监听阶段把最近约 1.5 秒音频留在手里。
    // 唤醒词在句首，而识别请求要等能量上沿才拉起 —— 等它起来，「小…」那一下早过去了，
    // 识别到的永远是半句，唤醒词自然匹配不上（表现：喊了很多次都唤不醒）。
    // 所以请求一起，先把这段历史补喂进去。
    // 用 AVAudioPCMBuffer 而不是 [Float]：数组有 COW 与独占性检查，
    // 音频线程写、主线程读会真出事；buffer 的原始指针没有这个问题。
    private var preRollBuf: AVAudioPCMBuffer?   // 环形缓冲，约 1.5 秒
    private var preFeedBuf: AVAudioPCMBuffer?   // 补喂时的小分块（只有主线程碰）
    private var preRollPos = 0                  // 音频线程写指针
    private var preRollFilled = 0

    // ── 音频线程私有状态（只有 tap 里读写）──
    private let lock = NSLock()
    private var feeding = false        // 是否把 buffer 送给识别请求（主线程设置）
    private var feedReq: SFSpeechAudioBufferRecognitionRequest?   // 与 feeding 同锁发布
    private var noiseFloor: Float = 0.004
    private var voiced = false
    private var voicedRun = 0
    private var silentRun = 0
    private var lastPush: Double = 0
    private var bargeRun = 0

    // ── 主线程状态 ──
    private var awake = false
    private var currentText = ""
    private var lastChangeAt: Double = 0
    private var pauseTimer: Timer?
    private var idleStopAt: Double = 0
    private var requestStartedAt: Double = 0
    private var paused = false         // AI 在思考/朗读中：整段不听，只保留打断检测
    private var pausedAt: Double = 0   // 进入暂停的时刻：用来兜底「JS 漏发解除」导致的永久性聋
    private var pendingSeed = ""       // 唤醒词后面紧跟着说的内容（「小鲸鱼，帮我查X」）
    private var wakeCooldownUntil: Double = 0   // 说完一句后短暂不认唤醒词，防止尾音二次触发
    private var noSpeechStreak = 0     // 连续「没听到人声」次数（用来决定要不要退到网络识别）
    private var warnedBothPaths = false // 两条识别通路都失败过，只警告一次

    // ── 识别器「哑火」看门狗 ──
    // 背景（2026-09-20 实测）：设备端识别器有一种**静默失效**——音频在喂（rms 正常、
    // 块数在涨）、人声确实存在，但它不回任何结果、也不报任何错。已有的自救全部依赖
    // 「错误回调」，这个状态一个都覆盖不到；currentText 永远是空，finalize 永不触发，
    // 表现就是「唤醒都成功了，可怎么都不发送」。
    // 解法：自己计时。喂够了音频、期间有真实人声、却长时间没有任何回调进展 → 重开请求；
    // 连续两次还这样 → 判定这条路坏了，切网络。
    private var lastResultAt: Double = 0      // 最近一次识别回调（含空结果）的时间
    private var feedSamplesTotal = 0          // 音频线程累计喂给识别器的样本数（永不清零）
    private var voiceSamples = 0              // 音频线程累计「超过门限」的样本数（永不清零）
    private var fedAtStart = 0                // 请求启动时的 feedSamplesTotal 快照
    private var voicedAtStart = 0             // 请求启动时的 voiceSamples 快照
    private var stallStreak = 0               // 连续哑火次数（出字即清零）

    // ── 常驻监听的「续命」状态 ──
    // 背景（实测，2026-09-19）：能量上沿拉起识别请求后，SFSpeech 常常在音频还没攒够时
    // 就回一次 1110「No speech detected」，请求随之被收掉。而**上沿只有一次**——
    // 用户还在说话期间 voiced 一直是 true，不会再产生新的上沿，于是这一整句剩下的部分
    // 没有任何识别器在听。表现就是「第一次能发，之后怎么喊都唤不醒，只能点按钮」。
    // 解法：说话期间（电平仍在门限之上）请求死了就立刻补拉，直到真正安静下来。
    private var lastRms: Float = 0            // 音频线程写、主线程读的最新一帧 RMS
    private var lastEdgeUpAt: Double = 0      // 最近一次能量上沿
    private var lastReqEndAt: Double = 0      // 最近一次请求收摊
    private var quickFails = 0                // 连续「起来不到 1 秒就失败」的次数
    private var requestOnDevice = false       // 本次请求实际走的通路（判失败时要用）
    private var devicePathFailed = false      // 设备端这条路报过「没听到人声」
    private var networkPathFailed = false     // 网络这条路报过「没听到人声」
    private var bothPathsFailed: Bool { devicePathFailed && networkPathFailed }
    private var restartCooldownUntil: Double = 0   // 快速失败连发后的冷却，防请求风暴

    // ── 声道诊断窗口（只在开头一小段记，平时零开销）──
    // 为什么要这个：这台机器开回声消除后输入是 9 声道，而「哪一路才是真正的主麦」
    // 只能实测。攒每个声道的能量再打日志，一眼看出该取哪一路。
    private var diagAcc: [Double] = []
    private var diagFrames = 0
    private var diagUntil: Double = 0
    private var diagNextLog: Double = 0

    // ── 送识别的实测（用来把「音频根本没送进去」与「送进去了但识别器认不出」分开）──
    private var feedSq = 0.0
    private var feedN = 0
    private var feedBlocks = 0
    private var feedPeak: Float = 0
    private var feedFormatLogged = false
    private var player: AVAudioPlayer?   // 回环自检放音用

    private var threshold: Float { max(0.014, noiseFloor * 3.2) * sensitivity }

    func log(_ s: String) { onLog?(s) }

    private func fmtLine(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))Hz 声道=\(f.channelCount) 交错=\(f.isInterleaved ? "是" : "否")"
    }

    // MARK: 权限

    /// 申请「语音识别」+「麦克风」两项权限。两者都通过才真正可用。
    func requestPermissions(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            let speechOK = (st == .authorized)
            let speechWhy: String
            switch st {
            case .authorized: speechWhy = "已授权"
            case .denied: speechWhy = "语音识别被拒绝（系统设置 → 隐私与安全性 → 语音识别）"
            case .restricted: speechWhy = "语音识别被系统限制"
            case .notDetermined: speechWhy = "语音识别未决定"
            @unknown default: speechWhy = "语音识别未知状态"
            }
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    done(speechOK && micOK,
                         "语音识别=\(speechWhy) 麦克风=\(micOK ? "已授权" : "被拒绝（系统设置 → 隐私与安全性 → 麦克风）")")
                }
            }
        }
    }

    // MARK: 启停

    func start() {
        guard !running else { return }
        let loc = Locale(identifier: "zh-CN")
        guard let rec = SFSpeechRecognizer(locale: loc) else {
            report("zh-CN 识别器不可用（这台机器没装中文识别）"); return
        }
        guard rec.isAvailable else { report("识别器当前不可用（可能被系统限制）"); return }
        recognizer = rec
        onDeviceOK = rec.supportsOnDeviceRecognition
        // 每次启动都从**设备端**开始，不再把上次「改用网络」的结论读回来。
        // 为什么：那个结论是 2026-09-19 早些时候得出的，而当时真正的病根是
        // 9 声道 buffer 直接喂给识别器（那条多声道 bug）—— 设备端是被冤枉的。
        // 当天晚些时候的文件自检给出反证：同一段音频，网络通路报 No speech，
        // 设备端准确识别出「小鲸鱼今天天气怎么样」。
        // 设备端还有两个实打实的好处：音频不出本机、不受服务端波动/限流影响。
        usingNetwork = false
        UserDefaults.standard.set(false, forKey: "ftVoiceUseNetwork")
        log("识别器就绪 zh-CN，设备端=\(onDeviceOK ? "支持" : "不支持")，起始通路=设备端（失败再退网络）")

        let input = engine.inputNode
        log("输入格式(硬件): \(fmtLine(input.inputFormat(forBus: 0)))")
        // 回声消除：常驻监听 + 扬声器朗读会自激，必须开。老系统可能不支持 → 降级但不中断。
        if echoCancel {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { log("回声消除不可用（降级继续）: \(error.localizedDescription)") }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            report("麦克风输入格式无效（采样率 \(fmt.sampleRate) 声道 \(fmt.channelCount)）"); return
        }
        log("输入格式(就绪): \(fmtLine(fmt))")

        // 送识别必须是**单声道**。
        // 这台机器（内置 3 麦阵列 + 回声消除）输入节点给出的是 9 声道 buffer；
        // 把这种 buffer 原样交给 SFSpeechRecognizer，它拿到的是错的样本布局，
        // 结果每一次都回「No speech detected」——表现成「说完没反应 + 提示语音不可用」，
        // 而权限、识别器、电平、唤醒词匹配全都正常，所以极易误判成权限问题。
        // 这里在音频线程按第 0 声道拷成单声道，再送识别。
        guard let mf = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: fmt.sampleRate,
                                     channels: 1,
                                     interleaved: false),
              let mb = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: 8192) else {
            report("无法创建单声道转换缓冲"); return
        }
        monoFormat = mf
        monoBuf = mb
        inputChannels = Int(fmt.channelCount)
        // 预卷：常驻阶段留住最近约 1.5 秒。唤醒词在句首，识别请求却要等能量上沿才起来，
        // 没有它，请求里永远少了开头那一下，唤醒词就匹配不上。
        let preFrames = AVAudioFrameCount(min(96000, Int(fmt.sampleRate) * 3 / 2))
        preRollBuf = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: preFrames)
        preFeedBuf = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: 8192)
        preRollPos = 0
        preRollFilled = 0
        // 诊断窗口：只在开头 90 秒记录每声道能量
        let t0 = CACurrentMediaTime()
        diagAcc = [Double](repeating: 0, count: Int(fmt.channelCount))
        diagFrames = 0
        diagUntil = t0 + 90
        diagNextLog = t0 + 1

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.onAudio(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            report("音频引擎启动失败: \(error.localizedDescription)"); return
        }
        running = true
        paused = false     // 重新开启时清掉「AI 正在说话」的遗留暂停，否则一开就是聋的
        log("语音引擎已启动 采样率=\(Int(fmt.sampleRate)) 声道=\(fmt.channelCount) 门限=\(String(format: "%.4f", threshold))")
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopRequest()
        setFeeding(false)
        pauseTimer?.invalidate(); pauseTimer = nil
        awake = false
        paused = false
        resetPausePush()
        // 无条件关一次：外放守护切换时 echoCancel 可能已经先被改掉了，
        // 按当前值判断会漏关，残留的 voice processing 会让下一次采集莫名其妙地变 9 声道。
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        diagUntil = 0; diagNextLog = 0
        log("语音引擎已停止")
    }

    // MARK: 外放消音（AEC）档位与外放守护

    func setEchoMode(_ m: String) {
        echoMode = m
        echoCancel = (m == "on")
        echoGuard = false
        log("外放消音档位: \(m)（AEC 实际=\(echoCancel)）")
    }

    /// 外放守护（仅 auto 档）：AI 在思考/朗读、或页面刚播完提示音的这段时间里把 AEC 打开，
    /// 让它自己的声音不再被麦克风捡回来当成下一轮的人声。
    ///
    /// 为什么不常开：实测开 AEC 后静默电平从 0.0030 掉到 0.0002，灵敏度是实打实变差的；
    /// 而污染只发生在「它在发声」的那一小段，没必要拿全时段的灵敏度去换。
    /// 切换要重建采集（约 0.3 秒静默），所以只在真正跨越边界时做。
    func setEchoGuard(_ on: Bool) {
        guard echoMode == "auto" else { return }
        if echoGuard == on { pendingGuard = nil; return }
        // 关守护恰好撞上用户正在捕捉：不能拦腰重建采集 ——
        // 实测（2026-09-20）：打断朗读进捕捉 2 秒后守护关闭触发重建，把刚开的捕捉
        // 打断，识别出一堆空碎片 → 空收句 → JS 状态机卡死在 awake，之后唤醒/说话
        // 全被同态跳过静默吞掉，表现就是「第一轮能发，之后永远不再发送」。
        // 开守护不推迟：AEC 必须赶在 TTS 出声前就位，晚了就压不住回声。
        if !on && (awake || request != nil) {
            if pendingGuard != on {
                pendingGuard = on
                log("外放守护关闭推迟：本轮捕捉结束后再生效")
            }
            return
        }
        applyEchoGuard(on)
    }

    private func applyEchoGuard(_ on: Bool) {
        echoGuard = on
        guard running else { return }
        echoCancel = on
        log("外放守护: \(on ? "开" : "关")（重建采集以切换 AEC）")
        let wasAwake = awake, wasPaused = paused, keep = currentText
        stop()
        start()
        awake = wasAwake
        paused = wasPaused
        currentText = keep
        if awake && !paused && request == nil { startRequest() }
    }

    /// tick 调用：没有捕捉在跑、请求也空了，把推迟的守护切换补上
    private func flushPendingGuard() {
        if let pg = pendingGuard, !awake, request == nil {
            pendingGuard = nil
            applyEchoGuard(pg)
        }
    }

    // MARK: 自检（flag 驱动，用来把「识别器本身坏了」和「实时送流送错了」分开）

    /// 直接对一个音频**文件**跑 SFSpeech，两条通路各跑一次。
    /// 这一步把排查一刀切开：文件能识别 → 识别器/权限/语言资源都没问题，
    /// 那问题就在我们的实时送流；文件也识别不了 → 根本不在送流，别再折腾 buffer。
    func selfTestFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            log("自检: 找不到测试音频 \(path)"); return
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            log("自检: zh-CN 识别器创建失败"); return
        }
        log("自检: 识别器 isAvailable=\(rec.isAvailable) 设备端支持=\(rec.supportsOnDeviceRecognition) 文件=\(path)")
        for onDevice in [true, false] {
            let tag = onDevice ? "设备端" : "网络"
            let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
            req.requiresOnDeviceRecognition = onDevice
            req.shouldReportPartialResults = false
            var done = false
            rec.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let e = error {
                        let ns = e as NSError
                        self?.log("自检[\(tag)] 失败: [\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
                        done = true
                    } else if let r = result, r.isFinal, !done {
                        done = true
                        self?.log("自检[\(tag)] 成功: 「\(r.bestTranscription.formattedString)」")
                    }
                }
            }
        }
    }

    /// 回环自检（flag 驱动）：把扬声器当音源，走一遍**完整的实时链路**
    /// （采集 → 单声道拷贝 → 送识别 → 唤醒词 → 判停 → final），全程不需要人说话。
    /// 这样「用户说没反应」就变成一个能反复重跑、能二分定位的确定性用例。
    ///
    /// 必须关掉回声消除：AEC 的职责就是把扬声器那一路消掉，开着测必然是假阴性。
    func loopbackSelfTest(_ audioPath: String) {
        echoCancel = false
        usingNetwork = false         // 先用设备端（文件自检已证设备端可用、网络反而报 No speech）
        start()
        guard running else { log("回环自检: 引擎没起来"); return }
        awake = true                 // 不等唤醒词，直接进捕捉态
        currentText = ""
        lastChangeAt = CACurrentMediaTime()
        if request == nil { startRequest() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            do {
                self.player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath))
                self.player?.volume = 1.0
                self.player?.play()
                self.log("回环自检: 开始放音（扬声器 → 麦克风）")
            } catch {
                self.log("回环自检: 放音失败 \(error.localizedDescription)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) { [weak self] in
            guard let self = self else { return }
            self.log("回环自检: 结束（awake=\(self.awake) 已拿到文本=「\(self.currentText)」）")
            self.manualStop()
            self.stop()
        }
    }

    /// 回声自检（flag 驱动）：同一段音频放两遍——关 AEC 一遍、开 AEC 一遍。
    ///
    /// 用途很实际：界面里任何扬声器外放（提示音、朗读、音效）都会被自己的麦克风捡回去，
    /// 于是第二轮开始听到的全是「它自己的声音」——唤醒词匹配不上、判停也停不下来。
    /// AEC 的职责正是把扬声器那一路减掉，所以判断它有没有生效的判据是反直觉的：
    /// **开 AEC 之后，同一段外放应该基本听不见了**（峰值电平塌下去、识别不出文字）。
    /// 两轮一比就知道这台机器的 AEC 到底管不管用，该不该默认开。
    func aecSelfTest(_ audioPath: String) {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("回声自检: 找不到测试音频 \(audioPath)"); return
        }
        let rounds = [false, true]
        func run(_ idx: Int) {
            if idx >= rounds.count { log("回声自检: 两轮跑完"); return }
            let ec = rounds[idx]
            let tag = ec ? "开 AEC" : "关 AEC"
            echoCancel = ec
            usingNetwork = false
            stop()
            start()
            guard running else { log("回声自检[\(tag)]: 引擎没起来"); run(idx + 1); return }
            awake = true                 // 直接进捕捉态，省掉唤醒那一环
            currentText = ""
            lastChangeAt = CACurrentMediaTime()
            if request == nil { startRequest() }

            var peak: Float = 0
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                let r = self.lastRms
                if r > peak { peak = r }
            }
            timer.resume()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                do {
                    self.player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath))
                    self.player?.volume = 1.0
                    self.player?.play()
                    self.log("回声自检[\(tag)]: 开始放音（声道=\(self.inputChannels) 门限=\(String(format: "%.4f", self.threshold))）")
                } catch {
                    self.log("回声自检[\(tag)]: 放音失败 \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
                guard let self = self else { return }
                timer.cancel()
                self.log("回声自检[\(tag)]: 峰值电平=\(String(format: "%.4f", peak)) 识别到=「\(self.currentText)」")
                self.manualStop()
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(idx + 1) }
            }
        }
        run(0)
    }

    /// 唤醒链路自检（flag 驱动）：保持**常驻监听**（不进捕捉态），播一段含唤醒词的音频。
    ///
    /// 与回环自检的区别：回环一上来就 awake=true，把唤醒词这一环整个跳过了。
    /// 而「第一次能发、之后叫不醒」的病根恰恰只在常驻这一段——上沿拉起请求、
    /// 请求被「No speech」提前收掉、续命有没有补上、唤醒词（含近音）有没有命中。
    /// 期望日志：识别请求开始 →（可能几次失败+续命）→ 唤醒命中「…」→ 一句说完。
    func wakeSelfTest(_ audioPath: String) {
        echoCancel = false
        usingNetwork = false         // 与线上一致：先走设备端
        start()
        guard running else { log("唤醒自检: 引擎没起来"); return }
        awake = false                 // 关键：就停在常驻态，等它自己被叫醒
        currentText = ""
        ambientEnabled = true
        wakeCooldownUntil = 0
        log("唤醒自检: 保持常驻监听，1.5 秒后放音")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            do {
                self.player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath))
                self.player?.volume = 1.0
                self.player?.play()
                self.log("唤醒自检: 开始放音（期望出现「唤醒命中」）")
            } catch {
                self.log("唤醒自检: 放音失败 \(error.localizedDescription)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            guard let self = self else { return }
            self.log("唤醒自检: 结束（awake=\(self.awake) 文本=「\(self.currentText)」）")
            self.stop()
        }
    }

    // MARK: 音频线程

    private func onAudio(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        guard n > 0, let ch = buf.floatChannelData else { return }
        let nch = max(1, Int(buf.format.channelCount))
        // 交错布局下所有声道挤在同一根指针里，取第 0 声道要按声道数跳着读。
        let st = buf.format.isInterleaved ? nch : 1
        let p = ch[0]

        var peak: Float = 0, sq: Float = 0
        for i in 0..<n { let v = p[i * st]; let a = abs(v); if a > peak { peak = a }; sq += v * v }
        let rms = (sq / Float(n)).squareRoot()

        let now = CACurrentMediaTime()

        // ⓪ 声道诊断：把每个声道的能量分别攒起来（只在开头 90 秒做，平时零开销）
        if now < diagUntil && diagAcc.count == nch {
            for c in 0..<nch {
                let q = ch[c]
                var s = 0.0
                for i in 0..<n { let v = Double(q[i * st]); s += v * v }
                diagAcc[c] += s
            }
            diagFrames += n
        }

        // ① 电平分桶（28 段 RMS，做视觉曲线拉伸）—— 每 ~33ms 推一帧
        if now - lastPush > 0.033 {
            lastPush = now
            let B = VoiceEngine.bands
            let seg = max(1, n / B)
            var out = [Float](repeating: 0, count: B)
            for b in 0..<B {
                let s = b * seg, e = min(n, s + seg)
                if s >= e { continue }
                var acc: Float = 0
                for i in s..<e { let v = p[i * st]; acc += v * v }
                let r = (acc / Float(e - s)).squareRoot()
                // 曲线：安静段压平，说话段拉开差距（够「大气」又不抖成噪声）
                out[b] = min(1, pow(min(1, r * 7.5), 0.62))
            }
            DispatchQueue.main.async { [weak self] in self?.onLevels?(out) }
        }

        // ② VAD：自适应噪声底 + 上/下沿滞回
        if !voiced {
            noiseFloor += (rms - noiseFloor) * 0.02        // 只在非发声时更新底噪
            if rms > threshold {
                voicedRun += 1
                if voicedRun >= 2 { voiced = true; silentRun = 0; pushEdge(true) }
            } else { voicedRun = 0 }
        } else {
            if rms < threshold * 0.72 {
                silentRun += 1
                if silentRun >= 12 { voiced = false; voicedRun = 0; pushEdge(false) }
            } else { silentRun = 0 }
        }

        // 主线程要靠「现在还有没有人声」决定要不要给死掉的识别请求续命，
        // 所以这里把最新一帧能量发布出去（Float 单次写入，不做锁）。
        lastRms = rms

        // ③ 打断检测：朗读中检测到明显高于门限的人声 → 交给主线程打断 TTS
        lock.lock(); let isFeeding = feeding; let fReq = feedReq; lock.unlock()
        if !isFeeding && rms > threshold * 2.2 && voiced {
            bargeRun += 1
            if bargeRun == 9 { DispatchQueue.main.async { [weak self] in self?.onBargeIn?() } }
        } else { bargeRun = 0 }

        // ④ 送识别：拷成单声道再喂。
        // 直接把 9 声道的 tap buffer 丢给 SFSpeechRecognizer 就是「No speech detected」的根因，
        // 所以这里必须过一道单声道拷贝。
        if isFeeding, let req = fReq, let mb = monoBuf, let dst = mb.floatChannelData?[0] {
            let m = min(n, Int(mb.frameCapacity))
            mb.frameLength = AVAudioFrameCount(m)
            if st == 1 {
                memcpy(dst, p, m * MemoryLayout<Float>.size)
            } else {
                for i in 0..<m { dst[i] = p[i * st] }
            }
            // 实测「真正送进识别器的那份数据」——若这里 rms≈0 而 tap 的 rms 有值，
            // 说明拷贝这一步是坏的；若两者一致，问题就在识别器那一侧，不在采集。
            if !feedFormatLogged {
                feedFormatLogged = true
                let f = mb.format
                let line = "送入识别格式: \(Int(f.sampleRate))Hz 声道=\(f.channelCount) 交错=\(f.isInterleaved ? "是" : "否") 首块=\(m)帧"
                DispatchQueue.main.async { [weak self] in self?.log(line) }
            }
            var s2 = 0.0
            var pk = feedPeak
            for i in 0..<m { let v = dst[i]; s2 += Double(v * v); let a = abs(v); if a > pk { pk = a } }
            feedSq += s2
            feedPeak = pk
            feedN += m
            feedBlocks += 1
            feedSamplesTotal += m                      // 哑火看门狗：喂给识别器的总量（永不清零）
            if s2 / Double(max(1, m)) > Double(threshold * 0.8) {  // 期间有人声的样本量（同上）
                voiceSamples += m
            }
            req.append(mb)
        } else if let pb = preRollBuf, let pd = pb.floatChannelData?[0] {
            // 常驻阶段（没在送识别）把这段音频留在环形缓冲里，给下一次请求当预卷。
            // feeding 时不写：那些音频本来就已经送进识别器了。
            let cap = Int(pb.frameCapacity)
            let k = min(n, cap)
            for i in 0..<k { pd[preRollPos] = p[i * st]; preRollPos = (preRollPos + 1) % cap }
            if preRollFilled < cap { preRollFilled = min(cap, preRollFilled + k) }
        }
    }

    /// 只在「上沿/下沿」这一瞬间跨线程，避免每帧都跳主线程
    private func pushEdge(_ up: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.running else { return }
            if up { self.onVoiceEdgeUp() } else { self.onVoiceEdgeDown() }
        }
    }

    private func setFeeding(_ v: Bool) {
        // feedReq 与 feeding 在同一把锁下发布：
        // 让音频线程拿到「已确定可写」的请求引用，避免它在实时线程上读主线程的
        // `request` 属性——那是跨线程的 ARC 引用，既可能读到 nil 也可能不安全。
        lock.lock()
        feeding = v
        feedReq = v ? request : nil
        lock.unlock()
    }

    // MARK: 识别请求生命周期（主线程）

    private func startRequest() {
        guard running, request == nil else { return }
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 识别通路：强制优先，其次看「自动学习」的结论，最后受「设备端到底可不可用」约束
        let wantNetwork: Bool
        switch forcePath {
        case "network": wantNetwork = true
        case "device":  wantNetwork = false
        default:        wantNetwork = usingNetwork
        }
        let onDevice = onDeviceOK && !wantNetwork
        req.requiresOnDeviceRecognition = onDevice
        req.taskHint = .dictation
        requestOnDevice = onDevice
        request = req
        requestStartedAt = CACurrentMediaTime()
        currentText = ""
        lastChangeAt = CACurrentMediaTime()
        lastResultAt = CACurrentMediaTime()    // 给新请求 8 秒观察期，别把启动慢当哑火
        fedAtStart = feedSamplesTotal
        voicedAtStart = voiceSamples
        setFeeding(true)
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
        log("识别请求开始（\(onDevice ? "设备端" : "网络")）")
        feedPreRoll()          // 把唤醒词开头的那一段补进去，别让识别器从半句开始听
        // 诊断窗口跟着每次识别请求重新起算，保证「人正在说话」那几秒一定被记到
        diagUntil = CACurrentMediaTime() + 20
        if diagNextLog == 0 { diagNextLog = CACurrentMediaTime() + 1 }
    }

    private func stopRequest() {
        setFeeding(false)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        lastReqEndAt = CACurrentMediaTime()
    }

    /// 把环形缓冲里最近的一段音频按时间顺序补喂给刚拉起的请求。
    ///
    /// 为什么必须有：唤醒词在句首（「小鲸鱼…」），而请求是能量上沿之后才起来的，
    /// 中间差着上沿检测那两百毫秒。少了预卷，识别器从「鲸鱼…」甚至「鱼…」开始听，
    /// 匹配函数再怎么做近音容错也无济于事 —— 这是「喊了很多次都唤不醒」的另一半原因。
    private func feedPreRoll() {
        // 只在常驻唤醒这条路上补：点按钮（manualStart）时 awake 已经是 true，
        // 而此刻的预卷是点击**之前**的 1.5 秒 —— 很可能是 AI 刚念完的回复，
        // 补进去只会污染这一句。
        guard !awake else { return }
        guard let req = request,
              let src = preRollBuf, let s = src.floatChannelData?[0],
              let dst = preFeedBuf, let d = dst.floatChannelData?[0] else { return }
        let cap = Int(src.frameCapacity)
        let n = min(preRollFilled, cap)
        guard n > 0 else { return }
        let start = (preRollPos - n + cap) % cap
        var written = 0
        while written < n {
            let chunk = min(n - written, Int(dst.frameCapacity))
            dst.frameLength = AVAudioFrameCount(chunk)
            for i in 0..<chunk { d[i] = s[(start + written + i) % cap] }
            req.append(dst)
            written += chunk
        }
        log("预卷补喂 \(n) 帧（唤醒词开头那一段）")
    }

    /// 常驻监听阶段给识别请求「续命」。
    ///
    /// 为什么必须有它：`onVoiceEdgeUp` 只在能量**上沿**拉起请求，而上沿一句话只有一次。
    /// 识别器却经常在音频刚起头、还没攒够内容时就回一次 1110「No speech detected」，
    /// 请求随之收掉 —— 此后用户还在说，voiced 一直是 true，再没有新的上沿，
    /// 这一整句后面的内容（包括唤醒词）就完全没有识别器在听。
    /// 实测表现正是「第一次能发出去，之后怎么喊都唤不醒，只能点按钮」。
    /// 判据只用「现在还有人声」，安静时绝不白拉，避免请求风暴。
    private func keepListeningAlive(_ now: Double) {
        guard running, ambientEnabled, !paused, !awake, request == nil else { return }
        guard now >= restartCooldownUntil else { return }
        guard lastRms > threshold * 0.8 else { return }      // 确实有人在说话才补拉
        guard now - lastReqEndAt > 0.25 else { return }      // 别在同一瞬间反复起停
        // 刚说完一句的尾音期不补拉：那一段是收尾噪声，拉起来必定又是「没听清」。
        guard now >= wakeCooldownUntil else { return }
        startRequest()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            let ns = error as NSError
            // 收摊那一瞬间补回来的错误是收尾噪声，不是真的失败。
            // 实测代价：说完一句正要发送，紧跟一个 1110 把设备端判成「坏了」，
            // 于是整条通路被切走 —— 明明这一句识别得很准。
            if CACurrentMediaTime() - lastReqEndAt < 1.0 { return }
            // 取消是正常收尾，不当错误报。
            // 301 = kLSRErrorDomain「Recognition request was canceled」，我们自己
            // finalizeUtterance → stopRequest → task.cancel() 就会产生它。漏掉它的后果很具体：
            // 每一句**成功**说完之后，HUD 都会闪一次「没听清」，看起来像又失败了。
            let isCancel = ns.code == 203 || ns.code == 216 ||
                           (ns.domain == "kLSRErrorDomain" && ns.code == 301)
            if !isCancel {
                // 识别层的失败大多是「这一次没听清」，是可恢复的：
                // 走 notice 而不是 error，否则 HUD 会永久显示「语音不可用」把真相藏起来。
                log("识别出错[\(ns.domain) \(ns.code)]: \(ns.localizedDescription)")
                onNotice?("没听清（\(ns.localizedDescription)）")
                noteFailure(ns)
            }
            // 出错后必须回到「还能再听」的状态。
            // 否则一旦 awake 卡在 true，onVoiceEdgeUp 里 `!awake` 这个条件永远不成立，
            // 引擎就彻底聋了 —— 表面看是「说完没反应」，实际是自己把自己锁死了。
            if awake && !currentText.isEmpty { finalizeUtterance(); return }
            if awake { awake = false; currentText = ""; log("这轮没听到内容，回到监听") }
            let quick = CACurrentMediaTime() - requestStartedAt < 1.0
            stopRequest()
            // 常驻阶段这一轮被错误收掉后必须立刻补回来：上沿只有一次，
            // 不补就等于这句剩下的话没人听，唤醒词也就永远等不到。
            if !awake {
                if quick {
                    quickFails += 1
                    if quickFails >= 3 {
                        quickFails = 0
                        restartCooldownUntil = CACurrentMediaTime() + 1.5
                        log("识别请求连续「起来就失败」，冷却 1.5 秒（防请求风暴）")
                    }
                } else {
                    quickFails = 0      // 撑够 1 秒才失败的，属于正常收尾，不算连发
                }
                keepListeningAlive(CACurrentMediaTime())
            }
            return
        }
        guard let r = result else { return }
        lastResultAt = CACurrentMediaTime()    // 有回调 = 识别器这条命还活着（哪怕内容为空）
        let text = r.bestTranscription.formattedString
        if !text.isEmpty {
            noSpeechStreak = 0; warnedBothPaths = false; quickFails = 0   // 真听到内容了，失败计数清零
            if text != currentText { stallStreak = 0 }   // 真出字了，哑火计数清零
        }

        if !awake {
            if CACurrentMediaTime() < wakeCooldownUntil {
                // 冷却期内不出唤醒：否则刚说完那句的尾音会被当成新一句的开头
                return
            }
            if let (hit, rest) = VoiceEngine.matchWake(text, words: wakeWords) {
                awake = true
                pendingSeed = rest
                currentText = rest
                onWake?(hit)
                log("唤醒命中「\(hit)」，后续=「\(rest)」")
            } else {
                // 常驻监听阶段听到的都不是唤醒词，给 UI 一个「听见了」的反馈
                log("常驻听到: 「\(text)」")
                onPartial?(text, false)
            }
        } else if !text.isEmpty && text != currentText {
            // 空串的「修订」必须忽略。
            // 实测：网络识别偶尔会在句中回一次 formattedString==""，照单全收就会把
            // 已经认到的内容整个冲掉 —— 结果这一句永远凑不满、也就永远发不出去
            // （日志表现为一行「在听: 「」」之后就没动静了）。
            currentText = text
            lastChangeAt = CACurrentMediaTime()
            let said = VoiceEngine.stripWake(text, words: wakeWords) ?? text
            log("在听: 「\(said)」")
            onPartial?(said, false)
        }
        if r.isFinal && awake { finalizeUtterance() }
    }

    /// 能量上沿：常驻监听模式下，这可能是唤醒词的开始 → 拉起识别
    private func onVoiceEdgeUp() {
        guard !paused else { return }
        lastEdgeUpAt = CACurrentMediaTime()
        if ambientEnabled && request == nil && !awake { startRequest() }
    }

    /// 能量下沿：扫描完一段没有唤醒词 → 收掉请求，回到纯电平监听（省电）
    private func onVoiceEdgeDown() {
        guard !awake else { return }
        idleStopAt = CACurrentMediaTime()
    }

    /// 主线程定时器：判停（停顿 N 毫秒算说完）+ 无唤醒词时收摊
    func tick() {
        guard running else { return }
        let now = CACurrentMediaTime()
        flushPendingGuard()      // 推迟的守护关闭：捕捉一结束就补上（见 setEchoGuard 注释）

        // 「AI 在发声」的暂停由 JS 解除，可 JS 那一侧有可能不来（朗读被打断、音色被卸载、
        // 页面切走）。漏一次，原生就永远停在 paused，能量上沿被成批丢弃 ——
        // 症状正是「第一次能发，之后怎么都不识别」。给一条很长的兜底：宁可偶尔多听一句。
        if paused && pausedAt > 0 && now - pausedAt > 120 {
            paused = false
            pausedAt = 0
            log("暂停超过 120 秒没收到解除，自动恢复聆听")
        }

        // 声道诊断：每秒打一次各声道能量，用来判定这台机器的多声道里哪一路是主麦
        if diagNextLog > 0 && now >= diagNextLog {
            diagNextLog = now + 1
            if now < diagUntil {
                if diagFrames > 0 {
                    let f = Double(diagFrames)
                    var parts: [String] = []
                    for (i, s) in diagAcc.enumerated() {
                        parts.append("ch\(i)=\(String(format: "%.4f", (s / f).squareRoot()))")
                    }
                    log("声道能量(1秒平均): \(parts.joined(separator: " "))")
                    for i in 0..<diagAcc.count { diagAcc[i] = 0 }
                    diagFrames = 0
                }
                if feedBlocks > 0 {
                    log(String(format: "送入识别: rms=%.4f 峰值=%.4f 块=%d 样本=%d",
                               (feedSq / Double(max(1, feedN))).squareRoot(), feedPeak, feedBlocks, feedN))
                }
                feedSq = 0; feedN = 0; feedBlocks = 0; feedPeak = 0
            } else {
                log("声道诊断窗口结束")
                diagNextLog = 0
            }
        }

        if awake {
            let silentFor = (now - lastChangeAt) * 1000
            let hasText = !currentText.isEmpty
            // 只在「确实有内容」时推读秒：空跑一轮时界面不该出现倒计时。
            // 两个用途 —— ① 让用户看得见「它在数秒」（这一秒多的黑箱正是「说完没反应」的来源）
            //              ② 数满即发，界面与真正的判停同源，不会各说各话。
            if hasText {
                let p = min(1, silentFor / max(200, pauseMs))
                if abs(p - lastPausePush) >= 0.04 {     // 变化够大才跨线程
                    lastPausePush = p
                    onPause?(p, true)
                }
            } else {
                resetPausePush()
            }
            if silentFor > pauseMs && hasText { finalizeUtterance() }
        } else {
            resetPausePush()
            if request != nil && idleStopAt > 0 && (now - idleStopAt) > 0.9 {
                stopRequest(); idleStopAt = 0
            }
            // 人还在说、请求却已经被识别器的「No speech」提前收掉 → 补拉一次。
            // 少了这一句，常驻监听在第一次上沿之后就再也叫不醒（详见 keepListeningAlive 注释）。
            keepListeningAlive(now)
        }
        // ── 哑火看门狗 ──
        // 识别器静默失效（喂了音频、有人声、零结果零错误）时，错误路径的自救全都
        // 覆盖不到 —— 只能自己计时发现。三个条件同时成立才算哑火：
        //   ① 请求已跑 8 秒以上（排除启动慢）；
        //   ② 这期间累计喂了 8 秒以上的音频；
        //   ③ 其中至少 1.5 秒是超过门限的人声（排除「安静房间里请求空转」的误判）；
        //   ④ 距上次任何回调进展已超 8 秒（出字/空回调都算进展）。
        if request != nil, !paused,
           (now - requestStartedAt) > 8,
           Double(feedSamplesTotal - fedAtStart) / 48000 > 8,
           Double(voiceSamples - voicedAtStart) / 48000 > 1.5,
           now - max(lastResultAt, lastChangeAt) > 8 {
            stallStreak += 1
            let fed = Double(feedSamplesTotal - fedAtStart) / 48000
            let voiced = Double(voiceSamples - voicedAtStart) / 48000
            log(String(format: "识别器哑火（喂了 %.1f 秒音频、其中 %.1f 秒人声，却没回一个字）→ 重开识别", fed, voiced))
            if stallStreak >= 2 && requestOnDevice && forcePath == "auto" {
                usingNetwork = true
                UserDefaults.standard.set(true, forKey: "ftVoiceUseNetwork")
                log("设备端识别连续哑火 → 这轮起改用网络识别（这条路的音频会离开本机；已记住，可在设置里改回）")
                onModeChange?()
            }
            let keep = awake
            stopRequest()
            if keep { startRequest() } else { keepListeningAlive(now) }
            return
        }

        // 识别请求有约 1 分钟上限：只在超过 45 秒时重开，避免长句被截断
        if request != nil && (now - requestStartedAt) > 45 {
            log("识别请求接近上限，重开")
            let keep = awake
            stopRequest()
            if keep { startRequest() }
        }
    }

    /// 判停进度跨线程推送的重置：只在真的推过非零进度时才发一次收尾信号
    private func resetPausePush() {
        guard lastPausePush != 0 else { return }
        lastPausePush = 0
        onPause?(0, false)
    }

    private func finalizeUtterance() {
        let said = VoiceEngine.stripWake(currentText, words: wakeWords) ?? currentText
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        awake = false
        currentText = ""
        pendingSeed = ""
        resetPausePush()
        wakeCooldownUntil = CACurrentMediaTime() + 1.6     // 尾音冷却
        stopRequest()
        idleStopAt = 0
        if text.isEmpty { onPartial?("", true); return }
        log("一句说完：\(text)")
        onFinal?(text)
    }

    /// 外部（JS）主动触发一次手动录音：绕过唤醒词，直接进入捕捉态
    func manualStart() {
        guard running else { return }
        awake = true
        currentText = ""
        lastChangeAt = CACurrentMediaTime()
        if request == nil { startRequest() }
        log("手动进入捕捉态")
    }

    func manualStop() { if awake { finalizeUtterance() } }

    /// JS 通知「正在思考/朗读」→ 整段停下来（但仍保留打断检测）。
    ///
    /// 为什么连识别请求一起收掉，而不是只停送音频：扬声器在念回复时拾音会听到自己，
    /// 能量门控就被不断触发、拉起一串新的识别请求，每个都在几秒后回「No speech detected」。
    /// 那串错误会把 HUD 永久钉在「语音不可用」，看起来就是「说完没反应」。
    /// 真正的中断由打断检测负责，不靠识别。
    func setBusy(_ busy: Bool) {
        paused = busy
        if busy {
            pausedAt = CACurrentMediaTime()
            setFeeding(false)
            if request != nil {
                let had = awake
                awake = false
                currentText = ""
                stopRequest()
                if had { log("AI 在思考/朗读，暂停聆听") }
            }
        } else {
            pausedAt = 0
            if awake { setFeeding(true) }
        }
    }

    private func report(_ msg: String) {
        log("错误: \(msg)")
        onError?(msg)
    }

    /// 「没听到人声」在**确实喂了人声**的情况下反复出现，说明这条识别通路没吃进音频
    /// （或设备端模型不可用）。连续几次就退到网络识别自救，否则用户看到的就是
    /// 「说完没反应 + 提示语音不可用」——功能整体哑掉，而权限、引擎、电平全是好的。
    private func noteFailure(_ ns: NSError) {
        guard ns.localizedDescription.lowercased().contains("speech") else { return }
        // 只认「真的喂了够长一段音频」的失败。环境噪声触发的短请求会被这条挡掉，
        // 否则咳两声就可能把识别悄悄切到网络。
        guard CACurrentMediaTime() - requestStartedAt >= 3.0 else { return }
        noSpeechStreak += 1
        guard forcePath == "auto" else { return }
        if requestOnDevice {
            // 设备端没吃进音频 → 换网络。这条路会把音频送出本机，日志里说清楚。
            devicePathFailed = true
            usingNetwork = true
            UserDefaults.standard.set(true, forKey: "ftVoiceUseNetwork")
            log("设备端识别没吃到人声 → 改用网络识别（音频会离开本机）")
            onModeChange?()
        } else {
            // 网络这条路的失败很常见（服务端波动／限流），而且它本来就不该是首选。
            // 实测（2026-09-19 文件自检）：同一段音频网络报 No speech、设备端准确识别。
            networkPathFailed = true
            usingNetwork = false
            UserDefaults.standard.set(false, forKey: "ftVoiceUseNetwork")
            log("网络识别没吃到人声 → 退回设备端识别（音频不出本机）")
            onModeChange?()
        }
        noSpeechStreak = 0
        if !warnedBothPaths && bothPathsFailed {
            warnedBothPaths = true
            log("⚠️ 设备端与网络都报过「没听到人声」：问题多半不在识别通路，而在送进去的音频本身（声道/格式/电平）")
        }
    }

    // MARK: 唤醒词匹配工具

    /// 只保留中日韩文字与字母数字，其余（空格/标点）全部丢掉 ——
    /// 识别结果里的标点和空格会让「小鲸鱼」变成「小鲸鱼，」而匹配不上。
    private static func compact(_ s: String) -> (String, [String.Index]) {
        var out = ""
        var map: [String.Index] = []
        for idx in s.indices {
            let c = s[idx]
            if c.isLetter || c.isNumber {
                out.append(c); map.append(idx)
            }
        }
        return (out, map)
    }

    /// 返回 (命中的唤醒词, 唤醒词之后剩下的内容)
    static func matchWake(_ text: String, words: [String]) -> (String, String)? {
        if let r = matchLiteral(text, words: words) { return r }
        // 字面认不出，再比读音。自定义昵称（「阿福」「小七」这类）在字面上几乎必然
        // 被识别器写成别的字，只比字面就是「自由设昵称」做不出来的根本原因。
        return matchByPinyin(text, words: words)
    }

    // MARK: 拼音层 —— 自由昵称能不能唤得醒，全看这一层

    /// 单字 → 无声调小写拼音。非汉字（标点/数字）返回空，匹配时直接跳过。
    private static func pinyinChar(_ ch: Character) -> String {
        let s = String(ch)
        if let latin = s.applyingTransform(.mandarinToLatin, reverse: false), !latin.isEmpty {
            let flat = latin.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                     locale: Locale(identifier: "en"))
            let letters = flat.filter { $0.isLetter }
            if !letters.isEmpty { return letters.lowercased() }
        }
        return ""
    }

    /// 整串 → (拼音串, 拼音串每个字母对应的原字序号)。
    /// 映射表是命中之后「唤醒词后面还剩多少」的唯一依据 —— 少了它就没法剥词。
    static func pinyinMap(_ text: String) -> (String, [Int]) {
        var out = ""
        var map: [Int] = []
        var i = 0
        for ch in text {
            let p = pinyinChar(ch)
            for _ in p { map.append(i) }
            out += p
            i += 1
        }
        return (out, map)
    }

    /// 拼音通路的匹配：先精确子串，再按拼音长度给编辑距离容差。
    ///
    /// 为什么有效：识别器对没见过的人名/昵称，错的是**字**，读音通常还在
    /// （「小鲸鱼」→「小金鱼」：xiaojingyu / xiaojinyu 只差一个字母）。
    /// 拼音串上放 1~3 的距离容差，命中率比字面高一个量级。
    static func matchByPinyin(_ text: String, words: [String]) -> (String, String)? {
        let chars = Array(text)
        let (tp, map) = pinyinMap(text)
        guard tp.count >= 2 else { return nil }
        let tpArr = Array(tp)
        for w in words {
            let wp = Array(pinyinMap(w).0)
            guard wp.count >= 2 else { continue }
            // ① 读音对、字不对：拼音串上直接搜得到
            if let r = tp.range(of: String(wp)) {
                let endP = tp.distance(from: tp.startIndex, to: r.upperBound)
                return (w, restAfterPinyin(chars, map: map, endP: endP))
            }
            // ② 读音也差一点：滑窗 + 编辑距离。容差随词长放宽（短词必须严，否则满街误唤醒）
            let maxDist = wp.count <= 3 ? 1 : (wp.count <= 6 ? 2 : 3)
            var bestD = Int.max, bestEnd = -1
            let lo = max(1, wp.count - maxDist), hi = min(tpArr.count, wp.count + maxDist)
            guard lo <= hi else { continue }
            for len in lo...hi {
                for i in 0...(tpArr.count - len) {
                    // 首字母必须相同（「小七」xiaoqi 不该被「天气」tianqi 唤醒）
                    if tpArr[i] != wp[0] { continue }
                    let d = editDistance(Array(tpArr[i..<(i + len)]), wp)
                    if d < bestD { bestD = d; bestEnd = i + len }
                }
            }
            if bestD <= maxDist && bestEnd > 0 {
                return (w, restAfterPinyin(chars, map: map, endP: bestEnd))
            }
        }
        return nil
    }

    private static func restAfterPinyin(_ chars: [Character], map: [Int], endP: Int) -> String {
        let cut = endP < map.count ? map[endP] : chars.count
        let rest = String(chars[cut...])
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.、!！?？~～"))
    }

    private static func matchLiteral(_ text: String, words: [String]) -> (String, String)? {
        let (c, map) = compact(text)
        guard !c.isEmpty else { return nil }
        let chars = Array(c)
        for w in words {
            let wc = compact(w).0
            if wc.isEmpty { continue }
            // ① 精确命中：最快路径，也是短词（2 字）唯一走的路
            if let r = c.range(of: wc) {
                let endOffset = c.distance(from: c.startIndex, to: r.upperBound)
                return (w, restAfter(text, map: map, endOffset: endOffset))
            }
            // ② 近音容错：识别器稳定把「小鲸鱼」听成「小金鱼」，只认正字就永远唤不醒。
            //    做法是在文本上滑一个与唤醒词等长的窗口，编辑距离 ≤1 即算命中。
            //    只对 3 字及以上的词开——2 字词容错会误唤醒一大片（「小鱼」≈「多余」）。
            let n = wc.count
            guard n >= 3, chars.count >= n else { continue }
            let wArr = Array(wc)
            for i in 0...(chars.count - n) {
                // 首字必须相同（唤醒词都以「小/嗨」开头）：只放宽后面的近音字，
                // 否则「多余」「可以」这类两字差一的片段也会被当成唤醒。
                guard chars[i] == wArr[0] else { continue }
                if editDistance(Array(chars[i..<(i + n)]), wArr) <= 1 {
                    // 命中信息由调用方（handle）统一打日志，这里保持纯函数
                    return (w, restAfter(text, map: map, endOffset: i + n))
                }
            }
        }
        return nil
    }

    private static func restAfter(_ text: String, map: [String.Index], endOffset: Int) -> String {
        let cut = endOffset < map.count ? map[endOffset] : text.endIndex
        let rest = String(text[cut...])
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.、!！?？~～"))
    }

    /// 两个等长（或接近等长）字符序列的编辑距离，只用来做 1 个字的近音容错
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        let (m, n) = (a.count, b.count)
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var cur = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            cur[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[n]
    }

    static func stripWake(_ text: String, words: [String]) -> String? {
        matchWake(text, words: words)?.1
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 15        // 最多重试 15 次
    private let retryInterval = 4.0    // 每 4 秒一次，总共约 60 秒
    private var launchBalance: Double? // 启动时的余额基线（推算本次消费）
    private var balanceTimer: Timer?
    private let url = URL(string: "http://127.0.0.1:3080")!
    private var skins: [String] = []   // 三套皮肤 CSS（0=暗金, 1=翡翠晨光, 2=猩红熔岩）
    private var themeIndex = 0
    private let skinNames = ["暗金·深夜", "翡翠·晨光", "猩红·熔岩"]
    private var skinMenuItems: [NSMenuItem] = []
    private var shortcutMonitor: Any? // ⌥⌘1/2/3 快捷键监听（绕过 WKWebView 抢键）
    private var browserWindows: [NSWindow] = [] // 内置浏览器窗口（保持引用防释放）
    private var repaintWorkItem: DispatchWorkItem? // 强制重绘防抖
    private let voice = VoiceEngine()              // 语音引擎（原生 STT + 电平）
    private var voiceTick: Timer?                  // 判停轮询（200ms）
    private var voiceOn = false                    // 语音总开关状态（JS 是真相源，这里做镜像）
    private var voiceMenuItem: NSMenuItem?         // 菜单里的「语音输入」勾选态

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 加载两套皮肤并读取上次选择
        skins = [
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-emerald-light", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-scarlet", ofType: "css") ?? "", encoding: .utf8)) ?? "",
        ]
        themeIndex = UserDefaults.standard.integer(forKey: "ftThemeIndex")
        if themeIndex >= skins.count { themeIndex = 0 }
        buildMenu()
        installShortcuts()

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "发条屋"
        window.center()
        window.setFrameAutosaveName("发条屋窗口") // 记住窗口大小和位置
        // 顶部标题栏：透明 + 外观跟随皮肤（暗金=深，翡翠晨光=深绿玻璃渐变）
        window.titlebarAppearsTransparent = true
        let isDarkLaunch = themeIndex != 1
        window.appearance = NSAppearance(named: isDarkLaunch ? .darkAqua : .aqua)
        switch themeIndex {
        case 1:
            window.backgroundColor = AppDelegate.titlebarGlassGradient()
        case 2:
            window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.03, blue: 0.03, alpha: 1) // 猩红熔岩深红黑
        default:
            window.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.114, alpha: 1)
        }

        let config = WKWebViewConfiguration()
        // 生灵层要用 Web Audio 程序化合成机械音效：放开自动播放限制（否则 AudioContext 永远 suspended）
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "fatiaowuSetSkin")
        config.userContentController.add(self, name: "fatiaowuLog")
        config.userContentController.add(self, name: "fatiaowuVoice")
        if let skin = AppDelegate.skinUserScript(css: skins[themeIndex], initialDark: themeIndex == 0) {
            config.userContentController.addUserScript(skin)
        }
        // 生灵层：发条机芯 + 小鲸鱼桌宠（独立脚本，见 resources/alive.js）
        if let alive = AppDelegate.aliveUserScript() {
            config.userContentController.addUserScript(alive)
        }
        // 语音层：波形 HUD + 交互（独立脚本，见 resources/voice.js）。
        // 识别与电平来自原生 VoiceEngine，这里只负责「看起来」和「送进 harness」。
        if let vjs = AppDelegate.namedUserScript("voice") {
            config.userContentController.addUserScript(vjs)
        }
        // 临时诊断探针（flag 驱动）：只有存在 /tmp/ft-voice-probe.flag 时才注入 resources/probe.js。
        // 为什么必须在这里测而不能在 Chrome 里测：Web Speech API / getUserMedia 的可用性
        // 取决于**内核与宿主权限模型**，WKWebView 与 Chrome 完全不同，Chrome 的结论对线上无效。
        if FileManager.default.fileExists(atPath: "/tmp/ft-voice-probe.flag"),
           let probe = AppDelegate.namedUserScript("probe") {
            config.userContentController.addUserScript(probe)
        }
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // ── 主窗口双页结构：dsh 主页 ⇄ DeepSeek 网页版聊天（免费） ──
        // 两个页面叠在同一容器里切 hidden，主页面 UI 原样保留；切换钮悬浮在
        // 标题栏区域（titlebar 透明），不挡页面内容。
        let container = NSView(frame: rect)
        container.wantsLayer = true
        window.contentView = container
        container.addSubview(webView)

        // 聊天页与主页穿同一套皮肤：当前皮肤 CSS 在 documentStart 烤进注入脚本（chatSkinUserScript），
        // 换肤时 refreshChatSkin() 重建，保证聊天页永远与主页同装。
        chatWebView = makeChatWebView(in: container)
        chatWebView?.isHidden = true          // 惰性加载：第一次切过去才真正 load

        for v in [webView, chatWebView].compactMap({ $0 }) {
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        // 切换胶囊钮：悬浮在内容区**顶部正中**。右上角会压住页面自己的控件（两页都是），
        // 标题栏 accessory 又太小 —— 顶中在聊天页/主页的头部都是空档，大小也能放开做。
        chatToggleBtn = NSButton(title: "", target: self, action: #selector(toggleChatMode(_:)))
        chatToggleBtn?.isBordered = false
        chatToggleBtn?.wantsLayer = true
        if let l = chatToggleBtn?.layer {
            l.cornerRadius = 15
            l.borderWidth = 1
            l.shadowOpacity = 0.35
            l.shadowColor = NSColor.black.cgColor
            l.shadowRadius = 7
            l.shadowOffset = NSSize(width: 0, height: 2)
            l.masksToBounds = false     // 阴影不被圆角裁掉
        }
        if let btn = chatToggleBtn {
            container.addSubview(btn, positioned: .above, relativeTo: nil)
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                btn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
                btn.heightAnchor.constraint(equalToConstant: 30),
            ])
        }
        styleChatToggle()

        // “正在连接服务”提示
        statusLabel = NSTextField(labelWithString: "正在连接发条屋服务…")
        statusLabel.font = .systemFont(ofSize: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(statusLabel)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 先自签 dsh web 鉴权 cookie（secret 持久化在 credentials 里，跨服务重启有效），
        // 写入 WKWebView 后再加载页面，避免服务重启后撞上「authentication required」门页
        seedAuthThenLoad()
        setupVoice()

        // 唤醒链路自检：常驻态播放一段含唤醒词的音频，看它能不能自己被叫醒。
        // （回环自检是 awake=true 直接进捕捉态，测不到唤醒词这一环。）
        // 放音期间临时关掉自动发送，免得为了一次诊断真的把消息发出去。
        if FileManager.default.fileExists(atPath: "/tmp/ft-voice-aec.flag") {
            voice.aecSelfTest("/tmp/ft-voice-aec.m4a")
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-voice-wake.flag") {
            webView?.evaluateJavaScript("window.__ftVoiceDebug&&window.__ftVoiceDebug.setPrefsVolatile({autoSend:false})")
            voice.wakeSelfTest("/tmp/ft-voice-wake.m4a")
        }
        // 语音自检（flag 驱动）：拿一个音频文件直接跑 SFSpeech，两条通路各一次。
        // 用途：把「识别器本身不可用」与「实时送流送错了」这两件事一刀切开。
        if FileManager.default.fileExists(atPath: "/tmp/ft-voice-selftest.flag") {
            voice.selfTestFile("/tmp/ft-voice-selftest.m4a")
        }
        // 回环自检：扬声器 → 麦克风 → 识别，全自动跑一遍实时链路（会放出 4 秒声音）
        if FileManager.default.fileExists(atPath: "/tmp/ft-voice-loopback.flag") {
            // 先看输入框里有什么：非空会触发「草稿保护」而只插入不发送，测不到发送这一段。
            // prepareLoopback 只会在「内容恰好全是上一轮遗留的测试句」时清空，别的一律不动。
            // 这里必须重试：applicationDidFinishLaunching 时页面还没加载，window.__ftVoiceDebug 还不存在。
            var tries = 0
            func tryPrepare() {
                tries += 1
                webView?.evaluateJavaScript("(window.__ftVoiceDebug?window.__ftVoiceDebug.prepareLoopback():null)") { v, _ in
                    let s = (v as? String) ?? ""
                    if s.isEmpty && tries < 24 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryPrepare() }
                    } else {
                        AppDelegate.log("回环自检: 输入框准备 = \(s.isEmpty ? "（接口一直没就绪）" : s)")
                        // 接口就绪了，顺手把朗读临时静音（只改内存、不落偏好），
                        // 免得深夜为了一次诊断放出一长段朗读
                        self.webView?.evaluateJavaScript("window.__ftVoiceDebug.setPrefsVolatile({speak:false})")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tryPrepare() }
            voice.loopbackSelfTest("/tmp/ft-voice-selftest.m4a")
        }

        // WKWebView 全屏切换/窗口尺寸变化后偶发陈旧渲染：强制重绘
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didResizeNotification, object: window)


    }

    // ---------- dsh web 鉴权自签 ----------

    // base64url（无填充），与 dsh 服务端 encodeBase64Url 一致
    private static func b64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    // 从 ~/.dsh/.credentials.yaml 读取 client-connection/browser-session 的持久化 secret
    private static func browserAuthSecret() -> Data? {
        guard let content = try? String(contentsOfFile: "/Users/yangliu/.dsh/.credentials.yaml", encoding: .utf8) else {
            return nil
        }
        var secretB64: String?
        var inBlock = false
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("client-connection/browser-session:") { inBlock = true; continue }
            if inBlock {
                if t.hasPrefix("secret:") {
                    secretB64 = t.dropFirst("secret:".count).trimmingCharacters(in: .whitespaces)
                    break
                }
                // 进入下一个顶层记录则中止
                if !t.hasPrefix("#"), !t.isEmpty, t.contains(":"), !t.hasPrefix("kind:"), !t.hasPrefix("payload:"), !t.hasPrefix("version:") {
                    break
                }
            }
        }
        guard var b64 = secretB64 else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let secret = Data(base64Encoded: b64), secret.count == 32 else { return nil }
        return secret
    }

    // 复刻 dsh-client-connection 的 cookie 算法：
    // name = "dsh-auth-" + b64url(sha256(authority))
    // value = "v1." + b64url(JSON) + "." + b64url(hmac-sha256(secret, body))
    private static func browserAuthCookie() -> HTTPCookie? {
        guard let secret = browserAuthSecret() else { return nil }
        let authority = "127.0.0.1:3080"
        let name = "dsh-auth-" + b64url(Data(SHA256.hash(data: Data(authority.utf8))))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let expires = now + 30 * 24 * 3600 * 1000 // 30 天，与服务端 maxAgeDays 一致
        let payload = "{\"version\":1,\"authority\":\"\(authority)\",\"issuedAt\":\(now),\"expiresAt\":\(expires)}"
        let body = b64url(Data(payload.utf8))
        let sig = b64url(Data(HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))))
        let value = "v1.\(body).\(sig)"
        return HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "127.0.0.1",
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600),
        ])
    }

    private func seedAuthThenLoad() {
        if let cookie = AppDelegate.browserAuthCookie() {
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
                guard let self = self else { return }
                AppDelegate.log("自签鉴权 cookie 已写入，加载页面")
                self.loadURL()
                self.startBalanceMonitor()
            }
        } else {
            AppDelegate.log("警告：自签鉴权 cookie 失败（secret 缺失或格式不符），直接加载页面")
            loadURL()
            startBalanceMonitor()
        }
    }

    // ---------- 余额/消费监控 ----------

    private func startBalanceMonitor() {
        fetchBalance()
        balanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchBalance() }
        }
    }

    private func fetchBalance() {
        guard let key = AppDelegate.deepseekApiKey() else {
            setStatus("余额不可用")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            // 后台线程只做解析
            var total: Double?
            var symbol = "¥"
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let infos = json["balance_infos"] as? [[String: Any]],
               let info = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos.first,
               let totalStr = info["total_balance"] as? String,
               let parsed = Double(totalStr) {
                total = parsed
                symbol = (info["currency"] as? String) == "CNY" ? "¥" : "$"
            }
            // 跳回主线程更新 UI
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let t = total else {
                    self.setStatus("余额获取失败")
                    return
                }
                if self.launchBalance == nil { self.launchBalance = t }
                let consumed = max(0, (self.launchBalance ?? t) - t)
                let text = String(format: "余额 %@%.2f · 本次已消费 %@%.2f", symbol, t, symbol, consumed)
                self.setStatus(text)
                AppDelegate.log("余额: \(text)")
            }
        }.resume()
    }

    private func setStatus(_ text: String) {
        webView?.evaluateJavaScript("window.__fatiaowuSetStatus && window.__fatiaowuSetStatus(\(AppDelegate.jsStringLiteral(text)))") { _, _ in }
    }

    // 应用指定皮肤（菜单选择），记忆选择
    private func applySkin(_ index: Int) {
        guard index >= 0 && index < skins.count, !skins[index].isEmpty else { return }
        themeIndex = index
        UserDefaults.standard.set(themeIndex, forKey: "ftThemeIndex")
        let isDark = themeIndex != 1
        // 窗口外观跟随皮肤
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        switch themeIndex {
        case 1:
            window?.backgroundColor = AppDelegate.titlebarGlassGradient()
        case 2:
            window?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.03, blue: 0.03, alpha: 1)
        default:
            window?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.114, alpha: 1)
        }
        // 菜单勾选状态
        for (i, item) in skinMenuItems.enumerated() {
            item.state = (i == themeIndex) ? .on : .off
        }
        let css = skins[themeIndex]
        webView?.evaluateJavaScript("window.__ftSetSkin && window.__ftSetSkin(\(AppDelegate.jsStringLiteral(css)), \(isDark ? "true" : "false"))") { _, _ in }
        webView?.evaluateJavaScript("window.__ftMarkSkin && window.__ftMarkSkin(\(themeIndex))") { _, _ in }
        // 聊天页同步换肤（重建聊天 WebView，已加载则自动重载拿新皮肤）
        refreshChatSkin()
        // 语音 HUD 外壳的深浅也跟着换（两页都推）
        pushVoiceTheme(to: webView)
        pushVoiceTheme(to: chatWebView)
        // 切换胶囊钮的底色描边跟着皮肤深浅换装
        styleChatToggle()
        AppDelegate.log("已切换皮肤: \(skinNames[themeIndex])")
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        applySkin(sender.tag)
    }

    // 语音菜单项 → 交给 voice.js 的状态机（这里不自己维护开关，避免两处状态不一致）
    @objc private func toggleVoiceMenu(_ sender: NSMenuItem) {
        activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.toggle()") { _, _ in }
    }

    @objc private func listenOnce(_ sender: NSMenuItem) {
        activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.listenOnce()") { _, _ in }
    }

    // ── 聊天模式 ──
    // 主窗口内切换：dsh 主页 ⇄ DeepSeek 官方网页版（chat.deepseek.com，网页聊天免费、
    // 不走 dsh 的 API 余额）。登录态在持久 dataStore 里，登录一次长期有效。
    private var chatWebView: WKWebView?
    private var chatToggleBtn: NSButton?
    /// 语音引擎当前归属哪一页（dsh/chat）。两页共用一个 VoiceEngine，事件只推给活动页，
    /// 活动页之外的语音命令一律拦下 —— 否则隐藏页的定时器/收尾命令会搅局。
    private var voicePage = "dsh"
    private func activeVoiceWebView() -> WKWebView? { voicePage == "chat" ? chatWebView : webView }

    // 创建聊天页 WebView：皮肤在 documentStart 烤进注入脚本，与主页同一套 CSS。
    private func makeChatWebView(in container: NSView) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // 复用日志通道：聊天皮肤脚本把注入结果报回应用日志
        cfg.userContentController.add(self, name: "fatiaowuLog")
        // 语音命令通道：聊天页的 voice.js 与主页同款（脚本按 hostname 自适应成 chat 模式）
        cfg.userContentController.add(self, name: "fatiaowuVoice")
        if let skin = AppDelegate.chatSkinUserScript(css: skins[themeIndex], isDark: themeIndex != 1) {
            cfg.userContentController.addUserScript(skin)
        }
        // 语音层同款注入。识别/电平/唤醒全在原生引擎里，与页面无关；voice.js 只管
        // 「看起来」与「送进当前页」。两页共用一个引擎，归属权由 toggleChatMode 交接。
        if let vjs = AppDelegate.namedUserScript("voice") {
            cfg.userContentController.addUserScript(vjs)
        }
        let wv = WKWebView(frame: container.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.appearance = NSAppearance(named: themeIndex == 1 ? .aqua : .darkAqua)   // 控件/表单跟皮肤深浅走
        container.addSubview(wv)
        return wv
    }

    /// 换肤时同步聊天页：用户脚本无法中途替换，按新皮肤整体重建。
    private func refreshChatSkin() {
        guard let container = webView?.superview, let old = chatWebView else { return }
        let wasVisible = !old.isHidden
        let hadUrl = old.url != nil
        old.navigationDelegate = nil
        old.removeFromSuperview()
        chatWebView = makeChatWebView(in: container)
        chatWebView?.isHidden = !wasVisible
        if hadUrl {
            AppDelegate.log("聊天皮肤: 重建聊天页（\(skinNames[themeIndex])）")
            chatWebView?.load(URLRequest(url: URL(string: "https://chat.deepseek.com")!))
        }
    }

    @objc private func toggleChatMode(_ sender: Any?) {
        let toChat = chatWebView?.isHidden ?? true   // 主页 → 聊天；聊天 → 主页
        chatWebView?.isHidden = !toChat
        webView.isHidden = toChat
        chatWebView?.allowsBackForwardNavigationGestures = true
        chatToggleBtn?.toolTip = toChat ? "回到发条屋主页" : "聊天模式 · 免费"
        styleChatToggle()
        // ── 语音随页交接 ──
        // 引擎只有一个，归属权交给到达页：离开页 suspend（停朗读/清守护/停引擎，
        // 用独立命令而不推状态，否则到达页会把 running=false 读成「引擎掉了」）；
        // 到达页 resume（自己 prefs.on 才接上，direct=false 不抢进捕捉态）。
        // 首次加载时 voice.js 还没注入完（documentEnd），这里的 resume 会扑空 ——
        // didFinish 里会补一次。
        voicePage = toChat ? "chat" : "dsh"
        let leaving = toChat ? webView : chatWebView
        leaving?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.suspend()") { _, _ in }
        voice.stop()
        voiceOn = false
        let arriving = toChat ? chatWebView : webView
        pushVoiceTheme(to: arriving)
        if toChat {
            if chatWebView?.url == nil {
                AppDelegate.log("聊天模式: 首次加载 DeepSeek 网页版")
                chatWebView?.load(URLRequest(url: URL(string: "https://chat.deepseek.com")!))
            }
        }
        arriving?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.resume()") { _, _ in }
    }

    /// 切换胶囊钮的装束：文案标明「去哪」，底色描边随当前皮肤深浅换装。
    /// 在聊天页时强调色描边 + 「🏠 主页」—— 因为那一刻用户要找的是「切回去」。
    private func styleChatToggle() {
        guard let btn = chatToggleBtn, btn.layer != nil else { return }
        let inChat = !(chatWebView?.isHidden ?? true)
        let dark = themeIndex != 1   // 与皮肤一致：翡翠·晨光 = 浅，其余 = 深
        let text = inChat ? "🏠 主页" : "💬 聊天"
        let bg = dark
            ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: 0.93)
            : NSColor(srgbRed: 0.965, green: 0.976, blue: 0.955, alpha: 0.96)
        let border = dark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor(srgbRed: 0.08, green: 0.24, blue: 0.16, alpha: 0.28)
        let fg = dark ? NSColor.white.withAlphaComponent(0.92)
                      : NSColor(srgbRed: 0.10, green: 0.22, blue: 0.15, alpha: 1.0)
        // 在聊天页：金色强调描边把「回主页」这个入口从页面内容里拎出来
        let accentBorder = NSColor(srgbRed: 0.85, green: 0.64, blue: 0.25, alpha: 0.85)
        btn.layer?.backgroundColor = bg.cgColor
        btn.layer?.borderColor = (inChat ? accentBorder : border).cgColor
        btn.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byClipping
        btn.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: fg,
            .paragraphStyle: para,
        ])
    }

    /// 语音 HUD 的主题深浅推送（换肤的唯一真相源）。HUD 外壳/中心线的配色跟着挂 .ft-light。
    private func pushVoiceTheme(to wv: WKWebView?) {
        let dark = themeIndex != 1
        wv?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.setTheme(\(dark ? "true" : "false"))") { _, _ in }
    }

    // 麦克风采集授权：WKWebView 里 getUserMedia 必须由宿主明确放行，否则 promise 直接 reject。
    // 这是「波形由 JS 自己用 AnalyserNode 驱动」这条路能否走通的前提。
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        AppDelegate.log("媒体采集请求: type=\(type.rawValue) host=\(origin.host) → 放行")
        decisionHandler(.grant)
    }

    // JS → 原生日志：注入脚本的探针结果统一写进 fatiaowu-app.log，
    // 这是「无录屏权限下取证」的主通道（app 自己写文件，不依赖截图权限）。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fatiaowuLog" {
            AppDelegate.log("JS: \(message.body)")
            return
        }
        if message.name == "fatiaowuVoice" {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
            // 发送方页面：由 message.webView 判定（WebView 拿不到时按当前活动页算）。
            let sender: String
            if let mw = message.webView { sender = (mw === chatWebView) ? "chat" : "dsh" }
            else { sender = voicePage }
            handleVoiceCommand(cmd, body, from: sender, replyTo: message.webView ?? activeVoiceWebView())
            return
        }
        guard message.name == "fatiaowuSetSkin" else { return }
        if let index = message.body as? Int, index >= 0, index < skins.count {
            applySkin(index)
        } else if let n = message.body as? NSNumber {
            applySkin(n.intValue)
        }
    }

    // ⌥⌘1/2/3 快捷键：直接监听按键事件（按物理键位识别，不受输入法/键盘布局影响，
    // 也不怕 WKWebView 抢先吃掉按键）。不用 ⌘⇧1/2/3，因为 ⌘⇧3 是系统截图键。
    private func installShortcuts() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard mods == [.command, .option] else { return event }
            // 物理键位：1=18, 2=19, 3=20（ANSI 键位，任何布局都一致）
            switch event.keyCode {
            case 18: self.applySkin(0); AppDelegate.log("快捷键 ⌥⌘1 → 暗金·深夜")
            case 19: self.applySkin(1); AppDelegate.log("快捷键 ⌥⌘2 → 翡翠·晨光")
            case 20: self.applySkin(2); AppDelegate.log("快捷键 ⌥⌘3 → 猩红·熔岩")
            default: return event
            }
            return nil // 已处理，不再传给菜单/网页
        }
    }

    // 生成标题栏「深绿玻璃」渐变（浅色皮肤用）
    private static func titlebarGlassGradient() -> NSColor {
        let image = NSImage(size: NSSize(width: 2, height: 64))
        image.lockFocus()
        let grad = NSGradient(
            starting: NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.62, alpha: 1),
            ending: NSColor(calibratedRed: 0.63, green: 0.79, blue: 0.69, alpha: 1)
        )!
        grad.draw(in: NSRect(x: 0, y: 0, width: 2, height: 64), angle: -90)
        image.unlockFocus()
        return NSColor(patternImage: image)
    }

    // 从 ~/.dsh/.credentials.yaml 读取 DeepSeek API 密钥
    private static func deepseekApiKey() -> String? {
        guard let content = try? String(contentsOfFile: "/Users/yangliu/.dsh/.credentials.yaml", encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "DEEPSEEK_API_KEY" {
                return parts[1]
            }
        }
        return nil
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 发条屋",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let skinItem = NSMenuItem(title: "切换皮肤", action: nil, keyEquivalent: "")
        let skinSubmenu = NSMenu()
        for (i, name) in skinNames.enumerated() {
            let mi = NSMenuItem(title: name,
                                action: #selector(selectSkin(_:)),
                                keyEquivalent: "\(i + 1)")
            mi.keyEquivalentModifierMask = [.command, .option]
            mi.tag = i
            mi.target = self
            mi.state = (i == themeIndex) ? .on : .off
            skinMenuItems.append(mi)
            skinSubmenu.addItem(mi)
        }
        skinItem.submenu = skinSubmenu
        appMenu.addItem(skinItem)
        appMenu.addItem(.separator())
        // 语音：菜单项只是 JS 状态机的一个入口（真相源在 voice.js），避免两处各存一份状态
        let vItem = NSMenuItem(title: "语音输入", action: #selector(toggleVoiceMenu(_:)), keyEquivalent: "v")
        vItem.keyEquivalentModifierMask = [.command, .option]
        vItem.target = self
        voiceMenuItem = vItem
        appMenu.addItem(vItem)
        let vOnce = NSMenuItem(title: "现在听一句（免唤醒词）", action: #selector(listenOnce(_:)), keyEquivalent: "b")
        vOnce.keyEquivalentModifierMask = [.command, .option]
        vOnce.target = self
        appMenu.addItem(vOnce)
        // 聊天模式：DeepSeek 官方网页版，免费聊天、不走 API 余额。
        // 网页登录态存在默认 WKWebsiteDataStore 里，登录一次以后一直有效。
        let chatItem = NSMenuItem(title: "聊天模式（DeepSeek 网页版 · 免费）",
                                  action: #selector(toggleChatMode(_:)), keyEquivalent: "c")
        chatItem.keyEquivalentModifierMask = [.command, .option]
        chatItem.target = self
        appMenu.addItem(chatItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 发条屋",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单：没有它，⌘C/⌘V/⌘X/⌘A 不会进响应链，WKWebView 收不到 copy:/paste:，
        // 整个界面（选中文字、输入框粘贴）都会失效。
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
        let menus = mainMenu.items.compactMap { $0.submenu?.title }.joined(separator: "/")
        let editItems = (editItem.submenu?.items ?? [])
            .filter { !$0.isSeparatorItem }
            .map { "\($0.title)⌘\($0.keyEquivalent)" }
            .joined(separator: " ")
        AppDelegate.log("菜单自检: [\(menus)] 编辑菜单项: \(editItems)")
    }

    // 读取内置皮肤 CSS，生成注入脚本（在页面最早期注入，避免闪烁）
    // 生灵层脚本：从 bundle 读 resources/alive.js 直接注入（atDocumentEnd，此时 DOM 已就绪）
    private static func aliveUserScript() -> WKUserScript? {
        guard let path = Bundle.main.path(forResource: "alive", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8),
              !js.isEmpty else {
            log("生灵层加载失败：alive.js 未找到或为空")
            return nil
        }
        log("生灵层加载成功：\(js.count) 字符")
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // ---------- 语音：原生引擎 ↔ 注入层（voice.js）的桥 ----------
    // 分工：原生负责「听」（识别 + 电平 + 唤醒词 + 判停），JS 负责「看起来」和「送进 harness」。
    private func setupVoice() {
        voice.onLog = { msg in AppDelegate.log("语音: \(msg)") }
        voice.onError = { [weak self] msg in
            AppDelegate.log("语音错误: \(msg)")
            self?.voiceCall("error", AppDelegate.jsStringLiteral(msg))
        }
        voice.onNotice = { [weak self] msg in
            AppDelegate.log("语音觉察: \(msg)")
            self?.voiceCall("notice", AppDelegate.jsStringLiteral(msg))
        }
        voice.onLevels = { [weak self] bands in
            guard let self = self else { return }
            var s = ""
            s.reserveCapacity(bands.count * 6)
            for (i, v) in bands.enumerated() {
                if i > 0 { s += "," }
                s += String(format: "%.3f", v)
            }
            self.activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.levels([\(s)])") { _, _ in }
        }
        voice.onPartial = { [weak self] text, isFinal in
            self?.voiceCall("partial", AppDelegate.jsStringLiteral(text), isFinal ? "true" : "false")
        }
        voice.onWake = { [weak self] word in
            self?.voiceCall("wake", AppDelegate.jsStringLiteral(word))
        }
        voice.onFinal = { [weak self] text in
            self?.voiceCall("final", AppDelegate.jsStringLiteral(text))
        }
        voice.onBargeIn = { [weak self] in self?.voiceCall("bargeIn") }
        voice.onPause = { [weak self] p, hasText in
            self?.voiceCall("pause", String(format: "%.3f", p), hasText ? "true" : "false")
        }
        // 识别通路变了（设备端 ↔ 网络）要把新状态推给 JS，否则界面上看不出来
        voice.onModeChange = { [weak self] in self?.pushVoiceStatus() }

        // 判停轮询：100ms 一次。它同时是「判停进度」的采样源，间隔就是倒计时条的锚点密度
        // （200ms 在 1.2 秒的停顿里只有 6 个锚点，倒计时会一跳一跳的）。
        voiceTick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.voice.tick()
        }
        AppDelegate.log("语音桥已就绪")
    }

    /// 统一的 native → JS 调用入口（JS 侧挂 window.__ftVoice）。只发给**活动页**。
    private func voiceCall(_ fn: String, _ args: String...) {
        let tail = args.isEmpty ? "" : args.joined(separator: ",")
        activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.\(fn)(\(tail))") { _, _ in }
    }

    private func handleVoiceCommand(_ cmd: String, _ body: [String: Any], from sender: String, replyTo: WKWebView?) {
        // 归属仲裁：只有「当前活动页」能驱动引擎。切页时旧页已被 suspend，这里再挡一道
        // —— 万一它的守护定时器/收尾命令漏发过来（echoGuard、busy），不能搅局。
        // suspend / prefsGet / prefsPush 豁免：suspend 本来就是切页流程里的旧页发的；
        // 偏好同步与页面归属无关。
        let gated: Set<String> = ["enable", "config", "manualStart", "manualStop", "busy", "echoGuard", "disable"]
        if gated.contains(cmd) && sender != voicePage {
            AppDelegate.log("语音命令[\(cmd)] 来自非活动页(\(sender))，已忽略（活动=\(voicePage)）")
            return
        }
        switch cmd {
        case "enable":
            if let w = body["wakeWords"] as? [String], !w.isEmpty { voice.wakeWords = w }
            if let a = body["ambient"] as? Bool { voice.ambientEnabled = a }
            if let p = body["pauseMs"] as? Double { voice.pauseMs = p }
            if let s = body["sensitivity"] as? Double { voice.sensitivity = Float(s) }
            if let e = body["echoCancel"] as? Bool { voice.echoCancel = e }
            if let m = body["echoMode"] as? String, !m.isEmpty { voice.setEchoMode(m) }
            if let f = body["forcePath"] as? String, !f.isEmpty { voice.forcePath = f }
            voice.requestPermissions { [weak self] ok, why in
                guard let self = self else { return }
                AppDelegate.log("语音权限: \(why)")
                if ok {
                    self.voice.start()
                    self.voiceOn = self.voice.running
                } else {
                    self.voiceOn = false
                    self.voiceCall("error", AppDelegate.jsStringLiteral(why))
                }
                self.pushVoiceStatus()
            }
        case "disable":
            voice.stop()
            voiceOn = false
            pushVoiceStatus()
        case "config":
            if let w = body["wakeWords"] as? [String], !w.isEmpty { voice.wakeWords = w }
            if let a = body["ambient"] as? Bool { voice.ambientEnabled = a }
            if let p = body["pauseMs"] as? Double { voice.pauseMs = p }
            if let s = body["sensitivity"] as? Double { voice.sensitivity = Float(s) }
            if let e = body["echoCancel"] as? Bool { voice.echoCancel = e }
            if let m = body["echoMode"] as? String, !m.isEmpty { voice.setEchoMode(m) }
            if let f = body["forcePath"] as? String, !f.isEmpty { voice.forcePath = f }
            if let r = body["resetPath"] as? Bool, r {
                // 用户想重新试设备端（比如后来装上了中文语言资源）
                UserDefaults.standard.set(false, forKey: "ftVoiceUseNetwork")
            }
            AppDelegate.log("语音配置: 唤醒词=\(voice.wakeWords.joined(separator: "/")) 常驻=\(voice.ambientEnabled) 停顿=\(Int(voice.pauseMs))ms 灵敏度=\(voice.sensitivity) 回声消除=\(voice.echoCancel) 通路=\(voice.forcePath)")
            pushVoiceStatus()
        case "manualStart":
            AppDelegate.log("语音命令: 手动开录")
            voice.manualStart()
        case "manualStop":
            AppDelegate.log("语音命令: 手动收句")
            voice.manualStop()
        case "busy":
            // 这行很关键：它标出「什么时候停止把音频送识别」。
            // 若 busy=true 在听的时候误发，识别器拿不到音频 → 也是「说完没反应」的一种。
            let b = (body["value"] as? Bool) ?? false
            AppDelegate.log("语音命令: busy=\(b)")
            voice.setBusy(b)
        case "echoGuard":
            let b = (body["value"] as? Bool) ?? false
            voice.setEchoGuard(b)
        case "suspend":
            // 切页：引擎停掉但**不推状态** —— 推了会把到达页吓出「引擎掉了」的误判。
            voice.stop()
        case "prefsGet":
            // 页面启动时来取全局偏好（另一页存的）。没有存过就静默：首次启动本来就没有。
            if let json = UserDefaults.standard.string(forKey: "ftVoicePrefsJSON"), !json.isEmpty {
                AppDelegate.log("语音偏好: 向 \(sender) 页回放（\(json.count) 字符）")
                replyTo?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.syncPrefs(\(AppDelegate.jsStringLiteral(json)))") { _, _ in }
            }
        case "prefsPush":
            if let json = body["json"] as? String {
                UserDefaults.standard.set(json, forKey: "ftVoicePrefsJSON")
            }
        default:
            break
        }
    }

    private func pushVoiceStatus() {
        // 这里必须产出**合法 JSON**：JS 侧是 JSON.parse 收的。
        // 曾经的写法用 jsonArray() 拼数组，而它吐的是单引号 JS 字面量 ['a','b'] ——
        // 合法 JS、非法 JSON，JSON.parse 抛错又被 catch 吞掉，
        // 表现成「唤醒词永远推不过去、状态一直是默认值」这种极难查的静默故障。
        // 所以交给 JSONSerialization，别再手拼。
        let payload: [String: Any] = [
            "running": voice.running,
            "onDevice": voice.onDeviceOK,
            "mode": voice.usingNetwork ? "network" : "device",
            "forcePath": voice.forcePath,
            "echoCancel": voice.echoCancel,
            "echoMode": voice.echoMode,
            "echoGuard": voice.echoGuard,
            "wakeWords": voice.wakeWords
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"running\":false,\"onDevice\":false,\"wakeWords\":[]}"
        voiceCall("status", AppDelegate.jsStringLiteral(json))
        voiceMenuItem?.state = voice.running ? .on : .off
    }

    // 通用注入辅助：按资源名读 JS 并注入主框架。
    // 与 aliveUserScript 同一套约定（失败只记日志、不抛），便于后续加脚本不改结构。
    private static func namedUserScript(_ name: String, at injectionTime: WKUserScriptInjectionTime = .atDocumentEnd) -> WKUserScript? {
        guard let path = Bundle.main.path(forResource: name, ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8),
              !js.isEmpty else {
            log("脚本加载失败：\(name).js 未找到或为空")
            return nil
        }
        log("脚本加载成功：\(name).js \(js.count) 字符")
        return WKUserScript(source: js, injectionTime: injectionTime, forMainFrameOnly: true)
    }

    // 聊天页皮肤：把**当前皮肤 CSS 原样**注入 chat.deepseek.com。
    // 依据（2026-09-20 无头探证实测）：DeepSeek 网页版的设计令牌（--dsw-alias-*）与
    // dsh 皮肤同一套词汇表，皮肤 CSS 里的令牌覆盖 + 背景光斑会原样生效；dsh 专属
    // 选择器在聊天页不命中，自然回落成「纯令牌 + 背景」，三套皮肤零翻译直接对应。
    // 另在 documentStart 抢写它的主题偏好（localStorage themePreference），浅色皮肤
    //（翡翠·晨光）会把它锁成 light，其余锁 dark。
    private static func chatSkinUserScript(css: String, isDark: Bool) -> WKUserScript? {
        guard !css.isEmpty else {
            log("聊天皮肤加载失败：CSS 为空")
            return nil
        }
        log("聊天皮肤加载成功：\(css.count) 字符")
        let cssLiteral = jsStringLiteral(css)
        let darkFlag = isDark ? "true" : "false"
        let js = """
        (function () {
          if (!/(^|\\.)deepseek\\.com$/i.test(location.hostname)) return;
          var log = function (m) { try { window.webkit.messageHandlers.fatiaowuLog.postMessage(m); } catch (e) {} };
          // DeepSeek 自家主题偏好：documentStart 抢先写（它启动时读一次）
          function writePref(dark) {
            try { localStorage.setItem('__appKit_@deepseek/chat_themePreference',
              JSON.stringify({ value: dark ? 'dark' : 'light', __version: '0' })); } catch (e) {}
          }
          writePref(\(darkFlag));
          if (document.documentElement) {
            document.documentElement.style.colorScheme = \(isDark ? "'dark'" : "'light'");
          }

          // 与主页 skinUserScript 同一套 CSSOM 注入机制（按大括号拆规则逐条插）
          function splitCss(css) {
            var rules = [], depth = 0, start = 0, inComment = false, inString = null;
            for (var i = 0; i < css.length; i++) {
              var c = css.charAt(i), n = css.charAt(i + 1);
              if (inComment) { if (c === '*' && n === '/') { inComment = false; i++; } continue; }
              if (inString) { if (c === '\\\\') { i++; } else if (c === inString) { inString = null; } continue; }
              if (c === '/' && n === '*') { inComment = true; i++; continue; }
              if (c === '"' || c === "'") { inString = c; continue; }
              if (c === '{') { depth++; }
              else if (c === '}') { depth--; if (depth === 0) { rules.push(css.slice(start, i + 1)); start = i + 1; } }
            }
            return rules;
          }
          var curCss = \(cssLiteral);
          var curDark = \(darkFlag);
          var sheetEl = document.createElement('style');
          sheetEl.id = 'fatiaowu-chat-skin';
          (document.documentElement || document.head).appendChild(sheetEl);
          function apply() {
            var sheet = sheetEl.sheet;
            if (sheet && sheet.deleteRule) { while (sheet.cssRules.length) { sheet.deleteRule(0); } }
            var inserted = 0;
            try {
              if (sheet && sheet.insertRule) {
                var rules = splitCss(curCss);
                for (var i = 0; i < rules.length; i++) {
                  try { sheet.insertRule(rules[i], sheet.cssRules.length); inserted++; } catch (e) {}
                }
              }
            } catch (e) {}
            if (inserted === 0) { try { sheetEl.textContent = curCss; } catch (e) {} }
          }
          apply();
          // 实时换肤入口（原生换肤走重建 WebView，这里兜 SPA 内部清样式的场景）
          window.__ftChatSetSkin = function (cssText, dark) {
            curCss = String(cssText); curDark = !!dark; writePref(curDark); apply();
          };
          // 保险：样式标签被框架清掉 4 秒内补回
          setInterval(function () {
            if (!document.getElementById('fatiaowu-chat-skin')) {
              document.documentElement.appendChild(sheetEl); apply();
            }
          }, 4000);
          log('聊天皮肤: 已注入（' + curCss.length + ' 字符，' + (curDark ? 'dark' : 'light') + '）');
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func skinUserScript(css: String, initialDark: Bool) -> WKUserScript? {        guard !css.isEmpty else {
            log("皮肤加载失败：CSS 为空")
            return nil
        }
        log("皮肤加载成功：\(css.count) 字符")
        let cssLiteral = jsStringLiteral(css)
        // 加载用户头像蒙版 PNG（FTW logo，形状在 alpha 通道）→ data URI，渲染时用 --ft-accent 着色
        var userAvatarURI = ""
        if let pngPath = Bundle.main.path(forResource: "user-avatar", ofType: "png"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pngPath)) {
            userAvatarURI = "data:image/png;base64," + data.base64EncodedString()
        }
        let userAvLiteral = jsStringLiteral(userAvatarURI)
        let js = """
        (function () {
          var cssText = \(cssLiteral);
          var USER_AV = \(userAvLiteral);

          // 按顶层大括号拆分 CSS 规则
          function splitCss(css) {
            var rules = [], depth = 0, start = 0, inComment = false, inString = null;
            for (var i = 0; i < css.length; i++) {
              var c = css.charAt(i), n = css.charAt(i + 1);
              if (inComment) {
                if (c === '*' && n === '/') { inComment = false; i++; }
                continue;
              }
              if (inString) {
                if (c === '\\\\') { i++; }
                else if (c === inString) { inString = null; }
                continue;
              }
              if (c === '/' && n === '*') { inComment = true; i++; continue; }
              if (c === '"' || c === "'") { inString = c; continue; }
              if (c === '{') { depth++; }
              else if (c === '}') {
                depth--;
                if (depth === 0) { rules.push(css.slice(start, i + 1)); start = i + 1; }
              }
            }
            return rules;
          }

          // 注入样式表
          var s = document.createElement('style');
          s.id = 'fatiaowu-skin';
          s.type = 'text/css';
          (document.documentElement || document.head || document.body).appendChild(s);
          var inserted = 0;
          try {
            var sheet = s.sheet;
            if (sheet && sheet.insertRule) {
              var rules = splitCss(cssText);
              for (var i = 0; i < rules.length; i++) {
                try { sheet.insertRule(rules[i], sheet.cssRules.length); inserted++; } catch (e) {}
              }
            }
          } catch (e) {}
          // 兜底：如果 CSSOM 方式失败，直接写 textContent
          if (inserted === 0) {
            try { s.textContent = cssText; } catch (e) {}
          }

          // 主题深浅：跟随皮肤（暗金=深，翡翠晨光=浅）
          var __ftDark = \(initialDark ? "true" : "false");
          function forceTheme() {
            if (document.documentElement) { document.documentElement.style.colorScheme = __ftDark ? 'dark' : 'light'; }
            if (!document.body) return;
            if (__ftDark) {
              if (!document.body.hasAttribute('data-ds-dark-theme')) { document.body.setAttribute('data-ds-dark-theme', ''); }
            } else {
              if (document.body.hasAttribute('data-ds-dark-theme')) { document.body.removeAttribute('data-ds-dark-theme'); }
            }
          }
          forceTheme();
          if (window.MutationObserver) {
            var obs = new MutationObserver(function () { forceTheme(); });
            if (document.body) {
              obs.observe(document.body, { attributes: true, attributeFilter: ['data-ds-dark-theme'] });
            }
            document.addEventListener('DOMContentLoaded', function () {
              if (document.body) {
                obs.observe(document.body, { attributes: true, attributeFilter: ['data-ds-dark-theme'] });
              }
              forceTheme();
            });
          }

          // 余额/消费状态信息条（会话框上方，细小不抢眼）
          var __fatiaowuPending = null;
          function ensureStatusBar() {
            if (document.getElementById('fatiaowu-status')) return;
            var el = document.createElement('div');
            el.id = 'fatiaowu-status';
            el.style.cssText = 'position:fixed;top:50px;right:28px;z-index:999;font-size:11px;line-height:16px;color:var(--ft-status);letter-spacing:.3px;font-weight:400;pointer-events:none;text-shadow:0 1px 3px var(--ft-status-shadow);white-space:nowrap;';
            el.textContent = __fatiaowuPending !== null ? __fatiaowuPending : '余额加载中…';
            document.body.appendChild(el);
          }
          window.__fatiaowuSetStatus = function (t) {
            __fatiaowuPending = t;
            ensureStatusBar();
            var el = document.getElementById('fatiaowu-status');
            if (el) el.textContent = t;
          };
          if (document.body) { ensureStatusBar(); }
          else { document.addEventListener('DOMContentLoaded', ensureStatusBar); }

          // 对话区空白的装饰「灯环」（藏在内容后面，填补空洞不抢眼）
          function ensureCenterMark() {
            if (document.getElementById('fatiaowu-mark')) return;
            var m = document.createElement('div');
            m.id = 'fatiaowu-mark';
            m.style.cssText = 'position:fixed;top:62%;left:calc(50% + 134px);transform:translate(-50%,-50%);width:380px;height:380px;z-index:-1;pointer-events:none;opacity:.6;';
            m.innerHTML = '<svg width="380" height="380" viewBox="0 0 380 380" fill="none" xmlns="http://www.w3.org/2000/svg"><defs><radialGradient id="fg" cx="50%" cy="50%" r="50%"><stop offset="0" style="stop-color:var(--ft-accent-bg)"/><stop offset="1" stop-color="rgba(217,164,65,0)"/></radialGradient></defs><circle cx="190" cy="190" r="160" fill="url(#fg)"/><circle cx="190" cy="190" r="102" style="stroke:var(--ft-accent-soft)" stroke-width="1"/><circle cx="190" cy="190" r="160" style="stroke:var(--ft-accent-softer)" stroke-width="1" stroke-dasharray="2 7"/></svg>';
            document.body.appendChild(m);
          }
          if (document.body) { ensureCenterMark(); }
          else { document.addEventListener('DOMContentLoaded', ensureCenterMark); }

          // ===== 双方头像：我=皮肤色 FTW 立方体（蒙版着色，换肤自动变色），你=小鲸鱼 =====
          var WHALE_PATH = "M22.9168 1.43018C22.6713 1.31018 22.5658 1.53918 22.4223 1.65519C22.3733 1.69269 22.3318 1.74169 22.2903 1.78669C21.9317 2.1697 21.5127 2.42121 20.9657 2.39121C20.1657 2.34621 19.4827 2.59771 18.8787 3.20973C18.7502 2.45521 18.3236 2.0047 17.6746 1.71569C17.3351 1.56568 16.9916 1.41518 16.7536 1.08867C16.5876 0.856163 16.5421 0.597155 16.4591 0.341647C16.4061 0.187643 16.3536 0.0301382 16.1761 0.00363739C15.9836 -0.0263635 15.9081 0.135141 15.8326 0.270145C15.5306 0.822162 15.4136 1.43018 15.4251 2.0462C15.4516 3.43174 16.0366 4.53527 17.1991 5.3203C17.3311 5.4103 17.3651 5.5003 17.3236 5.63181C17.2441 5.90231 17.1501 6.16482 17.0671 6.43533C17.0141 6.60784 16.9351 6.64584 16.7501 6.57033C16.1121 6.30383 15.5611 5.90931 15.074 5.4328C14.2475 4.63328 13.5 3.75075 12.568 3.05973C12.349 2.89822 12.13 2.74822 11.9034 2.60522C10.9524 1.68169 12.028 0.923165 12.277 0.833162C12.5375 0.739159 12.3675 0.41615 11.5259 0.42015C10.6844 0.42365 9.91439 0.705658 8.93286 1.08117C8.78935 1.13767 8.63835 1.17867 8.48384 1.21267C7.59332 1.04367 6.66829 1.00617 5.70226 1.11517C3.88321 1.31768 2.43016 2.1777 1.36213 3.64575C0.0790928 5.4103 -0.222916 7.41536 0.146595 9.50642C0.535106 11.7105 1.66014 13.535 3.38869 14.9616C5.18125 16.4406 7.24581 17.1657 9.60138 17.0266C11.0319 16.9441 12.6245 16.7526 14.421 15.2321C14.874 15.4576 15.3496 15.5476 16.1381 15.6151C16.7456 15.6716 17.3306 15.5851 17.7836 15.4911C18.4931 15.3411 18.4441 14.6841 18.1876 14.5636C16.1081 13.595 16.5646 13.9891 16.1496 13.67C17.2061 12.42 18.8202 10.1979 19.3182 7.17235C19.3672 6.83834 19.4297 6.36783 19.4222 6.09732C19.4182 5.93231 19.4562 5.86831 19.6447 5.84931C20.1657 5.78931 20.6712 5.64681 21.1357 5.3913C22.4833 4.65528 23.0268 3.44624 23.1548 1.9972C23.1738 1.77569 23.1508 1.54668 22.9168 1.43018ZM11.1749 14.4736C9.15936 12.889 8.18184 12.3675 7.77832 12.39C7.40081 12.4125 7.46881 12.8445 7.55182 13.126C7.63882 13.404 7.75182 13.5955 7.91033 13.8396C8.01983 14.0011 8.09533 14.2411 7.80083 14.4216C7.15181 14.8231 6.02327 14.2866 5.97027 14.2601C4.65673 13.4865 3.5587 12.4655 2.78467 11.069C2.03715 9.72493 1.60314 8.28289 1.53164 6.74384C1.51264 6.37233 1.62214 6.24082 1.99215 6.17332C2.47916 6.08332 2.98118 6.06432 3.46769 6.13582C5.52476 6.43633 7.27581 7.35586 8.74385 8.8129C9.58188 9.64243 10.2159 10.634 10.8689 11.6025C11.5634 12.631 12.3105 13.611 13.262 14.4146C13.598 14.6961 13.866 14.9101 14.1225 15.0681C13.349 15.1546 12.058 15.1731 11.1749 14.4746ZM12.141 8.25988C12.141 8.09488 12.273 7.96338 12.439 7.96338C12.4765 7.96338 12.5105 7.97088 12.541 7.98188C12.5825 7.99688 12.6205 8.01938 12.6505 8.05338C12.7035 8.10588 12.7335 8.18088 12.7335 8.25988C12.7335 8.42489 12.6015 8.55639 12.4355 8.55639C12.2695 8.55639 12.141 8.42489 12.141 8.25988ZM15.1415 9.79893C14.949 9.87793 14.7565 9.94544 14.5715 9.95294C14.2845 9.96794 13.9715 9.85143 13.8015 9.70893C13.5375 9.48742 13.3485 9.36342 13.2695 8.97691C13.2355 8.8119 13.2545 8.55639 13.2845 8.40989C13.3525 8.09438 13.277 7.89187 13.0545 7.70787C12.8735 7.55786 12.643 7.51636 12.39 7.51636C12.2955 7.51636 12.209 7.47486 12.1445 7.44136C12.039 7.38886 11.9519 7.25735 12.035 7.09585C12.0615 7.04335 12.19 6.91584 12.22 6.89334C12.5635 6.69784 12.9595 6.76184 13.326 6.90834C13.6655 7.04735 13.9225 7.30236 14.292 7.66287C14.6695 8.09838 14.7375 8.21838 14.9525 8.54539C15.1225 8.8009 15.277 9.06341 15.3831 9.36392C15.4471 9.55142 15.3641 9.70493 15.1415 9.79893Z";
          function addAvatars() {
            var urows = document.querySelectorAll('.Sixlwa_userRow:not([data-ftav])');
            for (var i = 0; i < urows.length; i++) {
              var row = urows[i];
              row.setAttribute('data-ftav', '1');
              if (!USER_AV) continue;
              row.style.position = 'relative';
              var av = document.createElement('div');
              av.className = 'ft-av-user';
              av.style.cssText = 'position:absolute;right:-60px;top:4px;width:32px;height:32px;border-radius:8px;border:1px solid var(--ft-accent-soft);background:var(--ft-accent-bg);box-shadow:0 0 6px var(--ft-accent-bg);';
              // 蒙版铺满整格（mask-size:100%），留白由蒙版本体控制（见 scripts/make-avatar-mask.py）：
              // 旧版 `center/76%` 把「外圈描边+间隙」一起缩进来，32px 下只有 0.6px，糊成一团。
              av.innerHTML = '<div style="width:100%;height:100%;border-radius:inherit;background:var(--ft-accent);-webkit-mask:url(' + USER_AV + ') center/100% 100% no-repeat;mask:url(' + USER_AV + ') center/100% 100% no-repeat;"></div>';
              row.appendChild(av);
            }
            var arows = document.querySelectorAll('.hWmORq_root:not([data-ftav])');
            for (var j = 0; j < arows.length; j++) {
              var arow = arows[j];
              arow.setAttribute('data-ftav', '1');
              arow.style.position = 'relative';
              var av2 = document.createElement('div');
              av2.className = 'ft-av-asst';
              av2.style.cssText = 'position:absolute;left:-48px;top:4px;width:32px;height:32px;border-radius:8px;background:var(--ft-accent-bg);border:1px solid var(--ft-accent-softer);display:flex;align-items:center;justify-content:center;';
              av2.innerHTML = '<svg width="24" height="18" viewBox="0 0 23.16 17.04" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="' + WHALE_PATH + '" style="fill:var(--ft-accent)"/></svg>';
              arow.insertBefore(av2, arow.firstChild);
            }
          }
          function watchAvatars() {
            addAvatars();
            var root = document.querySelector('.EvIC1a_scroll') || document.body;
            if (window.MutationObserver) {
              new MutationObserver(function () { addAvatars(); }).observe(root, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchAvatars(); }
          else { document.addEventListener('DOMContentLoaded', watchAvatars); }

          // ===== 表情包：金色表情按钮 + 面板 =====
          var EMOJIS = ['😀','😁','😂','🤣','😊','😍','🥰','😘','😜','🤔','😎','🥳','😢','😭','😤','🤯','😴','🤗','🤝','👍','👎','👏','🙏','💪','🔥','✨','⭐','🌟','💖','💛','💚','💙','🫶','🎉','🎂','🍰','☕','🍜','🍺','🐳','🖼️','🕰️','🌙','⚡','💡','✅','❌','⚠️'];
          function ensureEmojiButton() {
            if (document.getElementById('ft-emoji-btn')) return;
            var addBtn = document.querySelector('.uV2eYG_add');
            if (!addBtn || !addBtn.parentElement) return;
            var btn = document.createElement('button');
            btn.id = 'ft-emoji-btn';
            btn.type = 'button';
            btn.style.cssText = 'box-sizing:border-box;flex:none;width:28px;height:28px;border-radius:8px;border:1px solid var(--ft-accent-soft);background:var(--ft-accent-bg);cursor:pointer;font-size:15px;line-height:1;display:inline-flex;align-items:center;justify-content:center;';
            btn.textContent = '😊';
            btn.title = '表情';
            btn.addEventListener('click', function (e) { e.stopPropagation(); toggleEmojiPanel(btn); });
            addBtn.parentElement.insertBefore(btn, addBtn.nextElementSibling);
          }
          function toggleEmojiPanel(btn) {
            var old = document.getElementById('ft-emoji-panel');
            if (old) { old.remove(); return; }
            var panel = document.createElement('div');
            panel.id = 'ft-emoji-panel';
            panel.style.cssText = 'position:fixed;z-index:1200;padding:10px;border-radius:12px;border:1px solid var(--ft-accent-softer);background:rgba(23,29,45,.97);box-shadow:0 8px 28px rgba(0,0,0,.5);display:grid;grid-template-columns:repeat(8,30px);gap:2px;';
            for (var i = 0; i < EMOJIS.length; i++) {
              var b = document.createElement('button');
              b.type = 'button';
              b.style.cssText = 'width:30px;height:30px;border:none;background:transparent;border-radius:6px;cursor:pointer;font-size:17px;line-height:1;';
              b.textContent = EMOJIS[i];
              b.addEventListener('click', function (ev) {
                ev.stopPropagation();
                insertEmoji(this.textContent);
                panel.remove();
              });
              panel.appendChild(b);
            }
            var r = btn.getBoundingClientRect();
            panel.style.left = Math.max(8, r.left) + 'px';
            panel.style.bottom = (window.innerHeight - r.top + 10) + 'px';
            document.body.appendChild(panel);
            setTimeout(function () {
              document.addEventListener('click', function h(e) {
                if (!panel.contains(e.target) && e.target.id !== 'ft-emoji-btn') { panel.remove(); document.removeEventListener('click', h); }
              });
            }, 0);
          }
          function insertEmoji(emo) {
            var ta = document.querySelector('.uV2eYG_input');
            if (!ta) return;
            var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
            var start = ta.selectionStart != null ? ta.selectionStart : ta.value.length;
            var end = ta.selectionEnd != null ? ta.selectionEnd : start;
            var val = ta.value.slice(0, start) + emo + ta.value.slice(end);
            setter.call(ta, val);
            ta.dispatchEvent(new Event('input', { bubbles: true }));
            ta.focus();
            ta.setSelectionRange(start + emo.length, start + emo.length);
          }
          function watchEmojiButton() {
            ensureEmojiButton();
            var root = document.querySelector('.wSkVaW_composerStack') || document.querySelector('.uV2eYG_root') || document.body;
            if (window.MutationObserver) {
              new MutationObserver(function () { ensureEmojiButton(); }).observe(root, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchEmojiButton(); }
          else { document.addEventListener('DOMContentLoaded', watchEmojiButton); }

          // ===== 设置面板：皮肤栏目（插入通用设置区块内，Agent 预设之后，不置底） =====
          window.__ftMarkSkin = function (idx) {
            var cards = document.querySelectorAll('#ft-skin-section [data-ftskin]');
            for (var i = 0; i < cards.length; i++) {
              var on = parseInt(cards[i].getAttribute('data-ftskin'), 10) === idx;
              cards[i].style.borderColor = on ? 'var(--ft-accent)' : 'var(--ft-accent-softer)';
              cards[i].style.background = on ? 'var(--ft-accent-bg)' : 'transparent';
              cards[i].style.boxShadow = on ? '0 0 0 1px var(--ft-accent), 0 4px 14px rgba(0,0,0,.35)' : 'none';
            }
          };
          function ensureSkinSelector() {
            var content = document.querySelector('.VOzbGW_content');
            if (!content) return;
            if (document.getElementById('ft-skin-section')) return;
            var sec = document.createElement('div');
            sec.id = 'ft-skin-section';
            sec.style.cssText = 'flex-direction:column;gap:12px;padding:18px 14px;display:flex;border-bottom:1px solid var(--dsw-alias-border-l2);';
            var head = document.createElement('div');
            head.style.cssText = 'display:flex;align-items:center;gap:8px;color:var(--dsw-alias-label-primary);font-size:15px;font-weight:500;line-height:22px;';
            var dot = document.createElement('span');
            dot.style.cssText = 'width:6px;height:6px;border-radius:50%;background:var(--ft-accent);flex:none;';
            head.appendChild(dot);
            head.appendChild(document.createTextNode('皮肤'));
            sec.appendChild(head);
            var hint = document.createElement('div');
            hint.style.cssText = 'color:var(--dsw-alias-label-tertiary);font-size:12px;line-height:18px;';
            hint.textContent = '选择你喜欢的皮肤；也可用快捷键 ⌥⌘1 / ⌥⌘2 / ⌥⌘3 快速切换';
            sec.appendChild(hint);
            var row = document.createElement('div');
            row.style.cssText = 'display:flex;gap:10px;';
            var skins = [
              { name: '暗金·深夜', bg: 'linear-gradient(160deg,#161c2e 0%,#101726 55%,#0a0e17 100%)', accent: 'rgba(217,164,65,0.85)', dark: true },
              { name: '翡翠·晨光', bg: 'linear-gradient(160deg,#f0f5ea 0%,#e0e9de 55%,#d2e2d5 100%)', accent: 'rgba(15,157,110,0.9)', dark: false },
              { name: '猩红·熔岩', bg: 'linear-gradient(160deg,#2b0e0e 0%,#180808 55%,#0b0404 100%)', accent: 'rgba(255,71,87,0.9)', dark: true }
            ];
            for (var k = 0; k < skins.length; k++) {
              (function (idx) {
                var s = skins[idx];
                var card = document.createElement('button');
                card.type = 'button';
                card.setAttribute('data-ftskin', idx);
                card.style.cssText = 'flex:1;min-width:0;padding:0;border-radius:14px;border:1px solid var(--ft-accent-softer);background:transparent;cursor:pointer;overflow:hidden;display:flex;flex-direction:column;transition:border-color .15s,box-shadow .15s;';
                var prev = document.createElement('div');
                prev.style.cssText = 'height:72px;background:' + s.bg + ';position:relative;flex:none;';
                var side = document.createElement('div');
                side.style.cssText = 'position:absolute;left:0;top:0;bottom:0;width:15px;background:' + s.accent + ';opacity:.55;';
                var bubble = document.createElement('div');
                bubble.style.cssText = 'position:absolute;left:24px;bottom:12px;width:54%;height:14px;border-radius:7px;background:' + (s.dark ? 'rgba(255,255,255,.14)' : 'rgba(255,255,255,.65)') + ';border:1px solid ' + s.accent + ';';
                var bubble2 = document.createElement('div');
                bubble2.style.cssText = 'position:absolute;left:24px;top:12px;width:38%;height:9px;border-radius:5px;background:' + (s.dark ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.5)') + ';';
                prev.appendChild(side);
                prev.appendChild(bubble2);
                prev.appendChild(bubble);
                var name = document.createElement('div');
                name.style.cssText = 'padding:8px 6px;font-size:13px;line-height:20px;text-align:center;color:var(--dsw-alias-label-primary);';
                name.textContent = s.name;
                card.appendChild(prev);
                card.appendChild(name);
                card.addEventListener('click', function () {
                  try { window.webkit.messageHandlers.fatiaowuSetSkin.postMessage(idx); } catch (e) {}
                });
                row.appendChild(card);
              })(k);
            }
            sec.appendChild(row);
            // 插入到通用设置第一个栏目（Agent 预设）之后，不置底
            var sections = content.querySelectorAll('._WvWnq_section, [class*="_section"]');
            var anchor = sections.length > 0 ? sections[0] : null;
            if (anchor && anchor.parentNode) {
              if (anchor.nextSibling) { anchor.parentNode.insertBefore(sec, anchor.nextSibling); }
              else { anchor.parentNode.appendChild(sec); }
            } else if (content.firstChild) {
              content.insertBefore(sec, content.firstChild);
            } else {
              content.appendChild(sec);
            }
            window.__ftMarkSkin(0);
          }
          function watchSkinSelector() {
            ensureSkinSelector();
            if (window.MutationObserver) {
              new MutationObserver(function () { ensureSkinSelector(); }).observe(document.body, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchSkinSelector(); }
          else { document.addEventListener('DOMContentLoaded', watchSkinSelector); }

          // 皮肤切换：替换 #fatiaowu-skin 样式内容（配色与背景整体换肤）
          window.__ftSetSkin = function (css, dark) {
            if (typeof dark === 'boolean') { __ftDark = dark; }
            var s = document.getElementById('fatiaowu-skin');
            if (!s) {
              s = document.createElement('style');
              s.id = 'fatiaowu-skin';
              (document.head || document.documentElement).appendChild(s);
            }
            s.textContent = css;
            forceTheme();
          };
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // 把字符串安全地转成 JS 字符串字面量
    private static func jsStringLiteral(_ s: String) -> String {
        var out = "'"
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u{%04X}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "'"
    }

    private func loadURL() {
        webView.load(URLRequest(url: url))
    }

    // 首次加载失败：启动自动重连
    private func handleLoadFailure() {
        if retryTimer == nil && retryCount == 0 {
            statusLabel.stringValue = "正在连接发条屋服务…"
            statusLabel.isHidden = false
            scheduleNextRetry()
        }
        // 重试期间再次失败就忽略，由定时器驱动下一次尝试
    }

    private func scheduleNextRetry() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryOnce()
            }
        }
    }

    private func retryOnce() {
        guard retryCount < maxRetries else {
            showServerDownAlert()
            return
        }
        retryCount += 1
        statusLabel.stringValue = "正在连接发条屋服务…（第 \(retryCount) 次尝试）"
        loadURL()
        scheduleNextRetry()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryTimer?.invalidate()
        retryTimer = nil
        statusLabel.isHidden = true
        webView.evaluateJavaScript("window.__ftMarkSkin && window.__ftMarkSkin(\(themeIndex))") { _, _ in }
        // 聊天页就绪：补推主题 + resume。首次加载时 toggleChatMode 里的 resume 会扑空
        // （voice.js 是 documentEnd 注入，此刻刚就绪），这里兜住「切过去就该接上」的链路。
        if webView === chatWebView {
            pushVoiceTheme(to: chatWebView)
            chatWebView?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.resume()") { _, _ in }
        } else if webView === self.webView {
            pushVoiceTheme(to: webView)
        }
        // TEMP 设置导航结构探针
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.webView?.evaluateJavaScript("""
            (function(){
              var panel = document.querySelector('.VOzbGW_panel');
              if (!panel) return 'no-panel';
              var out = [];
              // 找面板里所有直接可见的文本项（导航/内容），带 class
              function walk(el, depth) {
                if (depth > 4) return;
                for (var i = 0; i < el.children.length; i++) {
                  var c = el.children[i];
                  var t = (c.textContent || '').trim();
                  if (c.children.length === 0 && t.length < 30 && t.length > 0) {
                    out.push('LEAF ' + t + ' | ' + c.tagName + '.' + String(c.className||'').substring(0,45));
                  }
                  walk(c, depth + 1);
                }
              }
              walk(panel, 0);
              return out.slice(0, 40).join('\n');
            })()
            """) { result, _ in
                if let s = result as? String { AppDelegate.log("导航探针: \n\(s)") }
            }
        }
        diagnoseSkin()
    }

    // 页面加载后自动检查皮肤是否生效，写入日志
    private func diagnoseSkin() {
        // 生灵层自检：/tmp/ft-alive.flag 内容为 idle|busy，强制到该状态后全窗截图 + 机芯特写
        if FileManager.default.fileExists(atPath: "/tmp/ft-alive.flag") {
            let raw = (try? String(contentsOfFile: "/tmp/ft-alive.flag", encoding: .utf8)) ?? ""
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.probeAlive(force: mode.isEmpty ? "idle" : mode)
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-snapshot.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.captureSnapshot()
            }
        }
        webView.evaluateJavaScript("""
        JSON.stringify({
          style: !!document.getElementById('fatiaowu-skin'),
          dark: document.body.hasAttribute('data-ds-dark-theme'),
          bg: getComputedStyle(document.body).getPropertyValue('--dsw-alias-bg-base'),
          brand: getComputedStyle(document.body).getPropertyValue('--dsw-alias-brand-primary'),
          bubble: getComputedStyle(document.body).getPropertyValue('--dsw-specific-bubble'),
          side: getComputedStyle(document.body).getPropertyValue('--dsw-specific-sidebar-fill'),
          art: getComputedStyle(document.body).backgroundImage !== 'none',
          title: document.title,
          bodyEls: document.body ? document.body.getElementsByTagName('*').length : -1
        })
        """) { result, _ in
            if let r = result as? String {
                AppDelegate.log("页面诊断: \(r)")
            }
        }
        // 3 秒后再复查一次，观察主题属性是否被插件来回切换
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("JSON.stringify({dark: document.body.hasAttribute('data-ds-dark-theme'), bar: !!document.getElementById('fatiaowu-status')})") { result, _ in
                if let r = result as? String {
                    AppDelegate.log("状态条: \(r)")
                }
            }
        }
        // 2.5 秒后检查左上角品牌区（无框方案：border 应为 0px、字标应为强调色、牌内字母应为墨色），换 dsh 版本后靠它快速回归
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("""
            (function () {
              function box(sel) {
                var el = document.querySelector(sel);
                if (!el) return sel + '=缺失';
                var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
                return sel + '=' + Math.round(r.width) + 'x' + Math.round(r.height) + '@' + Math.round(r.left) + ',' + Math.round(r.top)
                  + ' ' + cs.display
                  + ' border:' + cs.borderTopWidth + '/' + cs.borderTopStyle
                  + ' bg:' + cs.backgroundImage.slice(0, 12)
                  + ' color:' + cs.color;
              }
              var bn = document.querySelector('[class*="brandName"]');
              return JSON.stringify({
                collapsed: !!document.querySelector('[data-sidebar-collapsed]'),
                wordmark: document.querySelectorAll('svg[viewBox^="26 0 156"]').length,
                name: box('[class*="brandName"]'),
                mark: box('[class*="brandMark"]'),
                badgeInk: bn ? getComputedStyle(bn).getPropertyValue('--dsw-alias-label-primary-inverted').trim() : ''
              });
            })()
            """) { result, _ in
                if let r = result as? String { AppDelegate.log("品牌探针: \(r)") }
            }
        }

        // 10 秒后检查头像挂载数量（需要会话里有消息才会出现行元素）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("""
            JSON.stringify({
              userRows: document.querySelectorAll('.Sixlwa_userRow').length,
              userAv: document.querySelectorAll('.ft-av-user').length,
              asstAv: document.querySelectorAll('.ft-av-asst').length,
              maskPainted: (function(){ var el = document.querySelector('.ft-av-user div'); return el ? getComputedStyle(el).backgroundColor : 'n/a'; })()
            })
            """) { result, _ in
                if let r = result as? String {
                    AppDelegate.log("头像探针: \(r)")
                }
            }
        }
    }

    // 生灵层自检：强制运转状态 → 采两次状态（间隔 1s，比较齿轮角度证明真的在转）→ 全窗图 + 机芯特写
    private func probeAlive(force: String) {
        guard let wv = webView else { return }

        // settings 模式：先点开设置面板，验证「生灵」栏目是否插进去了
        if force == "settings" {
            wv.evaluateJavaScript("""
            (function(){
              var area = document.querySelector('[class$="_settingsArea"]');
              if (!area) return 'no-settingsArea';
              var b = area.querySelector('button,[role="button"]');
              if (!b) return 'no-button';
              b.click();
              return 'clicked';
            })()
            """) { r, _ in
                AppDelegate.log("生灵探针[settings]: 打开设置 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){
                  var s = document.getElementById('ft-alive-section');
                  var secs = document.querySelectorAll('[class$="_content"] [class*="_section"]');
                  return JSON.stringify({ alive: !!s, sections: secs.length,
                    skin: !!document.getElementById('ft-skin-section'),
                    toggles: s ? s.querySelectorAll('button').length : 0,
                    label: s ? s.textContent.replace(/\\s+/g,' ').slice(0,80) : null });
                })()
                """) { r, _ in
                    AppDelegate.log("生灵探针[settings] 栏目: \(r as? String ?? "nil")")
                }
                let c = WKSnapshotConfiguration()
                c.snapshotWidth = 1180
                self.writeSnapshot(wv, c, to: "/tmp/ft-alive-settings.png", label: "设置面板")
            }
            return
        }

        // tok 模式：核对真实 token 遥测（dsh 统计胶囊 aria-label + 传输层账本）
        if force == "tok" {
            let dump = "window.__ftAliveDebug ? JSON.stringify({pill: window.__ftAliveDebug.pill(), tele: window.__ftAliveDebug.state().tele, text: window.__ftAliveDebug.state().text, title: window.__ftAliveDebug.state().title}) : 'no-alive'"
            wv.evaluateJavaScript(dump) { r, _ in
                AppDelegate.log("用量探针: \(r as? String ?? "nil")")
            }
            // 真实会话可能还没有统计胶囊（新会话 steps=0 时不渲染）——注入同结构的假胶囊验证解析链路
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){
                  var real = document.querySelector('[data-composer-stats]');
                  if (real) return 'real-pill-present';
                  var d = document.createElement('div');
                  d.setAttribute('data-composer-stats', '1');
                  d.style.cssText = 'position:fixed;left:-9999px;top:0;';
                  var a = document.createElement('button');
                  a.setAttribute('aria-label', '24.6k tok · 缓存命中 92%');
                  var b = document.createElement('button');
                  b.setAttribute('aria-label', '3 轮 12 步 · 38 tok/s');
                  d.appendChild(a); d.appendChild(b);
                  document.body.appendChild(d);
                  return 'fake-pill-injected';
                })()
                """) { r, _ in
                    AppDelegate.log("用量探针: \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(dump) { r, _ in
                    AppDelegate.log("用量探针[注入后]: \(r as? String ?? "nil")")
                }
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 8), y: max(0, y - 8), width: w + 16, height: h + 16)
                    c.snapshotWidth = NSNumber(value: Int((w + 16) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-tok.png", label: "机芯读数")
                }
                wv.evaluateJavaScript("(function(){var d=document.querySelector('[data-composer-stats][style]');if(d)d.remove();return 'cleaned';})()") { _, _ in }
            }
            return
        }

        // liveflow 模式：走真实判据（注入假「停止生成」按钮）→ 灌合成用量 → 撤按钮触发完成，
        // 端到端验证「实时速率 → 转速 → 本轮增量 → 上弦音」这条链路（不触碰真实会话）
        if force == "liveflow" {
            let dump = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
            func readState(_ tag: String) {
                wv.evaluateJavaScript(dump) { r, _ in
                    AppDelegate.log("实时用量链路[\(tag)]: \(r as? String ?? "nil")")
                }
            }
            wv.evaluateJavaScript("""
            (function(){
              var b = document.createElement('button');
              b.id = 'ft-fake-stop';
              b.setAttribute('aria-label', '停止生成');
              b.style.cssText = 'position:fixed;left:-9999px;top:0;';
              document.body.appendChild(b);
              return 'injected';
            })()
            """) { r, _ in
                AppDelegate.log("实时用量链路: 注入假停止按钮 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.feed(5, 420)") { r, _ in
                    AppDelegate.log("实时用量链路: 灌合成用量 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { readState("t1 运转中") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { readState("t2 运转中") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-fake-stop');if(e)e.remove();return 'removed';})()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                readState("完成后(期望 done + 本轮增量)")
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 8), y: max(0, y - 8), width: w + 16, height: h + 16)
                    c.snapshotWidth = NSNumber(value: Int((w + 16) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-liveflow.png", label: "机芯读数[完成后]")
                }
            }
            return
        }

        // setopen 模式：查清设置面板的真实打开方式，以及「生灵」栏目到底被插到了哪儿
        if force == "setopen" {
            let js = """
            (function(){
              function cn(el){var c=el.className;if(c&&typeof c.baseVal==='string')c=c.baseVal;return (c||'').toString();}
              function desc(el){
                if(!el) return 'null';
                var r=el.getBoundingClientRect();
                return el.tagName.toLowerCase()+'['+cn(el).slice(0,50)+'] '+(r.width>0?'可见 ':'隐藏 ')+Math.round(r.width)+'x'+Math.round(r.height);
              }
              var sec=document.getElementById('ft-alive-section');
              function chain(el){
                var out=[], n=el, d=0;
                while(n && n!==document.body && d<8){
                  var r=n.getBoundingClientRect();
                  out.push(n.tagName.toLowerCase()+'['+cn(n).slice(0,44)+'] '+Math.round(r.width)+'x'+Math.round(r.height)+' pos:'+getComputedStyle(n).position);
                  n=n.parentNode; d++;
                }
                return out;
              }
              var pan=document.querySelector('[class$="_panel"]');
              var ovl=document.querySelector('[class$="_overlay"]');
              var area=document.querySelector('[class$="_settingsArea"]');
              var contacts=[];
              var trs=document.querySelectorAll('[class$="_triggerRow"]');
              for(var j=0;j<trs.length;j++){
                contacts.push({chain: chain(trs[j]), hasPanel: !!trs[j].querySelector('[class$="_panel"]'), hasOverlay: !!trs[j].querySelector('[class$="_overlay"]')});
              }
              var contents=[];
              var cs=document.querySelectorAll('[class$="_content"]');
              for(var i=0;i<cs.length;i++){
                var p=cs[i].parentNode;
                contents.push({cls:cn(cs[i]).slice(0,60), w:Math.round(cs[i].getBoundingClientRect().width),
                  h:Math.round(cs[i].getBoundingClientRect().height), parent:desc(p),
                  hasAlive: !!cs[i].querySelector('#ft-alive-section'), hasSkin: !!cs[i].querySelector('#ft-skin-section')});
              }
              return JSON.stringify({
                panelChain: pan ? chain(pan) : null,
                overlayChain: ovl ? chain(ovl) : null,
                areaChain: area ? chain(area) : null,
                triggerRows: contacts,
                overlayInArea: !!(area && ovl && area.contains(ovl)),
                overlayInTriggerRow: !!(trs.length && ovl && trs[0].contains(ovl)),
                aliveExists: !!sec,
                aliveParent: sec? desc(sec.parentNode) : null,
                aliveVisible: sec? (sec.offsetParent !== null) : null,
                aliveRect: sec? (function(){var r=sec.getBoundingClientRect();return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)];})() : null,
                // 「生灵」栏目里到底渲染了几行开关（文字直接读出来，不靠看图猜）
                aliveRows: sec? (function(){
                  var rs=sec.querySelectorAll('[class*="switchRow"],[class*="toggleRow"],[class*="row"]');
                  var out=[];
                  for(var i=0;i<rs.length;i++){
                    var t=(rs[i].textContent||'').replace(/\\s+/g,' ').trim();
                    if(t) out.push(t.slice(0,36));
                  }
                  return out;
                })() : null,
                aliveSwitches: sec? sec.querySelectorAll('[role="switch"],input[type="checkbox"],button[class*="switch"]').length : null,
                contentCount: cs.length,
                contents: contents.slice(0,6),
                sectionsTotal: document.querySelectorAll('[id$="-section"]').length,
                sectionIds: (function(){var a=[];var n=document.querySelectorAll('[id$="-section"]');for(var i=0;i<n.length;i++)a.push(n[i].id);return a;})()
              });
            })()
            """
            wv.evaluateJavaScript(js) { r, _ in
                AppDelegate.log("设置面板探针[关闭态]: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                // 点原生触发器（不是我的转发按钮）→ 看面板怎么出现
                wv.evaluateJavaScript("(function(){var a=document.querySelector('[class$=\"_settingsArea\"]');if(!a)return 'no-area';var b=a.querySelector('button');if(!b)return 'no-btn';b.click();return 'clicked-real';})()") { r, _ in
                    AppDelegate.log("设置面板探针: 点原生触发器 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(js) { r, _ in
                    AppDelegate.log("设置面板探针[打开后]: \(r as? String ?? "nil")")
                }
                // 面板内容可滚动：找到真正的滚动容器并滚到底，把「生灵」三条都露出来
                wv.evaluateJavaScript("""
                (function(){
                  var p=document.querySelector('[class$="_panel"]');
                  if(!p) return 'no-panel';
                  var best=null, bh=0;
                  var ns=p.querySelectorAll('*');
                  for(var i=0;i<ns.length;i++){
                    var el=ns[i];
                    if(el.scrollHeight - el.clientHeight > 30 && el.clientHeight > 180 && el.scrollHeight > bh){
                      best=el; bh=el.scrollHeight;
                    }
                  }
                  if(!best) return 'no-scroller';
                  best.scrollTop = best.scrollHeight;
                  return 'scrolled ' + Math.round(best.scrollTop) + '/' + Math.round(best.scrollHeight) + ' cls=' + String(best.className).slice(0,40);
                })()
                """) { r, _ in
                    AppDelegate.log("设置面板探针: 滚动 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){var p=document.querySelector('[class$="_panel"]');if(!p)return null;var r=p.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 4), y: max(0, y - 4), width: w + 8, height: h + 8)
                    c.snapshotWidth = NSNumber(value: Int(w + 8))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-set-alive.png", label: "设置面板[整块]")
                }
            }
            return
        }

        // setloc 模式：核对「设置」入口已搬到主区标题栏，并验证点击转发真的能打开面板
        if force == "setloc" {
            let st1 = "window.__ftAliveDebug ? JSON.stringify({moved: window.__ftAliveDebug.state().settingsMoved, hidden: window.__ftAliveDebug.state().settingsHidden, btn: (function(){var b=document.getElementById('ft-settings-btn');if(!b)return null;var r=b.getBoundingClientRect();return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)];})(), icon: (function(){var b=document.getElementById('ft-settings-btn');return b?b.children.length:-1;})()}) : 'no-alive'"
            wv.evaluateJavaScript(st1) { r, _ in
                AppDelegate.log("设置入口探针: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: 1180, y: 0, width: 260, height: 84)
                c.snapshotWidth = 1040
                self.writeSnapshot(wv, c, to: "/tmp/ft-set-header.png", label: "标题栏右上")
                wv.evaluateJavaScript("(function(){var b=document.getElementById('ft-settings-btn');if(b)b.click();return 'clicked';})()") { r, _ in
                    AppDelegate.log("设置入口探针: 点击转发 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                // 判据必须用「浮层是否真的有尺寸」——不能用 #ft-alive-section 是否存在
                // （那个节点常驻，面板关着也在，上一轮就是被它骗过一次）
                wv.evaluateJavaScript("""
                (function(){
                  function vis(el){ if(!el) return null; var r=el.getBoundingClientRect();
                    return Math.round(r.width)+'x'+Math.round(r.height)+' disp:'+getComputedStyle(el).display; }
                  var s  = document.getElementById('ft-alive-section');
                  var ov = document.querySelector('[class$="_overlay"]');
                  var pn = document.querySelector('[class$="_panel"]');
                  var t  = document.querySelector('[class$="_settingsArea"] button');
                  var b  = document.getElementById('ft-settings-btn');
                  return JSON.stringify({
                    overlay: vis(ov), panel: vis(pn),
                    aliveInPanel: !!(pn && pn.querySelector('#ft-alive-section')),
                    aliveVisible: s ? (s.offsetParent !== null) : null,
                    triggerExpanded: t ? t.getAttribute('aria-expanded') : null,
                    btnDataOn: b ? b.getAttribute('data-on') : null,
                    sections: document.querySelectorAll('[class$="_content"] [id$="-section"]').length
                  });
                })()
                """) { r, _ in
                    AppDelegate.log("设置入口探针 打开后: \(r as? String ?? "nil")")
                }
                let c = WKSnapshotConfiguration()
                c.snapshotWidth = 1180
                self.writeSnapshot(wv, c, to: "/tmp/ft-set-panel.png", label: "设置面板")
            }
            return
        }

        // pet 模式：桌宠特写（真实截图，放大后目检造型与摆动）
        if force == "pet" {
            let petRectJS = """
            (function(){
              var p = document.getElementById('ft-pet');
              if (!p) return null;
              var r = p.getBoundingClientRect();
              return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,
                mode:(window.__ftAliveDebug?window.__ftAliveDebug.state().petMode:''),
                eye:(window.__ftAliveDebug?window.__ftAliveDebug.state().petEye:'')});
            })()
            """
            wv.evaluateJavaScript(petRectJS) { r, _ in
                AppDelegate.log("桌宠探针: \(r as? String ?? "nil")")
            }
            wv.evaluateJavaScript("window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'") { r, _ in
                AppDelegate.log("生灵探针[pet] state: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(petRectJS) { res, _ in
                    let full = WKSnapshotConfiguration()
                    full.snapshotWidth = 1180
                    self.writeSnapshot(wv, full, to: "/tmp/ft-pet-full.png", label: "全窗[pet]")
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double, w > 4 else {
                        AppDelegate.log("桌宠探针: 拿不到几何")
                        return
                    }
                    AppDelegate.log("桌宠探针 几何: \(Int(w))x\(Int(h))@\(Int(x)),\(Int(y)) mode=\(o["mode"] ?? "") eye=\(o["eye"] ?? "")")
                    let pad = 18.0
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - pad), y: max(0, y - pad), width: w + pad * 2, height: h + pad * 2)
                    c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 8))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-pet-zoom.png", label: "桌宠特写")
                }
            }
            return
        }

        // petact 模式：把每个新行为依次拉一遍并逐个截图（只验「特效落点/活动范围」，
        // 手感与好不好看交给用户实测）。截图区固定为「侧栏 + 正文左缘 360px」。
        if force == "petact" {
            let acts: [(String, Double)] = [("stretch", 0.5), ("spout", 0.35), ("chase", 1.2),
                                            ("peek", 2.7), ("spin", 0.3), ("visitClock", 3.6)]
            var delay = 0.4
            for (m, shot) in acts {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, let wv = self.webView else { return }
                    wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.play('\(m)')") { _, _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + shot) { [weak self] in
                    guard let self = self, let wv = self.webView else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: 0, y: 60, width: 360, height: 880)
                    c.snapshotWidth = 1080
                    self.writeSnapshot(wv, c, to: "/tmp/ft-act-\(m).png", label: "行为[\(m)]")
                    wv.evaluateJavaScript("""
                    (function(){var d=window.__ftAliveDebug;if(!d)return null;var s=d.state();
                    return JSON.stringify({mode:s.petMode,play:s.petPlay,pos:s.petPos,jelly:s.petJelly,
                    bubs:s.petBubs,scale:s.petScale,home:s.petHome});})()
                    """) { r, _ in
                        AppDelegate.log("行为探针[\(m)]: \(r as? String ?? "nil")")
                    }
                }
                delay += shot + 0.6
            }
            // 最后来一次「完成庆祝」（三连跳 + 星光 + 泡泡 + 和弦）
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.cheer()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: 0, y: 60, width: 360, height: 880)
                c.snapshotWidth = 1080
                self.writeSnapshot(wv, c, to: "/tmp/ft-act-cheer.png", label: "行为[cheer]")
            }
            return
        }

        // dom 模式：把侧栏底部/品牌区/主区头部的真实结构 dump 出来（决定「设置」往哪挪）
        if force == "dom" {
            wv.evaluateJavaScript("""
            (function(){
              function cn(el){
                var c = el.className;
                if (c && typeof c.baseVal === 'string') c = c.baseVal;
                return (c || '').toString();
              }
              function d(el){
                var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
                return {
                  t: el.tagName.toLowerCase(),
                  c: cn(el).split(/\\s+/).filter(function(x){return x.indexOf('_')>-1;}).join(' ').slice(0,60),
                  a: (el.getAttribute('aria-label') || el.getAttribute('title') || '').slice(0,24),
                  x: (el.textContent||'').replace(/\\s+/g,' ').trim().slice(0,24),
                  r: [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]
                };
              }
              function walk(el, depth, budget){
                if (!el || depth < 0 || budget.n <= 0) return null;
                budget.n--;
                var o = d(el);
                if (depth > 0) {
                  var kids = [];
                  for (var i = 0; i < el.children.length && i < 14; i++) {
                    var k = walk(el.children[i], depth-1, budget);
                    if (k) kids.push(k);
                  }
                  if (kids.length) o.k = kids;
                }
                return o;
              }
              var roots = {
                sideRoot: '[class$="_root"][class*="_hHd"]',
                logoRow: '[class$="_logoRow"]',
                footArea: '[class$="_footArea"]',
                settingsArea: '[class$="_settingsArea"]',
                footerActions: '[class$="_footerActions"]',
                regionArea: '[class$="_regionArea"]',
                mainHeader: '[class$="_header"]'
              };
              var out = {};
              for (var key in roots) {
                var el = document.querySelector(roots[key]);
                out[key] = el ? walk(el, 3, {n: 40}) : '缺失';
              }
              // 侧栏底部 260px 内出现的所有可点元素
              var bottom = [];
              var sb = document.querySelector('[class$="_root"][class*="_hHd"]');
              if (sb) {
                var br = sb.getBoundingClientRect();
                var all = sb.querySelectorAll('button,[role="button"],a');
                for (var i = 0; i < all.length; i++) {
                  var r = all[i].getBoundingClientRect();
                  if (r.top > br.bottom - 280 && r.width > 0) {
                    bottom.push({a: (all[i].getAttribute('aria-label')||all[i].getAttribute('title')||'').slice(0,20),
                                 x: (all[i].textContent||'').replace(/\\s+/g,' ').trim().slice(0,20),
                                 r: [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]});
                  }
                }
              }
              out.sidebarBottomButtons = bottom;
              return JSON.stringify(out);
            })()
            """) { r, _ in
                if let s = r as? String {
                    AppDelegate.log("DOM探针:\n\(s)")
                } else {
                    AppDelegate.log("DOM探针: 无结果 \(String(describing: r))")
                }
            }
            return
        }

        // stopbtn 模式：注入一个假的「停止生成」按钮来验证主判定路径（不打扰真实会话）
        if force == "stopbtn" {
            let stateJS = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
            func readState(_ tag: String) {
                wv.evaluateJavaScript(stateJS) { r, _ in
                    AppDelegate.log("停止按钮路径 \(tag): \(r as? String ?? "nil")")
                }
            }
            wv.evaluateJavaScript("""
            (function(){
              var b = document.createElement('button');
              b.id = 'ft-fake-stop';
              b.setAttribute('aria-label', '停止生成');
              b.style.cssText = 'position:fixed;left:-9999px;top:0;';
              document.body.appendChild(b);
              return 'injected';
            })()
            """) { r, _ in
                AppDelegate.log("停止按钮路径: 注入假按钮 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { readState("注入后(期望 busy)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-fake-stop');if(e)e.remove();return 'removed';})()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { readState("移除后 0.9s(期望 done)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { readState("移除后 2.2s(期望 idle)") }
            return
        }

        // collapse 模式：折叠侧栏，验证机芯退化成「只剩齿轮」
        if force == "collapse" {
            wv.evaluateJavaScript("""
            (function(){var t=document.querySelector('[class$="_toggle"]');if(!t)return 'no-toggle';t.click();return 'clicked';})()
            """) { r, _ in
                AppDelegate.log("生灵探针[collapse]: 折叠 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let full = WKSnapshotConfiguration()
                full.snapshotWidth = 1180
                self.writeSnapshot(wv, full, to: "/tmp/ft-alive-collapse.png", label: "全窗[折叠]")
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,sw:e.querySelector('svg').getBoundingClientRect().width});})()
                """) { r, _ in
                    AppDelegate.log("生灵探针[collapse] 机芯几何: \(r as? String ?? "nil")")
                    guard let s = r as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let pad = 10.0
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - pad), y: max(0, y - pad), width: w + pad * 2, height: h + pad * 2)
                    c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-collapse.png", label: "机芯[折叠]")
                }
            }
            return
        }

        wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.force(\(AppDelegate.jsStringLiteral(force)))") { _, _ in }

        let stateJS = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
        for (delay, tag) in [(1.2, "t0"), (2.2, "t1")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView?.evaluateJavaScript(stateJS) { r, _ in
                    AppDelegate.log("生灵探针[\(force)] \(tag): \(r as? String ?? "nil")")
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            let full = WKSnapshotConfiguration()
            full.snapshotWidth = 1180
            self.writeSnapshot(wv, full, to: "/tmp/ft-alive-\(force).png", label: "全窗[\(force)]")

            wv.evaluateJavaScript("""
            (function(){var e=document.getElementById('ft-clock');if(!e)return null;
            var r=e.getBoundingClientRect();
            return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
            """) { res, _ in
                guard let s = res as? String,
                      let d = s.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let x = o["x"] as? Double, let y = o["y"] as? Double,
                      let w = o["w"] as? Double, let h = o["h"] as? Double else {
                    AppDelegate.log("机芯特写[\(force)]: 取不到 #ft-clock")
                    return
                }
                let pad = 12.0
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: h + pad * 2)
                c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 6))
                self.writeSnapshot(wv, c, to: "/tmp/ft-clock-\(force).png", label: "机芯特写[\(force)]")
            }
        }
    }

    // 截图自检：存在 /tmp/ft-snapshot.flag 时，把左上角品牌区截成 PNG（不需要录屏权限）
    // 同时若会话里有用户头像，再截一张头像特写（32px 的元素放大 8 倍看细节）
    private func captureSnapshot() {
        guard let wv = webView else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: 460, height: 150)
        cfg.snapshotWidth = 920
        writeSnapshot(wv, cfg, to: "/tmp/ft-snapshot.png", label: "品牌区")

        // 头像特写：把最后一个 .ft-av-user 克隆一份钉在视口角落（原地那份可能滚出可视区），
        // 截完再删掉。这样不需要滚动、不需要录屏权限，也能拿到 8 倍放大的真实渲染。
        wv.evaluateJavaScript("""
        (function () {
          var old = document.getElementById('ft-av-stage');
          if (old) old.remove();
          var es = document.querySelectorAll('.ft-av-user');
          if (!es.length) return null;
          var src = es[es.length - 1];
          var stage = src.cloneNode(true);
          stage.id = 'ft-av-stage';
          stage.style.cssText += ';position:fixed !important;left:auto !important;top:auto !important;right:20px;bottom:20px;z-index:2147483000;';
          document.body.appendChild(stage);
          var r = stage.getBoundingClientRect();
          var inner = stage.firstElementChild;
          var cs = inner ? getComputedStyle(inner) : null;
          return JSON.stringify({
            count: es.length, x: r.left, y: r.top, w: r.width, h: r.height,
            maskSize: cs ? (cs.webkitMaskSize || cs.maskSize) : '',
            maskImage: cs ? (cs.webkitMaskImage || cs.maskImage || '').slice(0, 24) : '',
            bg: cs ? cs.backgroundColor : ''
          });
        })()
        """) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let x = obj["x"] as? Double, let y = obj["y"] as? Double,
                  let w = obj["w"] as? Double, let h = obj["h"] as? Double else {
                AppDelegate.log("头像截图: 页面里没有用户头像元素")
                return
            }
            AppDelegate.log("头像截图: \(obj["count"] ?? 0) 个 · 几何 \(Int(w))x\(Int(h))@\(Int(x)),\(Int(y)) · maskSize=\(obj["maskSize"] ?? "") · mask=\(obj["maskImage"] ?? "") · bg=\(obj["bg"] ?? "")")
            let pad = 14.0
            let c2 = WKSnapshotConfiguration()
            c2.rect = CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: h + pad * 2)
            c2.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 8))
            self.writeSnapshot(wv, c2, to: "/tmp/ft-avatar.png", label: "头像特写") {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-av-stage');if(e)e.remove();})()") { _, _ in }
            }
        }
    }

    private func writeSnapshot(_ wv: WKWebView, _ cfg: WKSnapshotConfiguration, to path: String,
                              label: String, done: (() -> Void)? = nil) {
        wv.takeSnapshot(with: cfg) { image, error in
            defer { done?() }
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                AppDelegate.log("截图自检[\(label)]: 失败 \(error?.localizedDescription ?? "无图")")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                AppDelegate.log("截图自检[\(label)]: 已写 \(path) (\(png.count) 字节)")
            } catch {
                AppDelegate.log("截图自检[\(label)]: 写盘失败 \(error.localizedDescription)")
            }
        }
    }

    // 简单日志，写到 ~/.dsh/logs/fatiaowu-app.log 方便排查
    static func log(_ message: String) {
        let path = "/Users/yangliu/.dsh/logs/fatiaowu-app.log"
        let line = "[\(Date())] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        handleLoadFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        handleLoadFailure()
    }

    private func showServerDownAlert() {
        retryTimer?.invalidate()
        retryTimer = nil
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "发条屋服务未启动"
        alert.informativeText = "等了很久还是没有连上 DeepSeek Harness 服务。请确认后台服务已开启（登录系统后它会自动运行），然后重新打开「发条屋」。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true // 关掉窗口即退出
    }

    // 全屏/窗口尺寸变化后，WKWebView 偶发渲染陈旧（DOM 正确但画面是旧的），强制重绘
    @objc private func forceRepaint(_ note: Notification) {
        repaintWorkItem?.cancel()
        let delay: Double = (note.name == NSWindow.didResizeNotification) ? 0.4 : 1.0
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.setNeedsDisplay(wv.bounds)
            wv.evaluateJavaScript("""
            (function(){
              try {
                window.dispatchEvent(new Event('resize'));
                var b = document.body;
                if (b) {
                  b.style.display = 'none';
                  requestAnimationFrame(function(){ b.style.display = ''; });
                }
              } catch (e) {}
            })()
            """) { _, _ in }
        }
        repaintWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // ================= 内置浏览器 =================
    // 会话里点外部链接时，在本 App 内开一个浏览器窗口，而不是干等着不动。

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // 只拦截主会话窗口的链接点击；内置浏览器窗口内自由导航
        if webView !== self.webView {
            decisionHandler(.allow)
            return
        }
        let isLinkClick = navigationAction.navigationType == .linkActivated
        let isNewWindow = navigationAction.targetFrame == nil
        if isLinkClick || isNewWindow {
            let isDSH = (url.host == "127.0.0.1" || url.host == "localhost") && (url.port == 3080 || url.port == nil)
            if !isDSH {
                if url.scheme == "http" || url.scheme == "https" {
                    openInBuiltInBrowser(url)
                } else {
                    NSWorkspace.shared.open(url) // mailto: 等交给系统
                }
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // JS 打开的链接（window.open / target=_blank）：交给内置浏览器
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            openInBuiltInBrowser(url)
        }
        return nil // 不创建新 webview，直接打开内置浏览器
    }

    private func openInBuiltInBrowser(_ url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let rect = NSRect(x: 0, y: 0, width: 1080, height: 720)
            let win = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = url.host ?? "浏览"
            win.center()

            // 顶部小工具条：后退 / 前进 / 刷新 / 用默认浏览器打开
            let back = NSButton(title: "←", target: nil, action: nil)
            let forward = NSButton(title: "→", target: nil, action: nil)
            let reload = NSButton(title: "⟳", target: nil, action: nil)
            let external = BrowserOpenButton(title: "用默认浏览器打开", target: nil, action: nil)
            for b in [back, forward, reload, external] { b.bezelStyle = .rounded }

            let browser = WKWebView(frame: rect)
            browser.allowsBackForwardNavigationGestures = true

            back.target = browser
            back.action = #selector(WKWebView.goBack(_:))
            forward.target = browser
            forward.action = #selector(WKWebView.goForward(_:))
            reload.target = browser
            reload.action = #selector(WKWebView.reload(_:))
            external.onOpen = { [weak browser] in
                guard let browser, let url = browser.url else { return }
                NSWorkspace.shared.open(url)
            }

            let toolRow = NSStackView(views: [back, forward, reload, external])
            toolRow.orientation = .horizontal
            toolRow.spacing = 6
            toolRow.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

            let stack = NSStackView(views: [toolRow, browser])
            stack.orientation = .vertical
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            win.contentView = stack
            NSLayoutConstraint.activate([
                toolRow.heightAnchor.constraint(equalToConstant: 36),
            ])

            self.browserWindows.append(win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            browser.load(URLRequest(url: url))
        }
    }

}

// 入口：main.swift 顶层代码运行在主线程，这里明确切到主 actor
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
