#!/usr/bin/env bash
# UFI001C: 可选 — 从原厂 dump 恢复 modem 相关分区
#
# 什么时候用：
#   1) 刷 pmOS 后，mmcli -L 是空的 (modem 死了)
#   2) 你板子 IMEI 显示 000000... 或全 0
#   3) 你想彻底回到"出厂 modem 状态"
#
# 什么时候不需要用：
#   - 你现在 modem 好好的 (mmcli -m 0 能看到 IMEI 和 SIM 信息)
#   - 你只是从 OpenStick Debian 切换到 pmOS (modem 分区从没被改过)
#
# 前置：
#   - 你已经从 factory dump (full_emmc.bin) 提取了 modem/fsc/fsg/modemst1/modemst2/persist/sec 到当前目录
#   - 板子在 fastboot 模式 (lk2nd fastboot)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!] ${NC}%s\n" "$*"; }
die()  { printf "${RED}[X] ${NC}%s\n" "$*"; exit 1; }

echo ""
say "UFI001C: 从原厂备份恢复 modem 系列分区"
echo ""

# 前置检查
command -v fastboot >/dev/null || die "fastboot 未装 → brew install --cask android-platform-tools"

# 需要的文件
REQUIRED=(modem.bin modemst1.bin modemst2.bin fsc.bin fsg.bin persist.bin sec.bin)
MISSING=()
for f in "${REQUIRED[@]}"; do
    [ -f "$f" ] || MISSING+=("$f")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "以下文件缺失（跳过这些不刷）："
    for f in "${MISSING[@]}"; do echo "  - $f"; done
    warn "如果全都缺，检查你是不是在提取分区的目录里"
    echo ""
fi

# 显示会刷什么
say "将要 fastboot flash 的分区："
TOTAL_SIZE=0
for f in "${REQUIRED[@]}"; do
    if [ -f "$f" ]; then
        sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
        TOTAL_SIZE=$((TOTAL_SIZE + sz))
        printf "  %-15s %10d bytes\n" "$f" "$sz"
    fi
done
printf "  %-15s %10d bytes\n" "TOTAL" "$TOTAL_SIZE"
echo ""

# 强警告
warn "⚠️  这会覆盖板子当前的 modem 状态！"
warn "   如果你的板子 modem 现在工作正常 (mmcli -m 0 有输出)，"
warn "   你可能不需要跑这个脚本。它主要用于灾难恢复。"
echo ""
read -rp "确定要继续？输入 YES 继续，其它任何输入停止： " confirm
[ "$confirm" = "YES" ] || die "已取消"
echo ""

# 等 fastboot
say "等待 fastboot 设备..."
warn "触发方式: SSH 到板子 → sudo reboot bootloader"
for i in $(seq 1 60); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        say "检测到："
        fastboot devices
        break
    fi
    if [ "$i" = "60" ]; then
        die "60s 无 fastboot 设备"
    fi
    printf "\r  等待 %ds" "$i"
    sleep 1
done
echo ""

# 逐个刷
for f in "${REQUIRED[@]}"; do
    if [ -f "$f" ]; then
        partname="${f%.bin}"
        say "flash $partname ← $f"
        if fastboot flash "$partname" "$f" 2>&1; then
            printf "  ${GRN}✓${NC}\n"
        else
            warn "  刷 $partname 失败（分区可能不存在，跳过）"
        fi
    fi
done

echo ""
say "全部完成。重启..."
fastboot reboot

cat <<'DONE'

╔══════════════════════════════════════════════════════════════╗
║   Modem 分区已从原厂备份恢复。                               ║
║                                                              ║
║   板子重启后（约 30-60 秒），验证：                          ║
║                                                              ║
║     ssh root@172.16.42.1                                     ║
║     mmcli -L         # 应该看到 /Modem/0                     ║
║     mmcli -m 0       # 应该显示 IMEI 和 SIM 状态             ║
║                                                              ║
║   如果 modem 还是没工作，                                    ║
║   请把 dmesg | grep -i remoteproc 的输出发给 Craft Agent     ║
╚══════════════════════════════════════════════════════════════╝

DONE
