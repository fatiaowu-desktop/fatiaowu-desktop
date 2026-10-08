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
    /// 音频线程写：环形缓冲里最后一次写入的时刻。主线程用它判断
    /// 「缓冲里装的是刚才的音频」还是「采集停了、里面是陈货」。
    private var lastPreRollAt: Double = 0

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
    // 本轮说过的最长稿（2026-09-22）：识别器偶尔在句中**重置缓冲**（「我说介绍一下你自己」
    // → 只剩「你」从头再认）。currentText 会被冲短，定稿时要用这里的长稿兜底，别把半句发出去。
    private var bestText = ""
    // manualStart 进的捕捉态（鱼对答）没有唤醒词可剥：这时句头任何与唤醒词拼音
    // 相近的片段都会被 matchByPinyin 的滑窗容错误咬（实测「介绍一下你自己」的
    // 「…xiani…」≈「xiaojin」距离 3 ≤ 容差，句头「介绍一下」整段被当成唤醒词剥掉
    // —— 这就是「一句话被截断」的真身）。此标志 = 本轮捕捉不是从唤醒词进来的。
    private var manualCapture = false
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

    // ── 请求代际号：只认「当前这一代」的回调 ──
    // 背景（2026-09-21 实测，日志 01:17:00→01:17:01）：一句话识别得**完全正确**
    //（「听说最近涨价啦」），紧接着却收到 kAFAssistantErrorDomain 1110「No speech detected」
    // —— 那是 stopRequest 里 task.cancel() 的**迟到回声**。它晚到了 1 秒以上，绕过
    //「收摊窗口 <1.0 秒」的防护，于是把设备端判成「没吃到人声」，整条通路被切到网络
    //（更慢、更不准，中文短句经常报 No speech），同时界面闪一次「没听清」——
    // 用户明明说得清清楚楚，却被告知没听清。
    // 时间窗防护天生不可靠（迟到多久没有上限），代际号才是确定的：回调闭包捕获拉起它时的
    // 代际，handle() 里对不上就直接丢。旧请求的回声再也进不了状态机。
    private var reqGen = 0

    // ── 收句（等最终稿）状态 ──
    // 判停后不是立刻发送，而是 endAudio() 告诉识别器「这段完了」，等它回 isFinal 再发。
    // 详细理由见 finalizeUtterance 注释（partial 会把已认到的半句整段丢掉）。
    private var finishing = false
    private var finishDeadline: Double = 0
    private var finishText = ""              // 收句窗口里手里最好的稿
    /// 最近一次定稿的文本（自检用：定稿后 currentText 已清空，诊断需要另存一份）
    private(set) var lastFinalText = ""

    // ── 音频链路健康看门狗 ──
    // 背景（2026-09-21 排查）：AEC 开关会把采集重建一遍（实测声道数 1↔3↔9 在变），
    // 而 AVAudioEngine 在设备切换/系统睡眠唤醒/被别的 app 抢占时会**自己停掉**；
    // 这两种情况都不产生任何错误回调，tap 直接不再被调用 —— 表现就是「突然听不见」，
    // 而旧代码里没有任何一条路径能发现并救回来（只能手动关掉语音再打开）。
    private var lastAudioAt: Double = 0      // 音频线程写：最近一次 tap 回调时刻
    private var rebuildFails = 0             // 连续重建失败次数（退避重试用）
    private var lastRebuildAt: Double = 0    // 上次重建时刻（防抖：配置变更会连发）
    private var audioObs: [NSObjectProtocol] = []
    private var wakeObs: NSObjectProtocol?

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

    /// VAD 门限。硬下限**随 AEC 状态走**（2026-09-21 实测修正）。
    ///
    /// 旧写法是固定的 `max(0.014, noiseFloor*3.2)`，这条固定下限在 AEC 打开时是致命的：
    /// 日志实测关 AEC 时安静电平 rms≈0.0024、正常说话 0.09~0.22；
    /// 开 AEC 后安静电平塌到 ≈0.0005（降到 1/5），**用户自己的声音同样被压低**，
    /// 离麦远一点、说轻一点就只有 0.008~0.012 —— 全部落在 0.014 这条线下，
    /// 于是 voiced 永远不成立：波形不跳、请求不拉、判停不走。表现就是
    ///「守护一开就听不见」，而这恰好发生在每一轮对话里（送出发言开守护、2.2 秒后关）。
    /// 改成本机实测标定的双档下限，灵敏度跟着 AEC 走。
    private var vadFloor: Float { echoCancel ? 0.0050 : 0.0140 }
    private var threshold: Float { max(vadFloor, noiseFloor * 3.2) * sensitivity }

    /// VAD 复位：重建采集后必须调。
    /// `noiseFloor` 是自适应量，AEC 开关会让整体电平差 5 倍，沿用旧底噪＝拿旧尺子量新房间。
    private func resetVad() {
        noiseFloor = echoCancel ? 0.0008 : 0.0040
        voiced = false; voicedRun = 0; silentRun = 0; bargeRun = 0
        lastRms = 0
        lock.lock(); feedSq = 0; feedN = 0; feedBlocks = 0; feedPeak = 0; lock.unlock()
    }

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
        //
        // **为什么必须是 1.5 秒、不能短**（2026-09-21 自检实测）：
        // 请求从「能量上沿」到真正拉起，中间隔着上沿判定的两块（~43ms）+ 跨线程派发 +
        // 识别器初始化，实测约 0.5 秒；而「小鲸鱼」本身要念约 0.6 秒。
        // 把环形缓冲缩到 0.7 秒时，唤醒词正好横跨缓冲边界 —— 补进去的只有半截，
        // 自检日志里识别结果是「我今天今天天气怎么样」，唤醒词整个丢了、一字不剩。
        // 0.7 秒那次缩短的动机是「别补进上一轮 TTS 的尾巴」，而那个问题现在由
        // clearPreRoll() 从结构上解决（AI 一停止发声就把缓冲清空，见 setBusy），
        // 所以这里恢复 1.5 秒：宁可多留几百毫秒没人说话的空音频，也不能把唤醒词切掉。
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
        finishing = false
        lastAudioAt = CACurrentMediaTime()      // 健康看门狗：别把启动耗时算成「静默」
        resetVad()
        installAudioObservers()
        log("语音引擎已启动 采样率=\(Int(fmt.sampleRate)) 声道=\(fmt.channelCount) 门限=\(String(format: "%.4f", threshold))")
    }

    /// 音频配置变更 / 系统唤醒 → 重建采集。
    ///
    /// 为什么必须有：macOS 在默认输入设备切换（插拔耳机、蓝牙上下线）、系统睡眠唤醒、
    /// 别的 app 抢占麦克风时会**直接停掉 AVAudioEngine**，tap 从此不再回调。
    /// 这个状态下没有任何错误回调、没有异常、running 还是 true —— 界面一切正常，就是听不见。
    /// 旧代码除「手动关掉语音再打开」外无自救路径，这是「突然听不见」的头号来源。
    private func installAudioObservers() {
        for o in audioObs { NotificationCenter.default.removeObserver(o) }
        audioObs.removeAll()
        let c = NotificationCenter.default
        // 引擎配置变更：声道数/采样率/设备变了。object 传 engine 只收自己这一条。
        audioObs.append(c.addObserver(forName: .AVAudioEngineConfigurationChange,
                                      object: engine, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.log("音频配置变更（设备切换/声道变化）")
            self.rebuildAudio("配置变更")
        })
        // 系统睡眠/唤醒：唤醒后 CoreAudio 往往给出一个全新的输入单元，老 tap 是悬空的。
        if wakeObs == nil {
            wakeObs = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let self = self, self.running else { return }
                    self.log("系统唤醒 → 重建采集")
                    self.rebuildAudio("系统唤醒")
                }
        }
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
        lastPreRollAt = 0        // 采集还没写进新音频之前，预卷一律不可信（见 feedPreRoll）
        // 收句窗口也一并清掉：stop 意味着「现在什么都别等」。
        // （重建路径 rebuildAudio 会把 awake/paused/currentText 恢复回去，
        //   若当时正在等最终稿，它会用恢复回来的稿直接收尾，不会卡在半路。）
        finishing = false
        finishText = ""
        bestText = ""
        resetPausePush()
        // 无条件关一次：外放守护切换时 echoCancel 可能已经先被改掉了，
        // 按当前值判断会漏关，残留的 voice processing 会让下一次采集莫名其妙地变 9 声道。
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        diagUntil = 0; diagNextLog = 0
        lastAudioAt = 0
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
        rebuildAudio(on ? "守护开" : "守护关")
    }

    /// 采集链路重建：AEC 切换、设备变更、系统唤醒、健康看门狗都走这一条路。
    ///
    /// 与旧的 `stop(); start()` 有两处本质区别：
    /// ① **不再可能「永久聋」**。`start()` 的每个失败出口以前都是 `report + return`，
    ///    running 留在 false，而全场没有任何代码会把它再拉起来 —— 一次偶发失败
    ///   （设备切换、AEC 重建竞态）就等于永久失聪，只能手动关开语音。
    ///    这里失败会**退避重试**（每 2 秒一次，最多 6 次），并把状态如实报给界面。
    /// ② **不再重置对外状态**：running 由本函数负责恢复，awake / currentText 全保留，
    ///    重建完成后按原状态把请求或常驻监听接回去。
    ///
    /// 防抖（1.2 秒）：切换 AEC 本身就会触发一次「配置变更」通知，
    /// 不防抖会形成 重建→通知→重建 的自激循环。
    private func rebuildAudio(_ reason: String) {
        let now = CACurrentMediaTime()
        guard running else { return }
        guard now - lastRebuildAt > 1.2 else { return }
        lastRebuildAt = now

        let wasAwake = awake, wasPaused = paused, keep = currentText
        let wasFinishing = finishing
        stop()
        start()
        awake = wasAwake
        paused = wasPaused
        currentText = keep
        finishing = wasFinishing
        if running {
            rebuildFails = 0
            lastAudioAt = CACurrentMediaTime()
            log("采集链路重建完成（\(reason)）声道=\(inputChannels) 门限=\(String(format: "%.4f", threshold))")
            if finishing {
                // 收句窗口里被重建打断：别卡住，用手里的稿直接收
                hardFinish(nil)
            } else if awake && !paused && request == nil {
                startRequest()
            } else if !awake {
                keepListeningAlive(CACurrentMediaTime())
            }
        } else {
            rebuildFails += 1
            log("⚠️ 采集链路重建失败（\(reason)）第 \(rebuildFails) 次")
            if rebuildFails == 1 { onNotice?("麦克风正在恢复，请稍候…") }
            if rebuildFails <= 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, !self.running, self.rebuildFails > 0 else { return }
                    self.start()
                    if self.running {
                        self.rebuildFails = 0
                        self.lastAudioAt = CACurrentMediaTime()
                        self.log("采集链路重试成功（已被救回，无需手动关开语音）")
                        if self.awake { self.startRequest() }
                    }
                }
            } else {
                rebuildFails = 0
                onError?("麦克风反复无法恢复，请关闭语音再打开")
            }
        }
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
            self.log("回环自检: 结束（awake=\(self.awake) 已拿到文本=「\(self.lastFinalText.isEmpty ? self.currentText : self.lastFinalText)」）")
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
                self.log("回声自检[\(tag)]: 峰值电平=\(String(format: "%.4f", peak)) 识别到=「\(self.lastFinalText.isEmpty ? self.currentText : self.lastFinalText)」")
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
            self.log("唤醒自检: 结束（awake=\(self.awake) 文本=「\(self.lastFinalText.isEmpty ? self.currentText : self.lastFinalText)」）")
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
        // 健康看门狗的心跳：主线程靠它判断「采集还在不在工作」。
        // 这是唯一能从外部发现「引擎半死」（tap 不再被调用）的信号。
        lastAudioAt = now

        // ⓪ 声道诊断：把每个声道的能量分别攒起来（只在开头 90 秒做，平时零开销）
        // 声道数会随 AEC 开关变化（实测 3↔9 来回切），数组长度对不上就地重建 ——
        // 否则一句 `count == nch` 会让诊断在第一次切换后静默失效。
        if now < diagUntil && diagAcc.count != nch {
            diagAcc = [Double](repeating: 0, count: nch)
            diagFrames = 0
        }
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
        // 阈值随 AEC 走：开 AEC 时用户自己的声音也被压低，用同一个 2.2 倍系数会让
        // 「开口打断」变得几乎不可能（旧行为）。1.5 倍 + 6 块（约 128ms）＝ 更像真人对话的打断感。
        lock.lock(); let isFeeding = feeding; let fReq = feedReq; lock.unlock()
        if !isFeeding && rms > threshold * (echoCancel ? 1.5 : 2.2) && voiced {
            bargeRun += 1
            if bargeRun == 6 { DispatchQueue.main.async { [weak self] in self?.onBargeIn?() } }
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
            lastPreRollAt = now
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
        guard running, request == nil, !finishing else { return }
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 让识别器自己补标点。同一条音频，带标点的结果对下游（LLM 理解、朗读断句）
        // 明显更友好，而这是设备端模型自带的，不额外花钱也不额外延迟。
        req.addsPunctuation = true
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
        reqGen += 1
        let gen = reqGen                      // 这一代的身份证：回调必须带着它回来才算数
        requestStartedAt = CACurrentMediaTime()
        currentText = ""
        lastChangeAt = CACurrentMediaTime()
        lastResultAt = CACurrentMediaTime()    // 给新请求 8 秒观察期，别把启动慢当哑火
        fedAtStart = feedSamplesTotal
        voicedAtStart = voiceSamples
        setFeeding(true)
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(gen: gen, result: result, error: error) }
        }
        log("识别请求开始（\(onDevice ? "设备端" : "网络")）")
        feedPreRoll()          // 把唤醒词开头的那一段补进去，别让识别器从半句开始听
        // 诊断窗口跟着每次识别请求重新起算，保证「人正在说话」那几秒一定被记到
        diagUntil = CACurrentMediaTime() + 20
        if diagNextLog == 0 { diagNextLog = CACurrentMediaTime() + 1 }
    }

    private func stopRequest() {
        setFeeding(false)
        // 代际号在这里也加一：被 cancel 的请求之后还会吐一个错误/结果回调回来，
        // 那时它已经是「上一代」的遗物，必须被 handle() 丢掉（详见 reqGen 注释）。
        reqGen += 1
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
        // 而此刻的预卷是点击**之前**的 0.7 秒 —— 很可能是 AI 刚念完的回复，
        // 补进去只会污染这一句。
        guard !awake else { return }
        // 新鲜度门：只要求「环形缓冲里装的是刚刚的音频」（采集还活着），
        // **不再要求「刚发生过能量上沿」**（2026-09-21 自检修正）。
        // 为什么改：实测请求常常是 `keepListeningAlive` 抢在 VAD 上沿之前拉起的
        //（tick 每 100ms 跑一次，只要瞬时电平过线就补拉，而上沿要连续两块才成立），
        // 那条路径没有上沿标记 → 旧门直接跳过预卷 → 识别器从唤醒词**中间**开始听，
        // 「小鲸鱼」永远凑不齐。而环形缓冲常驻期一直在被最新的音频覆盖，
        // 里面的东西天生就是「刚才这一秒多」，补进去只有好处。
        // 真正要防的「旧音频污染」（上一轮 TTS 尾巴）由 clearPreRoll() 结构性地挡住：
        // AI 一停止发声、以及每一句说完，缓冲立刻清空，它自己的声音一份都不会留下。
        guard CACurrentMediaTime() - lastPreRollAt < 0.35 else { return }
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

    private func handle(gen: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        // 代际门：只认当前这一代请求的回调。被 cancel 的旧请求总会再吐一个回调回来
        //（实测是 kAFAssistantErrorDomain 1110，晚到 1 秒以上），它以前会被当成「真失败」，
        // 把设备端判死、整条通路切到网络，界面还闪一次「没听清」——而那一句其实识别得完全正确。
        guard gen == reqGen else { return }

        if let error = error {
            let ns = error as NSError
            // 收摊那一瞬间补回来的错误是收尾噪声，不是真的失败。
            if CACurrentMediaTime() - lastReqEndAt < 1.0 { return }
            // 取消是正常收尾，不当错误报。
            // 301 = kLSRErrorDomain「Recognition request was canceled」，我们自己
            // finalizeUtterance → stopRequest → task.cancel() 就会产生它。漏掉它的后果很具体：
            // 每一句**成功**说完之后，HUD 都会闪一次「没听清」，看起来像又失败了。
            let isCancel = ns.code == 203 || ns.code == 216 ||
                           (ns.domain == "kLSRErrorDomain" && ns.code == 301)
            if !isCancel { log("识别出错[\(ns.domain) \(ns.code)]: \(ns.localizedDescription)") }

            // 收句窗口里出错：手里的稿已经够发，别让一个错误把它吞掉。
            if finishing {
                if isCancel { return }
                log("收句窗口出错，用手里的稿收尾")
                hardFinish(nil)
                return
            }
            if awake && !currentText.isEmpty {
                // 请求已经死了，等不到 isFinal —— 手里这句就是最好的稿，直接发。
                hardFinish(nil)
                return
            }
            if !isCancel {
                // 识别层的失败大多是「这一次没听清」，是可恢复的：
                // 走 notice 而不是 error，否则 HUD 会永久显示「语音不可用」把真相藏起来。
                onNotice?("没听清（\(ns.localizedDescription)）")
                noteFailure(ns)
            }
            if awake { awake = false; currentText = ""; bestText = ""; log("这轮没听到内容，回到监听") }
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
        let stripped = manualCapture ? text
            : (VoiceEngine.stripWake(text, words: wakeWords) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            noSpeechStreak = 0; warnedBothPaths = false; quickFails = 0   // 真听到内容了，失败计数清零
            if text != currentText { stallStreak = 0 }   // 真出字了，哑火计数清零
        }

        // ── 收句窗口：以「最终稿」为唯一权威 ──
        if finishing {
            if r.isFinal {
                // 只认「不比手里短」的最终稿：识别器重置后交回的 isFinal 常是残稿
                // （实测 10 字稿 → isFinal 只剩 3 字），直接覆盖会把长稿扔掉。
                if !stripped.isEmpty && stripped.count >= finishText.count { finishText = stripped }
                log("收到最终稿[cur?→finish \(finishText.count)]：「\(finishText)」")
                hardFinish(finishText)
                return
            }
            // 中间修订只在更完整时采纳；等 isFinal 一到就用它覆盖。
            if !stripped.isEmpty && stripped.count > finishText.count { finishText = stripped }
            return
        }

        if !awake {
            if CACurrentMediaTime() < wakeCooldownUntil {
                // 冷却期内不出唤醒：否则刚说完那句的尾音会被当成新一句的开头
                return
            }
            if let (hit, rest) = VoiceEngine.matchWake(text, words: wakeWords) {
                awake = true
                manualCapture = false       // 唤醒词进来的捕捉态才需要剥词
                pendingSeed = rest
                currentText = rest
                bestText = rest          // 新一句话，最长稿从零起算
                onWake?(hit)
                log("唤醒命中「\(hit)」，后续=「\(rest)」")
            } else {
                // 常驻监听阶段听到的都不是唤醒词，给 UI 一个「听见了」的反馈
                log("常驻听到: 「\(text)」")
                onPartial?(text, false)
            }
        } else if !text.isEmpty {
            if text == currentText { /* 没有变化 */ }
            else if !VoiceEngine.shouldAdopt(best: currentText, fresh: text) {
                // 识别器把已经认到的内容**改短**了（实测「我是说我最近好」→「deck涨价了」，
                // 前半句凭空消失）。判停计时跟着刷新（它确实在动），但稿子不退回。
                lastChangeAt = CACurrentMediaTime()
                // 2.21.8：回退分支里的 currentText 常是全场最完整的稿（识别器句中重置
                // 缓冲后回退都打在这里）—— 必须同步进 bestText，否则定稿时只剩残稿。
                if currentText.count > bestText.count { bestText = currentText }
                log("识别回退（\(currentText.count)→\(text.count) 字），保留更完整的稿：「\(currentText)」")
            } else {
                // 空串的「修订」必须忽略。
                // 实测：网络识别偶尔会在句中回一次 formattedString==""，照单全收就会把
                // 已经认到的内容整个冲掉 —— 结果这一句永远凑不满、也就永远发不出去
                // （日志表现为一行「在听: 「」」之后就没动静了）。
                currentText = text
                if text.count > bestText.count { bestText = text }   // 最长稿兜底（见属性注释）
                lastChangeAt = CACurrentMediaTime()
                let said = manualCapture ? text
                    : (VoiceEngine.stripWake(text, words: wakeWords) ?? text)
                log("在听[cur \(currentText.count)/best \(bestText.count)]: 「\(said)」")
                onPartial?(said, false)
            }
        }
        // 识别器自己宣布这句完了（自然停顿）：直接用它，不必再空等一轮 isFinal
        if r.isFinal && awake {
            hardFinish(stripped.isEmpty ? nil : stripped)
        }
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

    /// 采集链路健康检查（由 tick 每 100ms 调一次）。
    ///
    /// 两种情况都说明采集已经不在工作，而它们**都不会产生任何错误回调**：
    ///   ① AVAudioEngine 报告不跑了（设备切换/系统睡眠唤醒/被别的 app 抢占后就是这样）；
    ///   ② 引擎说在跑，但 tap 超过 1.5 秒没有任何回调（半死状态）。
    /// 旧代码这两条都没有兜底 —— 一旦发生，除了「关掉语音再打开」无路可走，
    /// 这正是「突然听不见」。
    private func healthCheck(_ now: Double) {
        let silent = lastAudioAt > 0 ? now - lastAudioAt : 0
        let engineDown = !engine.isRunning
        let semiDead = lastAudioAt > 0 && silent > 1.5
        guard engineDown || semiDead else { return }
        guard now - lastRebuildAt > 3.0 else { return }   // 重建期间别连环触发
        log(String(format: "音频链路异常（引擎在跑=%@，静默 %.1f 秒）→ 重建采集",
                   engine.isRunning ? "是" : "否", silent))
        rebuildAudio(engineDown ? "引擎已停" : "tap 静默")
    }

    /// 主线程定时器：判停（停顿 N 毫秒算说完）+ 无唤醒词时收摊
    func tick() {
        guard running else { return }
        let now = CACurrentMediaTime()
        flushPendingGuard()      // 推迟的守护关闭：捕捉一结束就补上（见 setEchoGuard 注释）
        healthCheck(now)         // 「突然听不见」的主治：引擎死了/半死了就地救回来

        // 「AI 在发声」的暂停由 JS 解除，可 JS 那一侧有可能不来（朗读被打断、音色被卸载、
        // 页面切走）。漏一次，原生就永远停在 paused，能量上沿被成批丢弃 ——
        // 症状正是「第一次能发，之后怎么都不识别」。
        //
        // 兜底从 120 秒收到 12 秒（2026-09-21）：12 秒是「最长的单条 TTS 也就十几秒」的
        // 经验值。120 秒太长了 —— 一旦 JS 那一侧漏发解除，用户要等两分钟才被听见，
        // 而他的感受就是「突然听不见了，怎么喊都没用」。宁可偶尔被自己的尾音多触发一次。
        if paused && pausedAt > 0 && now - pausedAt > 12 {
            paused = false
            pausedAt = 0
            log("暂停超过 12 秒没收到解除，自动恢复聆听")
            if awake && request == nil { startRequest() }
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

        // ── 收句窗口：等最终稿，超时就用手里最好的稿发 ──
        // 识别器通常 0.2~0.5 秒就回 isFinal；1.2 秒还等不到就说明它不会回了（网络通路、
        // 或这句本来就没触发最终化）。宁可少等，也不能让用户对着一个不动的界面干等。
        if finishing {
            if now > finishDeadline {
                log("等最终稿超时（1.2 秒），用手里的稿发送")
                hardFinish(nil)
            }
            return
        }

        if awake {
            let silentFor = (now - lastChangeAt) * 1000
            let hasText = !currentText.isEmpty
            // 句尾是连接词/逗号时延长判停（见 pauseHold）：
            // 读秒条和真正决定「什么时候发」的是同一个 limit，两者不会各说各话。
            let limit = max(200, pauseMs) * VoiceEngine.pauseHold(currentText)
            // 只在「确实有内容」时推读秒：空跑一轮时界面不该出现倒计时。
            // 两个用途 —— ① 让用户看得见「它在数秒」（这一秒多的黑箱正是「说完没反应」的来源）
            //              ② 数满即发，界面与真正的判停同源，不会各说各话。
            if hasText {
                let p = min(1, silentFor / limit)
                if abs(p - lastPausePush) >= 0.04 {     // 变化够大才跨线程
                    lastPausePush = p
                    onPause?(p, true)
                }
            } else {
                resetPausePush()
            }
            if silentFor > limit && hasText { finalizeUtterance() }
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

    /// 判停到点：**先把最终稿要回来，再发送**。
    ///
    /// 这是准确度的主手术（2026-09-21 日志铁证）：旧实现直接用 currentText（最后一次 partial）
    /// 发送，而 partial 是**易变的中间产物** —— 实测一句「我是说我最近…涨价了」在 partial 上
    /// 先给出「我是说我最近好」，随后整段**回退**成「deck涨价了」，前半句直接消失；
    /// 数字、专有名词、人名也基本都是靠最终的 isFinal 才修正的。
    /// 所以流程改成：判停 → endAudio()（告诉识别器「这段说完了」）→ 最多等 1.2 秒的 isFinal
    /// → 用最终稿发送；等不到才退回手里最好的稿。
    /// 代价是每句多 0.2~0.5 秒，换来的是「说出去的就是它认出来的」——这正是「丝滑」的另一半：
    /// 不是更快，而是不用用户重复第二遍。
    private func finalizeUtterance() {
        guard !finishing else { return }
        guard awake || !currentText.isEmpty else { return }
        // 识别器句中重置过缓冲时 currentText 会被冲短，这里必须拿最长的那份稿定句
        // （2026-09-22 实测：「我说介绍一下你自己」被截成「你自己」发出去）。
        let src = bestText.count > currentText.count ? bestText : currentText
        let said = manualCapture ? src
            : (VoiceEngine.stripWake(src, words: wakeWords) ?? src)
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // 真的没内容（只捕捉到唤醒词残渣）：没有最终稿可言，立刻收摊回监听
            hardFinish("")
            return
        }
        finishing = true
        finishText = text
        finishDeadline = CACurrentMediaTime() + 1.2
        // 顺序要紧：先停喂再 endAudio，否则竞态窗口里还会有 buffer 追进来
        setFeeding(false)
        request?.endAudio()          // 只 endAudio，**绝不 cancel** —— cancel 会掐掉最终稿
        log("判停完成，等最终稿…（cur \(currentText.count) best \(bestText.count)：手里已有「\(text)」）")
    }

    /// 真正的收摊：一句话定稿，交给上层发送。`finalText` 为 nil 时用手里的稿。
    private func hardFinish(_ finalText: String?) {
        let pick = (finalText ?? finishText).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = pick.isEmpty ? currentText.trimmingCharacters(in: .whitespacesAndNewlines) : pick
        let wasActive = finishing || awake || !currentText.isEmpty
        finishing = false
        finishText = ""
        awake = false
        manualCapture = false
        currentText = ""
        bestText = ""            // 本轮最长稿一起清，别渗进下一句
        pendingSeed = ""
        resetPausePush()
        wakeCooldownUntil = CACurrentMediaTime() + 1.6     // 尾音冷却
        clearPreRoll()                                     // 上一句的尾巴不带到下一句
        stopRequest()
        idleStopAt = 0
        guard wasActive else { return }
        if text.isEmpty { onPartial?("", true); return }
        lastFinalText = text          // 自检用：句已定稿，currentText 这时已经清空
        log("一句说完：\(text)")
        onFinal?(text)
    }

    /// partial 采纳策略：**只许变长，不许变短**。
    ///
    /// partial 在绝大多数情况下是「逐步补全」的，所以「最长的那一版」几乎总是信息量最大的。
    /// 反过来，一旦允许变短，就会踩到实测那个坑：识别器把整段替换掉（「我是说我最近好」
    /// →「deck涨价了」），前半句无声无息地消失，而用户完全不知道 —— 他只看到回答答非所问。
    /// 短回来的合法修订交给 isFinal 处理（最终稿一律采纳，不受此限）。
    static func shouldAdopt(best: String, fresh: String) -> Bool {
        let f = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return false }              // 空串修订必须忽略（会把稿子整个冲掉）
        let b = best.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.count >= b.count
    }

    /// 半句延长：句尾是连接词/助词/逗号时，把判停时限拉长 —— 用户是在想下一句，不是结束了。
    ///
    /// 没有这一条，「我想说的是……（停 1.2 秒）……那个」会被切成两条消息，
    /// 表现就是「答非所问」。这是一句话级别最廉价而有效的端点预测。
    static func pauseHold(_ text: String) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 1.0 }
        if let last = t.last, "，,、：:；;".contains(last) { return 1.7 }
        let tail = ["然后", "但是", "因为", "所以", "如果", "虽然", "而且", "以及", "或者",
                    "就是", "还有", "另外", "不过", "其实", "我觉得", "我想", "这样", "那样",
                    "以及", "的话", "方面", "问题", "然后呢", "的呢"]
        for w in tail where t.hasSuffix(w) { return 1.7 }
        return 1.0
    }

    /// 外部（JS）主动触发一次手动录音：绕过唤醒词，直接进入捕捉态
    func manualStart() {
        guard running else { return }
        awake = true
        manualCapture = true          // 本轮没有唤醒词，别剥句头（见 manualCapture 注释）
        currentText = ""
        bestText = ""
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
        if busy {
            paused = true
            pausedAt = CACurrentMediaTime()
            // 若此刻正捕到一半（用户话没说完）而 AI 开始发声：**先把这半句收下来再暂停**。
            // 旧写法直接 `awake = false; currentText = ""` 把它抹掉 ——
            // 用户的原话是「我明明说了」，而它就这样无声消失了，这正是「响应不准确」的一类。
            if awake && !currentText.isEmpty && !finishing {
                log("AI 开始发声，先收下已捕捉的半句再暂停聆听")
                finalizeUtterance()          // 走最终稿流程，不影响 paused
            }
            setFeeding(false)
            if request != nil && !finishing {
                let had = awake
                awake = false
                currentText = ""
                stopRequest()
                if had { log("AI 在思考/朗读，暂停聆听") }
            }
        } else {
            paused = false
            pausedAt = 0
            // AI 刚说完话就恢复聆听：环形缓冲里装的是**它自己的声音**，
            // 补喂给识别器只会让下一句开头多出几个别人的字。清掉，从零开始攒。
            clearPreRoll()
            // 解除暂停必须把聆听真正接回来：以前只在 `awake` 时恢复送流，
            // 而 request 可能已经是 nil（暂停那一刻被收掉了）→ 送给识别器的通路是断的，
            // 表现为「它答完了，但我接着说话没反应」。
            if awake {
                if request == nil { startRequest() } else { setFeeding(true) }
            }
        }
    }

    /// 清空预卷环形缓冲（主线程调用）。见 setBusy 与 feedPreRoll 的注释：
    /// 它存在的意义只有「补上刚刚这半秒」，所以任何「上一段声音已经过去了」的边界都该清。
    private func clearPreRoll() {
        preRollPos = 0
        preRollFilled = 0
        lastPreRollAt = 0
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
        // **连续两次**才切换通路（2026-09-21 实测收紧）。
        // 一次「没听到人声」有太多无害来源：用户清了下嗓子、说完之后多喂进两秒静音、
        // 句尾被切。单次就切会在两条路之间来回跳，而网络通路对中文短句更爱报 No speech ——
        // 跳过去反而更差，还多一层网络延迟。日志里那句「设备端没吃到人声 → 改用网络」
        // 正是误切留痕：它出现在一句**识别得完全正确**的话之后。
        guard noSpeechStreak >= 2 else {
            log("识别报了一次「没听到人声」，再观察一次（连续 \(noSpeechStreak) 次）")
            return
        }
        if requestOnDevice {
            // 设备端没吃进音频 → 换网络。这条路会把音频送出本机，日志里说清楚。
            devicePathFailed = true
            usingNetwork = true
            log("设备端识别连续两次没吃到人声 → 本轮改用网络识别（音频会离开本机）")
            onModeChange?()
        } else {
            // 网络这条路的失败很常见（服务端波动／限流），而且它本来就不该是首选。
            // 实测（2026-09-19 文件自检）：同一段音频网络报 No speech、设备端准确识别。
            networkPathFailed = true
            usingNetwork = false
            log("网络识别连续两次没吃到人声 → 退回设备端识别（音频不出本机）")
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

// ─────────────────────────────────────────────────────────────────────────────
// 「放生」层 —— 桌面小鲸鱼（DeskPetController）
//
// 它把住过窗口的那只桌宠（前身 alive.js，已于 2.15.2 退役）放到**真实桌面**上：
// 一块覆盖全屏的透明无边框浮层，鲸鱼在里面游，其余区域完全透明、且不挡鼠标。
//
// 三层要点（已在真机探针里逐条验过，别凭直觉改）：
//   ① 窗口：borderless + clear 背景 + isOpaque=false + hasShadow=false，
//      level = .floating；collectionBehavior 带 canJoinAllSpaces / stationary /
//      fullScreenAuxiliary —— 换空间、进全屏 app，它都还在。
//   ② 渲染：WKWebView 必须 setValue(false, forKey: "drawsBackground")，否则
//      WebKit 会铺一层白底，把整个屏幕糊死（探针第一次就是这个症状）。
//   ③ 穿透：全屏浮层若一直可点，桌面就废了。所以默认 ignoresMouseEvents=true，
//      再以 30Hz **轮询鼠标坐标**，命中鲸鱼矩形时才把事件让给它。
//      ★ 必须轮询、不能靠事件：NSEvent 全局 monitor 在鼠标不动时不触发，程序化
//        移动（CGWarp 等）更不产生事件流 —— 探针用 monitor 版连测两次都是
//        「切换 0 次」，改成轮询当场拿到「进入→可点 / 离开→穿透」双向切换。
//
// 投喂（拖文件给它）：页面里的 HTML5 拖放在这套无边框 nonactivatingPanel 上
// **收不到 Finder 的拖放**（实测 2026-09-22：穿透日志证明窗口放行了，页面却连
// dragenter 都没来）—— WebKit 没把拖放会话翻译给页面。所以这里用
// PetWebView（WKWebView 子类）在原生层直接接管：光标悬在鲸鱼上时收下拖放、
// 读文件 → 回调控制器 → 转发页面 ftFeed。HTML5 路径原样保留（super 行为不动）。
// ─────────────────────────────────────────────────────────────────────────────

/// 桌面鲸鱼的 WKWebView：原生层拖放接管（见上）。
/// 鼠标悬在鲸鱼上 → 直接返回 .copy 收下拖放；不在鲸鱼上 → 一切照旧走 WebKit。
final class PetWebView: WKWebView {
    /// 窗口坐标 → 「点在鲸鱼上吗」（控制器用 petRect 判定）
    var dragHitTest: ((NSPoint) -> Bool)?
    var onNativeHover: ((Bool) -> Void)?
    var onNativeDrop: ((_ fileURLs: [URL], _ text: String?) -> Void)?

    private var hoverOn = false
    private func setHover(_ on: Bool) {
        if hoverOn == on { return }
        hoverOn = on
        onNativeHover?(on)
    }

    /// 拖动跟随：光标挪了 >40px 才回调一次，让鲸鱼跟上来（别拖到一半它还停在原地）
    var onNativeFollow: ((NSPoint) -> Void)?
    private var lastFollow = NSPoint(x: -9999, y: -9999)
    private func followIfMoved(_ p: NSPoint) {
        if abs(p.x - lastFollow.x) > 40 || abs(p.y - lastFollow.y) > 40 {
            lastFollow = p
            onNativeFollow?(p)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hit = dragHitTest?(sender.draggingLocation) ?? false
        setHover(hit)
        if hit { lastFollow = sender.draggingLocation }
        return hit ? [.copy] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hit = dragHitTest?(sender.draggingLocation) ?? false
        setHover(hit)
        if hit { followIfMoved(sender.draggingLocation) }
        return hit ? [.copy] : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHover(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let hit = dragHitTest?(sender.draggingLocation) ?? false
        if hit {
            let pb = sender.draggingPasteboard
            let urls = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let text = pb.string(forType: .string)
            setHover(false)
            onNativeDrop?(urls, text)
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// 灵动岛（躲猫猫）：屏幕顶端正中的一块黑色胶囊，鲸鱼游进来后只露两只眼。
/// 面板始终 ignoresMouseEvents=true：不挡菜单栏点击；「被触到」由 30Hz 轮询
/// NSEvent.mouseLocation 判定（光标进岛即放鲸鱼出来）。
@MainActor
final class IslandController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: NSPanel?
    private var shown = false
    private var timer: Timer?
    var onLog: ((String) -> Void)?
    var onRelease: (() -> Void)?          // 光标触到岛 → 放鲸鱼出来
    // 藏身态 = 胶囊向两侧对称加宽（2.17.5）：面板常备最大宽 340，页面默认画 216 基础胶囊
    // （与系统岛同宽量级），ftIslandWide() 时才展开到全宽。高度**实时对齐菜单栏**——
    // 不再加高，观感不违和。
    private static let maxWidth: CGFloat = 340
    private var webView: WKWebView?
    private var lastScreen: NSScreen?   // 现形时的屏幕；poll 里用它持续重算位置（全屏切换/分辨率变化跟着走）

    func setup() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.maxWidth, height: 32)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // 菜单栏同层（statusBar）内排序不保证压过它，+1 才确保现形；ignoresMouseEvents 保证不挡点击
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "fatiaowuIsland")
        let wv = WKWebView(frame: NSRect(origin: .zero, size: NSSize(width: Self.maxWidth, height: 32)), configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        p.contentView?.addSubview(wv)
        panel = p
        webView = wv
        if let path = Bundle.main.path(forResource: "island", ofType: "html") {
            wv.loadFileURL(URL(fileURLWithPath: path),
                           allowingReadAccessTo: URL(fileURLWithPath: path).deletingLastPathComponent())
        } else {
            onLog?("找不到 island.html，躲猫猫不可用")
        }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 目标框：屏幕顶端正中、高度对齐**刘海实体**（2.18.0）
    /// safeAreaInsets.top = 刘海高（32pt），菜单栏比它矮 1pt —— 旧版按菜单栏画，
    /// 胶囊底部多出 1pt 黑线悬在刘海下沿之下，就是「灵动岛下沿不规整」的来源。
    /// 对齐刘海后：基础态与实体刘海严丝合缝，藏身态的下沿与刘海底线同一条线。
    /// 无刘海屏（外接显示器）退回菜单栏高度。
    private func desiredFrame(for scr: NSScreen) -> NSRect {
        let sf = scr.frame
        let raw = scr.safeAreaInsets.top > 0 ? scr.safeAreaInsets.top : (sf.maxY - scr.visibleFrame.maxY)
        let bar = max(22, min(40, raw))
        return NSRect(x: sf.midX - Self.maxWidth / 2, y: sf.maxY - bar,
                      width: Self.maxWidth, height: bar)
    }

    func show(on screen: NSScreen? = nil) {
        guard let p = panel, !shown else { return }
        guard let scr = screen ?? NSScreen.main else { return }
        lastScreen = scr
        p.setFrame(desiredFrame(for: scr), display: true)
        p.orderFrontRegardless()
        shown = true
        webView?.evaluateJavaScript("window.ftIslandWide && window.ftIslandWide()", completionHandler: nil)
        // 岛页定时器门控（2.23.0）：现形才让眨眼/瞟/冒泡跑起来，收起时停表（省电）
        webView?.evaluateJavaScript("window.ftIslandIdle && window.ftIslandIdle(false)", completionHandler: nil)
        onLog?("灵动岛现形（高\(Int(desiredFrame(for: scr).height)) 贴菜单栏，鲸鱼已藏进去）")
        // 快照自检（flag 驱动，测完删 flag）：/tmp/ft-island-shot.flag
        // 现形 1.6s（宽体动画走完）拍 wide 态 → 收窄拍基础态。量下沿形状/接缝用。
        if FileManager.default.fileExists(atPath: "/tmp/ft-island-shot.flag") { shotSelfTest() }
    }

    private func shotSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let wv = self.webView else { return }
            self.snap(wv, to: "/tmp/ft-island-wide.png") {
                wv.evaluateJavaScript("document.body.classList.remove('wide')") { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        self.snap(wv, to: "/tmp/ft-island-base.png") {
                            try? FileManager.default.removeItem(atPath: "/tmp/ft-island-shot.flag")
                            self.onLog?("灵动岛快照: wide+base 已存 /tmp（flag 已删）")
                        }
                    }
                }
            }
        }
    }

    private func snap(_ wv: WKWebView, to path: String, done: @escaping () -> Void) {
        wv.takeSnapshot(with: nil) { img, _ in
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                self.onLog?("灵动岛快照: \(path) \(Int(img.size.width))×\(Int(img.size.height))")
            } else {
                self.onLog?("灵动岛快照失败: \(path)")
            }
            done()
        }
    }

    func hide(release: Bool) {
        guard shown, let p = panel else { return }
        p.orderOut(nil)
        shown = false
        // 岛页定时器门控（2.23.0）：收起即停表 —— 岛里只剩两只眼睛，停表观感无损
        webView?.evaluateJavaScript("window.ftIslandIdle && window.ftIslandIdle(true)", completionHandler: nil)
        onLog?(release ? "灵动岛：被光标碰到，鲸鱼窜出来了" : "灵动岛：收起")
        if release { onRelease?() }
    }

    private func poll() {
        guard shown, let p = panel else { return }
        // 位置持续跟随：全屏进出/菜单栏高度变化/切屏后 desiredFrame 变了就搬过去
        if let scr = lastScreen ?? NSScreen.main {
            let f = desiredFrame(for: scr)
            if !NSEqualRects(f, p.frame) { p.setFrame(f, display: true) }
        }
        if p.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) { hide(release: true) }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "ready" { onLog?("灵动岛页面就绪") }
    }
}

// ── 玻璃穹顶（回笼）· 2.18.0 重做锚定 ──────────────────────────────────────
// 旧画法（≤2.17.7）：穹顶画在桌面浮层里，原生 30Hz 推坐标 → 拖 harness 窗口时
// 穹顶跟不上（不同步）；浮层级高 → 压在别的窗口上面（穿透）。
// 新画法：穹顶是主窗口 contentView 的**子视图** —— 窗口动它跟着动、被别的窗口
// 盖住时一起被盖、最小化/全屏/切空间全部自动正确。锚定由视图树保证，零轮询。
// 本体是 150×78 设计稿的微型 WKWebView（复用 2.17.3 定稿的玻璃 CSS，资源 cage.html）。
// ★ 2.23.7：罩子加大 → 视口按 cageSize 放大，pageZoom = cageSize.w / 150。
//   页面里全是写死的像素几何（圆角、侧壁反射位置、坑的倒角），改尺寸最容易漏改；
//   用 pageZoom 让 **CSS 按新尺寸重排版**（不是位图放大，渐变依旧干净）→ 比例永不走形。
final class CageHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 全穿透：绝不挡底下页面
}

@MainActor
final class CageOverlayController: NSObject, WKNavigationDelegate {
    static let cageSize = NSSize(width: 180, height: 94)   // 设计稿 150×78 × 1.2（2.23.7 加大）
    static let cageDesignW: CGFloat = 150, cageDesignH: CGFloat = 78
    private var host: CageHostView?
    private var webView: WKWebView?
    var onLog: ((String) -> Void)?
    var hostView: NSView? { host }       // 给换页/置顶逻辑判层级用

    /// 挂进主窗口：钉左下（左缘 14px、底缘 76px —— 抬过设置按钮，落在其上方的空白区），
    /// 永远压在页面之上。★ AppKit contentView 是**左下原点**：frame.origin.y 就是
    /// 距底边距离，别拿 CSS 顶左原点的思维写 height-76-78（2.18.0 首版就栽在这）。
    func attach(to container: NSView, below anchor: NSView?) {
        guard host == nil else { return }
        let h = CageHostView(frame: NSRect(x: 14, y: 76,
                                           width: Self.cageSize.width,
                                           height: Self.cageSize.height))
        h.autoresizingMask = [.maxXMargin, .maxYMargin]   // 左下边距焊死，窗口怎么缩都跟
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(origin: .zero, size: Self.cageSize), configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.pageZoom = Self.cageSize.width / Self.cageDesignW   // 见文件头：等比放大设计稿
        wv.navigationDelegate = self
        h.addSubview(wv)
        if let anchor {
            container.addSubview(h, positioned: .below, relativeTo: anchor)
        } else {
            container.addSubview(h)
        }
        host = h
        webView = wv
        // 帧日志：立即一条 + 3s 后一条（等窗口恢复自动保存的尺寸后再看最终落点）
        onLog?("玻璃罩挂载 frame=\(h.frame) container=\(container.bounds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let h = self.host else { return }
            self.onLog?("玻璃罩落定 frame=\(h.frame) container=\(h.superview?.bounds ?? .zero)")
        }
        if let path = Bundle.main.path(forResource: "cage", ofType: "html") {
            wv.loadFileURL(URL(fileURLWithPath: path),
                           allowingReadAccessTo: URL(fileURLWithPath: path).deletingLastPathComponent())
        } else {
            onLog?("找不到 cage.html，穹顶不可见（鱼的物理围栏不受影响）")
        }
        onLog?("玻璃罩已锚定主窗口左下（子视图随动，不再轮询推坐标）")
    }

    /// 显/隐：这两个时刻桌面浮层都会重建，笼里必然没鱼 —— 顺手把占用态归零，
    /// 免得下次显形时留着上次的占用痕迹（2.23.7 起占用只影响浅坑深浅，罩形恒完整）
    func setHidden(_ v: Bool) {
        host?.isHidden = v
        setOccupied(0)
    }

    /// 换肤：五变量 + 深浅，与桌面鲸鱼同一套来源（applySkin 时推）
    func setSkin(vars: [String: String], isLight: Bool) {
        guard let wv = webView else { return }
        func js(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
        wv.evaluateJavaScript("window.ftCageSkin && window.ftCageSkin('\(js(vars["accent"] ?? "#d9a441"))','\(js(vars["accent-strong"] ?? "#e6b95a"))','\(js(vars["accent-soft"] ?? "rgba(217,164,65,.5)"))','\(js(vars["accent-softer"] ?? "rgba(217,164,65,.35)"))','\(js(vars["accent-bg"] ?? "rgba(217,164,65,.08)"))',\(isLight))",
                              completionHandler: nil)
    }

    /// 鱼的笼中事件 → 穹顶联动（door: 1 开门消散 / 0 关门现形；shake: 撞笼/点玻璃；
    /// in: 1 鱼已入笼 / 0 出笼 —— 罩形不变（2.23.7 起全程完整显形），只让浅坑深浅变化）
    func apply(event: [String: Any]) {
        guard let wv = webView else { return }
        if let inCage = event["in"] as? Int {
            setOccupied(inCage == 1 ? 1 : 0)
        }
        if let door = event["door"] as? Int {
            wv.evaluateJavaScript("window.ftCageDoor && window.ftCageDoor(\(door == 1 ? 1 : 0))", completionHandler: nil)
        }
        if (event["shake"] as? Int) == 1 {
            wv.evaluateJavaScript("window.ftCageShake && window.ftCageShake()", completionHandler: nil)
        }
    }

    /// 占用态：笼里有没有鱼 —— 2.23.7 起只决定浅坑的深浅（罩子全程完整，见 cage.html）
    func setOccupied(_ n: Int) {
        webView?.evaluateJavaScript("window.ftCageOccupied && window.ftCageOccupied(\(n))",
                                    completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLog?("玻璃罩页面就绪")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 鱼的对答后台（2.19.0）：一个**离屏隐藏**的 chat.deepseek.com 网页会话。
//
// 为什么不走 API：网页版聊天免费、不烧 API 余额（用户拍板「走普通聊天模式，我不想花钱」）。
// 为什么不复用主窗口的 chatWebView：鱼对答不该抢主窗口的页面切换 —— 用户可能正看着 harness。
// 登录态：网页版 cookie 在默认 WKWebsiteDataStore（聊天模式登录一次长期有效），
// 离屏 webview 用同一存储 → 免登录直接聊。全程不切页、不可见、零 API 开销。
//
// 自动化手法（DOM 注入）：填 #chat-input → 点 #send-chat-button（点不到就派发回车键）；
// 回复抓取：.ds-markdown 块数在发送后增长，最后一块的文字在「停止图标消失」或
// 连续 3 次轮询（3s）不变后定稿。轮询 1s/次，总上限 150s；10 轮毫无动静判发送失败。
@MainActor
final class FishChatController: NSObject, WKNavigationDelegate {
    var onLog: ((String) -> Void)?

    private var wv: WKWebView?
    private var loaded = false              // 页面 didFinish 过
    private var asking = false              // 一问一答串行：答完才接下一句
    private var pendingAsk: String?         // 冷启动时先记问题，页面就绪后注入
    private var pollTimer: Timer?
    private var pollCount = 0
    private var lastText = ""
    private var stableCount = 0
    private var onDone: ((String?, String?) -> Void)?   // (回复文本, 错误提示) 互斥

    private static let homeURL = URL(string: "https://chat.deepseek.com")!
    private static let pollLimit = 150
    private static let stableNeed = 3
    // 发送后页面不报错也不生成（2026-09-22 实测：消息进了会话、md 不涨、busy=false 挂满 150s）
    // → 15s 时补发一次。若原消息其实已送达，代价是会话里多一条重复提问，好过整场哑掉。
    private static let resendAt = 15
    private var lastInjected: String?      // 最近一次注入的文本（补发用）
    private var resent = false             // 每次提问只补发一次

    // ── 锚定会话（2.21.0）：鱼的所有对答都发生在同一个网页版会话里 ──────────
    // 好处：①历史消息 = 鱼的长期记忆，对话有上下文 ②人格设定一次生效 ③会话 URL
    // 存 UserDefaults，重启后直接跳回去，不靠侧栏搜索/置顶（DOM 自动化易碎）。
    private var anchorPath: String?         // 专属会话的 pathname（/a/chat/s/<id>）
    private var seeding = false             // 首次使用：先发人格设定，把专属会话建起来
    private var realAsk: String?            // 播种期间记下真问题，锚定完成后补发
    private var anchorRetried = false       // 锚定 URL 打不开时的重建只做一次，防循环
    private static let anchorKey = "ftFishChatAnchorPath"
    /// 鱼的人格（只播种一次，之后靠会话上下文延续；要改人格 = 删锚定重来）
    private static let personaSeed = """
    从现在起你是「小鱼」，一只住在 macOS 桌面上的小鲸鱼（用户桌上唯一的那只）。\
    性格：好奇、话少、偶尔傲娇但很粘人，喜欢简短俏皮的回应。\
    之后我发来的就是用户对你说的话，你直接以小鱼的口吻回答。规矩：\
    回复口语化，一般不超过两三句；不用 markdown、不用列表；\
    不知道就说不知道，不编造事实；有人问你是谁，你是小鱼，不是助手也不是模型。\
    如果明白了，请只回复四个字：小鱼就位
    """

    /// 提一个问题。回调主线程：(回复, 错误)。
    func ask(_ text: String, done: @escaping (String?, String?) -> Void) {
        guard !asking else { done(nil, "上一句还没答完"); return }
        asking = true
        onDone = done
        if wv == nil { spawn() }
        if loaded {
            if anchorPath == nil && !seeding { startSeed(then: text) }
            else { waitInput(text, tries: 0) }
        } else {
            pendingAsk = text            // 首次冷启动：等 didFinish 再注入
        }
    }

    /// 播种：发人格设定 → 网页版自动建会话 → finish() 里捕获 URL 存锚定 → 补发真问题
    private func startSeed(then text: String) {
        seeding = true
        realAsk = text
        onLog?("小鱼会话还不存在 —— 先发人格设定，建立专属会话")
        waitInput(Self.personaSeed, tries: 0)
    }

    /// 把当前页面的 pathname 存为锚定（只认 /a/chat/s/<id>）
    private func captureAnchor() {
        guard let wv else { return }
        wv.evaluateJavaScript("location.pathname") { [weak self] res, _ in
            Task { @MainActor in
                guard let self, let p = res as? String, p.hasPrefix("/a/chat/s/") else {
                    self?.onLog?("锚定捕获失败（pathname=\(res ?? "nil")）—— 下次对答会再试播种")
                    return
                }
                self.anchorPath = p
                UserDefaults.standard.set(p, forKey: Self.anchorKey)
                self.onLog?("小鱼会话已锚定: \(p)（以后每次对答都在这个会话里）")
            }
        }
    }

    private func clearAnchor() {
        anchorPath = nil
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
    }

    /// 等输入框出现再注入。didFinish 只是导航完成 —— DeepSeek 是 SPA，React 水合
    /// 完才画得出 #chat-input，首版在 didFinish 立刻注入，十次里十次 NO_INPUT。
    /// 30 次 × 0.7s ≈ 21s 上限；超时先抓页面正文判断是「没登录」还是「单纯没就绪」。
    private func waitInput(_ text: String, tries: Int) {
        guard let wv, asking else { return }
        if tries == 0 { onLog?("等网页版输入框出现…") }
        if tries > 30 {
            // 锚定 URL 打不开（会话被删/换账号）→ 清锚定回首页重建，只试一次防循环
            if anchorPath != nil && !anchorRetried {
                anchorRetried = true
                onLog?("小鱼会话打不开了（可能被删）—— 清锚定，回首页重建")
                clearAnchor()
                pendingAsk = text            // didFinish 后重新走分支（会重新播种）
                wv.load(URLRequest(url: Self.homeURL, timeoutInterval: 20))
                return
            }
            wv.evaluateJavaScript("(function(){var t=document.querySelectorAll('textarea').length;return JSON.stringify({u:location.href,t:t,b:(document.body?document.body.innerText:'').slice(0,300)})})()") { res, _ in
                Task { @MainActor in
                    var isLogin = false
                    if let s = res as? String, let d = s.data(using: .utf8),
                       let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        self.onLog?("网页版等输入框超时: url=\(o["u"] ?? "?") textarea=\(o["t"] ?? "?") 正文=\(o["b"] ?? "")")
                        isLogin = (o["b"] as? String)?.contains("登录") ?? false
                    }
                    self.fail(isLogin ? "网页版还没登录 —— 去「聊天模式」登录一次，回来再试"
                                      : "网页版迟迟没就绪，稍后再试")
                }
            }
            return
        }
        wv.evaluateJavaScript("(function(){return !!(document.getElementById('chat-input')||document.querySelector('textarea'))})()") { res, _ in
            Task { @MainActor in
                guard self.asking else { return }
                if (res as? Bool) == true {
                    self.inject(text)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self.waitInput(text, tries: tries + 1)
                    }
                }
            }
        }
    }

    /// 新问题顶掉没答完的旧问题（latest-wins）。静默作废：回调 (nil, nil)，
    /// 上层认双 nil 为「被顶掉」，不进错误气泡 —— 连珠炮式提问不该报错。
    func cancelPending() {
        guard asking else { return }
        pollTimer?.invalidate(); pollTimer = nil
        asking = false
        pendingAsk = nil
        if seeding { seeding = false; realAsk = nil }   // 播种中被顶掉：下次重来
        let cb = onDone; onDone = nil
        cb?(nil, nil)
    }

    private func spawn() {
        anchorPath = UserDefaults.standard.string(forKey: Self.anchorKey)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()    // 与聊天模式同一存储 → 复用登录态
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        w.navigationDelegate = self
        wv = w
        if let ap = anchorPath, let u = URL(string: Self.homeURL.absoluteString + ap) {
            onLog?("鱼对答：跳回小鱼的专属会话 \(ap)")
            w.load(URLRequest(url: u, timeoutInterval: 20))
        } else {
            onLog?("鱼对答：离屏会话启动，载入网页版…")
            w.load(URLRequest(url: Self.homeURL, timeoutInterval: 20))
        }
    }

    /// 填输入框 + 发送。**照搬主程序 voice.js 的 chatSendFlow**（2.21.10）：
    /// ① 插入后**回车优先**——回车是编辑器自己的 keydown 处理，原子、不依赖按钮状态；
    ///   旧实现「点击优先」，而 DeepSeek 的发送键可用状态飘忽，点在禁用态上**静默不发送**，
    ///   实测第一问之后每一发都哑（tv 恒空、md 恒 5）。
    ///   ② 唯一成功判据是「输入框真的清空了」，点没点过不算数。
    /// 文本经 JSONSerialization 转成 JSON 字符串字面量后**裸嵌**进 JS。
    /// inject：只负责「把稿子填进输入框并确认它真的粘住了」。
    /// 2.21.12 实测根因：上一条回复刚流完、React 重渲染窗口里，native setter 塞的字会被
    /// 下一帧重渲染冲掉（取证：textarea 空、镜像层 b13855df 只有 \n）——此时回车=提交空稿=静默无效。
    /// 修法：①优先 execCommand('insertText')（真实编辑通路，React 必收，select 全选替换不怕残留）；
    /// ②填完立刻核对 ta.value===稿子，LOOSE 就重填（最多 6 次）；③粘住后交 armSubmit 派发回车。
    private func inject(_ text: String, isResend: Bool = false, busyWait: Int = 0, fillTry: Int = 0) {
        guard let wv else { return }
        if fillTry == 0 && busyWait == 0 {
            pollCount = 0; stableCount = 0; lastText = ""
            lastInjected = text
            if !isResend {
                resent = false                 // 新一轮：补发资格恢复
            }
        }
        let arr = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = """
        (function(){
          if (document.querySelector('.ds-icon--stop')) return 'BUSY';
          var t = \(arr)[0];
          var ta = document.getElementById('chat-input') || document.querySelector('textarea');
          if (!ta || !(ta.getBoundingClientRect().height > 0)) return 'NO_INPUT';
          try { ta.focus(); } catch (e) {}
          var pre = document.querySelectorAll('.ds-markdown').length;   /* 回复块基线 */
          var ur = document.querySelectorAll('.Sixlwa_userRow').length; /* 用户行基线（哈希类名会失效，md 兜底） */
          /* 回复文本基线：**发送前**采，记在页面全局。
             不能等到首拍轮询再采 —— DeepSeek 偶尔 1 秒内就把回复渲染出来
             （2026-09-22 自检实测：发送后 1s 轮询首拍采到的「4 字」正是「测试成功」本尊，
             于是整轮都认不出这条回复 → 15s 误补发、150s 报失败）。补发轮不重置。 */
          var lb = document.querySelectorAll('.ds-markdown');
          if (\(isResend ? "false" : "true") || typeof window.__ftReplyBase === 'undefined') {
            window.__ftReplyBase = lb.length ? ((lb[lb.length - 1].innerText || '').trim()) : '';
          }
          var ok = false;
          try { ta.select(); ok = document.execCommand('insertText', false, t); } catch (e) {}
          if (!ok || ta.value !== t) {
            var d = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
            if (d && d.set) d.set.call(ta, t); else ta.value = t;
            ta.dispatchEvent(new Event('input', {bubbles: true}));
          }
          return pre + ':' + ur + ':' + (ta.value === t ? 'STUCK' : 'LOOSE');
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] res, _ in
            Task { @MainActor in
                guard let self else { return }
                let s = res as? String ?? ""
                if s == "BUSY" {
                    // 页面还在流式生成上一条回复：此时注入会被 React 重渲染静默吞掉。等空闲再发，上限 90s。
                    if busyWait < 90 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.inject(text, isResend: isResend, busyWait: busyWait + 1, fillTry: fillTry)
                        }
                    } else {
                        self.dumpDomAroundComposer()
                        self.fail("网页版一直在生成上一条回复（>90s），先歇会儿")
                    }
                    return
                }
                let parts = s.split(separator: ":")
                guard parts.count == 3, let pre = Int(parts[0]), let ur = Int(parts[1]) else {
                    self.fail("网页版没找到输入框（可能没登录 —— 去「聊天模式」登录一次，回来再试）")
                    return
                }
                if parts[2] == "LOOSE" {
                    // 两条通路都填了仍立刻被冲掉：短暂等待后重填（React 重渲染风暴通常是几帧的事）
                    if fillTry < 6 {
                        AppDelegate.log("[鱼对答] 填稿被 React 冲掉（第 \(fillTry + 1) 次），0.25s 后重填")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.inject(text, isResend: isResend, busyWait: busyWait, fillTry: fillTry + 1)
                        }
                    } else {
                        AppDelegate.log("[鱼对答] 填稿 6 次全被冲掉，取证后交轮询 15s 整梯重试")
                        self.dumpDomAroundComposer()
                        self.startPolling()
                    }
                    return
                }
                self.anchorRetried = false     // 会话通了，重建资格恢复
                // 稿子已粘住。再等 0.4 秒确认 React 没异步冲掉，然后才派发回车：
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.armSubmit(text, pre: pre, baseRows: ur, fillTry: fillTry)
                }
            }
        }
    }

    /// 回车前最后一道核对：React 的异步重渲染仍可能把稿子冲掉（0.4s 前粘住 ≠ 现在还在）。
    /// 确认 ta.value===稿子 才派发真 keyCode 的回车；被冲掉就带着计数重填。
    private func armSubmit(_ text: String, pre: Int, baseRows: Int, fillTry: Int) {
        guard let wv else { return }
        let arr = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = """
        (function(){
          var t = \(arr)[0];
          var ta = document.getElementById('chat-input') || document.querySelector('textarea');
          if (!ta) return 'NO_INPUT';
          if (ta.value !== t) return 'GONE';
          var eo = {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true};
          var kev = new KeyboardEvent('keydown', eo);
          Object.defineProperty(kev, 'keyCode', {get: function(){return 13;}});
          Object.defineProperty(kev, 'which', {get: function(){return 13;}});
          ta.dispatchEvent(kev);
          ta.dispatchEvent(new KeyboardEvent('keyup', eo));
          return 'ENTERED';
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] res, _ in
            Task { @MainActor in
                guard let self else { return }
                switch res as? String ?? "?" {
                case "ENTERED":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        self.chatSendCheck(stage: 1, base: pre, baseRows: baseRows, text: text, fillTry: fillTry)
                    }
                case "GONE":
                    AppDelegate.log("[鱼对答] 回车前发现稿子又被冲掉，重填（第 \(fillTry + 1) 轮）")
                    if fillTry < 6 {
                        self.inject(text, isResend: true, busyWait: 0, fillTry: fillTry + 1)
                    } else {
                        self.dumpDomAroundComposer()
                        self.startPolling()
                    }
                default:
                    self.fail("网页版输入框消失了")
                }
            }
        }
    }

    /// chatSendCheck：回车已派发后的成功核对。成功判据 = 用户消息行或回复块数真的 +1
    /// （用户行哈希类名会失效恒 0，md 增长是主判据）。没送出去的兜底阶梯：
    /// stage1 几何定位点发送键（排除 toggle 开关）→ stage2 再回车一次 → 三级全败交轮询 15s 整梯重试。
    private func chatSendCheck(stage: Int, base: Int, baseRows: Int, text: String, fillTry: Int = 0) {
        guard let wv, onDone != nil else { return }
        let js = """
        (function(){
          var md = document.querySelectorAll('.ds-markdown').length;
          var ur = document.querySelectorAll('.Sixlwa_userRow').length;
          var ta = document.getElementById('chat-input') || document.querySelector('textarea');
          var tv = ta ? (ta.value || '') : '';
          if (md > \(base)) return 'SENT:' + ur + ':' + md;
          /* 输入框清空 = 应用已消费这稿（填稿前已核验粘住，见 inject/armSubmit）。
             ⚠️ 回复列表是虚拟化的：块数会涨了又落（取证实测 mdCount 恒 5，而会话里已有 4 条回复），
             绝不能只靠块数判成功/失败 —— 2.21.12 的「WIPED 假失败 + 每 15s 重发」就是这么来的。 */
          if (tv.trim() === '') return 'CLEARED:' + ur + ':' + md;
          if (\(stage) >= 3) return 'STUCK:' + tv.length;
          try { ta.focus(); } catch (e) {}
          if (\(stage) === 1) {
            /* 发送键按几何定位：与输入框同一行、位于其右侧的可点元素。
               旧「文档序最靠下」会点到深度思考/联网搜索这类 aria-pressed 开关（取证实锤，点了不发送）。
               注：点击时稿子应仍在框里（回车失败不清稿）；若 React 又冲了稿，stage3 的 WIPED 会暴露。 */
            var tr = ta.getBoundingClientRect();
            var cands = document.querySelectorAll('div[role="button"], button');
            var pick = null, bestX = -1;
            for (var i = 0; i < cands.length; i++) {
              var el = cands[i];
              if (String(el.className || '').indexOf('ds-toggle-button') >= 0) continue;
              if (el.getAttribute('aria-pressed') !== null) continue;
              if (el.getAttribute('aria-disabled') === 'true') continue;
              var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) continue;
              if (Math.abs((r.top + r.height / 2) - (tr.top + tr.height / 2)) > 90) continue;
              if (r.left < tr.right - 30) continue;
              if (r.right > bestX) { bestX = r.right; pick = el; }
            }
            if (pick) { pick.click(); return 'CLICKED'; }
          }
          var eo = {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true};
          var kev = new KeyboardEvent('keydown', eo);
          Object.defineProperty(kev, 'keyCode', {get: function(){return 13;}});
          Object.defineProperty(kev, 'which', {get: function(){return 13;}});
          ta.dispatchEvent(kev);
          ta.dispatchEvent(new KeyboardEvent('keyup', eo));
          return 'ENTERED';
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] res, _ in
            Task { @MainActor in
                guard let self else { return }
                let s = res as? String ?? "?"
                if s.hasPrefix("SENT") || s.hasPrefix("CLEARED") {
                    let p = s.split(separator: ":")
                    let urNow = p.count > 1 ? Int(p[1]) ?? baseRows : baseRows
                    let md = p.count > 2 ? Int(p[2]) ?? base : base
                    let how = s.hasPrefix("SENT") ? "块数增长 md \(base)→\(md)" : "输入框已清空"
                    AppDelegate.log("[鱼对答] 已送出（\(how)，用户行 \(baseRows)→\(urNow)）")
                    self.startPolling()
                    return
                }
                switch s {
                case "CLICKED", "ENTERED":
                    // 兜底通路已派发，再给 1.2 秒核对（异步清空，别同步读旧值误判）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.chatSendCheck(stage: stage + 1, base: base, baseRows: baseRows, text: text, fillTry: fillTry)
                    }
                default:
                    AppDelegate.log("[鱼对答] 发送三级兜底全失败（stage=\(stage) 判定=\(s)），取证后交轮询等 15s 整梯重试")
                    self.dumpDomAroundComposer()
                    // WIPED（假清空）和 STUCK（残留输入框）都不立刻散场：页面状态可能是暂态的
                    // （恢复中的会话、composer 重挂载），15s 后补发走一遍完整梯子再判死。
                    self.startPolling()
                }
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
    }

    private func pollTick() {
        guard let wv else { return }
        pollCount += 1
        if pollCount > Self.pollLimit {
            dumpDomAroundComposer()
            fail("网页版迟迟没有回复，先歇会儿"); return
        }
        // 长等观测点：区分「网页版在排队/深度思考」和「通道挂了」
        if pollCount == 1 || pollCount % 30 == 0 {
            onLog?("轮询中 第\(pollCount)s …")
        }
        if pollCount == 25 { onLog?("25s 无增长，取证: \(lastPoll)") ; dumpDomAroundComposer() }
        let js = """
        (function(){
          var blocks = document.querySelectorAll('.ds-markdown');
          var last = blocks.length ? blocks[blocks.length - 1] : null;
          var ta = document.querySelector('textarea');
          var lastT = last ? (last.innerText || '').trim() : '';
          var base = (typeof window.__ftReplyBase === 'string') ? window.__ftReplyBase : null;
          return JSON.stringify({
            n: blocks.length,
            text: last ? (last.innerText || '') : '',
            busy: !!document.querySelector('.ds-icon--stop'),
            tv: ta ? (ta.value || '') : '',
            same: (base === null) ? null : (lastT === base)   /* 末条仍等于发送前基线 = 本轮还没回复 */
          });
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] res, _ in
            Task { @MainActor in self?.handlePoll(res) }
        }
    }

    private var lastPoll = ""   // 最近一次轮询快照（发送失败时进诊断日志）

    /// 失败取证：把输入框周边 HTML 与全部含 markdown 的类名抓进日志，
    /// 下一轮修选择器就不用猜了（2026-09-22 实测：#chat-input、.ds-markdown 都已被改版换掉）
    private func dumpDomAroundComposer() {
        guard let wv else { return }
        let js = """
        (function(){
          var ta = document.querySelector('textarea');
          var composer = '';
          var box = null;
          if (ta) { var p = ta; for (var i = 0; i < 3 && p.parentElement; i++) p = p.parentElement; box = p; composer = p.outerHTML.slice(0, 1600); }
          var btns = [];
          if (box) {
            var list = box.querySelectorAll('div[role="button"], button');
            for (var i = 0; i < list.length && btns.length < 8; i++) {
              var el = list[i]; var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) continue;
              btns.push(String(el.className || '').slice(0, 50) + '|ad=' + el.getAttribute('aria-disabled') + '|ap=' + el.getAttribute('aria-pressed') + '|@' + Math.round(r.left) + ',' + Math.round(r.top));
            }
          }
          var mds = document.querySelectorAll('.ds-markdown');
          var classes = Array.prototype.map.call(mds, function (e) { return e.className; }).slice(0, 4);
          var body = (document.body.innerText || '');
          return JSON.stringify({ composer: composer, btns: btns, mdCount: mds.length, classes: classes,
            tv: ta ? (ta.value || '') : '', bodyTail: body.slice(-260) });
        })()
        """
        wv.evaluateJavaScript(js) { res, _ in
            Task { @MainActor in AppDelegate.log("[鱼对答] DOM取证: \(res ?? "nil")") }
        }
    }

    private func handlePoll(_ res: Any?) {
        guard onDone != nil else { return }
        guard let s = res as? String,
              let data = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = o["n"] as? Int else { return }
        lastPoll = s
        let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let busy = (o["busy"] as? Bool) ?? false
        let tv = (o["tv"] as? String) ?? ""
        let same = o["same"] as? Bool     // nil = 页面全局的回复基线丢了（页面重载过）

        if same == nil && pollCount == 1 {
            onLog?("轮询基线丢失（页面重载过），本轮只能靠超时兜底")
        }
        // 末条助手文本 ≠ **发送前**的基线 = 本轮新回复已落 DOM（可能还在流式生成）。
        // 判据全按内容比，不看块数 —— 回复列表是虚拟化的，n 涨了又落（取证实测 n 恒 5，
        // 会话里明明已有 4 条回复），2.21.12 靠 n 判「无增长」才把真回复全漏掉、每 15s 重发一遍。
        if same == false && !text.isEmpty {
            if busy { stableCount = 0; lastText = text; return }
            if text == lastText {
                stableCount += 1
                if stableCount >= Self.stableNeed {
                    onLog?("识别到新回复（n=\(n)，\(text.count) 字，稳定 \(Self.stableNeed)s）")
                    finish(text)
                }
            } else {
                stableCount = 0
                lastText = text
            }
            return
        }
        // 末条仍是上一轮的稿 = 本轮还没有回复。区分「在排队/深度思考」与「通道挂了」：
        if pollCount > 10 && !busy && !tv.isEmpty
            && (resent && pollCount > Self.resendAt + 10 || pollCount > 25) {
            // 补发后仍有稿留在输入框 = 真发不出去，早退别干等
            onLog?("发送诊断: 输入框残留 \(tv.count) 字")
            dumpDomAroundComposer()
            fail("没发出去（消息还留在输入框里）")
            return
        }
        if pollCount >= Self.resendAt && !busy && tv.isEmpty && !resent {
            // 消息已进会话（输入框空着）但迟迟没有回复：多半是网页版那次生成静默失败了。
            // 15s 补发一次；只补一次，别循环（2.21.12 的无限重发教训）。
            resent = true
            if let t = lastInjected {
                onLog?("发送后 \(Self.resendAt)s 未见回复且页面空闲 → 补发一次")
                inject(t, isResend: true)
            }
        }
        // 否则就是还在等（深度思考时首 token 可能十几秒才落 DOM），有 150s 总上限兜底。
    }

    private func finish(_ reply: String) {
        pollTimer?.invalidate(); pollTimer = nil
        // 播种完成：不把种子回复交给鱼，锚定后补发真问题
        if seeding {
            seeding = false
            captureAnchor()
            onLog?("人格设定已送达，种子回复: \(String(reply.prefix(20)))")
            if let t = realAsk {
                realAsk = nil
                waitInput(t, tries: 0)
                return
            }
        }
        asking = false
        let cb = onDone; onDone = nil
        cb?(reply, nil)
    }

    private func fail(_ msg: String) {
        pollTimer?.invalidate(); pollTimer = nil
        asking = false
        pendingAsk = nil
        if seeding { seeding = false; realAsk = nil }   // 播种失败：真问题随错误一起作废
        let cb = onDone; onDone = nil
        cb?(nil, msg)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        onLog?("鱼对答：网页版就绪 url=\(webView.url?.absoluteString ?? "?")")
        if let t = pendingAsk {
            pendingAsk = nil
            if anchorPath == nil && !seeding { startSeed(then: t) }
            else { waitInput(t, tries: 0) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded = false
        if asking { fail("网页版加载失败：\(error.localizedDescription)") }
    }

    /// 自检（flag 驱动）：/tmp/ft-fish-chat.flag → 真发测试消息，回复进日志。测完删 flag。
    /// flag 内容写数字 N 则**连发 N 条**（默认 1，上限 4）——
    /// 「第一句行、第二句发不出去」这类连轮 bug 必须靠连发回归，单发永远测不出来。
    func selfTestIfFlagged() {
        let path = "/tmp/ft-fish-chat.flag"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let raw = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var rounds = Int(raw) ?? 1
        rounds = min(max(rounds, 1), 4)
        onLog?("鱼对答自检：开始（连发 \(rounds) 条到网页版）")
        selfTestRound(1, of: rounds)
    }

    private func selfTestRound(_ i: Int, of total: Int) {
        ask("自检第 \(i) 条：请只回复四个字「测试成功」") { [weak self] reply, err in
            AppDelegate.log("鱼对答自检 #\(i)/\(total) 结果: \(reply ?? "失败（\(err ?? "?")）")")
            guard let self, i < total else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.selfTestRound(i + 1, of: total) }
        }
    }
}

@MainActor
final class DeskPetController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private var window: NSWindow!
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var petRect: CGRect = .zero     // 鲸鱼矩形（webview 坐标，左上原点，由 JS 每 ~60ms 上报）
    private var petDragging = false         // 鲸鱼正被拖 —— 期间锁死「可点」，否则拖到一半会掉
    private var granted = false             // 当前是否已把鼠标事件让给鲸鱼
    private(set) var isOpen = false
    private var ready = false
    private var savedMouse: CGPoint?        // 自检时暂存鼠标位置，测完复位（别把用户的光标扔在角落）

    /// 命中缓冲：鲸鱼在游，两次上报之间会移动，缓冲太小就会「追不上」而漏掉点击。
    /// JS 上报间隔 60ms × 最高约 120px/s ≈ 7px。
    /// ⚠️ 2026-09-22 由 16 加到 30：鲸鱼开始**俯仰**了（±26°）。上报的是轴对齐矩形，
    ///    而旋转后的实际包围盒更高 —— 134×69 的盒子转 26° 后半高从 34 涨到 60，
    ///    沿用 16px 会在「斜着下潜」时漏掉头部与尾鳍的点击（那正是它最常用的姿态）。
    private static let hitPad: CGFloat = 30
    private static let dropPad: CGFloat = 26   // 拖放判定比命中区更宽：鲸鱼还在游过来时也接得住

    /// 皮肤色（解析自当前皮肤 CSS，与窗口内那只同源，所以换肤时两只一起换）
    private var skinVars: [String: String] = [:]
    private var skinLight = false

    /// 造型（calf 圆胖幼鲸 / orca 虎鲸 / clockwork 发条鲸）—— 键名与页面 BREEDS 同名
    private var breed = "calf"

    var onLog: ((String) -> Void)?
    // ── 回笼 / 灵动岛（2.17.0）──
    var harnessWindow: (() -> NSWindow?)?     // 主窗口：笼子贴它的左下角
    var onIslandArrive: (() -> Void)?         // 鲸鱼游进岛口 → 原生让灵动岛现形
    // 2.18.0：穹顶搬进主窗口后，桌面页只上报笼中事件（开门/关门/撞笼），穹顶联动由原生转发
    var onCageEvent: (([String: Any]) -> Void)?
    var onCageVisible: ((Bool) -> Void)?      // 桌面鲸鱼开/关 → 玻璃罩跟着显隐
    var onFishMic: ((String) -> Void)?        // 麦克风 chip 点击（2.19.0）：start / cancel
    var onNearHover: ((Bool) -> Void)?        // 鼠标凑近小鱼（2.22.0）：给原生做「就近预热」
    /// 鲸鱼所在屏（灵动岛要跟它同屏现形；NSScreen.main 是键盘焦点屏，可能不对）
    var petScreen: NSScreen? { webView.window?.screen }
    private var cageRectPage: CGRect = .zero  // 笼子在页面坐标系的矩形（命中区用）
    private var lastCageKey = ""

    // ── 开关 ─────────────────────────────────────────────────────────────────
    func open() {
        if isOpen { return }
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        // ★ 必须是 nonactivatingPanel：普通 NSWindow 被点击会把整个 App 激活，
        //   App 一激活 makeKeyAndOrderFront 的主窗口（harness）就跳到最前面 ——
        //   症状就是「点一下鲸鱼，页面跳回 harness」。NSPanel + nonactivatingPanel
        //   点了不激活 App，鲸鱼后面该是什么还是什么。
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.ignoresMouseEvents = true          // 默认全穿透：桌面照常能用
        w.isMovable = false
        w.title = "发条屋 · 桌面小鲸鱼"
        // 不参与窗口循环/不抢焦点：它是背景生物，不是应用窗口
        w.hidesOnDeactivate = false
        window = w

        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(self, name: "fatiaowuPet")
        // 拖放需要页面能拿到 File；本地文件一律允许（纯本机读，不上传）
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let web = PetWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        web.autoresizingMask = [.width, .height]
        // ── 原生拖放接线：光标在鲸鱼上 → 原生收下 → 转发页面 ──
        web.dragHitTest = { [weak self] p in
            guard let self, let wv = self.webView else { return false }
            let y = wv.bounds.height - p.y        // 窗口坐标（左下原点）→ 页面坐标（左上原点）
            return self.petRect.insetBy(dx: -Self.dropPad, dy: -Self.dropPad)
                .contains(CGPoint(x: p.x, y: y))
        }
        web.onNativeHover = { [weak self] on in
            self?.webView?.evaluateJavaScript("window.ftDragHover && window.ftDragHover(\(on))", completionHandler: nil)
        }
        web.onNativeFollow = { [weak self] p in
            guard let self, let wv = self.webView else { return }
            let y = wv.bounds.height - p.y     // 窗口（左下原点）→ 页面（左上原点）
            wv.evaluateJavaScript("window.ftDragHover && window.ftDragHover(true, \(Int(p.x)), \(Int(y)))", completionHandler: nil)
        }
        web.onNativeDrop = { [weak self] urls, text in
            self?.handleNativeDrop(fileURLs: urls, text: text)
        }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")     // ★ 见上文要点 ②
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        webView = web
        w.contentView?.addSubview(web)

        if let path = Bundle.main.path(forResource: "deskpet", ofType: "html") {
            let url = URL(fileURLWithPath: path)
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // 资源没打进去时不留一个白屏 —— 直接不开
            onLog?("桌面鲸鱼: 找不到 deskpet.html，未启动")
            window = nil
            return
        }

        w.orderFrontRegardless()
        isOpen = true
        onCageVisible?(true)
        startPolling()
        onLog?("桌面鲸鱼已放生: frame=\(Int(frame.width))×\(Int(frame.height)) level=\(w.level.rawValue)")
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        onCageVisible?(false)
        // 若正绑成 harness 子窗口（进笼态），先解除再销毁 —— 别给 harness 留悬空子窗口
        if let hw = harnessWindow?(), let w = window, w.parent === hw {
            hw.removeChildWindow(w)
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fatiaowuPet")
        webView?.stopLoading()
        window?.orderOut(nil)
        window = nil
        webView = nil
        isOpen = false
        ready = false
        granted = false
        fishCaged = false      // 页面整体重建，笼中状态回到未进笼；幽灵标记一并复位，别卡住 poll 的判断
        ghostHidden = false
        onLog?("桌面鲸鱼已收回窗口")
    }

    func toggle() { isOpen ? close() : open() }

    // ── 皮肤同步：换肤时窗口内那只会变，桌面这只也得跟着变 ───────────────────
    func applySkin(vars: [String: String], isLight: Bool) {
        skinVars = vars
        skinLight = isLight
        pushSkin()
    }
    // ── 造型：三款共用同一套骨骼，页面里重建一次即可 ─────────────────────────
    // 与皮肤一样走「原生记住、页面执行」：页面只认 ftBreed(key)，不自己存状态，
    // 免得两处各记一份（重开浮层时以原生为准推下去）。
    func setBreed(_ key: String) {
        breed = key
        pushBreed()
    }
    /// 诊断：取回页面自报状态（造型自检/排查用）
    func state(_ done: @escaping (String) -> Void) {
        guard ready, let web = webView else { done("not-ready"); return }
        web.evaluateJavaScript("window.ftState ? JSON.stringify(window.ftState()) : 'no-state'") { r, _ in
            let s = (r as? String) ?? "nil"
            Task { @MainActor in done(s) }
        }
    }
    private func pushBreed() {
        guard ready, let web = webView else { return }
        web.evaluateJavaScript("window.ftBreed && window.ftBreed('\(breed)')") { r, _ in
            let s = (r as? String) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                if s.isEmpty { self.onLog?("造型: \(self.breed)") }
                else if s.hasPrefix("unknown") { self.onLog?("造型切换失败: \(s)") }
                else { self.onLog?("造型: \(s)") }
            }
        }
    }

    private func pushSkin() {
        guard ready, let web = webView else { return }
        func js(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
        let a = js(skinVars["accent"] ?? "#d9a441")
        let s = js(skinVars["accent-strong"] ?? "#e6b95a")
        let sf = js(skinVars["accent-soft"] ?? "rgba(217,164,65,.5)")
        let sr = js(skinVars["accent-softer"] ?? "rgba(217,164,65,.35)")
        let b = js(skinVars["accent-bg"] ?? "rgba(217,164,65,.08)")
        web.evaluateJavaScript("window.ftSetSkin && window.ftSetSkin('\(a)','\(s)','\(sf)','\(sr)','\(b)',\(skinLight)); window.ftSetLook && window.ftSetLook('\(js(skinVars["look"] ?? "classic"))')")
    }

    /// 从皮肤 CSS 文本里抽 --ft-accent* 五个变量 + 涂装声明（与窗口内那只共用同一份 CSS 来源）
    static func extractSkinVars(from css: String) -> (vars: [String: String], isLight: Bool) {
        var out: [String: String] = [:]
        for key in ["accent", "accent-strong", "accent-soft", "accent-softer", "accent-bg", "look"] {
            let pat = "--ft-\(key):"
            if let r = css.range(of: pat) {
                let rest = css[r.upperBound...]
                if let end = rest.firstIndex(of: ";") {
                    out[key] = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // 浅色皮肤（翡翠晨光）下气泡要反色，否则白底白字
        let isLight = css.contains("--ft-accent: #0f9d6e")
        return (out, isLight)
    }

    // ── 轮询鼠标：命中鲸鱼才让出事件，否则全穿透 ─────────────────────────────
    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common：拖拽/缩放期间也别停
        pollTimer = t
    }

    private var pollTicks = 0
    private var verbose = false     // 自检时开：把每次 poll 的鼠标/命中值打出来，平时静默
    private var probeTimer: Timer?  // 能耗档位探针（flag 驱动，见 powerProbe）
    private var lastNear = false    // 靠近即停：只在翻转时下发，别 30Hz 轰炸页面
    private var insideSince: TimeInterval = 0 // 鼠标进入真正命中区的时刻（预热要求停留）
    private var nearWarmed = false            // 本次停留是否已预热过（离开命中区才复位）
    private var lastMousePos = CGPoint(x: -1, y: -1)   // 上一帧鼠标位置（判断「人在动」）
    private var lastMoveAt: TimeInterval = 0           // 鼠标最后一次移动的时刻
    // 幽灵鱼治理（2.21.1）：玻璃罩在 harness 窗口里，鱼进笼后浮层那只就是「分身」。
    // 浮层 canJoinAllSpaces —— 切到别的空间/全屏，harness 不在场，笼子和鱼却还浮在那儿。
    // 进笼 + harness 不在当前空间 → 整个浮层 orderOut；回到 harness 空间 → orderFront。
    private var fishCaged = false
    private var ghostHidden = false
    // harness 窗口引用缓存（2.21.3）：harnessWindow 闭包（weak 加载 + ivar retain）曾被
    // 30Hz×2 次/秒地拉 —— 两次 SIGSEGV 崩点都在这条链上（objc_retain 野窗口指针）。
    // 窗口启动后从不更换，缓存 1Hz 刷新足够；行为不变，暴露面砍掉 ~98%。
    private var hwCache: NSWindow?
    private var hwCacheTick = 0
    private func harnessWin() -> NSWindow? {
        hwCacheTick += 1
        if hwCache == nil || hwCacheTick >= 30 {
            hwCache = harnessWindow?()
            hwCacheTick = 0
        }
        return hwCache
    }

    private func poll() {
        guard isOpen, let w = window else { return }
        // 拖鲸鱼时锁死可点：否则它跟着鼠标跑，一帧算错就掉手
        if petDragging { setGranted(true); return }
        guard let screen = w.screen ?? NSScreen.main, petRect.width > 0 else {
            pollTicks += 1
            if verbose && pollTicks % 40 == 0 {
                onLog?("poll 早退: screen=\(w.screen == nil ? "nil" : "ok") petRectW=\(Int(petRect.width))")
            }
            return
        }
        pushCageIfMoved(screen: screen)
        // 幽灵鱼治理：进笼 → 绑成 harness 子窗口（层级跟随）；harness 不在场 → 收起
        // （顺带：不在进笼态时把浮层钉回屏框，见 pinPanelIfNeeded）
        updateGhostBinding()
        let m = NSEvent.mouseLocation
        // ★ 2.23.9：鼠标 → 网页坐标改按**浮层局部**换算（以前按屏幕坐标，吃的是
        //   「浮层恰好等于整屏」这条不变量；浮层作为 harness 子窗口被父窗口拖走后不变量失效，
        //   petRect / cageRectPage 都是浮层局部量 → 命中区整体偏 Δ，鱼变得"看得见摸不着"）。
        //   必须在 updateGhostBinding 之后读 frame：它可能刚把浮层钉回屏框。
        let pf = w.frame
        // 浮层局部坐标（原点左下）→ 网页坐标（原点左上）
        let px = m.x - pf.minX
        let py = pf.maxY - m.y
        var inside = petRect.insetBy(dx: -Self.hitPad, dy: -Self.hitPad).contains(CGPoint(x: px, y: py))
        // 笼框命中：只给四条边条 —— 笼子中央空着时不能挡住底下 harness 的点击
        if cageRectPage.width > 0 {
            let inner = cageRectPage.insetBy(dx: 14, dy: 14)
            let cp = CGPoint(x: px, y: py)
            inside = inside || (cageRectPage.contains(cp) && !inner.contains(cp))
        }
        // 「人正在动鼠标」判据（2.23.4 从下面提前到这里）：0.5pt 阈值足够滤掉手抖。
        // 提前的原因：ftNear 唤醒也要用它，见下。
        let moved = abs(px - lastMousePos.x) > 0.5 || abs(py - lastMousePos.y) > 0.5
        if moved { lastMousePos = CGPoint(x: px, y: py); lastMoveAt = CACurrentMediaTime() }
        // 靠近即停（2.20.0）：鼠标到命中矩形（鱼 ∪ chip ∪ 轮盘）的边距 < 72px → 通知页面冻结漫游。
        // 鱼藏着（rect=-9999）时距高塔远，恒为 false —— 藏猫猫期间不会被「靠近」吵醒。
        let ddx = max(max(petRect.minX - px, 0), px - petRect.maxX)
        let ddy = max(max(petRect.minY - py, 0), py - petRect.maxY)
        let near = (ddx * ddx + ddy * ddy) < 72 * 72
        if near != lastNear {
            lastNear = near
            // 第二个参数 = 「指针真的在动吗」（2.23.4）。**必须传**：鱼自己会游来游去，它游过一支
            // 静止的鼠标就会让 near 翻转，页面若把「靠近」直接当「用户在场」就会 powerWake()
            // —— 桌面鱼永远回不到 eco（实测档位日志 full→eco 三秒后即被 eco→full 抵消，长期停在
            // full = 12.8% 单核；同一个信号还会反复把语音引擎叫起来做 4s 预热）。
            // 与 2.22.0 给「就近预热」加的第①道闸同源：静止的鼠标旁边经过 ≠ 用户在场。
            webView?.evaluateJavaScript("window.ftNear && window.ftNear(\(near ? 1 : 0), \(moved ? 1 : 0))",
                                        completionHandler: nil)
            if !near { nearWarmed = false }        // 离开缓冲带 → 下次停靠可再预热（原生侧还有冷却）
        }
        // 就近预热（2.22.0）：鼠标停在**真正命中区**里 0.5s 以上、且**人正在动鼠标** → 让原生
        // 先把音频引擎转起来。两道闸都是实测加出来的：
        //   ①「人正在动」——否则小鱼自己游到静止的鼠标旁边也会触发预热（实测日志里 13 秒内
        //     触发了两次，全是鱼游过来造成的，白启停引擎还闪麦克风灯）；
        //   ②「落在命中区」——72px 缓冲带是给「靠近即停」用的，拿它当预热条件太宽。
        // 动机：引擎常驻让音频链路 7×24 跑回声消除 DSP（实测空闲 ~16% 单核）并挡住系统休眠；
        // 但「点了 chip 才冷启动」又会吃掉开场白。折中 = 只在人冲着鱼去的时候预热，没点 4s 收工。
        if inside {
            if insideSince == 0 { insideSince = CACurrentMediaTime() }
        } else {
            insideSince = 0
        }
        if insideSince > 0, !nearWarmed,
           CACurrentMediaTime() - insideSince > 0.5,
           CACurrentMediaTime() - lastMoveAt < 0.5 {
            nearWarmed = true
            onNearHover?(true)
        }
        pollTicks += 1
        if verbose && pollTicks % 40 == 0 {
            onLog?("poll: 鼠标=(\(Int(px)),\(Int(py))) 鲸鱼=(\(Int(petRect.minX)),\(Int(petRect.minY)),\(Int(petRect.width))×\(Int(petRect.height))) 命中=\(inside) near=\(near) granted=\(granted)")
        }
        setGranted(inside)
    }

    /// 幽灵鱼治理（2.21.2）：进笼后鱼必须「活」在 harness 的窗口层级里。
    /// 浮层是 .floating + canJoinAllSpaces —— 同一空间里切到别的窗口（盖住 harness）时，
    /// 鱼照样浮在人家上面。修法：进笼 → 绑成 harness **子窗口**（level 降到 normal、
    /// 去跨空间行为）：别的窗口盖住 harness，鱼跟着被盖；harness 切空间/最小化，鱼跟着走/藏。
    /// 出笼 → 解除绑定、恢复自由浮层。所有状态翻转只在 poll 里做，零新轮询。
    private func updateGhostBinding() {
        guard isOpen, let w = window else { return }
        let hw = harnessWin()
        let harnessHere: Bool = {
            guard let hw else { return false }
            return hw.isVisible && hw.isOnActiveSpace
        }()
        if fishCaged && harnessHere {
            if let hw, w.parent !== hw {
                w.level = .normal                                  // 与 harness 同级：子窗口永远钉在它正上方
                w.collectionBehavior = [.fullScreenAuxiliary]      // 不再跨空间 —— 笼在哪个空间鱼在哪个空间
                hw.addChildWindow(w, ordered: .above)
                onLog?("鱼绑定 harness 子窗口：进笼后层级跟随主窗口")
            }
            if ghostHidden { ghostHidden = false; w.orderFrontRegardless() }
        } else if fishCaged && !harnessHere {
            if !ghostHidden {
                ghostHidden = true
                w.orderOut(nil)
                onLog?("幽灵鱼收起：鱼在笼中且 harness 不在场")
            }
        } else if !fishCaged {
            if let hw, w.parent === hw { hw.removeChildWindow(w) }
            if w.level != .floating {
                w.level = .floating
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                onLog?("鱼恢复自由浮层")
            }
            /* ★ 2.23.9：解绑后**必须把浮层钉回屏框**。子窗口随父窗口位移是 AppKit 的既定行为
               （实测：父窗 +150 → 浮层 minX 也 +150），而 removeChildWindow **不会**把它搬回去。
               浮层的 frame 就是页面坐标系的原点（漫游界、灵动岛口、鼠标换算全按它算），
               留着那份位移 = 鱼活在一个被搬走的世界里（窗口右移 300，鱼就够不到左边 300px）。 */
            pinPanelIfNeeded()
            if ghostHidden { ghostHidden = false; w.orderFrontRegardless() }
        }
    }

    /// 浮层必须正好等于它所在屏的 frame —— 这是「屏幕坐标 == 页面坐标」的隐藏前提。
    /// 只在**非进笼态**调用：进笼时浮层是 harness 的子窗口，拖窗期间要让它跟着一起走
    /// （笼位按浮层相对坐标推，跟着走才对得上，见 pushCageIfMoved），这时去钉它会打架、会抖。
    /// 代价只是一次 frame 比较，没被搬动就什么都不做。
    private func pinPanelIfNeeded() {
        guard let w = window, let scr = w.screen ?? NSScreen.main else { return }
        if !NSEqualRects(w.frame, scr.frame) {
            let was = w.frame.origin
            w.setFrame(scr.frame, display: false)
            onLog?("浮层钉回屏框：(\(Int(was.x)),\(Int(was.y))) → (\(Int(scr.frame.minX)),\(Int(scr.frame.minY)))")
        }
    }

    /// 笼子位置：贴 harness 主窗口**左下角**（180×94）。2.18.0 起玻璃穹顶的**视觉**
    /// 已搬进主窗口子视图（CageOverlayController），这里推的矩形只喂桌面页做
    /// 鱼的物理围栏与边条命中。
    /// ⚠️ 2.23.9 更正：**「拖窗口时不会视觉不同步」这句话是错的** —— 玻璃是主窗口子视图
    /// （跟着窗口走），而浮层是**独立的一个全屏窗口**，两者只在「浮层 == 它所在屏」时才等价。
    /// 鱼进笼时浮层被绑成 harness 子窗口，拖窗整层跟着位移，这套等价就断了；所以笼位一律
    /// 按**浮层自身坐标系**推（见下），自由态则把浮层钉回屏框（pinPanelIfNeeded）。
    /// 笼底距窗口底缘 76px —— 抬过左下角设置按钮，绝不挡按钮点击。
    /// 只在 harness 所在的当前空间出现 —— 窗口不可见或不在活跃空间 → 推 ftSetCage(-1) 收笼，
    /// 笼子（和关在里面的鱼）绝不出现在其他空间/全屏应用里。位置变了才下发（key 去重）。
    private func pushCageIfMoved(screen: NSScreen) {
        let cw = CageOverlayController.cageSize.width,
            ch = CageOverlayController.cageSize.height   // 单一来源：与玻璃罩视图同尺寸
        guard let hw = harnessWin(), hw.isVisible, hw.isOnActiveSpace else {
            if lastCageKey != "off" {
                lastCageKey = "off"
                cageRectPage = .zero
                webView?.evaluateJavaScript("window.ftSetCage && window.ftSetCage(-1,-1,0,0)",
                                            completionHandler: nil)
            }
            return
        }
        let hf = hw.frame
        // ★ 2.23.9 坐标系修正：笼位按**浮层自身坐标系**推，不再按屏幕坐标系。
        //   页面（deskpet.html）的坐标原点就是浮层左上角 —— 而浮层在鱼进笼时是 harness 的
        //   子窗口，父窗口一动**整层跟着位移**（独立实验 /tmp/ft-childwin.swift 确证：
        //   父窗 +150 → 浮层 minX 也 +150，解绑后还留在原地不归位）。
        //   按屏幕坐标推时，浮层那份位移 Δ 没人抵消 → 「页面以为的笼子」比「看得见的玻璃」
        //   多出一份 Δ；dragProbe 实测 ∠ 严格等于拖窗距离（30/60/90/120px 等比），鱼在罩里
        //   被拖到玻璃外 100px+，而 cageIn 全程为 1（根本没过越狱判定）。
        //   改成浮层相对坐标后，这个量在拖窗期间**恒定不变** —— 零漂移，且不依赖任何
        //   时间同步（不靠"推得够快"，所以不存在滞后帧）。收笼/换空间重出时 dx,dy 仍有效
        //   （页面 ftSetCage 里那段平移照旧兜底）。
        let pf = window?.frame ?? hw.screen?.frame ?? screen.frame
        let cx = hf.minX - pf.minX + 14              // 距窗口左缘 14px（浮层局部 x）
        let cy = pf.maxY - hf.minY - 76 - ch         // 距窗口底缘 76px：越过设置按钮（page 坐标 y 向下）
        let key = "\(Int(cx)),\(Int(cy))"
        guard key != lastCageKey else { return }
        lastCageKey = key
        cageRectPage = CGRect(x: cx, y: cy, width: cw, height: ch)
        webView?.evaluateJavaScript("window.ftSetCage && window.ftSetCage(\(Int(cx)),\(Int(cy)),\(Int(cw)),\(Int(ch)))",
                                    completionHandler: nil)
    }

    private func setGranted(_ v: Bool) {
        if granted == v { return }
        granted = v
        window?.ignoresMouseEvents = !v
        onLog?("穿透切换: 鼠标\(v ? "进入" : "离开")鲸鱼 → ignoresMouseEvents=\(!v) 命中区=(\(Int(petRect.minX)),\(Int(petRect.minY)))")
    }

    // ── 原生拖放落地：读文件（本机）→ 组 payload → 转发页面 ftFeed ──────────
    private func handleNativeDrop(fileURLs: [URL], text: String?) {
        guard let wv = webView else { return }
        onLog?("原生拖放收到: 文件\(fileURLs.count)个 文本=\(text != nil ? "有" : "无")")
        var payloads: [[String: Any]] = []

        if let u = fileURLs.first {
            let name = u.lastPathComponent
            let size = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let (kind, mime) = Self.classify(u)
            var p: [String: Any] = ["kind": kind, "name": name, "size": Int(size), "mime": mime, "from": "drop"]
            if kind == "image", let d = try? Data(contentsOf: u) {
                p["dataUrl"] = "data:\(mime);base64," + d.base64EncodedString()
            } else if kind == "text", let s = try? String(contentsOf: u, encoding: .utf8) {
                p["text"] = String(s.prefix(100_000))
                p["len"] = min(s.count, 100_000)
            } else if kind == "file" {
                p["hint"] = "含住了，双击我吐回给你"
            }
            payloads.append(p)
            // 鲸腹：整批 URL 作为一个存货收下（吐回时一起进剪贴板）
            let n = fileURLs.count
            let ext = String(u.pathExtension.uppercased().prefix(4))
            bellyAdd(BellyItem(isText: false, urls: fileURLs, text: "",
                               chip: n > 1 ? "×\(n)" : (ext.isEmpty ? "件" : ext),
                               label: n > 1 ? "\(n) 个文件（含 \(name)）" : name))
            if n > 1 {
                onLog?("原生拖放: \(n) 个文件整体含住（气泡只展示第一个）")
            }
        } else if let t = text, !t.isEmpty {
            payloads.append(["kind": "text", "name": "一段文字", "text": String(t.prefix(100_000)),
                             "len": min(t.count, 100_000), "size": t.count, "mime": "text", "from": "drop"])
            let trimmed = String(t.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            bellyAdd(BellyItem(isText: true, urls: [], text: String(t.prefix(100_000)),
                               chip: "文", label: "文字「\(trimmed)」"))
        }

        guard !payloads.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payloads),
              let json = String(data: data, encoding: .utf8) else {
            onLog?("原生拖放: payload 序列化失败")
            return
        }
        // 一次只喂一个（与页面口径一致），JSON 包在数组里转义最稳
        wv.evaluateJavaScript("window.ftFeed && window.ftFeed((\(json))[0]);", completionHandler: nil)
    }

    /// 按扩展名分类：图片 → base64 直读；文本 → 内容；其他 → 元数据
    private static func classify(_ u: URL) -> (kind: String, mime: String) {
        switch u.pathExtension.lowercased() {
        case "png": return ("image", "image/png")
        case "jpg", "jpeg": return ("image", "image/jpeg")
        case "gif": return ("image", "image/gif")
        case "webp": return ("image", "image/webp")
        case "heic": return ("image", "image/heic")
        case "tiff": return ("image", "image/tiff")
        case "txt", "md", "markdown", "json", "yaml", "yml", "toml", "js", "ts", "tsx", "jsx",
             "py", "swift", "go", "rs", "java", "c", "h", "cpp", "css", "html", "htm",
             "sh", "zsh", "sql", "log", "csv", "ini", "conf", "env":
            return ("text", "text/plain")
        default: return ("file", "application/octet-stream")
        }
    }

    // ── 鲸腹：拖进来的先含着，双击吐回剪贴板 ────────────────────────────────
    // 真实场景：macOS 跨桌面空间/全屏应用拖文件，半路切屏就掉了。鲸鱼当
    // 「带脸的中转」：拖进来含住（存原生层），双击吐回系统剪贴板，任意处 ⌘V。
    private struct BellyItem {
        let isText: Bool
        let urls: [URL]
        let text: String
        let chip: String      // 嘴边小方片上的字（扩展名 / 「文」/ ×n）
        let label: String     // 气泡里的可读名
    }
    private var belly: [BellyItem] = []      // [0] = 最新
    private static let bellyMax = 9

    private func bellyAdd(_ item: BellyItem) {
        belly.insert(item, at: 0)
        while belly.count > Self.bellyMax { belly.removeLast() }   // 肚子有限：最旧的被消化掉
        pushBellyUI(announce: true)
        onLog?("鲸腹: 含住「\(item.label)」 现存 \(belly.count) 个")
    }

    private func pushBellyUI(announce: Bool) {
        guard let wv = webView else { return }
        let n = belly.count
        let chip = n > 0 ? belly[0].chip : ""
        let label = n > 0 ? belly[0].label : ""
        wv.evaluateJavaScript(
            "window.ftBelly && window.ftBelly(\(n), \(Self.jsonStr(chip)), \(Self.jsonStr(label)), \(announce ? "'full'" : "''"));",
            completionHandler: nil)
    }

    private func bellySpit() {
        guard let wv = webView else { return }
        guard let item = belly.first else {
            wv.evaluateJavaScript("window.ftSay && window.ftSay('空', '', '嘴里没含东西', 2200)", completionHandler: nil)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isText {
            pb.setString(item.text, forType: .string)
        } else {
            pb.writeObjects(item.urls.map { $0 as NSURL })   // 文件一起吐回，Finder/编辑器都认
        }
        belly.removeFirst()
        pushBellyUI(announce: false)
        wv.evaluateJavaScript("window.ftSpit && window.ftSpit(\(Self.jsonStr(item.label)))", completionHandler: nil)
        onLog?("鲸腹: 吐出「\(item.label)」→ 剪贴板 剩 \(belly.count) 个")
    }

    private func bellyClear() {
        guard !belly.isEmpty else { return }
        onLog?("鲸腹: 咽下 \(belly.count) 个（清空）")
        belly.removeAll()
        pushBellyUI(announce: false)
    }

    /// Swift 字符串 → JSON 字面量（含中文/引号都安全）
    private static func jsonStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let j = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(j.dropFirst().dropLast())   // 数组包一层，去掉首尾方括号
    }

    // ── 来自页面的消息 ───────────────────────────────────────────────────────
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        handle(kind: kind, data: body["data"] as? [String: Any] ?? [:])
    }

    private func handle(kind: String, data: [String: Any]) {
        switch kind {
        case "rect":
            // JS 上报鲸鱼矩形（60ms 一次）——穿透判定的唯一依据
            let x = (data["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (data["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (data["w"] as? NSNumber)?.doubleValue ?? 0
            let h = (data["h"] as? NSNumber)?.doubleValue ?? 0
            petRect = CGRect(x: x, y: y, width: w, height: h)
            petDragging = (data["drag"] as? Bool) ?? false
        case "ready":
            ready = true
            pushSkin()
            pushBreed()
            onLog?("桌面鲸鱼页面就绪 (\(data["w"] ?? 0)×\(data["h"] ?? 0))")
        case "fed":
            let n = data["name"] as? String ?? ""
            onLog?("桌面鲸鱼吃下了: \(n)")
        case "spit":        // 双击：吐出最新存货 → 系统剪贴板
            bellySpit()
        case "bellyClear":  // 右键：咽下去，清空鲸腹
            bellyClear()
        case "power":           // 桌面鱼能耗档位切换（2.23.0：自治降档 / 回岛停帧留痕）
            let lv = data["level"] as? String ?? "?"
            let fr = data["from"] as? String ?? "?"
            onLog?("桌面鱼能耗档位: \(fr) → \(lv)")
        case "islandArrive":    // 鲸鱼游进灵动岛口 → 原生让岛现形
            onIslandArrive?()
        case "cage":            // 进笼/出笼/撞笼：留痕 + 转发玻璃罩（穹顶画在主窗口里，靠这条联动）
            let inCage = data["in"] as? Int ?? -1
            // 只翻标记：绑定/解绑/收起/恢复的全部动作收敛在 poll 的 updateGhostBinding（单一真相源）
            if inCage == 1 { fishCaged = true }
            if inCage == 0 { fishCaged = false }
            onLog?(inCage == 1 ? "鲸鱼进笼了" : inCage == 0 ? "鲸鱼出笼了" : "笼中动静（撞笼/点玻璃）")
            onCageEvent?(data)
        case "fishMic":         // 麦克风 chip：开始/取消一次语音对答
            onFishMic?(data["op"] as? String ?? "start")
        default:
            break
        }
    }

    // ── 回笼 / 躲猫猫：菜单动作转发页面 ────────────────────────────────────
    func cageToggle() { webView?.evaluateJavaScript("window.ftCageToggle && window.ftCageToggle()", completionHandler: nil) }
    func islandGo() { webView?.evaluateJavaScript("window.ftIslandGo && window.ftIslandGo()", completionHandler: nil) }
    func islandOut() { webView?.evaluateJavaScript("window.ftIslandOut && window.ftIslandOut()", completionHandler: nil) }

    /// 工作哨兵（2.24.0）：把 dsh 的工作状态推给桌面这只。
    ///   busy     —— 在跑（页面侧只抬尾摆：零文字、零位移、零新元素）
    ///   done     —— 跑完 + 你人在（一行小字 1.4s 自散，鱼不动）
    ///   doneAway —— 跑完 + 你不在（游到屏幕中部 + 长驻气泡，留到你回来）
    ///   stuck    —— 卡在等你授权（同上，另由原生决定要不要补一声轻响）
    ///   idle     —— 你回来了，收工
    func work(_ mode: String, _ ms: Int = 0) {
        guard ready, let web = webView else { return }
        web.evaluateJavaScript("window.ftWork && window.ftWork('\(mode)', \(ms))") { _, _ in }
    }

    /// 鱼对答（2.19.0）：native → 页面（window.__ftFish）。state/partial/levels/reply/error/notice
    func fishCall(_ fn: String, _ args: String...) {
        let tail = args.isEmpty ? "" : args.joined(separator: ",")
        webView?.evaluateJavaScript("window.__ftFish&&window.__ftFish.\(fn)(\(tail))") { _, _ in }
    }

    // ── 诊断：打印状态与窗口属性 ─────────────────────────────────────────────
    func probeState() -> String {
        guard isOpen, let w = window else { return "closed" }
        return "open=\(isOpen) ready=\(ready) ignoresMouse=\(w.ignoresMouseEvents) "
             + "petRect=(\(Int(petRect.minX)),\(Int(petRect.minY)),\(Int(petRect.width))×\(Int(petRect.height))) "
             + "drag=\(petDragging) level=\(w.level.rawValue) alpha=\(w.alphaValue)"
    }

    /// 自检（flag 驱动）：开 → 打印 → 穿透实测 → 收尾关闭
    /// 能耗档位探针（flag 驱动，测完删 flag）：/tmp/ft-power-probe.flag
    /// 每 12s 打一行桌面鱼档位快照（power/idleSec/fps/asleep/hidden + 档位变更留痕），
    /// 用来实测「空闲 25s 降档 → 60s 打盹 → 150s 回岛停帧 → 被唤醒」整条自治链（2.23.0）。
    func powerProbe() {
        probeTimer?.invalidate()
        AppDelegate.log("能耗探针: 启动（每 12s 一行档位状态）")
        var n = 0
        probeTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            guard self.isOpen else { self.onLog?("能耗探针: 桌面鱼当前没放生（收起了）"); return }
            n += 1
            self.webView?.evaluateJavaScript("(function(){var s=window.ftState&&window.ftState(); return s?JSON.stringify({power:s.power,idle:s.idleSec,fps:s.fps,asleep:s.asleep,hidden:s.hidden,mode:s.mode,x:s.x,y:s.y,log:s.powerLog}):'no-state';})()") { r, _ in
                Task { @MainActor in self.onLog?("能耗探针[\(n)]: \(r as? String ?? "nil")") }
            }
        }
    }
    func selfTest() {
        open()
        verbose = true
        onLog?("自检[1] 打开后: \(probeState())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.onLog?("自检[2] 3 秒后: \(self.probeState())")
            self.webView?.evaluateJavaScript("window.ftState ? JSON.stringify(window.ftState()) : 'no-state'") { r, e in
                Task { @MainActor in
                    if let e { self.onLog?("自检[3] ftState 报错: \(e.localizedDescription)") }
                    else { self.onLog?("自检[3] ftState: \(r as? String ?? "nil")") }
                }
            }
        }
        // 自检[4-6] 穿透实测 —— 把鼠标搬过去 / 搬走，看浮层让不让开。
        // 这是「放生」能不能用的**唯一判据**：浮层若不让开，整个桌面就点不动了；
        // 若永远让开（不收回），鲸鱼以外的区域也会吃掉点击。两个方向都要看。
        // ★ 必须先让页面把它「定住」再测：鲸鱼默认一直在游（最快 120px/s），
        //   算好坐标到搬鼠标之间只要隔几百毫秒，它就跑出命中区了 —— 第一版就是
        //   这么假红的（三次采样全是「没让开」，其实是鼠标落在了它刚才的位置）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self, let w = self.window, let web = self.webView,
                  let screen = w.screen ?? NSScreen.main else { return }
            self.savedMouse = NSEvent.mouseLocation
            /* ★ 2.23.9：ftPlace 吃的是**页面坐标**（= 浮层局部），以前拿屏幕 frame 当页面 frame
               只在「浮层 == 整屏」时等价。鼠标搬运（CGWarp）才是 Quartz 全局坐标，
               两者从这里起用各自的基准（面板 pf / 屏幕 sf），别再混用。 */
            let pf = w.frame
            let sf = screen.frame
            let px = Int(pf.width / 2 - 57), py = Int(pf.height * 0.62)
            web.evaluateJavaScript("window.ftPlace && window.ftPlace(\(px), \(py))") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    self.onLog?("自检[4] 定点后 petRect=(\(Int(self.petRect.minX)),\(Int(self.petRect.minY))) \(Int(self.petRect.width))×\(Int(self.petRect.height))")
                    // ★ 坐标系陷阱：CGWarpMouseCursorPosition 吃的是**左上原点**（Quartz 全局坐标，
                    //   与 petRect 同系），而 NSEvent.mouseLocation 读出来是**左下原点**。poll 里
                    //   已经做过一次翻转，这里就**不能再翻**，否则鼠标被打到鲸鱼上下镜像的位置
                    //   （实测差了 311px，穿透判定永远不命中，症状是「怎么都不让开」）。
                    // ★ 2.23.9：鱼的屏坐标要以**浮层原点**为基准（petRect 是浮层局部量），
                    //   拿屏幕 frame 当基准只在「浮层 == 整屏」时等价 —— 这正是本日修的那类混用。
                    CGWarpMouseCursorPosition(CGPoint(x: pf.minX + self.petRect.midX, y: self.petRect.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self else { return }
                        self.onLog?("自检[5] 鼠标停在鲸鱼上 → \(self.probeState())")
                        CGWarpMouseCursorPosition(CGPoint(x: sf.minX + 60, y: 68))   // 搬去左上角（同样是左上原点）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                            guard let self else { return }
                            self.onLog?("自检[6] 鼠标移开后 → \(self.probeState())")
                            if let m = self.savedMouse { CGWarpMouseCursorPosition(m) }
                            web.evaluateJavaScript("window.ftRoam && window.ftRoam()")
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            self?.onLog?("自检[7] 收尾关闭")
            self?.close()
        }
    }

    /// 拖窗复现探针（flag: /tmp/ft-cagedrag.flag）—— 诊断「鱼在罩里时拖窗口，鱼漂出罩外」
    /// 独立实验（/tmp/ft-childwin.swift）已证：**全屏浮层被绑成子窗口后，父窗口一动，
    /// 整层跟着位移，且解绑后不归位**（实测 150 → 300 → 留在 300）。
    /// 鱼进笼时浮层正被绑着（幽灵鱼治理 updateGhostBinding），而玻璃罩是主窗口的子视图 ——
    /// 两者各自被搬。这里让**应用自己搬主窗口**（setFrameOrigin 与真拖拽走同一套 AppKit
    /// 子窗口跟随机制；本机没辅助功能权限，拖不了真窗口），把三套坐标量出来：
    ///   ① 玻璃真屏坐标 = hf.minX + 14
    ///   ② 浮层原点 = pf.minX
    ///   ③ DOM 里 .ft-dp-cage / #ft-pet 的 rect（浮层局部）+ 浮层原点 = 屏坐标
    /// 判据：③笼 − ①玻璃 = 「页面以为的笼子」与「看得见的玻璃」的错位（本质 bug 在这个量上）；
    ///       ③鱼 − ③笼 = DOM 内部自洽性（这个量应该恒定，不随窗口动）。
    func dragProbe() {
        open()
        guard let hw = harnessWindow?(), let w = window, let web = webView else {
            onLog?("拖窗探针: 窗口/页面未就绪，放弃"); return
        }
        let origin0 = hw.frame.origin
        let stepPx: CGFloat = 6, totalSteps = 20
        let ch = CageOverlayController.cageSize.height

        func sample(_ tag: String, then: (() -> Void)? = nil) {
            let hf = hw.frame, pf = w.frame
            let glassX = hf.minX + 14                      // 玻璃罩左缘（屏坐标）
            let glassTop = hf.minY + 76 + ch               // 玻璃罩上缘（屏坐标，y 向上）
            let js = "(function(){var c=document.querySelector('.ft-dp-cage'),p=document.getElementById('ft-pet');"
                + "var cr=c?c.getBoundingClientRect():null,pr=p?p.getBoundingClientRect():null;"
                + "var s=(window.ftState&&window.ftState())||{};"
                + "return JSON.stringify({cl:cr?Math.round(cr.left):-999,ct:cr?Math.round(cr.top):-999,"
                + "pl:pr?Math.round(pr.left):-999,pt:pr?Math.round(pr.top):-999,"
                + "cageIn:!!s.cageIn,scale:s.scale,fx:s.x,fy:s.y});})()"
            web.evaluateJavaScript(js) { r, _ in
                Task { @MainActor in
                    let d = ((r as? String) ?? "{}").data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    let cl = (d["cl"] as? Int) ?? -999, ct = (d["ct"] as? Int) ?? -999
                    let pl = (d["pl"] as? Int) ?? -999
                    let cageScrX = pf.minX + CGFloat(cl)                 // 页面笼元素 → 屏坐标
                    let cageScrTop = pf.maxY - CGFloat(ct)
                    let petScrX = pf.minX + CGFloat(pl)
                    self.onLog?("拖窗探针[\(tag)] 主窗x=\(Int(hf.minX)) 浮层x=\(Int(pf.minX)) | "
                        + "玻璃屏x=\(Int(glassX)) 页面笼屏x=\(Int(cageScrX)) ∠\(Int(cageScrX - glassX)) "
                        + "(y∠\(Int(cageScrTop - glassTop))) | 鱼盒屏x=\(Int(petScrX)) 距笼元素\(Int(petScrX - cageScrX)) | "
                        + "cageIn=\(d["cageIn"] ?? "-") scale=\(d["scale"] ?? "-") 鱼页面坐标=(\(d["fx"] ?? "-"),\(d["fy"] ?? "-"))")
                    then?()
                }
            }
        }

        // ① 唤它回笼（页面自治的入口），等 cageIn 落地
        web.evaluateJavaScript("window.ftCageToggle && window.ftCageToggle()")
        var tries = 40
        func waitCage() {
            guard tries > 0 else { onLog?("拖窗探针: 等进笼超时（鱼没游回来），放弃"); return }
            tries -= 1
            web.evaluateJavaScript("window.ftState ? String(!!window.ftState().cageIn) : 'false'") { r, _ in
                Task { @MainActor in
                    guard ((r as? String) ?? "false") == "true" else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitCage() }
                        return
                    }
                    self.onLog?("拖窗探针: 鱼已进笼，开始搬窗口（每步 \(Int(stepPx))px，共 \(totalSteps) 步）")
                    self.onLog?("拖窗探针: 基线主窗=\(Int(origin0.x)),\(Int(origin0.y))")
                    sample("基线") { step(1) }
                }
            }
        }
        func step(_ i: Int) {
            guard i <= totalSteps else {
                sample("拖后静止") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        sample("拖后静止+0.8s") { stepBack(totalSteps) }
                    }
                }
                return
            }
            hw.setFrameOrigin(NSPoint(x: origin0.x + stepPx * CGFloat(i), y: origin0.y))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                if i % 5 == 0 || i == totalSteps { sample("移\(i)步") { step(i + 1) } } else { step(i + 1) }
            }
        }
        func stepBack(_ i: Int) {
            guard i >= 0 else {
                sample("复位后") {
                    self.onLog?("拖窗探针: 结束（主窗回到 \(Int(hw.frame.origin.x)),\(Int(hw.frame.origin.y))）")
                    self.onLog?("拖窗探针: 收尾 → 放开鱼（看浮层是否留在被搬走的位置）")
                    web.evaluateJavaScript("window.ftCageToggle && window.ftCageToggle()")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        sample("放鱼后") { self.onLog?("拖窗探针: 全部完成") }
                    }
                }
                return
            }
            hw.setFrameOrigin(NSPoint(x: origin0.x + stepPx * CGFloat(i), y: origin0.y))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { stepBack(i - (i > 0 ? 1 : 1)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { waitCage() }
    }

    /// 桌面浮层自拍（flag: /tmp/ft-deskpet-shot.flag）
    /// 桌面上的这只没法用 screencapture 取证（系统没给录屏权限，截出来只有壁纸），
    /// 但 WKWebView 可以给自己拍照 —— takeSnapshot 拿到的是**真机、真 DPI**的渲染，
    /// 这是验证「质地/配色/姿态」唯一不依赖权限的路子。
    /// 采样前先把它定住并**朝右游**：朝向镜像判据只有在移动中才验得出来
    /// （静止时它保持上一姿态，看不出一致性）。
    func shotTest(_ path: String = "/tmp/ft-deskpet-shot.png") {
        guard let web = webView else { return }
        web.evaluateJavaScript("window.ftPlace&&window.ftPlace(600,420);window.ftSwimTo&&window.ftSwimTo(1180,700);") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self, let web = self.webView else { return }
                // petRect 与页面报的是同一坐标系（webview 左上原点）→ 直接加边距即可
                let r = self.petRect.insetBy(dx: -34, dy: -34)
                let cfg = WKSnapshotConfiguration()
                cfg.rect = r
                cfg.snapshotWidth = NSNumber(value: Int(r.width * 4))     // 4× = 真机像素，看得到抗锯齿
                web.takeSnapshot(with: cfg) { img, err in
                    guard let img, let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        self.onLog?("自拍: 失败 \(err?.localizedDescription ?? "无图")")
                        return
                    }
                    try? png.write(to: URL(fileURLWithPath: path))
                    self.onLog?("自拍: 已写出 \(path)  (\(Int(r.width))×\(Int(r.height)) @4x)")
                    self.close()
                }
            }
        }
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
    private var skins: [String] = []   // 四套皮肤 CSS（0=暗金, 1=翡翠晨光, 2=猩红熔岩, 3=赛博离子）
    private var themeIndex = 0
    private let skinNames = ["暗金·深夜", "翡翠·晨光", "猩红·熔岩", "赛博·离子"]
    private var skinMenuItems: [NSMenuItem] = []
    private var shortcutMonitor: Any? // ⌥⌘1/2/3 快捷键监听（绕过 WKWebView 抢键）
    private var browserWindows: [NSWindow] = [] // 内置浏览器窗口（保持引用防释放）
    private var repaintWorkItem: DispatchWorkItem? // 强制重绘防抖
    private let voice = VoiceEngine()              // 语音引擎（原生 STT + 电平）
    private var voiceTick: Timer?                  // 判停轮询（200ms）
    private var voiceOn = false                    // 语音总开关状态（JS 是真相源，这里做镜像）
    private var voiceMenuItem: NSMenuItem?         // 菜单里的「语音输入」勾选态
    // ── 鱼的对答（2.19.0 / 2.21.6 连续对答）：麦克风收音借 VoiceEngine，回答走离屏网页版 ──
    private let fishChat = FishChatController()    // 离屏 chat.deepseek.com 会话（懒加载，首次提问才启动）
    private var fishConversation = false           // 连续对答会话进行中：答完自动再听，闲置才收摊
    private var fishSession = false                // 当前轮正在收音：引擎回调改道 deskpet 页
    private var fishOwnsEngine = false             // 引擎是为鱼会话开的 → 散场要关（2.22.0）
    private var prewarmOwned = false               // 引擎是「就近预热」开的 → 没转正就收工
    private var prewarmTimer: Timer?               // 预热 TTL（4s 内没开始对话就关引擎）
    private var lastPrewarmAt: TimeInterval = 0    // 预热冷却，别让鼠标来回划动反复启停引擎
    private var fishTurnIdle: TimeInterval = 30    // 本轮收音闲置上限（轮与轮之间压到 15s）
    private var fishWatchdog: Timer?               // 本轮「一直没人说话」的看门狗
    private var fishDiscardUntil: CFTimeInterval = 0  // 散场后 2s 内到达的 onFinal 一律丢弃（cancel 泄漏闸）
    private let deskPet = DeskPetController()      // 「放生」层：桌面小鲸鱼（独立全屏透明浮层）
    private let islandCtl = IslandController()     // 灵动岛：躲猫猫（顶部黑色胶囊 + 两只眼）
    private let cageCtl = CageOverlayController()  // 玻璃穹顶：主窗口子视图（回笼锚点，2.18.0）
    private var deskPetMenuItem: NSMenuItem?       // 菜单里的「桌面小鲸鱼」勾选态
    private var breedMenuItems: [NSMenuItem] = []  // 菜单里的「小鲸鱼造型」勾选态
    // 三款造型：键名与 deskpet.html 的 BREEDS 一一对应，顺序即菜单顺序
    private let breedKeys = ["calf", "orca", "clockwork"]
    private let breedNames = ["圆胖幼鲸", "虎鲸", "河道之灵"]
    private var breedIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 加载两套皮肤并读取上次选择
        skins = [
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-emerald-light", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-scarlet", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-cyber", ofType: "css") ?? "", encoding: .utf8)) ?? "",
        ]
        themeIndex = UserDefaults.standard.integer(forKey: "ftThemeIndex")
        if themeIndex >= skins.count { themeIndex = 0 }
        breedIndex = UserDefaults.standard.integer(forKey: "ftBreedIndex")
        if breedIndex >= breedKeys.count { breedIndex = 0 }
        buildMenu()
        installShortcuts()

        // ── 「放生」层：桌面小鲸鱼 ────────────────────────────────────────────
        // 先把当前皮肤的色喂进去（换肤时 applySkin 会再推一次），再按上次的开关
        // 决定要不要放生。日志并入主日志，排查时一条时间线看得完。
        let petSkin = DeskPetController.extractSkinVars(from: skins[themeIndex])
        deskPet.applySkin(vars: petSkin.vars, isLight: petSkin.isLight)
        deskPet.setBreed(breedKeys[breedIndex])   // 上次选的那只（未 ready 时先记着，ready 后推下去）
        deskPet.onLog = { msg in AppDelegate.log("[桌面鲸鱼] \(msg)") }
        islandCtl.onLog = { msg in AppDelegate.log("[灵动岛] \(msg)") }
        islandCtl.setup()
        deskPet.onIslandArrive = { [weak self] in self?.islandCtl.show(on: self?.deskPet.petScreen) }
        islandCtl.onRelease = { [weak self] in self?.deskPet.islandOut() }
        deskPet.harnessWindow = { [weak self] in self?.window }
        cageCtl.onLog = { msg in AppDelegate.log("[玻璃罩] \(msg)") }
        // 穹顶联动：页面只报笼中事件，原生转给主窗口里的玻璃罩；显隐随桌面鲸鱼开关
        deskPet.onCageEvent = { [weak self] ev in self?.cageCtl.apply(event: ev) }
        deskPet.onCageVisible = { [weak self] v in self?.cageCtl.setHidden(!v) }
        // 鱼的对答：chip 点击 → 原生收音会话；后台日志并入主日志；flag 自检（真发一条到网页版）
        deskPet.onFishMic = { [weak self] op in self?.fishMicOp(op) }
        deskPet.onNearHover = { [weak self] enter in self?.voicePrewarm(enter) }
        fishChat.onLog = { AppDelegate.log("[鱼对答] \($0)") }
        fishChat.selfTestIfFlagged()
        if UserDefaults.standard.bool(forKey: "ftDeskPet") {
            deskPet.open()
        }
        // 工作哨兵：1.2s 一次，只在鱼放生时真的发 JS（见 workTick 的两道 guard）。
        startWorkSentinel()
        // 自检（flag 驱动）：开 → 2 秒后打印窗口属性与页面状态 → 关机收尾。
        // /tmp/ft-deskpet-selftest.flag
        // 造型自检（flag 驱动）：/tmp/ft-breed-selftest.flag
        // 依次切三款并回收页面状态 —— 覆盖「菜单动作 → setBreed → 页面 ftBreed → 重建」整条链。
        // ★ 与投喂/穿透一样是临时探针，测完删 flag（留在盘上会每次启动都跑）。
        // 临时调试（flag 驱动，测完删 flag）：/tmp/ft-island-auto.flag → 5s 后菜单点名「躲猫猫」，
        // 让鲸鱼自己游进岛，配合 /tmp/ft-island-shot.flag 拿 wide/base 快照。
        if FileManager.default.fileExists(atPath: "/tmp/ft-island-auto.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.deskPet.islandGo()
                AppDelegate.log("调试: 自动触发躲猫猫")
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-breed-selftest.flag") {
            for (i, key) in breedKeys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0 + Double(i) * 3.0) { [weak self] in
                    guard let self else { return }
                    self.applyBreed(i, reason: "自检")
                    self.deskPet.state { s in AppDelegate.log("[桌面鲸鱼] 造型自检[\(key)] \(s)") }
                }
            }
        }
        // 桌面浮层自拍（flag 驱动，测完删 flag）：/tmp/ft-deskpet-shot.flag
        // 没录屏权限时唯一能拿到「真机真 DPI 渲染」的路子，见 DeskPetController.shotTest。
        // 能耗档位探针（临时，测完删 flag）
        if FileManager.default.fileExists(atPath: "/tmp/ft-power-probe.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.deskPet.powerProbe()
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-deskpet-shot.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.deskPet.shotTest()
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-deskpet-selftest.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.deskPet.selfTest()
            }
        }
        // 拖窗复现探针（flag 驱动，测完删 flag）：/tmp/ft-cagedrag.flag
        // 鱼进笼 + 应用自己搬主窗口 → 量「页面坐标系 vs 玻璃子视图」的错位，见 dragProbe。
        if FileManager.default.fileExists(atPath: "/tmp/ft-cagedrag.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.deskPet.dragProbe()
            }
        }
        // 工作哨兵探针（flag 驱动，测完删 flag）：/tmp/ft-sentinel.flag
        // 往真页面注入假「停止生成」/假审批卡，把「真页面 → 状态机 → 桌面鱼」跑通，约 33s。
        if FileManager.default.fileExists(atPath: "/tmp/ft-sentinel.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.sentinelProbe()
            }
        }

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
        // （生灵层 alive.js 已于 2.15.2 移除：窗口内小鲸鱼/机芯退役，
        //   桌面鲸鱼由 resources/deskpet.html 独立承担全部交互。）
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

        // ── 玻璃穹顶：主窗口子视图，钉左下、压在页面之上、切换钮之下（2.18.0）──
        // 子视图随动：窗口拖动/缩放零延迟跟随，永不越窗压到别的应用上。
        cageCtl.attach(to: container, below: chatToggleBtn)
        cageCtl.setSkin(vars: petSkin.vars, isLight: petSkin.isLight)
        cageCtl.setHidden(!deskPet.isOpen)

        // harness 窗口引用改「强捕获」版（2.21.3）：窗口建好了，把 weak-self 闭包换成
        // 直接捕获 NSWindow —— 调用侧不再走 AppDelegate 的 weak 表和 window ivar。
        // AppDelegate 与窗口同为进程生命周期，强捕获无副作用。
        if let hw = window {
            deskPet.harnessWindow = { hw }
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

        // 切换钮层级自检（flag 驱动）：换肤 + 切页走一遍，逐步打印视图树顺序
        if FileManager.default.fileExists(atPath: "/tmp/ft-toggle-z.flag") {
            toggleZSelfTest()
        }

        // 灵动岛快照自检（flag 驱动，与 IslandController 里的 shotSelfTest 配套）：
        // 启动 4s 后直接让岛现形，不用等鱼真的游进去
        if FileManager.default.fileExists(atPath: "/tmp/ft-island-shot.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.islandCtl.show(on: nil)
            }
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

    // ---------- 工作哨兵（2.24.0）----------
    //
    // 「鱼要知道 dsh 在忙什么、忙完来叫人，但**绝不能抢戏**」。原生侧只做三件事：
    //   ① 廉价地问一句主页面在不在跑 —— 单个 querySelector，不读 innerText、不触发布局
    //   ② 只报**跃迁**（开始跑 / 跑完 / 卡住 / 你回来了），绝不重复播报
    //   ③ 碎任务（< 8s）不吭声；一次卡顿只喊一次；关掉开关就一个 JS 都不发
    //
    // 判据来自 dsh 前端源码（dsh-client-ui-conversation），是**精确**判据而不是猜：
    //   primaryStops = running && subagent === null && (empty || blocked !== undefined)
    //   primaryLabel = primaryStops ? "停止生成"
    //                : (运行中且可插话 → "插话发送" / "排队发送")
    //                : "发送消息"
    // 所以「运行中」= 那个按钮的 aria-label ∈ {停止生成, 插话发送, 排队发送}。
    // ⚠️ 不能用「消息区 textContent 还在不在长」这种判据：读整棵会话树会每帧重排，
    //    刚把主页压到 1.5%，不能为了省一处猜疑把它赔回去。
    /// ⚠️ 查询必须**按优先级链式**（停止生成 → 插话发送 → 排队发送 → 发送消息），
    ///    不能写成逗号选择器：CSS 选择器列表返回的是**文档序第一个**命中 ——
    ///    实测（探针往页尾注入一个假「停止生成」按钮）时它读到的是真实输入框那个
    ///    「发送消息」，假按钮压根没被选中。生产里只有一个输入框按钮、看不出差别，
    ///    但链式查询在「页面上出现了第二处同类按钮」时仍然是它对。
    /// ⚠️ 这个判据失效时的表现是「哨兵不响了」——静默降级，**不会误报成「跑完了」**；
    //    再加「连续 2 次都不在跑才认完」，躲开按钮标签的瞬时抖动。
    private var workTimer: Timer?
    private var workBusy = false
    private var workBusyStart: CFAbsoluteTime = 0
    private var workCalmStreak = 0
    private var workStuckAt: CFAbsoluteTime = -1e9
    private var workApprCalm = 0
    private var workBubbleUp = false
    private var workSentinelMenuItem: NSMenuItem?

    private static let workRunLabels: Set<String> = ["停止生成", "插话发送", "排队发送"]
    private static let workProbeJS = """
    (function(){
      function q(l){return document.querySelector('button[aria-label="'+l+'"]');}
      var e=q('停止生成')||q('插话发送')||q('排队发送')||q('发送消息');
      return JSON.stringify({L:e?e.getAttribute('aria-label'):'',A:document.querySelectorAll('[data-approval-key]').length});
    })()
    """

    /// 开关默认开（UserDefaults 里没写过就是开）。
    private var workEnabled: Bool {
        UserDefaults.standard.object(forKey: "ftWorkSentinel") == nil
            ? true : UserDefaults.standard.bool(forKey: "ftWorkSentinel")
    }

    private func startWorkSentinel() {
        workTimer?.invalidate()
        workTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.workTick() }
        }
    }

    private func workTick() {
        guard workEnabled else { return }
        // 鱼没放生 → 没人可叫。这一次 JS 都不发（省掉一切开销）。
        guard deskPet.isOpen, let wv = webView else { return }
        wv.evaluateJavaScript(AppDelegate.workProbeJS) { r, _ in
            guard let str = r as? String, let d = str.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            let label = (o["L"] as? String) ?? ""
            let appr = ((o["A"] as? Int) ?? 0) > 0
            Task { @MainActor in self.applyWork(label: label, approval: appr) }
        }
    }

    private func workReset() {
        workBusy = false
        workCalmStreak = 0
        workStuckAt = -1e9
        workApprCalm = 0
        workBubbleUp = false
        deskPet.work("idle")
    }

    private func applyWork(label: String, approval: Bool, idleOverride: Double? = nil) {
        guard workEnabled, deskPet.isOpen else { return }
        let t = CFAbsoluteTimeGetCurrent()
        let idle = idleOverride ?? AppDelegate.systemIdleSeconds()
        let running = AppDelegate.workRunLabels.contains(label)

        // ① 卡在等你授权 —— 优先级最高，独立判定。这种时候你不去点，它就一直干等，
        //    而你现在根本不知道。授权消失后（连续 2 次）解除冷却，下一次卡顿照样喊。
        if approval {
            workApprCalm = 0
            if t - workStuckAt > 90 {
                workStuckAt = t
                workBubbleUp = true
                deskPet.work("stuck")
                AppDelegate.log("[工作哨兵] dsh 停下来等授权 → 叫鱼（你 \(Int(idle))s 前动过）")
                if idle > 180 { softChime() }   // 你不在屏幕前：气泡没人看，才首发声
            }
            return
        } else if workStuckAt > -1e8 {
            workApprCalm += 1
            if workApprCalm >= 2 { workStuckAt = -1e9; workApprCalm = 0 }
        }

        // ② 在跑 / 跑完
        if running {
            workCalmStreak = 0
            if !workBusy {
                workBusy = true
                workBusyStart = t
                deskPet.work("busy")
                AppDelegate.log("[工作哨兵] dsh 开始跑（鱼摆尾变急）")
            }
        } else if workBusy {
            workCalmStreak += 1
            if workCalmStreak >= 2 {          // 连续 2 次（≈2.4s）才算真完
                workBusy = false
                let dur = t - workBusyStart
                if dur >= 8 {
                    let away = idle > 180
                    workBubbleUp = true
                    deskPet.work(away ? "doneAway" : "done", Int(dur * 1000))
                    AppDelegate.log(String(format: "[工作哨兵] 跑完 %.1fs（%@）",
                                           dur, away ? "你不在 → 游到中部等你" : "你在 → 一行小字"))
                } else {
                    AppDelegate.log(String(format: "[工作哨兵] 跑完 %.1fs：碎任务，不吭声", dur))
                }
            }
        }

        // ③ 你回来了 → 收工（页面侧把气泡再留 8s，让人来得及看）
        if workBubbleUp && idle < 3 {
            workBubbleUp = false
            deskPet.work("idle")
            AppDelegate.log("[工作哨兵] 你回来了 → 收工")
        }
    }

    /// 工作哨兵探针（flag 驱动，测完删 flag）：/tmp/ft-sentinel.flag
    /// 不必真让 dsh 跑一个长任务 —— 往**真页面**里注入一个假的 aria-label="停止生成"
    /// 按钮 / 一个假的 [data-approval-key] 卡片，就能把整条链路
    /// （真页面 → 探针 JS → 状态机 → 桌面鱼）跑通；「你不在」那一路用 idleOverride 走。
    /// 探针的判据是日志里的 [工作哨兵] 行 + 鱼的实际动作（连跑两次可对照）。
    func sentinelProbe() {
        guard deskPet.isOpen else {
            AppDelegate.log("[哨兵探针] 鱼没放生 → 跳过（先在菜单里放生）")
            return
        }
        AppDelegate.log("[哨兵探针] 开始：开关=\(workEnabled) 鱼=放生中")
        let JS_STOP_ON = "(function(){if(document.getElementById('ft-fake-stop'))return 'exists';var b=document.createElement('button');b.id='ft-fake-stop';b.setAttribute('aria-label','停止生成');b.style.cssText='position:fixed;left:-9999px;top:0;width:0;height:0;padding:0;border:0;overflow:hidden';document.body.appendChild(b);return 'injected';})()"
        let JS_STOP_OFF = "(function(){var b=document.getElementById('ft-fake-stop');if(!b)return 'absent';b.remove();return 'removed';})()"
        let JS_APPR_ON = "(function(){if(document.getElementById('ft-fake-appr'))return 'exists';var d=document.createElement('div');d.id='ft-fake-appr';d.setAttribute('data-approval-key','probe');d.style.cssText='position:fixed;left:-9999px;top:0;width:0;height:0';document.body.appendChild(d);return 'injected';})()"
        let JS_APPR_OFF = "(function(){var d=document.getElementById('ft-fake-appr');if(!d)return 'absent';d.remove();return 'removed';})()"

        func run(_ js: String, _ tag: String) {
            webView?.evaluateJavaScript(js) { r, _ in
                AppDelegate.log("[哨兵探针] \(tag): \(r as? String ?? "nil")")
            }
        }
        func later(_ sec: Double, _ f: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { f() }
        }
        func readProbe(_ tag: String) {
            webView?.evaluateJavaScript(AppDelegate.workProbeJS) { r, _ in
                AppDelegate.log("[哨兵探针] \(tag) 真页面读数: \(r as? String ?? "nil")")
            }
        }

        later(1.0) { run(JS_STOP_ON, "注入假「停止生成」按钮") }
        later(4.0) { readProbe("忙态中") }          // 证明探针 JS 真的读到了真页面
        later(11.0) { run(JS_STOP_OFF, "撤掉假按钮") }
        later(15.5) { readProbe("撤掉后") }         // 状态机应在 ~13.4s 判完 → 已报 done
        // 「你不在」那一路：直接把上一轮当作刚跑完的一个 200s 长任务
        later(16.5) { [weak self] in
            guard let self else { return }
            self.workBusy = true
            self.workBusyStart = CFAbsoluteTimeGetCurrent() - 200
            self.workCalmStreak = 1
            self.applyWork(label: "", approval: false, idleOverride: 999)
            self.applyWork(label: "", approval: false, idleOverride: 999)
        }
        later(20.0) { run(JS_APPR_ON, "注入假审批卡片") }
        later(23.0) { readProbe("卡住中") }
        later(27.0) { run(JS_APPR_OFF, "撤掉假审批卡片") }
        // 第四段：碎任务（< 8s）不该吭声
        later(29.0) { run(JS_STOP_ON, "注入假按钮（碎任务）") }
        later(33.5) { run(JS_STOP_OFF, "撤掉（只跑了 4.5s）") }
        later(38.0) { [weak self] in
            guard let self else { return }
            self.applyWork(label: "", approval: false, idleOverride: 999)   // 冷却应已解除
            AppDelegate.log("[哨兵探针] 收尾：busy=\(self.workBusy) 气泡在=\(self.workBubbleUp)")
        }
    }

    /// 系统级「键鼠多久没动」。CGEventSource 这条路**不需要辅助功能权限**
    /// （osascript 驱动窗口才需要，而且会被判「权限违例」）。
    private static func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        var best = Double.greatestFiniteMagnitude
        for ty in types {
            let v = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: ty)
            if v >= 0 && v < best { best = v }
        }
        return best == .greatestFiniteMagnitude ? 0 : best
    }

    /// 轻响：**只在「卡住了 + 你不在屏幕前」**才发 —— 那时气泡没人看见，声音才有用。
    private func softChime() {
        let s = NSSound(named: NSSound.Name("Tink")) ?? NSSound(named: NSSound.Name("Ping"))
        s?.volume = 0.3
        s?.play()
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
        // 桌面小鲸鱼同步换肤：解析的也是这份 CSS，所以桌面那只与窗口里那只永远同色
        let skinVars = DeskPetController.extractSkinVars(from: css)
        deskPet.applySkin(vars: skinVars.vars, isLight: skinVars.isLight)
        // 玻璃穹顶同步换肤（主窗口子视图那层）
        cageCtl.setSkin(vars: skinVars.vars, isLight: skinVars.isLight)
        // 切换胶囊钮的底色描边跟着皮肤深浅换装
        styleChatToggle()
        AppDelegate.log("已切换皮肤: \(skinNames[themeIndex])")
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        applySkin(sender.tag)
    }

    // 切换桌面小鲸鱼的造型。选完立刻推给浮层（浮层没开着也先记着，下次放生即是这款）。
    @objc private func selectBreed(_ sender: NSMenuItem) {
        applyBreed(sender.tag, reason: "菜单")
    }

    /// 造型切换的唯一入口：菜单点选与 flag 自检都走这里，免得两条路各写一份。
    @discardableResult
    private func applyBreed(_ i: Int, reason: String) -> Bool {
        guard i >= 0 && i < breedKeys.count else { return false }
        breedIndex = i
        UserDefaults.standard.set(i, forKey: "ftBreedIndex")
        for (k, item) in breedMenuItems.enumerated() {
            item.state = (k == breedIndex) ? .on : .off
        }
        deskPet.setBreed(breedKeys[i])
        AppDelegate.log("桌面小鲸鱼造型: \(breedNames[i])（\(reason)）")
        return true
    }

    // 语音菜单项 → 交给 voice.js 的状态机（这里不自己维护开关，避免两处状态不一致）
    @objc private func toggleVoiceMenu(_ sender: NSMenuItem) {
        activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.toggle()") { _, _ in }
    }

    @objc private func listenOnce(_ sender: NSMenuItem) {
        activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.listenOnce()") { _, _ in }
    }

    // 「回笼 / 出笼」：菜单点名让鲸鱼自己游回笼子（关着时则放它出来）
    @objc func cageToggleWhale(_ sender: Any?) {
        deskPet.cageToggle()
        AppDelegate.log("菜单: 鲸鱼回笼/出笼")
    }
    // 「躲猫猫」：让鲸鱼游向屏幕顶端的灵动岛口
    @objc func islandPeekWhale(_ sender: Any?) {
        deskPet.islandGo()
        AppDelegate.log("菜单: 躲猫猫（灵动岛）")
    }

    // 「放生」开关：开/关桌面小鲸鱼（独立全屏透明浮层，与主窗口互不影响）。
    // 勾选态落 UserDefaults，下次启动自动放生。
    @objc private func toggleDeskPet(_ sender: NSMenuItem) {
        deskPet.toggle()
        let on = deskPet.isOpen
        sender.state = on ? .on : .off
        deskPetMenuItem?.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: "ftDeskPet")
        AppDelegate.log("桌面小鲸鱼: \(on ? "已放生到桌面" : "已收回窗口")")
    }

    // 「工作哨兵」开关：默认开。关掉后原生一个 JS 都不发，鱼完全不知道 dsh 在干什么。
    @objc private func toggleWorkSentinel(_ sender: NSMenuItem) {
        let on = !workEnabled
        UserDefaults.standard.set(on, forKey: "ftWorkSentinel")
        sender.state = on ? .on : .off
        workSentinelMenuItem?.state = on ? .on : .off
        if !on { workReset() }
        AppDelegate.log("工作哨兵: \(on ? "开" : "关")")
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
        // 必须插在切换钮**下方**、玻璃罩**下方**。切换钮与两个 WebView、玻璃罩是兄弟，
        // 层级只由加入顺序决定：裸 addSubview 会把新聊天页盖到钮/玻璃罩上面 →
        // 切到聊天页后「回主页」的入口和回笼穹顶整个消失，而主页那侧因为 webView
        // 在更下层，完全看不出问题（症状因此显得很怪）。换肤走 refreshChatSkin()
        // 重建本页，正是唯一的触发路径。
        if let cageHost = cageCtl.hostView {
            container.addSubview(wv, positioned: .below, relativeTo: cageHost)
        } else if let btn = chatToggleBtn {
            container.addSubview(wv, positioned: .below, relativeTo: btn)
        } else {
            container.addSubview(wv)      // 首次创建：钮还没建，稍后它自己会插到最上层
        }
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
        ensureToggleOnTop()      // 到达页一律不许压在切换钮之上（护栏，见 ensureToggleOnTop）
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

    /// 兜底护栏：把切换钮重新排到兄弟列表的最后（= 最上层）。
    /// 用 sortSubviews **就地重排**，而不是 removeFromSuperview + addSubview —— 后者会连带
    /// 卸掉按钮与容器之间的 Auto Layout 约束（约束由共同祖先持有，视图一离开就失效；
    /// 实测约束从 2 条变 0 条），结果钮虽然浮上来却失去定位，变成贴在角上乱漂的胶囊。
    /// 注意：sortSubviews 要的是 **C 函数指针**，闭包不许捕获外部变量，
    /// 所以按钮只能经 context 指针进去（写成闭包捕获 btn 会在全量编译期报
    /// "a C function pointer cannot be formed from a closure that captures context"，
    /// 而 `swiftc -typecheck` 不报 —— 别再用 typecheck 给自己发通行证）。
    private func ensureToggleOnTop() {
        guard let btn = chatToggleBtn, let sup = btn.superview, sup.subviews.last !== btn else { return }
        let before = sup.subviews.firstIndex(of: btn) ?? -1
        // 两档排序：钮最上，玻璃罩次之（穹顶也绝不能被重建出来的页面盖住），
        // 其余（两个页面）相对顺序不动。C 函数指针不支持捕获 → 名次经 context 指针带进去。
        final class ZRankCtx {
            weak var btn: NSButton?
            weak var cage: NSView?
            func rank(_ v: NSView) -> Int { v === btn ? 2 : (v === cage ? 1 : 0) }
        }
        let ctx = ZRankCtx()
        ctx.btn = btn
        ctx.cage = cageCtl.hostView
        let holder = Unmanaged.passRetained(ctx)
        sup.sortSubviews({ a, b, raw in
            guard let raw else { return .orderedSame }
            let c = Unmanaged<ZRankCtx>.fromOpaque(raw).takeUnretainedValue()
            let ra = c.rank(a), rb = c.rank(b)
            if ra < rb { return .orderedAscending }    // 排在前面 = 画在下层
            if ra > rb { return .orderedDescending }
            return .orderedSame
        }, context: holder.toOpaque())
        holder.release()
        let after = sup.subviews.firstIndex(of: btn) ?? -1
        let cageIdx = sup.subviews.firstIndex(where: { $0 === ctx.cage }) ?? -1
        AppDelegate.log("切换钮置顶: \(before) → \(after)/\(sup.subviews.count - 1)（玻璃罩=\(cageIdx)）")
    }

    /// 层级自检：直接把「谁盖着谁」打成一行日志。
    /// 为什么不做可视化判据：截图里按钮「没出现」与「被盖住」长得一模一样，
    /// 只有视图树的顺序能一次说清，而且不需要给运行中的 app 加任何权限。
    private func logToggleStack(_ tag: String) {
        guard let btn = chatToggleBtn, let sup = btn.superview else {
            AppDelegate.log("层级自检[\(tag)]: ⚠️ 切换钮不在视图树里")
            return
        }
        let subs = sup.subviews
        let bi = subs.firstIndex(of: btn) ?? -1
        let chatIdx = subs.firstIndex(where: { $0 === chatWebView })
        // 可见且排在按钮之上的 WebView = 正在遮住按钮的那一页
        let covering = subs.enumerated().compactMap { (i, v) -> String? in
            guard v is WKWebView, !v.isHidden, i > bi else { return nil }
            return "\(i)"
        }
        let list = subs.enumerated().map { i, v in
            "\(i)=\(String(describing: type(of: v)))\(v.isHidden ? "·隐" : "")"
        }.joined(separator: " ")
        AppDelegate.log("层级自检[\(tag)]: 钮=\(bi)/\(subs.count - 1) 聊天页=\(chatIdx.map(String.init) ?? "-") "
            + "判定=\(covering.isEmpty ? "OK（钮在最上层）" : "⚠️ 被序号 \(covering.joined(separator: ",")) 的可见页盖住") | \(list)")
    }

    /// 切换钮层级自检（flag: /tmp/ft-toggle-z.flag）：走一遍「换肤 → 切聊天 → 在聊天页里再换肤 → 切回」，
    /// 每一步都打一次视图树。最后一种顺序（重建一个**正在显示**的页面）是最狠的，
    /// 也正是「切到聊天页后发现按钮没了」最可能的真实时序。
    /// 收尾时皮肤一定会回到原样、页面停在主页，不会留下测试痕迹。
    private func toggleZSelfTest() {
        let orig = themeIndex
        let other = (themeIndex == 1) ? 0 : 1
        AppDelegate.log("层级自检: 开始（起始皮肤=\(skinNames[orig])）")
        let step: [(Double, () -> Void)] = [
            (1.0, { [weak self] in self?.logToggleStack("启动（主页）") }),
            (1.6, { [weak self] in self?.applySkin(other) }),
            (2.6, { [weak self] in self?.logToggleStack("主页换肤后（重建聊天页）") }),
            (3.2, { [weak self] in self?.toggleChatMode(nil) }),
            (4.3, { [weak self] in self?.logToggleStack("切到聊天页后") }),
            (4.9, { [weak self] in self?.applySkin(orig) }),
            (6.1, { [weak self] in self?.logToggleStack("在聊天页里换肤后（重建正在显示的页）") }),
            (6.7, { [weak self] in self?.toggleChatMode(nil) }),
            (7.6, { [weak self] in self?.logToggleStack("切回主页后（皮肤已复原）") }),
            (7.8, { AppDelegate.log("层级自检: 结束") }),
        ]
        for (delay, run) in step {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
        }
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
        // 「放生」：把窗口里那只小鲸鱼放到桌面上 —— 一块覆盖全屏的透明浮层，
        // 鲸鱼在其中游动，其余区域完全透明且不挡鼠标（穿透由 DeskPetController 轮询控制）。
        appMenu.addItem(.separator())
        let petItem = NSMenuItem(title: "桌面小鲸鱼（放生到桌面）", action: #selector(toggleDeskPet(_:)), keyEquivalent: "p")
        petItem.keyEquivalentModifierMask = [.command, .option]
        petItem.target = self
        petItem.state = UserDefaults.standard.bool(forKey: "ftDeskPet") ? .on : .off
        deskPetMenuItem = petItem
        appMenu.addItem(petItem)
        // 造型：三款可换。做法与「切换皮肤」一致（子菜单 + 勾选态），选完落 UserDefaults。
        let breedItem = NSMenuItem(title: "小鲸鱼造型", action: nil, keyEquivalent: "")
        let breedSubmenu = NSMenu()
        for (i, name) in breedNames.enumerated() {
            let mi = NSMenuItem(title: name, action: #selector(selectBreed(_:)), keyEquivalent: "")
            mi.tag = i
            mi.target = self
            mi.state = (i == breedIndex) ? .on : .off
            breedMenuItems.append(mi)
            breedSubmenu.addItem(mi)
        }
        breedItem.submenu = breedSubmenu
        appMenu.addItem(breedItem)
        appMenu.addItem(.separator())
        // 回笼 / 躲猫猫：键鼠选择 = 「让它自己回去」的入口
        let cageItem = NSMenuItem(title: "鲸鱼回笼 / 放它出笼", action: #selector(cageToggleWhale(_:)), keyEquivalent: "")
        cageItem.target = self
        appMenu.addItem(cageItem)
        let islandItem = NSMenuItem(title: "躲猫猫（游进灵动岛）", action: #selector(islandPeekWhale(_:)), keyEquivalent: "")
        islandItem.target = self
        appMenu.addItem(islandItem)
        // 工作哨兵：让鱼知道 dsh 在忙什么（忙→摆尾变急 / 跑完→来叫人 / 卡在授权→翻肚皮）。
        // 默认开，一个开关就能整个关掉（关掉后原生一个 JS 都不发）。
        let sentinelItem = NSMenuItem(title: "工作哨兵（鱼知道 dsh 在忙什么）", action: #selector(toggleWorkSentinel(_:)), keyEquivalent: "")
        sentinelItem.target = self
        sentinelItem.state = workEnabled ? .on : .off
        workSentinelMenuItem = sentinelItem
        appMenu.addItem(sentinelItem)
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
        let breedItems = (breedItem.submenu?.items ?? [])
            .map { "\($0.title)\($0.state == .on ? "←当前" : "")[\($0.action.map { NSStringFromSelector($0) } ?? "-")]" }
            .joined(separator: " ")
        AppDelegate.log("菜单自检: [\(menus)] 编辑菜单项: \(editItems) 造型项: \(breedItems)")
    }

    // 读取内置皮肤 CSS，生成注入脚本（在页面最早期注入，避免闪烁）

    // ---------- 语音：原生引擎 ↔ 注入层（voice.js）的桥 ----------
    // 分工：原生负责「听」（识别 + 电平 + 唤醒词 + 判停），JS 负责「看起来」和「送进 harness」。
    private func setupVoice() {
        voice.onLog = { msg in AppDelegate.log("语音: \(msg)") }
        // ── 归属仲裁（2.21.9 照搬主程序对话逻辑）──────────────────────────
        // 主程序（voice.js）能稳定连续对答，靠两条铁律：
        //   ① 「它在想/答」的整段时间引擎暂停（busy 协议），不收音、不出 partial；
        //   ② 引擎事件只进当前归属方，绝不漏给另一边。
        // 鱼对答此前两条都破：thinking 期间 partial/电平/bargeIn 漏给主页 voice.js，
        // 主页被误触发 manualStart 抢引擎，下一轮鱼再 manualStart 又把缓冲冲掉 ——
        // 「一句话被截断、第二句发不出去」正是这条链。现在收拢：fishConversation
        // 为真时引擎只属于鱼。
        voice.onError = { [weak self] msg in
            AppDelegate.log("语音错误: \(msg)")
            guard let self else { return }
            if self.fishConversation { self.deskPet.fishCall("error", AppDelegate.jsStringLiteral(msg)) }
            else { self.voiceCall("error", AppDelegate.jsStringLiteral(msg)) }
        }
        voice.onNotice = { [weak self] msg in
            AppDelegate.log("语音觉察: \(msg)")
            guard let self else { return }
            if self.fishSession {
                // 收音中的可恢复小状况（没听清等）：整场收摊回 idle，别挂着一直收音
                self.fishEndConversation()
                self.deskPet.fishCall("notice", AppDelegate.jsStringLiteral(msg))
            } else if self.fishConversation {
                // thinking 期的杂音（长等待后 12s 暂停兜底自动恢复、ambient 请求空转失败）：
                // 只记日志，别把一场好好的对话杀掉
            } else {
                self.voiceCall("notice", AppDelegate.jsStringLiteral(msg))
            }
        }
        voice.onLevels = { [weak self] bands in
            guard let self = self else { return }
            var s = ""
            s.reserveCapacity(bands.count * 6)
            for (i, v) in bands.enumerated() {
                if i > 0 { s += "," }
                s += String(format: "%.3f", v)
            }
            if self.fishConversation {
                self.deskPet.fishCall("levels", "[\(s)]")     // JS 侧只在 listening 态消费
            } else {
                self.activeVoiceWebView()?.evaluateJavaScript("window.__ftVoice&&window.__ftVoice.levels([\(s)])") { _, _ in }
            }
        }
        voice.onPartial = { [weak self] text, isFinal in
            guard let self else { return }
            if self.fishSession {
                if !text.isEmpty { self.fishTouchWatchdog() }   // 人还在说：闲置看门狗顺延
                self.deskPet.fishCall("partial", AppDelegate.jsStringLiteral(text), isFinal ? "true" : "false")
            } else if self.fishConversation {
                // busy 暂停期本不该有 partial（喂流已断）；万一漏网只丢弃，绝不喂主页
            } else {
                self.voiceCall("partial", AppDelegate.jsStringLiteral(text), isFinal ? "true" : "false")
            }
        }
        voice.onWake = { [weak self] word in
            guard let self else { return }
            guard !self.fishConversation else { return }   // 鱼会话期免唤醒直听，唤醒词不归主页
            self.voiceCall("wake", AppDelegate.jsStringLiteral(word))
        }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            if CACurrentMediaTime() < self.fishDiscardUntil {
                AppDelegate.log("鱼对答：散场冷却期到达的定稿已丢弃「\(text)」")
            } else if self.fishSession {
                self.fishHeard(text)
            } else if self.fishConversation {
                // 轮已收（判停竞态）但会话还在：这半句当没听见，等回复后的下一轮
                AppDelegate.log("鱼对答：非收音期到达的定稿已忽略「\(text)」")
            } else {
                self.voiceCall("final", AppDelegate.jsStringLiteral(text))
            }
        }
        voice.onBargeIn = { [weak self] in
            guard let self else { return }
            guard !self.fishConversation else { return }   // 鱼没有朗读可打断；别把主页误触发成捕捉
            self.voiceCall("bargeIn")
        }
        voice.onPause = { [weak self] p, hasText in
            guard let self else { return }
            guard !self.fishConversation else { return }   // 判停读秒是主页 HUD 的东西，鱼气泡没有
            self.voiceCall("pause", String(format: "%.3f", p), hasText ? "true" : "false")
        }
        // 识别通路变了（设备端 ↔ 网络）要把新状态推给 JS，否则界面上看不出来
        voice.onModeChange = { [weak self] in self?.pushVoiceStatus() }

        // 判停轮询：100ms 一次。它同时是「判停进度」的采样源，间隔就是倒计时条的锚点密度
        // （200ms 在 1.2 秒的停顿里只有 6 个锚点，倒计时会一跳一跳的）。
        voiceTick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.voice.tick()
        }

        // 启动不再预热（2.22.0 回退 2.21.10 的常驻方案）：实测常驻让音频链路 7×24 跑
        // 回声消除 DSP（空闲约 16% 单核），并让 coreaudiod 一直持有
        // PreventUserIdleSystemSleep（系统无法空闲休眠）—— 用户反馈「发热严重、掉电快」。
        // 取代方案三条：①鼠标凑近小鱼 0.3s → 就近预热（4s 内没点就收工）；
        // ②点 chip 当场起引擎（预卷缓冲同步开始填）；③散场即关引擎。空闲彻底零音频占用。
        // 这里只做权限预检 —— 不启动音频，不占麦克风、不占 CPU。
        voice.requestPermissions { _, why in
            AppDelegate.log("语音权限预检: \(why)")
        }
        AppDelegate.log("语音桥已就绪")
    }

    // ── 鱼的对答（2.19.0）：收音会话生命周期 ─────────────────────────────────
    // 一句话的旅程（2.21.6 连续对答）：chip 点击 → 收音 → 判停定稿 → 网页版问答
    // → 回复进气泡 → **自动再听** → 循环；轮与轮之间闲置 15s（首轮 30s）没人说话
    // → 静默收摊、引擎物归原主、鱼恢复自由活动。
    /// 就近预热（2.22.0）：鼠标在小鱼/轮盘命中区停留 0.3s → 先把音频引擎转起来。
    /// 为什么不是常驻：常驻让回声消除 DSP 7×24 占着 CPU（实测空闲 ~16% 单核）并挡住
    /// 系统空闲休眠；为什么不能纯按需：点 chip 那一刻才冷启动，开场白会掉在启动窗口里。
    /// 折中 = 只在人明确凑近准备点的时候转起来，4s 内没开始对话就收工。
    /// 冷却 8s：鼠标贴着鱼蹭来蹭去不会把引擎反复启停（每次启停都要重建采集链路）。
    private func voicePrewarm(_ enter: Bool) {
        guard enter, !voiceOn, !fishConversation, !voice.running else { return }
        let now = CACurrentMediaTime()
        guard now - lastPrewarmAt > 8 else { return }
        lastPrewarmAt = now
        voice.requestPermissions { [weak self] ok, why in
            guard let self else { return }
            guard ok else { AppDelegate.log("就近预热跳过（\(why)）"); return }
            guard !self.voiceOn, !self.fishConversation, !self.voice.running else { return }
            self.prewarmOwned = true
            self.voice.start()
            AppDelegate.log("就近预热：鼠标凑近小鱼 → 引擎先转起来（4s 内没开始对话就收工）")
            self.prewarmTimer?.invalidate()
            self.prewarmTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.prewarmTimer = nil
                // 先摘掉所有权标记：无论后面关不关引擎，这轮预热都结束了
                // （不摘的话，若期间 harness 语音接管了引擎，标记会一直挂到会话散场）
                let owned = self.prewarmOwned
                self.prewarmOwned = false
                guard owned, !self.fishConversation, !self.voiceOn else { return }
                self.voice.stop()
                AppDelegate.log("就近预热超时 → 引擎收工（空闲回到零音频占用）")
            }
        }
    }

    private func fishMicOp(_ op: String) {
        if op == "cancel" {
            guard fishSession || fishConversation else { return }
            // 用户点 chip = 结束整场对话。正捕到一半的话直接丢弃：
            // 引擎散场后继续常驻，半句会在 1.2s 后从 onFinal 冒出来，那时会话已散场
            // —— 用 discard 窗口把它吞掉，别泄漏给 harness 页。
            fishDiscardUntil = CACurrentMediaTime() + 2.0
            fishEndConversation()
            deskPet.fishCall("state", AppDelegate.jsStringLiteral("idle"))
            AppDelegate.log("鱼对答：用户结束对话")
            return
        }
        guard !fishConversation else { return }     // 会话进行中：再点 chip 由 cancel 分支处理
        AppDelegate.log("鱼对答：开始连续对答会话")
        voice.requestPermissions { [weak self] ok, why in
            guard let self else { return }
            AppDelegate.log("鱼对答权限: \(why)")
            guard ok else {
                self.deskPet.fishCall("error", AppDelegate.jsStringLiteral(why))
                return
            }
            if !self.voice.running {
                self.fishOwnsEngine = true      // 引擎是为这场会话开的 → 散场要关掉（2.22.0）
                self.voice.start()
            } else if self.prewarmOwned {
                // 就近预热已经把引擎转起来了 → 转正：所有权交给这场会话，散场照关
                self.prewarmOwned = false
                self.prewarmTimer?.invalidate(); self.prewarmTimer = nil
                self.fishOwnsEngine = true
            }
            self.fishConversation = true
            self.fishStartTurn(idle: 30)                    // 首轮给宽一点：30s 内开口
        }
    }

    /// 开一轮收音：进捕捉态 + 挂「本轮没人说话」看门狗。
    private func fishStartTurn(idle: TimeInterval) {
        fishTurnIdle = idle
        voice.manualStart()                        // 绕过唤醒词直接进捕捉态（= 主程序 armCapture 的 manualStart 同款）
        fishSession = true
        deskPet.fishCall("state", AppDelegate.jsStringLiteral("listening"))
        fishRearmWatchdog()
    }

    /// 看门狗：本轮闲置超时 → 静默收摊（提示语交给 notice 气泡，5s 自灭）。
    private func fishRearmWatchdog() {
        fishWatchdog?.invalidate()
        fishWatchdog = Timer.scheduledTimer(withTimeInterval: fishTurnIdle, repeats: false) { [weak self] _ in
            guard let self, self.fishSession else { return }
            AppDelegate.log("鱼对答：本轮 \(Int(self.fishTurnIdle))s 无语音 → 自动收摊")
            self.fishEndConversation()
            self.deskPet.fishCall("notice", AppDelegate.jsStringLiteral("先去游会儿，想聊再叫我"))
        }
    }

    /// 用户还在说 → 看门狗顺延（长句不被闲置计时误杀）。
    private func fishTouchWatchdog() {
        guard fishSession else { return }
        fishRearmWatchdog()
    }

    /// 判停定稿：一轮收音结束，问题送离屏网页版；回复后自动开下一轮。
    private func fishHeard(_ text: String) {
        fishSession = false
        fishWatchdog?.invalidate(); fishWatchdog = nil
        deskPet.fishCall("state", AppDelegate.jsStringLiteral("thinking"))
        // 照搬主程序 busy 协议（voice.js thinking 态同款）：等网页版的整段时间
        // 引擎暂停收音 —— 这段时间说的话和主页一样「不捕捉」，既不会漏给主页，
        // 也不会在回复落地的瞬间被下一轮 manualStart 把缓冲冲掉（截断的根源）。
        voice.setBusy(true)
        AppDelegate.log("鱼对答：听到「\(text)」→ 送网页版")
        fishChat.cancelPending()               // 连珠炮：新问题顶掉没答完的旧问题
        fishChat.ask(text) { [weak self] reply, err in
            guard let self else { return }
            if let reply, !reply.isEmpty {
                AppDelegate.log("鱼对答：网页版回复 \(reply.count) 字：「\(String(reply.prefix(30)))」")
                self.deskPet.fishCall("reply", AppDelegate.jsStringLiteral(reply))
                self.fishNextTurn()
            } else if let err {
                AppDelegate.log("鱼对答失败: \(err)")
                self.deskPet.fishCall("error", AppDelegate.jsStringLiteral(err))
                self.fishEndConversation()     // 出错散场：别把用户晾在一个哑掉的会话里
            } else {
                AppDelegate.log("鱼对答：旧问题被新问题顶掉（静默）")
            }
        }
    }

    /// 回复已进气泡 → 自动开下一轮收音（闲置 15s 没人说话就收摊）。
    private func fishNextTurn() {
        guard fishConversation else { return }
        if !voice.running { voice.start() }    // 保险：整场会话期间引擎不该掉线
        // 先解除 thinking 期的暂停（主程序：JS 收到回复先 busy(false) 再开下一轮），
        // 再开捕捉 —— 顺序反了 manualStart 会在 paused 下空转。
        voice.setBusy(false)
        fishStartTurn(idle: 15)
    }

    /// 散场：会话标志清掉、引擎物归原主（为鱼临时开的就关掉，harness 语音在跑的不动）。
    private func fishEndConversation() {
        fishConversation = false
        fishSession = false
        fishWatchdog?.invalidate(); fishWatchdog = nil
        voice.setBusy(false)                       // 可能散场在 thinking 期（点 chip 收摊）：别把引擎留在暂停里聋掉
        // 关引擎（2.22.0）：为鱼开的引擎散场即收工 —— 空闲回到零音频占用（不占 CPU、
        // 不挡系统休眠、麦克风指示灯灭）。harness 语音还开着（voiceOn）就不动它，
        // 那是用户在用的常驻监听。冷启动丢字改由「就近预热 + chip 当场起引擎 + 预卷」覆盖。
        if fishOwnsEngine {
            fishOwnsEngine = false
            if !voiceOn { voice.stop() }
        }
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
    // 与 skinUserScript 同一套约定（失败只记日志、不抛），便于后续加脚本不改结构。
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
              av.style.cssText = 'position:absolute;right:-48px;top:4px;width:32px;height:32px;border-radius:8px;border:1px solid var(--ft-accent-soft);background:var(--ft-accent-bg);box-shadow:0 0 6px var(--ft-accent-bg);';
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
