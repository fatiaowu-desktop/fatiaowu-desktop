# 发条屋 · 社区转发文案

## V2EX 版（技术社区，直接复制）

标题：给 DeepSeek Harness 写了原生 macOS 外壳「发条屋」——三套皮肤 / 全界面毛玻璃 / 余额监控，开源了

正文：
给 DeepSeek Harness 写了个原生 macOS 桌面外壳「发条屋」——Swift + AppKit + WKWebView，整个 App 只有 1.6MB（不打包浏览器），打开即用。

（截图上图：暗金·深夜 / 翡翠·晨光 / 猩红·熔岩）

亮点：
- 三套手搓皮肤：工作用暗金·深夜，护眼用翡翠·晨光，氛围用猩红·熔岩，⌥⌘1/2/3 秒切
- 全界面毛玻璃：气泡、输入卡、侧栏、标题栏、权限弹窗全部 frosted glass
- 无缝粒子动画：猩红熔岩粒子+烟尘+光晕呼吸、暗金工作区萤火虫星尘，循环零跳帧
- 余额监控：DeepSeek 官方 API，实时显示余额和本次消费
- 内置浏览器：会话里点外部链接直接在 App 内打开
- 表情面板、鲸鱼头像、完整会话统计

开源（MIT）：https://github.com/fatiaowu-desktop/fatiaowu-desktop
DSH 官方社区帖（11 万星项目）：https://github.com/deepseek-ai/deepseek-harness/discussions/2032
截图：https://github.com/fatiaowu-desktop/fatiaowu-desktop#%F0%9F%96%BC-%E4%B8%80%E8%A7%88

需要 macOS 14+ / Node 18+ / DeepSeek API Key。皮肤适配 DSH 0.1.0-rc.6（升级后可能需要微调，欢迎 PR）。

---

## 即刻 / 小红书版（短文案 + 图）

标题：给 DeepSeek 做了个会发光的桌面 🐳✨

正文：
把 DeepSeek Harness 变成了原生 Mac 应用「发条屋」——三套皮肤、全界面毛玻璃、余额监控、还有会飘的萤火虫星尘。整个 App 才 1.6MB，比一个表情包还小😂

已开源：github.com/fatiaowu-desktop/fatiaowu-desktop（MIT，随便用）
（配三张皮肤截图）

---

## 回复常见问题（FAQ）

Q: 有 Windows 版吗？
A: 目前只有 macOS（原生 AppKit）。CSS 皮肤理论上可借浏览器注入，但暂未做跨平台。

Q: DSH 升级后皮肤会坏吗？
A: 皮肤依赖 DSH 内部类名，适配 0.1.0-rc.6；升级后个别细节需要重新挂钩（README 有教程，欢迎 PR）。

Q: 会不会泄露 API Key？
A: 不会。Key 只在本地 ~/.dsh/.credentials.yaml，代码运行时读取，仓库里没有任何密钥。
