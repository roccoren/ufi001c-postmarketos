#!/usr/bin/env bash
# UFI001C: 完整 one-shot 刷机
#
# 一次性刷入:
#   1) upstream lk2nd v23.1 (替换掉 buggy LK1ST fork)
#   2) 匹配的 boot.img
#   3) rootfs.img
#   [可选] 从原厂 dump 恢复 modem 系列分区
#
# 前置:
#   - macOS + brew install --cask android-platform-tools
#   - pipx install edlclient  (救砖用)
#   - Mac 上有原厂 aboot 备份 (从 full_emmc.bin 提取过, 或从 factory-partitions/aboot.bin)
#
# 为什么一次刷 lk2nd + pmOS:
#   你板子的 LK1ST fork 是老 lk2nd (v0.5, ~2020 年), 有多个已知 bug:
#     - 不支持 fastboot getvar all
#     - Extlinux 支持不完整
#     - DTB 用远古 msm-id/board-id 匹配
#     - oem lk_log 只输 UART
#   upstream lk2nd v23.1 修了所有这些, 支持:
#     - compatible 字符串匹配 (跟 mainline pmOS DTB 天然兼容)
#     - fastboot getvar all 完整
#     - oem lk_log 通过 fastboot 通道回传
#     - Android boot.img v0/v2 都吃, 也吃 ext2/extlinux
#
set -euo pipefail

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; CYA='\033[0;36m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
info() { printf "${CYA}[i]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!]${NC} %s\n" "$*"; }
die()  { printf "${RED}[X]${NC} %s\n" "$*"; exit 1; }
ask()  { local q="$1" def="${2:-}"; read -rp "$q " a; echo "${a:-$def}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
say "UFI001C: 一次性刷入 lk2nd v23.1 + pmOS"
echo ""

# ========== 检查工具 ==========
say "[1/10] 检查前置工具"
for cmd in fastboot python3 shasum curl; do
    command -v $cmd >/dev/null || die "$cmd 未装。参考 MAC-SETUP.md"
done
command -v edl >/dev/null || warn "  edl 未装 — 强烈建议装 (pipx install edlclient) 用于救砖"
command -v zstd >/dev/null || warn "  zstd 未装 — 如果 rootfs 是 .zst 会解不了"
echo ""

# ========== 定位文件 ==========
say "[2/10] 检查所需文件"
NEEDED_FILES=(
    "aboot-lk2nd-latest.mbn:upstream lk2nd v23.1 aboot"
    "boot.img:pmOS boot (可以是 pmbootstrap 产的 zhihe-generic-boot.img)"
)
for entry in "${NEEDED_FILES[@]}"; do
    file="${entry%%:*}"
    desc="${entry##*:}"
    if [ -f "$file" ]; then
        printf "  ✓ %-30s %8s  (%s)\n" "$file" "$(du -h "$file" | cut -f1)" "$desc"
    else
        die "缺失: $file  ($desc)"
    fi
done

# rootfs (可以是 .img 或 .img.zst)
if [ -f rootfs.img ]; then
    ROOTFS=rootfs.img
elif [ -f rootfs.img.zst ]; then
    say "解压 rootfs.img.zst..."
    zstd -d --quiet rootfs.img.zst -o rootfs.img
    ROOTFS=rootfs.img
elif [ -f zhihe-generic.img ]; then
    ROOTFS=zhihe-generic.img
elif [ -f zhihe-generic-root.img ]; then
    ROOTFS=zhihe-generic-root.img
else
    die "缺 rootfs (rootfs.img / rootfs.img.zst / zhihe-generic.img / zhihe-generic-root.img)"
fi
printf "  ✓ %-30s %8s  (%s)\n" "$ROOTFS" "$(du -h "$ROOTFS" | cut -f1)" "pmOS rootfs"
echo ""

# ========== 找 factory aboot 备份 (保命!) ==========
say "[3/10] 检查 factory aboot 备份 (保命!!)"
FACTORY_ABOOT=""
for candidate in \
    "./factory-partitions/aboot.bin" \
    "$HOME/Downloads/q410-9008/factory-partitions/aboot.bin" \
    "$HOME/factory-partitions/aboot.bin"; do
    if [ -f "$candidate" ]; then
        FACTORY_ABOOT="$candidate"
        info "找到 factory aboot: $FACTORY_ABOOT"
        break
    fi
done

if [ -z "$FACTORY_ABOOT" ]; then
    warn "没找到 factory aboot 备份 — 救砖时没法回原厂 aboot"
    warn "建议先跑: mkdir -p ~/factory-partitions && dd from full_emmc.bin"
    ans=$(ask "继续吗？[y/N]" "N")
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "已取消，请先备份"
else
    printf "  ✓ %-40s %8s\n" "$FACTORY_ABOOT" "$(du -h "$FACTORY_ABOOT" | cut -f1)"
fi
echo ""

# ========== 检查 factory modem 分区 (可选) ==========
say "[4/10] 检查 factory modem 分区 (可选)"
FACTORY_MODEM_DIR=""
if [ -n "$FACTORY_ABOOT" ]; then
    FACTORY_MODEM_DIR=$(dirname "$FACTORY_ABOOT")
    for p in modemst1 modemst2 fsc fsg sec; do
        [ -f "$FACTORY_MODEM_DIR/$p.bin" ] && printf "  ✓ %s.bin\n" "$p"
    done
fi
echo ""

# ========== 用户确认 ==========
warn "[5/10] 最终确认"
cat <<EOF

即将执行:

  1. flash aboot ← aboot-lk2nd-latest.mbn (替换 LK1ST → upstream lk2nd v23.1)
  2. flash boot ← boot.img
  3. flash rootfs ← $ROOTFS
EOF

if [ -n "$FACTORY_MODEM_DIR" ]; then
    cat <<EOF
  4. (可选) 恢复原厂 modem 系列分区:
     - modemst1 modemst2 fsc fsg sec
EOF
fi

cat <<EOF

⚠️  风险:
  - 刷 aboot 有 <1% 概率变砖 (但你有 factory 备份, EDL 可救)
  - 之前的 boot/rootfs 会被覆盖

🛡️  兜底:
  - factory aboot 备份: $([ -n "$FACTORY_ABOOT" ] && echo "$FACTORY_ABOOT" || echo "❌ 没有")
  - 全盘原厂 dump: 假设你有 $HOME/Downloads/q410-9008/full_emmc.bin
  - 救砖: edl 短接 TP4-TP5, 然后 edl w aboot <factory.bin>

EOF

ans=$(ask "$(printf "${RED}输入 YES 开始, 别的都停${NC}")")
[ "$ans" = "YES" ] || die "已取消"
echo ""

# ========== 等 fastboot ==========
say "[6/10] 等待 fastboot 设备"
info "触发方式:"
info "  - 从 pmOS/Debian:  sudo reboot bootloader"
info "  - 拔电重来 (板子会回 lk1st fastboot)"

for i in $(seq 1 120); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        echo ""
        say "检测到:"
        fastboot devices
        break
    fi
    if [ "$i" = "120" ]; then
        die "120s 无 fastboot 设备"
    fi
    printf "\r  等待 %ds" "$i"
    sleep 1
done
echo ""

# ========== 刷 aboot (LK1ST → lk2nd v23.1) ==========
say "[7/10] 刷入 upstream lk2nd v23.1 aboot"
warn "  !!! 关键操作 !!!"
info "  当前 aboot 是 LK1ST_MSM8916 v0.5 (老 fork)"
info "  即将换成 upstream lk2nd v23.1"

if fastboot flash aboot aboot-lk2nd-latest.mbn 2>&1; then
    say "  ✓ aboot 刷入成功"
else
    die "aboot 刷入失败 - 板子未变砖 (仍在 fastboot), 继续用 LK1ST"
fi

# 让板子重启进新 lk2nd
say "  重启到新 lk2nd..."
fastboot reboot-bootloader 2>&1 || {
    warn "  reboot-bootloader 命令失败, 手动断电重启"
    warn "  请拔电重来, 然后 Enter 继续"
    read
}

# 等新 lk2nd 起来
sleep 8
for i in $(seq 1 60); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        say "  ✓ 新 lk2nd 起来了"
        break
    fi
    printf "\r  等新 lk2nd %ds" "$i"
    sleep 1
    if [ "$i" = "60" ]; then
        warn "新 lk2nd 没起来 - 可能变砖或需 EDL 恢复"
        info "救砖: 短接 TP4-TP5 + edl w aboot $FACTORY_ABOOT"
        die "STOP"
    fi
done
echo ""

# 验证 lk2nd 起来了
info "验证 lk2nd 特性..."
product=$(fastboot getvar product 2>&1 | grep -oE 'product:.*' | head -1)
info "  $product"
# lk2nd 会显示 lk2nd 相关信息
if fastboot getvar all 2>&1 | head -5 | grep -qE "partition-size|slot-count"; then
    say "  ✓ 新 lk2nd 支持完整 getvar all"
else
    warn "  仍是老 lk 行为? 继续试"
fi
echo ""

# ========== 刷 boot.img ==========
say "[8/10] 刷入 boot.img"
fastboot flash boot boot.img
say "  ✓ boot.img 刷入"
echo ""

# ========== 刷 rootfs.img ==========
say "[9/10] 刷入 rootfs (预计 3-5 分钟)"
fastboot flash rootfs "$ROOTFS"
say "  ✓ rootfs 刷入"
echo ""

# ========== (可选) 恢复 factory modem 分区 ==========
if [ -n "$FACTORY_MODEM_DIR" ]; then
    ans=$(ask "[9.5/10] 也恢复 factory modem 系列分区吗？[Y/n]" "Y")
    if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
        for p in modemst1 modemst2 fsc fsg sec; do
            if [ -f "$FACTORY_MODEM_DIR/$p.bin" ]; then
                printf "  flash %-12s ... " "$p"
                if fastboot flash "$p" "$FACTORY_MODEM_DIR/$p.bin" >/dev/null 2>&1; then
                    printf "${GRN}✓${NC}\n"
                else
                    printf "${RED}✗${NC} (跳过)\n"
                fi
            fi
        done
    fi
fi
echo ""

# ========== 重启 ==========
say "[10/10] 重启进 pmOS"
fastboot reboot

cat <<'DONE'

╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ✅ 完整刷机结束!                                            ║
║                                                              ║
║   板子在启动:                                                ║
║     lk2nd v23.1 (upstream) → pmOS                            ║
║                                                              ║
║   等 60-90 秒:                                               ║
║                                                              ║
║   Mac 端 (另一 terminal):                                    ║
║     while ! ping -c 1 -W 1 172.16.42.1 2>/dev/null; do       ║
║         sleep 2; done                                        ║
║     ssh user@172.16.42.1  # 或 root@                         ║
║                                                              ║
║   接不上? 用新 lk2nd 的调试:                                  ║
║     fastboot devices        # 看是不是回 fastboot 了         ║
║     fastboot oem lk_log     # 这次能看到内容! (新 lk2nd 修好)║
║     fastboot getvar all     # 完整分区表输出                  ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

DONE
