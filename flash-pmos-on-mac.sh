#!/usr/bin/env bash
# UFI001C postmarketOS 一键刷机脚本 (macOS)
#
# 前置条件：
#   1) 你的 UFI001C 当前跑着 OpenStick Debian（lk2nd 已经就位）
#   2) Mac 上已装：brew install --cask android-platform-tools && brew install zstd
#   3) 已经从 Debian 里 dd 备份了 modem/modemst*/fsc/fsg 等分区（保险起见）
#
# 用法：
#   chmod +x flash-pmos-on-mac.sh
#   ./flash-pmos-on-mac.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ========== 颜色 ==========
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!] ${NC}%s\n" "$*"; }
die()  { printf "${RED}[X] ${NC}%s\n" "$*"; exit 1; }

# ========== 前置检查 ==========
say "检查前置工具..."
command -v fastboot >/dev/null || die "fastboot 未安装 → brew install --cask android-platform-tools"
command -v zstd >/dev/null || die "zstd 未安装 → brew install zstd"
command -v shasum >/dev/null || die "shasum 缺失（macOS 内置，怎么会没有？）"

# ========== 校验镜像 ==========
say "校验 SHA256..."
if [ ! -f SHA256SUMS ]; then die "SHA256SUMS 缺失"; fi
if ! shasum -a 256 -c SHA256SUMS 2>&1 | tail -n +1 | grep -q "OK"; then
    warn "校验失败，请重新下载镜像包"
    exit 1
fi
say "镜像完整性 OK"

# ========== 解压 rootfs ==========
if [ ! -f rootfs.img ]; then
    say "解压 rootfs.img.zst → rootfs.img（约 800 MB）"
    zstd -d rootfs.img.zst -o rootfs.img
else
    say "rootfs.img 已存在，跳过解压"
fi
ls -lh boot.img rootfs.img

# ========== 提示用户备份 ==========
cat <<'EOF'

⚠️  最后一次确认：
   - 你已经从 Debian 里 dd 出 modem/modemst1/modemst2/fsc/fsg/persist/sec 等分区备份吗？
   - 备份在哪？ (示例路径：~/ufi001c-backup-20260820/)
   
   如果 NO，先 Ctrl+C，SSH 到 user@192.168.4.1，跑：
     sudo -i && cd /root && mkdir -p ufi001c-backup && cd ufi001c-backup
     for p in modem modemst1 modemst2 fsc fsg persist sec sbl1 tz rpm hyp aboot; do
       dd if=/dev/disk/by-partlabel/$p of=$p.bin bs=4M status=none conv=fsync
     done
     
   然后 scp -r user@192.168.4.1:/root/ufi001c-backup ~/ufi001c-backup-$(date +%Y%m%d)

EOF
read -rp "备份好了？回车继续，或 Ctrl+C 停下： " _

# ========== 等待 fastboot ==========
say "等待 UFI001C 进入 fastboot 模式..."
warn "如果板子还在 Debian 里跑：ssh user@192.168.4.1 → sudo reboot bootloader"
warn "如果是 EDL：拔插 + 短接 TP4-TP5 → edl e boot → edl reset"
echo ""

TIMEOUT=120
for i in $(seq 1 $TIMEOUT); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        say "检测到 fastboot 设备："
        fastboot devices
        break
    fi
    if [ "$i" = "$TIMEOUT" ]; then
        die "等了 ${TIMEOUT}s 没等到 fastboot 设备。检查 lk2nd 是否装了，或者插拔试试。"
    fi
    printf "\r  等待中 ... %ds" "$i"
    sleep 1
done
echo ""

# ========== 双确认 ==========
warn "即将开始刷写以下分区（会覆盖当前 Debian）："
echo "  boot   ← boot.img (21 MB)"
echo "  rootfs ← rootfs.img (800 MB)"
echo ""
read -rp "确定？输入 YES 继续： " confirm
[ "$confirm" = "YES" ] || die "已取消"

# ========== 刷 boot ==========
say "[1/2] fastboot flash boot boot.img"
fastboot flash boot boot.img

# ========== 刷 rootfs ==========
say "[2/2] fastboot flash rootfs rootfs.img  (约 3-5 分钟)"
fastboot flash rootfs rootfs.img

# ========== 重启 ==========
say "重启到 pmOS..."
fastboot reboot

cat <<'EOF'

╔══════════════════════════════════════════════════════════════╗
║   pmOS 已刷入。板子正在启动。                                ║
║                                                              ║
║   首次启动会执行 first-boot 脚本（apk fix + mkinitfs +      ║
║   服务注册），约 30-60 秒。                                  ║
║                                                              ║
║   接入方式：                                                 ║
║   • Mac 上 ifconfig 看新增的 enN 网卡                        ║
║   • SSH root@172.16.42.1  (密码 pmos)                        ║
║   • 或 SSH user@172.16.42.1 (密码 pmos)                      ║
║                                                              ║
║   登入后务必立刻：                                           ║
║   • passwd （改 root 密码）                                  ║
║   • 加你的 SSH pubkey 到 ~/.ssh/authorized_keys              ║
║   • 关掉 PasswordAuthentication（详见 README.md）            ║
║                                                              ║
║   验证 modem 是否活着：                                      ║
║   • mmcli -L                                                 ║
║   • mmcli -m 0                                               ║
╚══════════════════════════════════════════════════════════════╝

EOF

exit 0
