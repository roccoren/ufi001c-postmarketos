#!/usr/bin/env bash
# UFI001C postmarketOS 离线刷机脚本 (macOS)
#
# 这个脚本假设所有镜像文件都跟脚本在同一目录 —— 不联网下载。
# 用法：把整个 bundle 目录传到 Mac，进入目录，然后：
#   chmod +x flash-pmos-offline.sh
#   ./flash-pmos-offline.sh
#
# 需要的文件（跟脚本在一起）：
#   - boot.img
#   - rootfs.img.zst  (或者 rootfs.img 已经解压过了)
#   - SHA256SUMS
#
# 可选：
#   - bootloader/aboot-lk2nd-latest.mbn  (只有需要更新 lk2nd 时才用)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ========== 颜色 ==========
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf "${GRN}==>${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!] ${NC}%s\n" "$*"; }
die()  { printf "${RED}[X] ${NC}%s\n" "$*"; exit 1; }
ask()  { local q="$1" default="${2:-}"; read -rp "$q " a; echo "${a:-$default}"; }

echo ""
say "UFI001C postmarketOS 离线刷机 (v26.06-2)"
echo "工作目录: $SCRIPT_DIR"
echo ""

# ========== 检查前置工具 ==========
say "[1/8] 检查前置工具..."
for cmd in fastboot zstd shasum; do
    printf "  %-12s " "$cmd"
    if command -v $cmd >/dev/null; then
        printf "${GRN}✓${NC}\n"
    else
        printf "${RED}✗${NC}\n"
        die "$cmd 未安装。参考 MAC-SETUP.md"
    fi
done
echo ""

# ========== 检查文件齐全 ==========
say "[2/8] 检查镜像文件..."
REQUIRED=(boot.img SHA256SUMS)
OPTIONAL=(rootfs.img.zst rootfs.img)
for f in "${REQUIRED[@]}"; do
    [ -f "$f" ] || die "缺文件: $f"
    printf "  %-25s %8s\n" "$f" "$(du -h "$f" | cut -f1)"
done
if [ ! -f rootfs.img ] && [ ! -f rootfs.img.zst ]; then
    die "缺 rootfs 镜像（rootfs.img 或 rootfs.img.zst 至少要有一个）"
fi
for f in "${OPTIONAL[@]}"; do
    [ -f "$f" ] && printf "  %-25s %8s\n" "$f" "$(du -h "$f" | cut -f1)"
done
echo ""

# ========== 校验 ==========
say "[3/8] 校验 SHA256..."
if ! shasum -a 256 -c SHA256SUMS --ignore-missing 2>&1 | grep -q "OK"; then
    die "SHA256 校验失败。文件可能损坏，请重新下载。"
fi
# 打印结果
shasum -a 256 -c SHA256SUMS --ignore-missing 2>&1 | grep -E "OK|FAILED" | head -5
echo ""

# ========== 解压 rootfs.img.zst ==========
say "[4/8] 准备 rootfs.img..."
if [ ! -f rootfs.img ] && [ -f rootfs.img.zst ]; then
    warn "解压 rootfs.img.zst → rootfs.img (800 MB)..."
    zstd -d --quiet rootfs.img.zst -o rootfs.img
fi
say "boot.img size:    $(du -h boot.img | cut -f1)"
say "rootfs.img size:  $(du -h rootfs.img | cut -f1)"
echo ""

# ========== 备份提醒 ==========
warn "[5/8] modem 分区备份确认"
cat <<'BACKUP'

⚠️  你已经从当前 Debian 里备份好 modem 相关分区了吗？

如果 NO：
  1. SSH 到板子：ssh user@192.168.4.1  (密码 1)
  2. 备份：
     sudo -i && cd /root && mkdir -p ufi001c-backup && cd ufi001c-backup
     for p in modem modemst1 modemst2 fsc fsg persist sec sbl1 tz rpm hyp aboot; do
       if [ -e "/dev/disk/by-partlabel/$p" ]; then
         dd if=/dev/disk/by-partlabel/$p of=$p.bin bs=4M status=none conv=fsync
         echo "backed up: $p"
       fi
     done
     sha256sum *.bin > SHA256SUMS
  3. 从 Mac 拉备份：
     scp -r user@192.168.4.1:/root/ufi001c-backup ~/ufi001c-backup-$(date +%Y%m%d)

这份备份是唯一能让 4G/SMS 继续工作的凭证。

BACKUP
answer=$(ask "备份好了？[y/N]" "N")
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "先做备份再来"
echo ""

# ========== 等 fastboot ==========
say "[6/8] 等待 UFI001C 进入 fastboot 模式..."
warn "触发方式："
warn "  A) SSH 到 Debian 后：sudo reboot bootloader"
warn "  B) 强制：拔插 + 短接 TP4-TP5 触发 EDL，然后 edl e boot && edl reset"
echo ""

TIMEOUT=120
for i in $(seq 1 $TIMEOUT); do
    if fastboot devices 2>/dev/null | grep -qi "fastboot"; then
        echo ""
        say "检测到 fastboot 设备："
        fastboot devices
        break
    fi
    if [ "$i" = "$TIMEOUT" ]; then
        echo ""
        die "${TIMEOUT}s 无 fastboot 设备。检查 lk2nd 是否装了 + USB 连接。"
    fi
    printf "\r  等待 %ds" "$i"
    sleep 1
done
echo ""

# ========== 双确认 ==========
say "[7/8] 确认刷入分区"
warn "即将覆盖："
echo "  boot   ← boot.img    ($(du -h boot.img | cut -f1))"
echo "  rootfs ← rootfs.img  ($(du -h rootfs.img | cut -f1))"
echo ""
warn "**Debian 会被完全覆盖**（modem 分区不动）"
echo ""
answer=$(ask "确定？输入 YES 继续：")
[ "$answer" = "YES" ] || die "已取消"
echo ""

# ========== 刷 ==========
say "[8/8] 开始刷写..."
say "→ fastboot flash boot boot.img"
fastboot flash boot boot.img

say "→ fastboot flash rootfs rootfs.img  (预计 3-5 分钟)"
fastboot flash rootfs rootfs.img

say "→ fastboot reboot"
fastboot reboot

cat <<'DONE'

╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ✅ pmOS 已刷入。板子正在启动。                             ║
║                                                              ║
║   首次启动时间：30-90 秒                                     ║
║   （first-boot 脚本在做 machine-id / ssh-keygen /            ║
║    resize2fs / 启动 USB gadget / 服务注册）                  ║
║                                                              ║
║   ── 接入方式 ─────────────────────────────────────────      ║
║                                                              ║
║   USB RNDIS (推荐):                                          ║
║     Mac: ifconfig | grep -A2 en   # 找新增的 enN             ║
║     ssh root@172.16.42.1          # 密码 pmos                ║
║     或 ssh user@172.16.42.1        # 密码 pmos               ║
║                                                              ║
║   UART (如果 SSH 不通):                                      ║
║     screen /dev/tty.usbserial* 115200                        ║
║                                                              ║
║   ── 登入后必做安全加固 ───────────────────────────           ║
║                                                              ║
║   1. passwd                                                  ║
║   2. mkdir -p ~/.ssh && chmod 700 ~/.ssh                     ║
║      echo 'your-pubkey' > ~/.ssh/authorized_keys             ║
║      chmod 600 ~/.ssh/authorized_keys                        ║
║   3. sed -i 's/^PasswordAuth.*/PasswordAuthentication no/'   ║
║      /etc/ssh/sshd_config                                    ║
║      sed -i 's/^PermitRoot.*/PermitRootLogin prohibit-password/' \\ 
║      /etc/ssh/sshd_config                                    ║
║      rc-service sshd restart                                 ║
║                                                              ║
║   ── 验证 modem ──────────────────────────────────────        ║
║                                                              ║
║   mmcli -L         # 应该看到 /Modem/0                        ║
║   mmcli -m 0       # 应该显示 IMEI/SIM 状态                   ║
║                                                              ║
║   如果 SSH 30 秒后还不通，看 /var/log/first-boot.log         ║
║   （通过 UART 或者过一会儿再试）                             ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

DONE

# ========== 卸掉解压出来的 rootfs.img（省空间；可选） ==========
if [ -f rootfs.img.zst ]; then
    answer=$(ask "删掉解压后的 rootfs.img 省 800 MB？[y/N]" "N")
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        rm -f rootfs.img
        say "rootfs.img 已删除（保留 rootfs.img.zst 备用）"
    fi
fi

exit 0
