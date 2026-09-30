r"""
找游戏目录。按顺序：
  1. 脚本自己的命令行参数（各脚本自己处理）
  2. 环境变量 BROTATO_GAME_DIR
  3. Steam 的各个库：注册表里的 SteamPath，加上 steamapps\libraryfolders.vdf 里登记的其它库，
     找 steamapps\common\Brotato\Brotato.exe
"""
import os
import re
import sys


def steam_libraries():
    """Steam 的各个库目录（第一个是 Steam 自己的目录）；不是 Windows 或没装 Steam 时为空。"""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = winreg.QueryValueEx(key, "SteamPath")[0]
    except (ImportError, OSError):
        return []
    # SteamPath 是 d:/steam 这种正斜杠写法，normpath 顺手规范掉
    libs = [os.path.normpath(steam)]
    try:
        with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), encoding="utf-8", errors="replace") as f:
            text = f.read()
        # vdf 里的反斜杠是转义过的："E:\\SteamLibrary"
        for p in re.findall(r'"path"\s+"([^"]+)"', text):
            p = os.path.normpath(p.replace("\\\\", "\\"))
            if p not in libs:
                libs.append(p)
    except OSError:
        pass
    return libs


def find_game_dir(flag):
    """按 2、3 找游戏目录；找不到就退出，提示用 flag（脚本自己的参数）或环境变量指定。"""
    d = os.environ.get("BROTATO_GAME_DIR")
    if d:
        return d
    for lib in steam_libraries():
        d = os.path.join(lib, "steamapps", "common", "Brotato")
        if os.path.isfile(os.path.join(d, "Brotato.exe")):
            return d
    sys.exit("找不到游戏目录。设置环境变量 BROTATO_GAME_DIR，或用 %s 指定。" % flag)


if __name__ == "__main__":
    print(find_game_dir("命令行参数"))
