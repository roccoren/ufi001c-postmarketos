# macOS 上准备 UFI001C 刷机环境

针对本次 pmOS 刷机场景写的 Mac 侧安装指南。适配 Apple Silicon 和 Intel Mac，重点是 `fastboot` + `edl`（EDL 工具，Qualcomm 9008 模式救砖用）+ `zstd`（解压 rootfs）。

**目标状态**：跑完本指南，你的 Mac 上有：
- `fastboot` — 从 lk2nd fastboot 模式刷 boot.img + rootfs.img
- `edl` — Qualcomm EDL 9008 模式救砖 / 备份原厂固件
- `zstd` — 解压 `rootfs.img.zst`
- `libusb` — `edl` 的依赖
- 一份可信的 udev-like 权限（macOS 用 IOKit，不需要 udev 规则）

---

## Step 1: 装 Homebrew（如果还没有）

```bash
# Apple 官方指令，Apple Silicon + Intel 都通用
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 装完后按提示把 brew 加进 PATH
# Apple Silicon:  eval "$(/opt/homebrew/bin/brew shellenv)"
# Intel Mac:      eval "$(/usr/local/bin/brew shellenv)"

brew --version
```

## Step 2: 装 fastboot（Android platform-tools）

```bash
brew install --cask android-platform-tools
fastboot --version
# 期望: fastboot version 34.0.5-11315636 或更新
```

**验证 fastboot 能识别 UFI001C**（板子当前跑 Debian，先不用切模式，只测 CLI 到位）：

```bash
which fastboot
# /opt/homebrew/bin/fastboot  (Apple Silicon)
# /usr/local/bin/fastboot     (Intel)
```

## Step 3: 装 zstd + libusb + Python 3

```bash
brew install zstd libusb python@3.12
zstd --version
python3 --version
# python 需要 3.10+
```

## Step 4: 装 edl（Qualcomm EDL 客户端）

`edl` 是 Python 工具（bkerler/edl，业界标准），走 pipx 装最干净：

```bash
brew install pipx
pipx ensurepath

# 装 edlclient（含 edl 命令）
pipx install edlclient

# 验证
edl --help | head -20
# 期望看到 "Qualcomm Sahara / Firehose Client"
```

**如果 pipx 装失败**（有时候依赖 pyusb 编译不过），用备用方式：

```bash
# 直接从 GitHub 装 latest
pipx install "git+https://github.com/bkerler/edl.git"

# 或者传统 pip + venv
python3 -m venv ~/edl-venv
source ~/edl-venv/bin/activate
pip install edlclient
# 之后每次用 edl：source ~/edl-venv/bin/activate && edl ...
```

## Step 5: 允许 USB 设备访问（macOS 权限）

macOS 不需要 udev 规则，但 **首次接入 EDL/fastboot 设备时会弹权限提示**：

- 系统偏好设置 → 安全性与隐私 → **允许辅助功能 / USB 设备访问**
- 如果用 Terminal，给 Terminal 完整磁盘访问权限
- 如果 Apple Silicon 上 fastboot 无法 attach USB，检查 System Extensions 是否被拦（少见）

**验证**：把 UFI001C 拔了，插上（Debian 状态），跑：

```bash
system_profiler SPUSBDataType | grep -A5 -iE "qualcomm|thundercomm|shenzhen"
# 应该看到 Debian 状态下的 USB 描述（可能是 CDC-ACM/NCM 复合设备）
```

## Step 6: 测试 fastboot 触发能力

从当前 Debian 里触发 fastboot 重启（这一步现在不用真做，只演练命令）：

```bash
# SSH 到当前 Debian
ssh user@192.168.4.1
# 密码：1

sudo reboot bootloader
# 板子应该在几秒内重启进 lk2nd 的 fastboot 模式

# Mac 上：
fastboot devices
# 期望：某种设备 ID + "fastboot"
```

**如果 `fastboot devices` 一直空** 但你确定板子进了 fastboot：
1. `sudo dmesg | grep -i fastboot`（不适用于 Mac；改用 System Report）
2. 打开 系统信息 → USB → 找 lk2nd
3. 如果 Mac 没识别 → 重启 Mac 或换 USB 口（少数情况下 hub 有问题）

## Step 7: 测试 EDL 模式（了解怎么进）

**不用真进 EDL**，只熟悉命令：

```bash
# 假设板子已经进了 EDL 9008：
edl printgpt
# 期望：打印 GPT 分区表

edl r modem modem-current.bin
# 期望：从板子上拉 modem 分区

edl reset
# 复位板子
```

**怎么让板子进 EDL 有 3 种方式**：

1. **软触发**（推荐，前提是有 adb/系统正常）：
   - 从 Debian：`adb reboot edl` 或 `sudo reboot edl`（后者需要 lk2nd 支持）
2. **短接测试点**：拆机找 TP4-TP5，用镊子/回形针短接后插 USB
3. **强制**：用 `edl-tools` 的 layered 触发（`edl reset` 后立刻 modinit）

Mac 识别 EDL 设备后 `lsusb` 等价物：

```bash
system_profiler SPUSBDataType | grep -B2 -A5 "9008\|QDLoader"
# 期望看到 "Qualcomm HS-USB QDLoader 9008" 或类似
```

## Step 8: 检查磁盘空间

镜像总大小 ~190 MB，解压后 rootfs.img 是 800 MB。留 2 GB 以上空间：

```bash
df -h ~
# 至少 2 GB free
```

## Step 9: 一次性完整验证

跑这段 shell，如果全部通过说明环境 ready：

```bash
cat <<'PREFLIGHT' | bash
set -e
echo "=== Preflight for UFI001C flashing ==="
for cmd in fastboot zstd curl shasum python3; do
    printf "  %-12s " "$cmd"
    command -v $cmd >/dev/null && echo "✓" || { echo "✗ MISSING"; exit 1; }
done
printf "  %-12s " "edl"
command -v edl >/dev/null && echo "✓ (optional)" || echo "△ (optional - install via pipx)"
echo ""
echo "=== Homebrew 版本 ==="
brew --version | head -1
echo "=== disk space (need ~2 GB) ==="
df -h ~ | tail -1
echo ""
echo "✅ All required tools ready. Proceed to flashing."
PREFLIGHT
```

---

## 备忘：为什么每个工具都需要

| 工具 | 什么阶段用 | 缺了会怎么样 |
|------|-----------|--------------|
| `fastboot` | 从 lk2nd 刷 `boot.img` + `rootfs.img` | 无法刷机 |
| `edl` | 从 EDL 9008 备份原厂 / 救砖 / 首次刷 lk2nd | 无法救砖，无法备份 modem |
| `zstd` | 解压 `rootfs.img.zst` | 用 `rootfs.tar.gz` 备用（但要自己 `mkfs.ext4 + tar -x`） |
| `libusb` | `edl` 的 pyusb 依赖 | edl 无法访问 USB |
| `curl` | 从 GitHub 下载镜像 | 手动浏览器下载 |
| `shasum` | 校验镜像完整性 | 无法确认下载正确 |
| `python3` | `edl` 命令本体 | `edl` 无法安装 |

---

## 常见问题

### Q: fastboot 装完 `fastboot: command not found`
- Cask 装的 platform-tools 有时候不自动加 PATH。手动：
  ```bash
  # Apple Silicon
  export PATH="/opt/homebrew/Caskroom/android-platform-tools/*/platform-tools:$PATH"
  # Intel Mac  
  export PATH="/usr/local/Caskroom/android-platform-tools/*/platform-tools:$PATH"
  ```
- 或者直接 `brew link --overwrite android-platform-tools`

### Q: edl 装完运行时 `ImportError: No module named 'usb'`
- pipx 装的 edlclient 缺 pyusb backend（罕见）：
  ```bash
  pipx inject edlclient pyusb libusb1
  ```

### Q: macOS 提示 fastboot 是"未验证开发者"
- 首次执行时会拦，右键 → 打开 → 允许（只需一次）
- 或 `xattr -dr com.apple.quarantine /opt/homebrew/Caskroom/android-platform-tools`

### Q: Apple Silicon 上 fastboot 特别慢
- 已知问题，跟 macOS 15+ USB 栈有关。换 USB 2.0 端口或用带宽较低的 hub 反而更稳。
- 或者用 UTM 起 Linux VM 透过 USB（不推荐，除非你已经装了 UTM）。

### Q: EDL 遇到 `Retry: X/8` 无限循环
- 说明 Sahara 通信有问题。常见原因：
  1. 板子没真进 9008（USB 描述符是 CDC/HID 而不是 QDL） → 重新短接测试点
  2. macOS 拦了 USB 权限 → 系统信息里手动 attach
  3. 换 USB 口

---

## 下一步

Mac 环境就绪后，走 [FLASH.md](FLASH.md) 或直接跑 `flash-pmos-offline.sh`。
