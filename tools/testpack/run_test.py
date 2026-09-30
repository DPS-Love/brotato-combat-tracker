"""在隔离测试包里跑一遍自动测试。

  1. 打 Mod 包（tools/package.py），放进 build/testmods/
  2. 测试包不存在或测试脚本更新过，就重建（build_testpack.py）
  3. 用游戏本体的 Brotato.exe 加载测试包启动：独立用户目录、不连 Steam、不出声
  4. 等测试驱动跑完自动退出，汇总 results.json、截图和日志里的脚本错误

玩家的存档、设置、Steam 云和成就都不会被碰到。

用法：
  python tools/testpack/run_test.py [--game DIR] [--lang zh|en] [--with MOD.zip ...] [--wave 3] [--seconds 40]
不给 --game 就自动找游戏目录（见 tools/gamedir.py）。
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BUILD = os.path.join(REPO, "build")
USER_DIR = os.path.join(os.environ.get("APPDATA", ""), "BrotatoBCTTest")
sys.path.insert(0, os.path.join(REPO, "tools"))
import gamedir  # noqa: E402


def newest(paths):
    return max(os.path.getmtime(p) for p in paths)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default="")
    ap.add_argument("--lang", default="zh")
    ap.add_argument("--with", dest="extra", action="append", default=[], help="同时加载的其它 Mod zip（比如 BrotatoOnline）")
    ap.add_argument("--wave", default="3")
    ap.add_argument("--seconds", default="40")
    ap.add_argument("--loadout", default="")
    ap.add_argument("--enemy-mult", default="1")
    ap.add_argument("--players", default="1")
    ap.add_argument("--preview", default="", help="顺便生成创意工坊预览图，给出文件名（不带扩展名）")
    ap.add_argument("--preview-sub", default="")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()
    args.game = args.game or gamedir.find_game_dir("--game")

    # 1. 打包（输出到管道时 Python 默认用系统代码页，简体中文系统是 GBK，让它改用 UTF-8）
    out = subprocess.run([sys.executable, os.path.join(REPO, "tools", "package.py"), "--out", BUILD],
                         capture_output=True, text=True, encoding="utf-8",
                         env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    if out.returncode != 0:
        sys.exit(out.stderr or out.stdout)
    zip_path = out.stdout.splitlines()[0].strip()
    mods = os.path.join(BUILD, "testmods")
    shutil.rmtree(mods, ignore_errors=True)
    os.makedirs(mods)
    shutil.copy(zip_path, mods)
    for extra in args.extra:
        shutil.copy(extra, mods)

    # 2. 测试包
    pack = os.path.join(BUILD, "testpack", "BrotatoTest.pck")
    sources = [os.path.join(HERE, n) for n in ("build_testpack.py", "driver.gd", "platform_local.gd")]
    if not os.path.exists(pack) or os.path.getmtime(pack) < newest(sources):
        subprocess.run([sys.executable, os.path.join(HERE, "build_testpack.py"), "--game", args.game], check=True)

    # 3. 启动：结果目录清空；Mod 的配置删掉重新生成，测的是默认值（战斗日志留着，导入要用）
    shutil.rmtree(os.path.join(USER_DIR, "bct_test"), ignore_errors=True)
    config = os.path.join(USER_DIR, "CombatTracker", "config.cfg")
    if os.path.exists(config):
        os.remove(config)
    env = dict(os.environ)
    env["BCT_TEST_LANG"] = args.lang
    env["BCT_TEST_WAVE"] = args.wave
    env["BCT_TEST_SECONDS"] = args.seconds
    env["BCT_TEST_ENEMY_MULT"] = args.enemy_mult
    env["BCT_TEST_PLAYERS"] = args.players
    if args.preview:
        env["BCT_TEST_PREVIEW"] = args.preview
    if args.preview_sub:
        env["BCT_TEST_PREVIEW_SUB"] = args.preview_sub
    if args.loadout:
        env["BCT_TEST_LOADOUT"] = args.loadout
    exe = os.path.join(args.game, "Brotato.exe")
    cmd = [exe, "--main-pack", pack, "--mods-path", mods, "--audio-driver", "Dummy"]
    print("启动：", " ".join(cmd))
    started = time.time()
    with open(os.path.join(BUILD, "testrun-stdout.log"), "w", encoding="utf-8", errors="replace") as log:
        proc = subprocess.Popen(cmd, cwd=args.game, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("超时，已结束进程")
    print("用时 %.0f 秒，退出码 %s" % (time.time() - started, proc.returncode))

    # 4. 汇总
    result_dir = os.path.join(USER_DIR, "bct_test")
    results = os.path.join(result_dir, "results.json")
    if os.path.exists(results):
        with open(results, encoding="utf-8") as f:
            data = json.load(f)
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print("没有 results.json")
    for png in sorted(glob.glob(os.path.join(result_dir, "*.png"))):
        print("截图", png)
    errors = []
    for name in ("godot.log", "modloader.log"):
        p = os.path.join(USER_DIR, "logs", name)
        if os.path.exists(p):
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    low = line.lower()
                    if ("error" in low or "fatal" in low) and ("combattracker" in low or "mods-unpacked/dpslove" in low or "script error" in low or "parse error" in low):
                        errors.append(name + ": " + line.rstrip())
    print("日志里的相关错误：%d 条" % len(errors))
    for e in errors[:60]:
        print("  " + e)


if __name__ == "__main__":
    main()
