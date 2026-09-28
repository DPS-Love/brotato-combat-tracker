"""Godot 3 资源包（.pck）读取：列目录、解包。游戏更新后重新对齐挂钩点时用。

支持独立的 .pck，也支持嵌在 exe 末尾的包（比如游戏自带的 GodotWorkshopUtility.exe）。
嵌入包的文件偏移是相对整个 exe 的，不用再加包的起点。

用法：
  python tools/pck.py info    <pck>
  python tools/pck.py list    <pck> [通配符]
  python tools/pck.py extract <pck> <输出目录> [通配符]

例：解出全部脚本，再用 gdc.py 还原成可读的 GDScript
  python tools/pck.py extract "<游戏目录>/Brotato.pck" reference/game "*.gd*"
  python tools/gdc.py reference/game reference/src
"""
import fnmatch
import os
import struct
import sys


def read_index(path):
    f = open(path, "rb")
    if f.read(4) != b"GDPC":
        # 嵌在可执行文件末尾：[包][包长度 u64]["GDPC"]
        f.seek(-4, 2)
        if f.read(4) != b"GDPC":
            raise SystemExit("不是 Godot 资源包：" + path)
        f.seek(-12, 2)
        size = struct.unpack("<q", f.read(8))[0]
        f.seek(-12 - size, 2)
        if f.read(4) != b"GDPC":
            raise SystemExit("嵌入的资源包损坏：" + path)
    ver, major, minor, patch = struct.unpack("<4I", f.read(16))
    file_base = 0
    if ver >= 2:
        _flags, file_base = struct.unpack("<Iq", f.read(12))
    f.read(16 * 4)
    count = struct.unpack("<I", f.read(4))[0]
    entries = []
    for _ in range(count):
        n = struct.unpack("<I", f.read(4))[0]
        name = f.read(n).rstrip(b"\0").decode("utf-8")
        off, size = struct.unpack("<qq", f.read(16))
        f.read(16)  # md5
        if ver >= 2:
            f.read(4)
        entries.append((name, file_base + off, size))
    return f, (ver, major, minor, patch), entries


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd, pck = sys.argv[1], sys.argv[2]
    f, version, entries = read_index(pck)
    if cmd == "info":
        print("格式 %d，Godot %d.%d.%d，%d 个文件" % (version + (len(entries),)))
    elif cmd == "list":
        pattern = sys.argv[3] if len(sys.argv) > 3 else "*"
        for name, _, size in entries:
            if fnmatch.fnmatch(name, pattern):
                print(size, name)
    elif cmd == "extract":
        out = sys.argv[3]
        pattern = sys.argv[4] if len(sys.argv) > 4 else "*"
        n = 0
        for name, off, size in entries:
            if not fnmatch.fnmatch(name, pattern):
                continue
            dst = os.path.join(out, name.replace("res://", ""))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            f.seek(off)
            with open(dst, "wb") as g:
                g.write(f.read(size))
            n += 1
        print("解出 %d 个文件" % n)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
