# oh-my-Rime

这是一个面向 macOS 的个人定制版 [鼠鬚管（Squirrel）](https://github.com/rime/squirrel)，以 [Rime](https://rime.im) 输入法引擎为基础。它保留 Rime 的方案与配置兼容性，并对候选窗口、候选排序和剪贴板工作流做了本地化改造。

> 本项目适用于 macOS 13.0 及以上版本，当前以源码安装为主。

## 定制内容

### Apple 风格候选栏

- 将常规候选栏与展开候选网格重新绘制为接近 macOS 系统输入法的样式：更细、更浅的边框，统一的左侧对齐，以及平滑的展开／收起过渡。
- 根据候选词实际宽度自适应排版，不再使用固定候选数；相邻的 Rime 候选批次会连续拼接，避免翻页时出现多余空位或跳过候选词。
- 按 `=` 或 `↓` 进入／向下浏览展开网格；按 `-` 或 `↑` 向上浏览或回到普通候选栏；`←`、`→` 可在候选之间移动，数字键可直接选词。

### 智能候选排序

- 根据本机的选词习惯调整候选顺序。
- 带有轻量本地上下文模型，可结合前文优化排序；所有学习数据只保留在本机。
- 可在鼠鬚管输入法菜单中开关“智能候选排序”。

### 剪贴板历史与粘贴

- 使用全局快捷键 <kbd>⌥ V</kbd> 打开剪贴板历史；即使当前使用的是其他输入法也可以调用。
- 保存最近 7 天的文本、图片和文件记录；相同内容会去重并置顶。
- 打开后可用 `←` / `→`、`↑` / `↓`、`-` / `=`、Page Up / Page Down 或数字键导航；按空格或回车选择，Esc 关闭。
- 文本会直接插入；图片和文件会恢复到剪贴板后自动发送 <kbd>⌘ V</kbd>。图片同时提供原始格式及兼容性更好的 TIFF 表示，适配更多 App。

剪贴板历史保存在：

```text
~/Library/Application Support/Squirrel/ClipboardHistory/
```

图片或文件的自动粘贴依赖 macOS 的辅助功能权限。首次使用时，请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Squirrel 控制电脑。

## 安装

### 1. 准备环境

安装 Xcode（或至少安装 Command Line Tools）和 CMake：

```sh
xcode-select --install
brew install cmake
```

如果没有 Homebrew，可从 [CMake 官网](https://cmake.org/download/) 安装 CMake。

### 2. 获取代码与依赖

```sh
git clone --recursive git@github.com:JerryBlack28/oh-my-Rime.git
cd oh-my-Rime
bash ./action-install.sh
```

`action-install.sh` 会下载预编译的 librime 依赖，并初始化所需的 Rime 配方数据。

### 3. 构建并安装

```sh
make release
sudo make install
```

安装脚本会把 `Squirrel.app` 放入 `/Library/Input Methods/`，注册输入法并尝试启用它。安装完成后，到“系统设置 → 键盘 → 输入法”确认已添加“鼠鬚管”。

如果输入法没有立即出现，或部分应用无法输入，请退出登录后重新登录一次。

### 更新安装

拉取新代码后，重新执行构建和安装：

```sh
git pull --rebase
bash ./action-install.sh
make release
sudo make install
```

## 使用与配置

- 在 macOS 输入法菜单中切换至鼠鬚管。
- 用 <kbd>Ctrl</kbd> + <kbd>`</kbd> 或 <kbd>F4</kbd> 打开方案选单。
- 修改 Rime 用户配置后，在输入法菜单中选择“重新部署”使其生效。
- Rime 的用户配置目录通常为 `~/Library/Rime/`；方案、词典和 emoji 配置仍可按照 Rime 的标准方式维护。

## 开发

完整的上游构建说明见 [INSTALL.md](INSTALL.md)。常用命令：

```sh
make          # 构建 Release
make debug    # 构建 Debug
make clean    # 清理本项目构建产物
```

未跟踪的 `librime/`、`plum/` 和 `build-*` 目录是依赖或本地产物，不应直接提交。

## 致谢与许可

本项目基于 [rime/squirrel](https://github.com/rime/squirrel) 和 [Rime Input Method Engine](https://rime.im)。感谢鼠鬚管、librime、Plum 及其社区贡献者。

代码遵循原项目的 [GPL-3.0](LICENSE.txt) 许可证。
