"""核对 core/ 的纯净性：这里的脚本不许引用游戏或 Mod Loader 的全局名字。

core/ 里的解析器在后台线程里导入日志；游戏以后改了类名，这部分也不该受影响。
谁在 core/ 里写了 RunData、ItemService、ModLoaderLog 之类，这里就报出来。

用法：python tools/check_core.py
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(REPO, "mods-unpacked", "DPSLove-CombatTracker", "core")

# 游戏的自动加载与常用全局类、Mod Loader 的全局类
FORBIDDEN = [
    "RunData", "ItemService", "ProgressData", "Keys", "Utils", "Text", "CoopService", "WeaponService",
    "EntityService", "ChallengeService", "DebugService", "Platform", "SoundManager", "TempStats",
    "ModLoader", "ModLoaderLog", "ModLoaderMod", "ModLoaderStore", "ModLoaderConfig",
    "Player", "Enemy", "Unit", "Weapon", "Hitbox", "TakeDamageArgs", "Main",
]
PATTERN = re.compile(r"\b(" + "|".join(FORBIDDEN) + r")\b")


def main():
    bad = []
    for name in sorted(os.listdir(CORE)):
        if not name.endswith(".gd"):
            continue
        with open(os.path.join(CORE, name), encoding="utf-8") as f:
            for no, line in enumerate(f, 1):
                code = line.split("#", 1)[0]
                # 字符串里的字（比如日志前缀、文案）不算
                code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
                m = PATTERN.search(code)
                if m:
                    bad.append("%s:%d  %s    <- %s" % (name, no, line.rstrip(), m.group(1)))
    if bad:
        print("core/ 里引用了游戏或 Mod Loader 的全局名字：")
        print("\n".join(bad))
        sys.exit(1)
    print("core/ 干净")


if __name__ == "__main__":
    main()
