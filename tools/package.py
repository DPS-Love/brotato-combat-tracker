"""打发布包：
  build/DPSLove-CombatTracker-vX.Y.Z.zip          GitHub Release / 手动安装
  build/workshop/<创意工坊英文标题>.zip            创意工坊上传（内容相同）

zip 里只有 mods-unpacked/DPSLove-CombatTracker/ 这一个目录（Mod Loader 要求的结构）。
时间戳固定、不压缩（压缩结果随 zlib 版本而变），同样的源码在任何机器上打出来都逐字节相同，
本机打的包和 CI 发布的包可以直接比对哈希。

创意工坊那份用 docs/workshop/workshop.json 里的英文标题命名：tools/workshop_upload.py 自己设标题，文件名无所谓；
但游戏自带的上传工具（GodotWorkshopUtility）每次上传都拿 zip 的文件名设置英文标题，用它传的时候文件名就得是英文标题、
不能带版本号。build/workshop/ 里只留这一个 zip，两个工具传的都是整个目录。

同时核对版本号：manifest.json 的 version_number 必须和 game/tracker.gd 里的 VERSION 一致；
给了 --tag 时还要和标签（vX.Y.Z）一致。

用法：
  python tools/package.py [--tag v0.1.0] [--out build]
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_ID = "DPSLove-CombatTracker"
MOD_DIR = os.path.join(REPO, "mods-unpacked", MOD_ID)
INCLUDE_EXT = {".gd", ".json", ".png", ".txt", ".cfg"}
EXTRA_FILES = {"LICENSE": os.path.join(REPO, "LICENSE")}
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
WORKSHOP_JSON = os.path.join(REPO, "docs", "workshop", "workshop.json")


def versions():
    with open(os.path.join(MOD_DIR, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    with open(os.path.join(MOD_DIR, "game", "tracker.gd"), encoding="utf-8") as f:
        m = re.search(r'^const VERSION = "([^"]+)"', f.read(), re.M)
    return manifest["version_number"], (m.group(1) if m else None)


def workshop_title():
    with open(WORKSHOP_JSON, encoding="utf-8") as f:
        return json.load(f)["languages"]["english"]["title"]


def collect():
    files = []
    for root, _, names in os.walk(MOD_DIR):
        for name in names:
            path = os.path.join(root, name)
            if os.path.splitext(name)[1].lower() not in INCLUDE_EXT:
                continue
            rel = os.path.relpath(path, os.path.dirname(os.path.dirname(MOD_DIR))).replace(os.sep, "/")
            files.append((rel, path))
    for name, path in EXTRA_FILES.items():
        if os.path.exists(path):
            files.append(("mods-unpacked/%s/%s" % (MOD_ID, name), path))
    files.sort()
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="")
    ap.add_argument("--out", default=os.path.join(REPO, "build"))
    args = ap.parse_args()

    manifest_version, code_version = versions()
    if manifest_version != code_version:
        sys.exit("版本号不一致：manifest.json 是 %s，tracker.gd 是 %s" % (manifest_version, code_version))
    if args.tag and args.tag.lstrip("v") != manifest_version:
        sys.exit("标签 %s 和 manifest.json 的 %s 不一致" % (args.tag, manifest_version))

    os.makedirs(args.out, exist_ok=True)
    out = os.path.join(args.out, "%s-v%s.zip" % (MOD_ID, manifest_version))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for rel, path in collect():
            with open(path, "rb") as f:
                data = f.read()
            info = zipfile.ZipInfo(rel, FIXED_TIME)
            info.compress_type = zipfile.ZIP_STORED
            # zipfile 按打包的系统填「来源系统」（Windows 0、其他 3），固定下来各平台才逐字节相同
            info.create_system = 3
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
    with open(out, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()

    workshop_dir = os.path.join(args.out, "workshop")
    os.makedirs(workshop_dir, exist_ok=True)
    for name in os.listdir(workshop_dir):
        if name.lower().endswith(".zip"):
            os.remove(os.path.join(workshop_dir, name))
    workshop = os.path.join(workshop_dir, workshop_title() + ".zip")
    shutil.copyfile(out, workshop)

    print(out)
    print("sha256", digest)
    print("创意工坊上传用：", workshop)


if __name__ == "__main__":
    main()
