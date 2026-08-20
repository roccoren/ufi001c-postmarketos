#!/usr/bin/env bash
# UFI001C postmarketOS 一键刷机脚本 (macOS)
#
# 会自动从 GitHub release 下载最新镜像；也支持在本地目录已有镜像时直接使用。
#
# 前置条件：
#   1) 你的 UFI001C 当前跑着 OpenStick Debian（lk2nd 已经就位）
#   2) 已在 SSH 到 Debian 里 dd 备份了 modem/modemst*/fsc/fsg 等分区
#   3) macOS 上有：fastboot、zstd、curl、shasum
#
# 用法：
#   curl -sSL https://github.com/roccoren/ufi001c-postmarketos/releases/latest/download/flash-pmos-on-mac.sh | bash
#   # 或下下来跑：
#   chmod +x flash-pmos-on-mac.sh
#   ./flash-pmos-on-mac.sh

set -euo pipefail

REPO="roccoren/ufi001c-postmarketos"
RELEASE_TAG="${RELEASE_TAG:-latest}"
WORKDIR="${WORKDIR:-$(pwd)/pmos-ufi001c-$(date +%Y%m%d-%H%M%S)}"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!] ${NC}%s\n" "$*"; }
die()  { printf "${RED}[X] ${NC}%s\n" "$*"; exit 1; }

# ========== 前置检查 ==========
say "检查前置工具..."
command -v fastboot >/dev/null || die "fastboot 未安装 → brew install --cask android-platform-tools"
command -v zstd >/dev/null || die "zstd 未安装 → brew install zstd"
command -v shasum >/dev/null || die "shasum 缺失"
command -v curl >/dev/null || die "curl 缺失"

# ========== 准备工作目录 ==========
mkdir -p "$WORKDIR"
cd "$WORKDIR"
say "工作目录: $WORKDIR"

# ========== 下载镜像 ==========
BASE_URL="https://github.com/${REPO}/releases/${RELEASE_TAG}/download"
if [ "$RELEASE_TAG" = "latest" ]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
fi

download() {
    local f="$1"
    if [ -f "$f" ]; then
        say "$f 已存在，跳过下载"
        return 0
    fi
    say "下载 $f ..."
    curl -sSL --fail -o "$f" "${BASE_URL}/${f}" || die "下载 $f 失败"
}

download boot.img
download rootfs.img.zst
download SHA256SUMS

# ========== 校验镜像 ==========
say "校验 SHA256..."
if ! shasum -a 256 -c SHA256SUMS --ignore-missing 2>&1 | grep -q "OK"; then
    warn "校验失败，重新下载"
    exit 1
fi
say "镜像完整性 OK"

# ========== 解压 ==========
if [ ! -f rootfs.img ]; then
    say "解压 rootfs.img.zst → rootfs.img (约 800 MB)"
    zstd -d rootfs.img.zst -o rootfs.img
fi
ls -lh boot.img rootfs.img

# ========== 备份提醒 ==========
cat <<'REMINDER'

⚠️  最后确认：你已经从 Debian 里 dd 出 modem 相关分区备份吗？
   如果 NO，先 Ctrl+C。SSH 到 user@192.168.4.1 (密码 1)，然后：

     sudo -i && cd /root && mkdir -p ufi001c-backup && cd ufi001c-backup
     for p in modem modemst1 modemst2 fsc fsg persist sec sbl1 tz rpm hyp aboot; do
       dd if=/dev/disk/by-partlabel/$p of=$p.bin bs=4M status=none conv=fsync
     done
     
   然后 scp -r user@192.168.4.1:/root/ufi001c-backup ~/ufi001c-backup-$(date +%Y%m%d)

REMINDER
read -rp "备份好了？回车继续，或 Ctrl+C 停下： " _

# ========== 等 fastboot ==========
say "等待 UFI001C 进入 fastboot..."
warn "触发方式："
warn "  A) SSH 到 Debian 后跑：sudo reboot bootloader"
warn "  B) EDL 短接 TP4-TP5 后：edl e boot && edl reset"

TIMEOUT=120
for i in $(seq 1 $TIMEOUT); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        say "检测到 fastboot 设备："
        fastboot devices
        break
    fi
    [ "$i" = "$TIMEOUT" ] && die "${TIMEOUT}s 无 fastboot 设备。检查 lk2nd + USB。"
    printf "\r  等待 %ds" "$i"
    sleep 1
done
echo

# ========== 双确认 ==========
warn "即将覆盖："
echo "  boot   ← boot.img"
echo "  rootfs ← rootfs.img"
read -rp "确定？输入 YES 继续： " confirm
[ "$confirm" = "YES" ] || die "已取消"

# ========== 刷 ==========
say "[1/2] fastboot flash boot boot.img"
fastboot flash boot boot.img

say "[2/2] fastboot flash rootfs rootfs.img  (3-5 分钟)"
fastboot flash rootfs rootfs.img

say "重启到 pmOS..."
fastboot reboot

cat <<'END'

╔══════════════════════════════════════════════════════════════╗
║   pmOS 已刷入。首次启动约 30-60 秒（跑 first-boot 脚本）    ║
║                                                              ║
║   接入：SSH root@172.16.42.1  (密码 pmos)                    ║
║        或 SSH user@172.16.42.1 (密码 pmos)                   ║
║                                                              ║
║   首要动作：                                                 ║
║   1. passwd                                                  ║
║   2. echo 'your-pubkey' > ~/.ssh/authorized_keys             ║
║   3. sed -i 's/^PasswordAuth.*/PasswordAuthentication no/'   ║
║      /etc/ssh/sshd_config && rc-service sshd restart         ║
║                                                              ║
║   验 modem：mmcli -L && mmcli -m 0                           ║
╚══════════════════════════════════════════════════════════════╝

END
