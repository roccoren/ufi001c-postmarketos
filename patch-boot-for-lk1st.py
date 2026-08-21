#!/usr/bin/env python3
"""
patch-boot-for-lk1st.py

给 pmbootstrap 生成的 Android boot.img 打补丁，让它能在
LK1ST_MSM8916 fork (OpenStick 用的老 lk2nd 分支) 上启动。

Fix 1: 在 kernel 内部 0x2C offset 处写 kernel_size (LK1ST 用它找 appended DTB)
Fix 2: 如果 DTB 里没有 qcom,msm-id / qcom,board-id，加上

用法:
  python3 patch-boot-for-lk1st.py in.img out.img
"""
import sys, struct, os

def patch(inp, out):
    with open(inp, 'rb') as f:
        data = f.read()
    
    # Android boot.img header (v0)
    magic = data[0:8]
    if magic != b'ANDROID!':
        print(f"❌ Not an Android boot.img (magic: {magic!r})")
        sys.exit(1)
    
    kernel_size = struct.unpack_from('<I', data, 8)[0]
    kernel_addr = struct.unpack_from('<I', data, 12)[0]
    ramdisk_size = struct.unpack_from('<I', data, 16)[0]
    ramdisk_addr = struct.unpack_from('<I', data, 20)[0]
    second_size = struct.unpack_from('<I', data, 24)[0]
    tags_addr = struct.unpack_from('<I', data, 32)[0]
    page_size = struct.unpack_from('<I', data, 36)[0]
    hdr_ver = struct.unpack_from('<I', data, 40)[0]
    
    print(f"boot.img header:")
    print(f"  kernel:     {kernel_size:,} bytes @ 0x{kernel_addr:x}")
    print(f"  ramdisk:    {ramdisk_size:,} bytes @ 0x{ramdisk_addr:x}")
    print(f"  second:     {second_size:,} bytes")
    print(f"  page_size:  {page_size}")
    print(f"  header_ver: {hdr_ver}")
    
    # kernel starts at page_size offset in boot.img
    kernel_start = page_size
    kernel_end = kernel_start + kernel_size
    
    # 找 DTB — 可能 append 到 kernel 或者在 second_addr / 独立字段
    dtb_offset_in_kernel = None
    
    # 方式 1: DTB append 到 kernel (最常见)
    # 检查 kernel 最后一段是否有 d00dfeed magic
    if kernel_size > 0x40:
        # kernel 里 header 后可能有 appended DTB。找 d00dfeed magic
        for search_start in [kernel_end - 100000, kernel_end - 200000, kernel_end - 500000]:
            if search_start < kernel_start:
                continue
            for i in range(max(kernel_start, search_start), kernel_end - 4):
                if data[i:i+4] == b'\xd0\x0d\xfe\xed':
                    dtb_offset_in_kernel = i - kernel_start
                    print(f"  ✓ Found DTB magic in kernel at kernel-relative offset {dtb_offset_in_kernel:,}")
                    break
            if dtb_offset_in_kernel:
                break
    
    # 方式 2: DTB 在 second field
    if not dtb_offset_in_kernel and second_size > 0:
        # second_start 在 boot.img 中的位置
        kernel_pages = (kernel_size + page_size - 1) // page_size
        ramdisk_pages = (ramdisk_size + page_size - 1) // page_size
        second_start = (1 + kernel_pages + ramdisk_pages) * page_size
        if data[second_start:second_start+4] == b'\xd0\x0d\xfe\xed':
            print(f"  ! DTB is in 'second' field at boot.img offset {second_start}")
            print(f"    Need to move it into kernel (appended). Complex, aborting.")
            sys.exit(1)
    
    if not dtb_offset_in_kernel:
        print(f"  ❌ No DTB magic (d00dfeed) found in kernel bytes.")
        print(f"     This boot.img doesn't have appended DTB.")
        print(f"     LK1ST 需要 appended DTB. 请用 pmbootstrap 时确保 deviceinfo_append_dtb=true")
        sys.exit(1)
    
    # ========== FIX 1: 在 kernel 内部 0x2C 处写 dtb offset ==========
    # LK1ST 从 kernel+0x2C 读 u32 找 appended DTB 的偏移
    current_val = struct.unpack_from('<I', data, kernel_start + 0x2C)[0]
    print(f"\nkernel[0x2C] 当前值: 0x{current_val:08x}")
    
    if current_val == dtb_offset_in_kernel:
        print(f"  ✓ 已经指向正确的 DTB 位置，不用改")
        patched = bytearray(data)
    else:
        print(f"  → 改为: 0x{dtb_offset_in_kernel:08x} ({dtb_offset_in_kernel:,})")
        patched = bytearray(data)
        struct.pack_into('<I', patched, kernel_start + 0x2C, dtb_offset_in_kernel)
    
    # 写入
    with open(out, 'wb') as f:
        f.write(bytes(patched))
    
    print(f"\n✅ 已写入: {out}")
    print(f"   size: {os.path.getsize(out):,} bytes")
    print(f"\n下一步: fastboot boot {out}  (先内存测试)")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"用法: {sys.argv[0]} <input.img> <output.img>")
        sys.exit(1)
    patch(sys.argv[1], sys.argv[2])
