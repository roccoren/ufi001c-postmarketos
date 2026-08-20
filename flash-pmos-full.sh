#!/usr/bin/env bash
# UFI001C: 完整刷机 — 原厂 modem 分区 + pmOS
#
# 这个脚本做完整的"clean slate"刷机：
#   1) 从原厂 factory dump 恢复 modem/fsc/fsg/modemst1/modemst2/persist/sec
#   2) 刷 pmOS 的 boot + rootfs
#   3) 重启
#
# 结果：板子的 modem 是全新出厂状态 + 跑 pmOS
#
# 前置：
#   1) 你从 full_emmc.bin 提取过 factory partitions 到某个目录（下面 FACTORY_DIR）
#   2) 当前目录有 pmOS 的 boot.img + rootfs.img.zst
#   3) 板子当前跑 OpenStick Debian (或者已经在 fastboot 模式)
#
# 用法：
#   FACTORY_DIR=~/Downloads/q410-9008/factory-partitions ./flash-pmos-full.sh
#   或者交互式：./flash-pmos-full.sh（会问你 factory dir 路径）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; CYA='\033[0;36m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
info() { printf "${CYA}[i]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!]${NC} %s\n" "$*"; }
die()  { printf "${RED}[X]${NC} %s\n" "$*"; exit 1; }

echo ""
say "UFI001C: 完整刷机 (原厂 modem + pmOS v26.06-2)"
echo ""

# ========== [1/9] 检查工具 ==========
say "[1/9] 检查工具..."
for cmd in fastboot zstd shasum; do
    command -v $cmd >/dev/null || die "$cmd 未装。参考 MAC-SETUP.md"
done
echo ""

# ========== [2/9] 定位 factory partitions 目录 ==========
say "[2/9] 定位 factory partitions..."
FACTORY_DIR="${FACTORY_DIR:-}"
if [ -z "$FACTORY_DIR" ]; then
    # 尝试常见位置
    for candidate in \
        "./factory-partitions" \
        "$HOME/Downloads/q410-9008/factory-partitions" \
        "$HOME/Downloads/factory-partitions"; do
        if [ -f "$candidate/modem.bin" ]; then
            FACTORY_DIR="$candidate"
            info "自动找到：$FACTORY_DIR"
            break
        fi
    done
fi
if [ -z "$FACTORY_DIR" ] || [ ! -f "$FACTORY_DIR/modem.bin" ]; then
    read -rp "请输入 factory-partitions 目录路径（含 modem.bin 等）： " FACTORY_DIR
    FACTORY_DIR="${FACTORY_DIR/#\~/$HOME}"  # 展开 ~
fi
[ -d "$FACTORY_DIR" ] || die "目录不存在: $FACTORY_DIR"
[ -f "$FACTORY_DIR/modem.bin" ] || die "$FACTORY_DIR/modem.bin 不存在"
info "使用 factory dir: $FACTORY_DIR"

# 需要的 factory 分区
FACTORY_PARTS=(modem modemst1 modemst2 fsc fsg persist sec)
MISSING_FACTORY=()
for p in "${FACTORY_PARTS[@]}"; do
    [ -f "$FACTORY_DIR/$p.bin" ] || MISSING_FACTORY+=("$p")
done
if [ ${#MISSING_FACTORY[@]} -gt 0 ]; then
    warn "以下 factory 分区文件缺失（会跳过）:"
    for p in "${MISSING_FACTORY[@]}"; do echo "    - $p.bin"; done
fi
echo ""

# ========== [3/9] 检查 pmOS 文件 ==========
say "[3/9] 检查 pmOS 镜像..."
[ -f boot.img ] || die "boot.img 不在当前目录"
if [ ! -f rootfs.img ] && [ ! -f rootfs.img.zst ]; then
    die "缺 rootfs 镜像 (rootfs.img 或 rootfs.img.zst)"
fi
[ -f SHA256SUMS ] || warn "SHA256SUMS 缺失，跳过 pmOS 镜像校验"
echo ""

# ========== [4/9] 校验 pmOS ==========
if [ -f SHA256SUMS ]; then
    say "[4/9] 校验 pmOS SHA256..."
    if ! shasum -a 256 -c SHA256SUMS --ignore-missing 2>&1 | tail -5 | grep -q "OK"; then
        die "pmOS 镜像校验失败"
    fi
fi
echo ""

# ========== [5/9] 解压 rootfs.img.zst ==========
if [ ! -f rootfs.img ] && [ -f rootfs.img.zst ]; then
    say "[5/9] 解压 rootfs.img.zst → rootfs.img (800 MB)..."
    zstd -d --quiet rootfs.img.zst -o rootfs.img
else
    say "[5/9] rootfs.img 已存在"
fi
echo ""

# ========== [6/9] 显示刷机计划 ==========
say "[6/9] 刷机计划总览"
echo ""
info "阶段 A: 从原厂 dump 恢复 modem 相关分区（clean slate）"
for p in "${FACTORY_PARTS[@]}"; do
    if [ -f "$FACTORY_DIR/$p.bin" ]; then
        sz=$(stat -f%z "$FACTORY_DIR/$p.bin" 2>/dev/null || stat -c%s "$FACTORY_DIR/$p.bin")
        printf "    %-12s ← %s (%s bytes)\n" "$p" "$FACTORY_DIR/$p.bin" "$sz"
    fi
done
echo ""
info "阶段 B: 刷 pmOS"
printf "    %-12s ← %s\n" "boot"   "boot.img ($(du -h boot.img | cut -f1))"
printf "    %-12s ← %s\n" "rootfs" "rootfs.img ($(du -h rootfs.img | cut -f1))"
echo ""
warn "不会碰的分区（保留 OpenStick 的 lk2nd/hyp/tz/rpm/sbl1/aboot）"
echo "    sbl1, tz, rpm, hyp, aboot"
echo ""

# ========== [7/9] 双确认 ==========
warn "⚠️  最终确认："
warn "  - modem/fsc/fsg/modemst1/modemst2/persist/sec 会被覆盖成 factory 状态"
warn "    (你之前 Debian 时代 modem EFS 的所有变化都会被抹掉，IMEI 保留)"
warn "  - Debian 的 boot/rootfs 会被 pmOS 覆盖"
warn "  - 原厂 dump 仍然是你终极兜底 (edl wf full_emmc.bin 可完整回退)"
echo ""
read -rp "$(printf "${RED}输入 YES 开始刷机，其它任何输入停止： ${NC}")" confirm
[ "$confirm" = "YES" ] || die "已取消"
echo ""

# ========== [8/9] 等 fastboot ==========
say "[8/9] 等待 fastboot 设备..."
warn "触发方式："
warn "  A) SSH 到 Debian: sudo reboot bootloader"
warn "  B) EDL 短接 → edl e boot && edl reset"

TIMEOUT=180
for i in $(seq 1 $TIMEOUT); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        echo ""
        say "检测到 fastboot 设备："
        fastboot devices
        break
    fi
    if [ "$i" = "$TIMEOUT" ]; then
        die "${TIMEOUT}s 无 fastboot 设备"
    fi
    printf "\r  等待 %ds" "$i"
    sleep 1
done
echo ""

# ========== [9/9] 开刷！ ==========
say "[9/9] 开始刷写..."
echo ""
info "阶段 A: 恢复原厂 modem 分区"
for p in "${FACTORY_PARTS[@]}"; do
    if [ -f "$FACTORY_DIR/$p.bin" ]; then
        printf "  flash %-12s ... " "$p"
        if fastboot flash "$p" "$FACTORY_DIR/$p.bin" >/dev/null 2>&1; then
            printf "${GRN}✓${NC}\n"
        else
            printf "${RED}✗${NC} (分区可能不存在，跳过)\n"
        fi
    fi
done
echo ""

info "阶段 B: 刷 pmOS"
say "flash boot ← boot.img"
fastboot flash boot boot.img
say "flash rootfs ← rootfs.img (3-5 分钟)"
fastboot flash rootfs rootfs.img
echo ""

say "重启到 pmOS..."
fastboot reboot

cat <<'DONE'

╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ✅ 完整刷机完成！板子正在启动 pmOS。                       ║
║                                                              ║
║   已刷入：                                                   ║
║     - 原厂 modem/modemst1/modemst2/fsc/fsg/persist/sec       ║
║     - pmOS v26.06-2 boot + rootfs                            ║
║                                                              ║
║   首次启动约 30-90 秒（跑 first-boot 脚本）                  ║
║                                                              ║
║   ── 接入 ─────────────────────────────────────────           ║
║                                                              ║
║   USB RNDIS: ifconfig | grep -A2 en                          ║
║             ssh root@172.16.42.1  (密码 pmos)                ║
║                                                              ║
║   UART:      screen /dev/tty.usbserial* 115200               ║
║                                                              ║
║   ── 首次登录必做 ─────────────────────────────               ║
║                                                              ║
║   1. passwd                                                  ║
║   2. mkdir -p ~/.ssh && chmod 700 ~/.ssh                     ║
║      echo 'your-pubkey' > ~/.ssh/authorized_keys             ║
║   3. sed -i 's/PasswordAuth.*/PasswordAuthentication no/'    ║
║      /etc/ssh/sshd_config && rc-service sshd restart         ║
║                                                              ║
║   ── 验证 modem ───────────────────────────────               ║
║                                                              ║
║   mmcli -L                    # 应该看到 /Modem/0            ║
║   mmcli -m 0                  # 应该显示 IMEI + SIM 状态     ║
║   nmcli con add type gsm ifname '*' con-name 4g apn "3gnet"  ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

DONE
