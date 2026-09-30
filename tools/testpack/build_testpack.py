"""构建隔离测试包：复制游戏的 Brotato.pck，打几处补丁，另存为 build/testpack/BrotatoTest.pck。

补丁只存在于这份副本里，游戏本体一个字节都不动：
  - 用户目录改名为 BrotatoBCTTest：存档、设置、日志全部与玩家真实存档隔离
  - 平台层固定为 LocalPlatform：不初始化 Steam，不碰云存档、成就、统计
  - Mod Loader 用默认配置：从 --mods-path 指定的目录加载 zip（Steam 版默认只认订阅的创意工坊条目）
  - 追加一个自动加载的测试驱动（bct_test/driver.gd），自动开局、截图、核对、退出

用法：
  python tools/testpack/build_testpack.py [--game DIR] [--out build/testpack]
不给 --game 就自动找游戏目录（见 tools/gamedir.py）。
"""
import argparse
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))
import gamedir  # noqa: E402

USER_DIR_NAME = "BrotatoBCTTest"
DRIVER_PATH = "res://bct_test/driver.gd"
PLATFORM_PATH = "res://bct_test/platform_local.gd"


def read_pck(path):
    with open(path, "rb") as f:
        if f.read(4) != b"GDPC":
            raise SystemExit("不是 Godot PCK：" + path)
        ver, major, minor, patch = struct.unpack("<4I", f.read(16))
        if ver != 1:
            raise SystemExit("只支持 Godot 3 的 PCK（格式 1），这个是 %d" % ver)
        f.read(16 * 4)
        count = struct.unpack("<I", f.read(4))[0]
        index = []
        for _ in range(count):
            n = struct.unpack("<I", f.read(4))[0]
            name = f.read(n).rstrip(b"\0").decode("utf-8")
            off, size = struct.unpack("<qq", f.read(16))
            f.read(16)
            index.append((name, off, size))
        files = []
        for name, off, size in index:
            f.seek(off)
            files.append([name, f.read(size)])
    return (major, minor, patch), files


def write_pck(path, version, files):
    header = b"GDPC" + struct.pack("<4I", 1, *version) + b"\0" * 64 + struct.pack("<I", len(files))
    entries = []
    dir_size = 0
    for name, data in files:
        raw = name.encode("utf-8")
        padded = raw + b"\0" * ((4 - len(raw) % 4) % 4)
        entries.append(padded)
        dir_size += 4 + len(padded) + 16 + 16
    offset = len(header) + dir_size
    directory = b""
    for (name, data), padded in zip(files, entries):
        directory += struct.pack("<I", len(padded)) + padded
        directory += struct.pack("<qq", offset, len(data)) + hashlib.md5(data).digest()
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header)
        f.write(directory)
        for _, data in files:
            f.write(data)


# ---------------------------------------------------------------- project.binary（ECFG）

def _variant_string(s):
    b = s.encode("utf-8")
    return struct.pack("<II", 4, len(b)) + b + b"\0" * ((4 - len(b) % 4) % 4)


def _variant_bool(v):
    return struct.pack("<II", 1, 1 if v else 0)


def patch_project(data, set_values):
    """set_values: 键 -> 已编码的 Variant 字节。已有的键原地替换，没有的追加在末尾（自动加载按顺序生效，追加就是最后加载）。"""
    if data[:4] != b"ECFG":
        raise SystemExit("project.binary 格式不认识")
    count = struct.unpack_from("<I", data, 4)[0]
    o = 8
    items = []
    for _ in range(count):
        kl = struct.unpack_from("<I", data, o)[0]
        o += 4
        key = data[o:o + kl].decode("utf-8")
        o += kl
        vl = struct.unpack_from("<I", data, o)[0]
        o += 4
        items.append([key, data[o:o + vl]])
        o += vl
    seen = set()
    for item in items:
        if item[0] in set_values:
            item[1] = set_values[item[0]]
            seen.add(item[0])
    for key, value in set_values.items():
        if key not in seen:
            items.append([key, value])
    out = b"ECFG" + struct.pack("<I", len(items))
    for key, value in items:
        kb = key.encode("utf-8")
        out += struct.pack("<I", len(kb)) + kb + struct.pack("<I", len(value)) + value
    return out


OPTIONS_TRES = """[gd_resource type="Resource" load_steps=3 format=2]

[ext_resource path="res://addons/mod_loader/resources/options_current.gd" type="Script" id=1]
[ext_resource path="res://addons/mod_loader/options/profiles/default.tres" type="Resource" id=2]

[resource]
script = ExtResource( 1 )
current_options = ExtResource( 2 )
feature_override_options = {
}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default="")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "testpack"))
    args = ap.parse_args()
    args.game = args.game or gamedir.find_game_dir("--game")

    src = os.path.join(args.game, "Brotato.pck")
    os.makedirs(args.out, exist_ok=True)
    version, files = read_pck(src)
    by_name = {name: i for i, (name, _) in enumerate(files)}

    def put(name, data):
        if name in by_name:
            files[by_name[name]][1] = data
        else:
            by_name[name] = len(files)
            files.append([name, data])

    project = files[by_name["res://project.binary"]][1]
    put("res://project.binary", patch_project(project, {
        "application/config/use_custom_user_dir": _variant_bool(True),
        "application/config/custom_user_dir_name": _variant_string(USER_DIR_NAME),
        "autoload/BCTTestDriver": _variant_string("*" + DRIVER_PATH),
    }))
    put("res://addons/mod_loader/options/options.tres", OPTIONS_TRES.encode("utf-8"))
    put("res://singletons/platforms/platform.gd.remap", ('[remap]\n\npath="%s"\n' % PLATFORM_PATH).encode("utf-8"))
    for local, res in (("driver.gd", DRIVER_PATH), ("platform_local.gd", PLATFORM_PATH)):
        with open(os.path.join(HERE, local), "rb") as f:
            put(res, f.read())

    out = os.path.join(args.out, "BrotatoTest.pck")
    write_pck(out, version, files)
    print("写出", out, "共", len(files), "个文件，用户目录", USER_DIR_NAME)


if __name__ == "__main__":
    main()
