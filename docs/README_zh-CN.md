# 启动配置管理器

> 用勾选框管理 Windows 软件自启动，并把不同使用场景保存为预设。

启动配置管理器是一个本地 Windows 小工具，用来回答一个很日常的问题：电脑登录后，哪些软件应该自己启动？

你可以把“工作”“游戏”“轻量模式”等习惯保存为预设，需要时载入并统一应用。它并不试图替代所有系统管理工具，只希望让常见的自启动管理更直接、更容易理解。

## 项目状态

这是本项目的最终个人版本。它将作为个人使用工具、开发参考、灵感分享和开源使用的素材保留；没有后续发行版、自动更新计划或正式产品路线图。

开源并不意味着代码已经成熟或适合所有场景。欢迎阅读、学习、复用和改进，但请先理解它会修改 Windows 启动行为，并自行承担本机使用与二次开发的风险。

## 它能做什么

- 找出常见的第三方软件自启动项。
- 通过勾选决定软件下次登录或开机后是否自动启动。
- 管理注册表启动项、启动文件夹、登录/开机计划任务。
- 在高级模式下查看自动服务和部分第三方驱动。
- 保存多个命名预设，并在不同预设之间切换。
- 关闭启动文件夹项目时先本地暂存，而不是删除快捷方式。
- 全程在本机工作，不上传启动项、预设或使用数据。

## 使用前请注意

普通软件，例如下载器、聊天软件、截图工具、游戏平台等，通常可以按自己的需求勾选。

服务和驱动则不同。它们可能影响硬件、网卡、远程控制、灯效软件或安全软件，因此默认隐藏在“显示高级项目（服务、驱动）”中。不了解用途时，请不要关闭它们。

本程序改变的是“以后是否自动启动”，不会关闭当前已经运行的软件。

## 快速开始

1. 下载或克隆本项目。
2. 运行仓库中提供的 EXE，或直接运行对应语言的脚本。
3. 浏览列表：勾选代表启用，取消勾选代表禁用。
4. 点击“应用更改”。
5. 如需保存当前搭配，在预设框中输入名称，再点击“保存当前为预设”。

修改机器级项目、计划任务、服务或驱动时，程序会提示你以管理员身份重新打开。这是 Windows 的正常权限要求。

## 文件与语言版本

| 文件 | 说明 |
| --- | --- |
| `src/StartupPresetManager_zh-CN.ps1` | 简体中文界面的完整 PowerShell/WPF 程序。 |
| `src/StartupPresetManager_en-US.ps1` | 英文界面的完整 PowerShell/WPF 程序。 |
| `dist/StartupPresetManager_en-US.exe` | 英文 EXE 启动器。 |
| `dist/StartupPresetManager_zh-CN.exe` | 中文 EXE 启动器。 |
| `src/StartupPresetManagerLauncher.cs` | EXE 启动器的 C# 源码。 |
| `build/build_en-US.rsp` | 英文 EXE 的构建参数。 |
| `build/build_zh-CN.rsp` | 中文 EXE 的构建参数。 |
| `assets/favicon.ico` | EXE 使用的图标。 |

直接运行中文脚本的示例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_zh-CN.ps1
```

英文使用说明请查看 [README_en-US.md](README_en-US.md)。

## 预设是什么

预设就是一份“哪些项目开启、哪些项目关闭”的清单。

例如，你可以建立：

- **工作**：开启企业微信、ShareX、网盘；关闭游戏平台和娱乐软件。
- **游戏**：开启 Steam、显卡辅助工具、性能监控；关闭不需要的办公工具。
- **轻量模式**：只保留必要软件，让登录后的桌面尽量安静。

载入预设时，程序只会改变界面里的勾选状态，不会立刻修改系统。你可以先检查一遍，再点击“应用更改”。

## 程序如何处理启动项

| 类型 | 程序的做法 |
| --- | --- |
| 注册表 `Run` / `RunOnce` 项 | 保留原始启动命令，并切换 Windows 的启动批准状态。 |
| 启动文件夹 | 关闭时移入本地暂存区，开启时移回原来的位置。 |
| 登录/开机计划任务 | 启用或禁用符合条件的非 Microsoft 任务。 |
| 自动服务 | 在高级模式中显示，并在“自动”和“禁用”之间切换。 |
| 部分第三方驱动 | 在高级模式中显示，实际修改前会再次提示。 |

程序会尽量过滤 Microsoft/Windows 自带项目，但这只是为了让列表更清爽的实用判断，不是安全检测，也不能保证识别所有厂商自定义的启动方式。

### 代码如何扫描、表示与应用项目

脚本先用 `Get-AllStartupItems` 汇总各个扫描函数的结果，并放入 WPF `DataGrid` 绑定的 `ObservableCollection`。每个项目都由内置的 `StartupItem` 类表示，包含稳定 ID、显示名称、来源、触发时机、启动命令、当前勾选状态、原始状态、是否属于高级项目以及是否需要管理员权限。

稳定 ID 不是直接用显示名称，而是由 `Get-ItemId` 对“来源 + 路径/任务名/服务名”等信息计算 SHA-256 短哈希。这是为了让预设能在界面名称变化或不同来源存在同名项目时，仍尽量找到正确的对象。

具体扫描逻辑如下：

- `Get-RegistryStartupItems` 读取当前用户、机器级和 32 位兼容视图中的 `Run` / `RunOnce` 键。`Get-RegistryApproval` 会读取 Windows 的 `StartupApproved` 二进制状态：首字节为 `2` 代表启用、`3` 代表禁用。应用变更时 `Set-RegistryApproval` 只写这个状态值，保留原始启动命令，不删除注册表项目。
- `Get-StartupFolderItems` 扫描当前用户和所有用户的启动文件夹；对于 `.lnk` 快捷方式，它用 Windows Script Host 读取目标程序与参数。禁用时 `Set-StartupFolderItem` 将文件移到本地暂存目录，并把原路径写入设置；重新启用时移回原路径，因此不需要删除快捷方式。
- `Get-ScheduledStartupItems` 通过 `Get-ScheduledTask` 取得计划任务，排除 `\Microsoft\...` 目录，只保留登录或开机触发的任务。应用时分别调用 `Enable-ScheduledTask` 或 `Disable-ScheduledTask`。
- `Get-ServiceStartupItems` 通过 `Win32_Service` 查找自动启动服务。`Test-ThirdPartyService` 结合执行路径、文件公司信息和已知 Microsoft 路径进行保守过滤。应用时由 `Invoke-ScConfig` 调用 Windows 的 `sc.exe config`，在 `auto` 与 `disabled` 之间切换。
- `Get-DriverStartupItems` 读取自动加载的系统驱动，只显示少量已识别的第三方名称，并尝试读取签名者信息。驱动和服务都被标记为高级项目，且修改驱动前会出现额外确认。

### 预设、设置与恢复的实现

`%LOCALAPPDATA%\StartupPresetManager\settings.json` 由 `Read-Settings` 和 `Save-Settings` 读写。它保存三类信息：预设的项目 ID/开关状态、被暂存的启动文件夹项目的原始路径，以及曾由程序管理过的服务或驱动。

保存预设时，`Save-CurrentPreset` 记录当前列表中每个项目的 ID 与 `Enabled` 状态。载入时，`Load-SelectedPreset` 只匹配当前扫描到的 ID 并更新勾选框，不会立刻写入 Windows。这样可以先检查预设效果，再由用户决定是否应用。

### 安全设计与限制

程序将“扫描”和“修改”分开：启动时只读系统配置，不请求管理员权限；只有点击“应用更改”且确实包含机器级注册表、计划任务、服务或驱动时，才要求以管理员身份重新打开。

`OriginalEnabled` 与当前 `Enabled` 不同的项目才会进入 `Apply-Changes`。每一项都按自己的来源调用对应处理函数，单项失败会被记录并显示，其余项目仍会继续处理。该设计避免把不同启动机制强行用一种危险操作处理，也避免删除原始注册表命令、快捷方式或计划任务。

## 本地数据与恢复

程序设置保存在：

```text
%LOCALAPPDATA%\StartupPresetManager
```

这里包含预设、被暂存的启动文件夹项目，以及曾由本工具管理过的服务或驱动记录。需要备份时，备份整个这个文件夹即可。

删除该文件夹不会删除原有软件或系统启动项，但会失去预设，也可能需要手动找回被暂存的启动文件夹快捷方式。

## EXE 启动器是什么

`src/StartupPresetManagerLauncher.cs` 不是另一套完整界面，而是一个很小的 C# 启动器。它把 PowerShell 脚本和图标嵌入 EXE；EXE 运行时会将脚本释放到本地应用数据目录，再使用 Windows 自带 PowerShell 以 STA 模式启动 WPF 界面。

因此，EXE 只是脚本程序的便捷入口，不代表项目已被重写为原生 C# 应用。需要审阅功能、排查问题或二次开发时，应以对应语言的 `.ps1` 脚本和启动器源码为准。

## 它不是什么

- 它不是恶意软件查杀工具，也不是完整的系统安全审计工具。
- 它不会卸载软件、删除软件、结束正在运行的程序。
- 它不会覆盖所有罕见的持久化方式，例如浏览器扩展、WMI 事件订阅、Winlogon 设置或自定义 Shell。
- 它不是 Microsoft Sysinternals Autoruns 的替代品。

如需排查恶意软件或异常自启动，请使用可信的安全工具，或向有经验的技术人员求助。

## 项目缘起

这是一个由没有编程基础的用户提出实际需求，并借助 OpenAI Codex / ChatGPT 5.6 Terra 进行需求梳理、设计、实现、测试和打包的个人原型。

开源的目的不是把 AI 生成的代码当成终点，而是将这次完整的尝试公开为参考：它也许能成为其他人的开发灵感，或为熟悉 Windows、PowerShell、WPF/WinUI、应用安全和无障碍设计的开发者提供一个可以讨论和改进的起点。

## 构建参考

构建 EXE 需要一套可用的 Windows C# 编译环境。推荐在 Visual Studio 或 Build Tools 提供的 **Developer Command Prompt** 中进入项目目录，再运行：

```text
csc @build\build_en-US.rsp
```

`build/build_en-US.rsp` 使用相对路径，并生成英文启动器 `dist/StartupPresetManager_en-US.exe`；`build/build_zh-CN.rsp` 则生成中文启动器 `dist/StartupPresetManager_zh-CN.exe`。两份配置都将对应语言脚本以启动器需要的内部资源名嵌入 EXE。若要构建中文版本，请运行：

```text
csc @build\build_zh-CN.rsp
```

公开文档不应把某位开发者电脑上的编译器绝对路径写死。不同系统的 .NET Framework、Visual Studio 或 Build Tools 安装位置可能不同；只要当前命令行能找到 `csc`，上述命令即可使用。

源脚本还提供两项维护检查：

```powershell
# 只扫描并输出数量，不打开界面
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_zh-CN.ps1 -SelfTest

# 创建界面并完成加载检查后退出
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_zh-CN.ps1 -UiSmokeTest
```

当前 EXE 没有代码签名，Windows 首次运行时可能会提示“未知发布者”。请不要盲目绕过系统警告；如有更高信任需求，建议阅读源码并自行构建。

## 开源许可证

在邀请他人复用、修改或贡献前，请为仓库添加 `LICENSE` 文件。MIT 适合希望他人自由使用和改进的项目；GPL-3.0 适合希望衍生版本继续保持开源的项目。没有许可证时，访客不应默认拥有复用代码的权限。
