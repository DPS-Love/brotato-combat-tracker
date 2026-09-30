"""把 Mod 传到创意工坊：文件、预览图、标签、各语言的标题和说明、改动说明，一次设好。

游戏自带的上传工具（GodotWorkshopUtility）只设文件、预览图、标签和英文标题（取 zip 的文件名），
提交的改动说明是空的，其他语言的标题、各语言的说明都得传完再到网页上一项项改。
这个脚本调的是同一套 Steamworks 创意工坊接口（游戏目录里的 steam_api64.dll），把这些一次设好。

借正在运行的 Steam 客户端的登录：Steam 要开着、登录的是条目的作者，不需要账号密码，
也不用在游戏目录里放 steam_appid.txt（AppID 从环境变量交给 Steam）。
连着 Steam 的这一会儿，Steam 会显示在玩 Brotato（官方工具也一样）。需要 64 位的 Python。

要传的东西写在 docs/workshop/workshop.json：条目号、标签、预览图，各语言的标题和说明文件
（语言用 Steam 的 API 语言代码：english、schinese、tchinese、japanese…；english 必须有，
没有单独标题和说明的语言都显示英文那一份）。
文件是 package.py 打的 build/workshop/ 下那个 zip，脚本先打一次包。
改动说明默认取 docs/workshop/changenotes/v<版本>.txt，没有就取 v<版本> 标签的注释；都是 Steam 的 BBCode。

Steam 一次提交只收一种语言的标题和说明：英文以外的语言各自提交一次（和条目上现在的一样就跳过），
最后一次提交文件、预览图、标签、英文的标题和说明，带上改动说明。

用法：
  python tools/workshop_upload.py            # 打包，列出要传的东西，不连 Steam
  python tools/workshop_upload.py --check    # 再连上 Steam，对比条目上现在的标题和说明，不改任何东西
  python tools/workshop_upload.py --upload   # 上传
选项：
  --note 文件                                   改动说明换成这个文件
  --no-preview                                  不换预览图
  --visibility public|friends|private|unlisted  顺便改可见性（默认不动）
  --game 目录                                   游戏目录（找 steam_api64.dll），默认自动找，见 gamedir.py
"""
import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import gamedir  # noqa: E402

CONFIG = os.path.join(REPO, "docs", "workshop", "workshop.json")
MANIFEST = os.path.join(REPO, "mods-unpacked", "DPSLove-CombatTracker", "manifest.json")
CONTENT_DIR = os.path.join(REPO, "build", "workshop")
NOTES_DIR = os.path.join(REPO, "docs", "workshop", "changenotes")
AGREEMENT_URL = "https://steamcommunity.com/sharedfiles/workshoplegalagreement"

VISIBILITY = {"public": 0, "friends": 1, "private": 2, "unlisted": 3}
VISIBILITY_NAME = {v: k for k, v in VISIBILITY.items()}
# 提交和查询的结果（EResult）
RESULTS = {
    1: "成功",
    2: "失败",
    8: "参数不对（AppID 和条目对不上，或预览图太小）",
    9: "找不到文件（条目不存在，或读不了预览图 / 文件目录）",
    15: "没有权限（登录的账号没有这个游戏）",
    16: "超时",
    25: "超出限制（预览图要小于 1 MB，或 Steam 云空间不够）",
    33: "拿不到条目的锁，稍后再试",
}
# GetItemUpdateProgress 的阶段
STAGES = {1: "准备配置", 2: "准备文件", 3: "上传文件", 4: "上传预览图", 5: "提交"}
# 标题和说明的缓冲区大小（含结尾的 0）：k_cchPublishedDocumentTitleMax / k_cchPublishedDocumentDescriptionMax
TITLE_BUF = 129
DESCRIPTION_BUF = 8000
PREVIEW_MAX = 1024 * 1024


def fail(msg):
    sys.exit("错误：" + msg)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def repo_path(p):
    return p if os.path.isabs(p) else os.path.join(REPO, p)


def utf8_len(s):
    return len(s.encode("utf-8"))


# ---------------------------------------------------------------------------
# 要传什么
# ---------------------------------------------------------------------------

def load_plan(args):
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    with open(MANIFEST, encoding="utf-8") as f:
        version = json.load(f)["version_number"]

    if "english" not in cfg["languages"]:
        fail("workshop.json 里要有 english：没有单独标题和说明的语言都显示英文那一份")
    langs = []
    for code, entry in cfg["languages"].items():
        title = entry["title"]
        desc = read_text(repo_path(entry["description"]))
        for what, text, buf in (("标题", title, TITLE_BUF), ("说明", desc, DESCRIPTION_BUF)):
            if utf8_len(text) >= buf:
                fail("%s 的%s有 %d 字节，Steam 最多收 %d" % (code, what, utf8_len(text), buf - 1))
        langs.append({"code": code, "title": title, "description": desc, "file": entry["description"]})

    preview = None
    if not args.no_preview:
        preview = repo_path(cfg["preview"])
        if not os.path.isfile(preview):
            fail("找不到预览图 " + preview)
        if os.path.getsize(preview) >= PREVIEW_MAX:
            fail("预览图要小于 1 MB")

    note, note_from = change_note(args, version)
    return {
        "app_id": int(cfg["app_id"]),
        "item_id": int(cfg["item_id"]),
        "tags": list(cfg.get("tags", [])),
        "version": version,
        "preview": preview,
        "languages": langs,
        "note": note,
        "note_from": note_from,
        "visibility": args.visibility,
    }


def change_note(args, version):
    if args.note:
        return read_text(args.note), args.note
    path = os.path.join(NOTES_DIR, "v%s.txt" % version)
    if os.path.isfile(path):
        return read_text(path), os.path.relpath(path, REPO)
    # 退回 v<版本> 标签的注释：去掉署名，「- 」开头的行换成 BBCode 列表
    try:
        out = subprocess.run(["git", "tag", "-l", "--format=%(contents)", "v" + version],
                             cwd=REPO, capture_output=True, text=True, encoding="utf-8").stdout
    except OSError:
        out = ""
    lines = [l for l in out.splitlines() if not l.startswith("Co-Authored-By:")]
    text = "\n".join(lines).strip()
    if not text:
        fail("没有改动说明：写 docs/workshop/changenotes/v%s.txt，或用 --note 指定" % version)
    return bullets_to_bbcode(text), "标签 v%s 的注释" % version


def bullets_to_bbcode(text):
    out, in_list = [], False
    for line in text.splitlines():
        m = re.match(r"^\s*[-*]\s+(.*)$", line)
        if m:
            if not in_list:
                out.append("[list]")
                in_list = True
            out.append("[*]" + m.group(1))
            continue
        if in_list:
            out.append("[/list]")
            in_list = False
        out.append(line)
    if in_list:
        out.append("[/list]")
    return "\n".join(out)


def package():
    """打包（和发布包内容相同），返回创意工坊文件目录里的 zip。"""
    # 输出到管道时 Python 默认用系统代码页（简体中文系统是 GBK），让它改用 UTF-8
    r = subprocess.run([sys.executable, os.path.join(HERE, "package.py")], cwd=REPO,
                       capture_output=True, text=True, encoding="utf-8",
                       env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    if r.returncode != 0:
        fail("打包失败：" + (r.stderr or r.stdout).strip())
    zips = [n for n in os.listdir(CONTENT_DIR) if n.lower().endswith(".zip")]
    if len(zips) != 1:
        fail("build/workshop/ 里应当只有一个 zip：%s" % zips)
    return os.path.join(CONTENT_DIR, zips[0])


def dirty_mod_files():
    try:
        r = subprocess.run(["git", "status", "--porcelain", "--", "mods-unpacked"], cwd=REPO,
                           capture_output=True, text=True, encoding="utf-8")
        return [l for l in r.stdout.splitlines() if l.strip()]
    except OSError:
        return []


def show(plan, zip_path):
    print("条目      https://steamcommunity.com/sharedfiles/filedetails/?id=%d" % plan["item_id"])
    print("版本      %s" % plan["version"])
    print("文件      %s（%d 字节）" % (os.path.relpath(zip_path, REPO), os.path.getsize(zip_path)))
    if plan["preview"]:
        print("预览图    %s（%d 字节）" % (os.path.relpath(plan["preview"], REPO), os.path.getsize(plan["preview"])))
    else:
        print("预览图    不换")
    print("标签      %s" % ", ".join(plan["tags"]))
    print("可见性    %s" % (plan["visibility"] or "不动"))
    for l in plan["languages"]:
        print("%-9s 标题「%s」，说明 %s（%d 字节）" % (l["code"], l["title"], l["file"], utf8_len(l["description"])))
    print("改动说明  来自 %s：" % plan["note_from"])
    for line in plan["note"].splitlines():
        print("    " + line)
    dirty = dirty_mod_files()
    if dirty:
        print("注意：mods-unpacked 下有没提交的改动，传上去的是工作区里的版本：")
        for l in dirty:
            print("    " + l)


# ---------------------------------------------------------------------------
# Steamworks（steam_api64.dll 的扁平接口）
# ---------------------------------------------------------------------------

class SubmitItemUpdateResult(ctypes.Structure):
    # SubmitItemUpdateResult_t
    _fields_ = [("result", ctypes.c_int32),
                ("needs_agreement", ctypes.c_bool),
                ("file_id", ctypes.c_uint64)]


class QueryCompleted(ctypes.Structure):
    # SteamUGCQueryCompleted_t
    _fields_ = [("handle", ctypes.c_uint64),
                ("result", ctypes.c_int32),
                ("returned", ctypes.c_uint32),
                ("total", ctypes.c_uint32),
                ("cached", ctypes.c_bool),
                ("next_cursor", ctypes.c_char * 256)]


class Details(ctypes.Structure):
    # SteamUGCDetails_t 到 m_eVisibility 为止的部分；后面的字段不读，rest 给 Steam 留足写的地方
    _fields_ = [("file_id", ctypes.c_uint64),
                ("result", ctypes.c_int32),
                ("file_type", ctypes.c_int32),
                ("creator_app", ctypes.c_uint32),
                ("consumer_app", ctypes.c_uint32),
                ("title", ctypes.c_char * TITLE_BUF),
                ("description", ctypes.c_char * DESCRIPTION_BUF),
                ("owner", ctypes.c_uint64),
                ("time_created", ctypes.c_uint32),
                ("time_updated", ctypes.c_uint32),
                ("time_added", ctypes.c_uint32),
                ("visibility", ctypes.c_int32),
                ("rest", ctypes.c_byte * 4096)]


class ParamStringArray(ctypes.Structure):
    # SteamParamStringArray_t
    _fields_ = [("strings", ctypes.POINTER(ctypes.c_char_p)),
                ("count", ctypes.c_int32)]


# 回调号：k_iSteamUGCCallbacks (3400) + 1 / + 4
QUERY_COMPLETED = 3401
SUBMIT_ITEM_UPDATE_RESULT = 3404
INVALID_QUERY = 0xFFFFFFFFFFFFFFFF


class Steam:
    def __init__(self, game_dir, app_id):
        if ctypes.sizeof(ctypes.c_void_p) != 8:
            fail("要用 64 位的 Python（steam_api64.dll 是 64 位的）")
        dll = os.path.join(game_dir, "steam_api64.dll")
        if not os.path.isfile(dll):
            fail("游戏目录里没有 steam_api64.dll：" + game_dir)
        # 不经 Steam 启动时，Steam 从这两个环境变量知道是哪个游戏；要在载入 DLL 之前设
        os.environ["SteamAppId"] = str(app_id)
        os.environ["SteamGameId"] = str(app_id)
        self.api = ctypes.CDLL(dll)
        self.app_id = app_id
        u64, u32, vp, cp, b = ctypes.c_uint64, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_bool
        self._sig("SteamAPI_InitFlat", ctypes.c_int, [ctypes.c_char_p])
        self._sig("SteamAPI_Shutdown", None, [])
        self._sig("SteamAPI_SteamUGC_v021", vp, [])
        self._sig("SteamAPI_SteamUtils_v010", vp, [])
        self._sig("SteamAPI_SteamUser_v023", vp, [])
        self._sig("SteamAPI_ISteamUser_GetSteamID", u64, [vp])
        self._sig("SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest", u64, [vp, ctypes.POINTER(u64), u32])
        self._sig("SteamAPI_ISteamUGC_SetLanguage", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetReturnLongDescription", b, [vp, u64, b])
        self._sig("SteamAPI_ISteamUGC_SetAllowCachedResponse", b, [vp, u64, u32])
        self._sig("SteamAPI_ISteamUGC_SendQueryUGCRequest", u64, [vp, u64])
        self._sig("SteamAPI_ISteamUGC_GetQueryUGCResult", b, [vp, u64, u32, ctypes.POINTER(Details)])
        self._sig("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", b, [vp, u64])
        self._sig("SteamAPI_ISteamUGC_StartItemUpdate", u64, [vp, u32, u64])
        self._sig("SteamAPI_ISteamUGC_SetItemUpdateLanguage", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetItemTitle", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetItemDescription", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetItemContent", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetItemPreview", b, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_SetItemTags", b, [vp, u64, ctypes.POINTER(ParamStringArray), b])
        self._sig("SteamAPI_ISteamUGC_SetItemVisibility", b, [vp, u64, ctypes.c_int])
        self._sig("SteamAPI_ISteamUGC_SubmitItemUpdate", u64, [vp, u64, cp])
        self._sig("SteamAPI_ISteamUGC_GetItemUpdateProgress", ctypes.c_int,
                  [vp, u64, ctypes.POINTER(u64), ctypes.POINTER(u64)])
        self._sig("SteamAPI_ISteamUtils_IsAPICallCompleted", b, [vp, u64, ctypes.POINTER(b)])
        self._sig("SteamAPI_ISteamUtils_GetAPICallResult", b,
                  [vp, u64, vp, ctypes.c_int, ctypes.c_int, ctypes.POINTER(b)])
        self._sig("SteamAPI_ISteamUtils_GetAPICallFailureReason", ctypes.c_int, [vp, u64])

        err = ctypes.create_string_buffer(1024)
        r = self.api.SteamAPI_InitFlat(err)
        if r != 0:
            fail("连不上 Steam（%d）：%s。Steam 要开着、已经登录。" % (r, err.value.decode("utf-8", "replace")))
        self.ugc = self.api.SteamAPI_SteamUGC_v021()
        self.utils = self.api.SteamAPI_SteamUtils_v010()
        self.user = self.api.SteamAPI_SteamUser_v023()
        if not self.ugc or not self.utils or not self.user:
            self.shutdown()
            fail("拿不到 Steam 的接口（steam_api64.dll 换过版本？）")

    def _sig(self, name, restype, argtypes):
        try:
            f = getattr(self.api, name)
        except AttributeError:
            fail("steam_api64.dll 里没有 %s（游戏换了 Steamworks 版本？）" % name)
        f.restype = restype
        f.argtypes = argtypes

    def shutdown(self):
        self.api.SteamAPI_Shutdown()

    def steam_id(self):
        return self.api.SteamAPI_ISteamUser_GetSteamID(self.user)

    def details(self, item_id, language):
        """条目现在在某个语言下的标题、说明、作者等（不用本地缓存）。"""
        a, ugc = self.api, self.ugc
        label = "查询条目（%s）" % language
        ids = (ctypes.c_uint64 * 1)(item_id)
        q = a.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(ugc, ids, 1)
        if q == INVALID_QUERY:
            fail(label + "：Steam 没有接受这个请求")
        try:
            a.SteamAPI_ISteamUGC_SetLanguage(ugc, q, language.encode("utf-8"))
            a.SteamAPI_ISteamUGC_SetReturnLongDescription(ugc, q, True)
            a.SteamAPI_ISteamUGC_SetAllowCachedResponse(ugc, q, 0)
            res = QueryCompleted()
            self._call_result(a.SteamAPI_ISteamUGC_SendQueryUGCRequest(ugc, q), res, QUERY_COMPLETED, label,
                              timeout=60)
            if res.result != 1:
                fail("%s：%s（EResult %d）" % (label, RESULTS.get(res.result, "失败"), res.result))
            d = Details()
            if res.returned < 1 or not a.SteamAPI_ISteamUGC_GetQueryUGCResult(ugc, q, 0, ctypes.byref(d)):
                fail(label + "：没有返回结果")
            if d.result != 1:
                fail("%s：%s（EResult %d）" % (label, RESULTS.get(d.result, "失败"), d.result))
            return d
        finally:
            a.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(ugc, q)

    def submit(self, item_id, label, language, title, description,
               content=None, preview=None, tags=None, visibility=None, note=None):
        """提交一次更新；返回账号是不是还没接受创意工坊法律协议。"""
        a, ugc = self.api, self.ugc
        h = a.SteamAPI_ISteamUGC_StartItemUpdate(ugc, self.app_id, item_id)
        ok = a.SteamAPI_ISteamUGC_SetItemUpdateLanguage(ugc, h, language.encode("utf-8"))
        ok &= a.SteamAPI_ISteamUGC_SetItemTitle(ugc, h, title.encode("utf-8"))
        ok &= a.SteamAPI_ISteamUGC_SetItemDescription(ugc, h, description.encode("utf-8"))
        if content:
            ok &= a.SteamAPI_ISteamUGC_SetItemContent(ugc, h, content.encode("utf-8"))
        if preview:
            ok &= a.SteamAPI_ISteamUGC_SetItemPreview(ugc, h, preview.encode("utf-8"))
        if tags:
            arr = (ctypes.c_char_p * len(tags))(*[t.encode("utf-8") for t in tags])
            ok &= a.SteamAPI_ISteamUGC_SetItemTags(ugc, h, ctypes.byref(ParamStringArray(arr, len(tags))), False)
        if visibility is not None:
            ok &= a.SteamAPI_ISteamUGC_SetItemVisibility(ugc, h, visibility)
        if not ok:
            fail(label + "：Steam 不接受要改的内容")
        res = SubmitItemUpdateResult()
        call = a.SteamAPI_ISteamUGC_SubmitItemUpdate(ugc, h, note.encode("utf-8") if note else None)
        self._call_result(call, res, SUBMIT_ITEM_UPDATE_RESULT, label, progress=h)
        if res.result != 1:
            fail("%s：%s（EResult %d）" % (label, RESULTS.get(res.result, "失败"), res.result))
        print("  %s：完成" % label)
        return res.needs_agreement

    def _call_result(self, call, out, callback_id, label, progress=None, timeout=600.0):
        """等异步调用完成，把结果写进 out。progress 是更新句柄，给了就打印上传到了哪一步。"""
        a = self.api
        if call == 0:  # k_uAPICallInvalid
            fail(label + "：Steam 没有接受这个请求")
        failed = ctypes.c_bool(False)
        done, total = ctypes.c_uint64(0), ctypes.c_uint64(0)
        stage = -1
        start = time.time()
        while not a.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, ctypes.byref(failed)):
            if progress is not None:
                s = a.SteamAPI_ISteamUGC_GetItemUpdateProgress(self.ugc, progress, ctypes.byref(done),
                                                                ctypes.byref(total))
                if s != stage and s in STAGES:
                    stage = s
                    print("  %s：%s" % (label, STAGES[s]))
            if time.time() - start > timeout:
                fail("%s：等了 %d 秒还没完成" % (label, timeout))
            time.sleep(0.25)
        got = a.SteamAPI_ISteamUtils_GetAPICallResult(self.utils, call, ctypes.byref(out), ctypes.sizeof(out),
                                                       callback_id, ctypes.byref(failed))
        if not got or failed.value:
            fail("%s：拿不到结果（ESteamAPICallFailure %d）"
                 % (label, a.SteamAPI_ISteamUtils_GetAPICallFailureReason(self.utils, call)))


def steam_text(buf):
    return buf.decode("utf-8", "replace").replace("\r\n", "\n").strip()


def compare(steam, plan):
    """查条目现在各语言的标题和说明，打印和本地的差别；返回有改动的语言。"""
    me = steam.steam_id()
    remote = {l["code"]: steam.details(plan["item_id"], l["code"]) for l in plan["languages"]}
    en = remote["english"]
    if en.owner != me:
        fail("条目的作者（SteamID %d）不是现在登录的账号（%d）" % (en.owner, me))
    print("条目现在：可见性 %s，最后更新 %s" % (VISIBILITY_NAME.get(en.visibility, en.visibility),
                                            time.strftime("%Y-%m-%d %H:%M", time.localtime(en.time_updated))))
    changed = []
    for l in plan["languages"]:
        d = remote[l["code"]]
        old_title = steam_text(d.title)
        title_same = old_title == l["title"]
        desc_same = steam_text(d.description) == l["description"]
        print("%-9s 标题%s，说明%s" % (l["code"], "不变" if title_same else "「%s」→「%s」" % (old_title, l["title"]),
                                      "不变" if desc_same else "有改动"))
        if not (title_same and desc_same):
            changed.append(l["code"])
    return changed


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="把 Mod 传到创意工坊")
    ap.add_argument("--upload", action="store_true", help="上传（不加只列出要传的东西）")
    ap.add_argument("--check", action="store_true", help="连上 Steam 对比条目现在的标题和说明，不改任何东西")
    ap.add_argument("--note", default="", help="改动说明文件（BBCode）")
    ap.add_argument("--no-preview", action="store_true", help="不换预览图")
    ap.add_argument("--visibility", choices=sorted(VISIBILITY), default=None, help="顺便改可见性")
    ap.add_argument("--game", default="", help="游戏目录，找 steam_api64.dll")
    args = ap.parse_args()
    # 进度要逐行显示；输出到管道时控制台编码可能不认识说明里的个别字符
    sys.stdout.reconfigure(line_buffering=True, errors="replace")

    plan = load_plan(args)
    zip_path = package()
    show(plan, zip_path)

    if not args.upload and not args.check:
        print("\n只是列出来，没有连 Steam。--check 对比条目现在的内容，--upload 上传。")
        return

    game = args.game or gamedir.find_game_dir("--game")
    steam = Steam(game, plan["app_id"])
    try:
        print("\nSteam 已连上，登录的账号 SteamID %d" % steam.steam_id())
        changed = compare(steam, plan)
        if args.check:
            print("\n没有改任何东西。")
            return

        print()
        needs_agreement = False
        # 英文以外的语言：各提交一次标题和说明，不带改动说明
        for l in plan["languages"]:
            if l["code"] == "english":
                continue
            if l["code"] not in changed:
                print("  %s：标题和说明都没变，跳过" % l["code"])
                continue
            needs_agreement |= steam.submit(plan["item_id"], l["code"], l["code"], l["title"], l["description"])
        # 最后一次：文件、预览图、标签、可见性、英文的标题和说明，带上改动说明
        en = next(l for l in plan["languages"] if l["code"] == "english")
        visibility = VISIBILITY[plan["visibility"]] if plan["visibility"] else None
        needs_agreement |= steam.submit(plan["item_id"], "english + 文件", "english", en["title"], en["description"],
                                        content=CONTENT_DIR, preview=plan["preview"], tags=plan["tags"],
                                        visibility=visibility, note=plan["note"])
    finally:
        steam.shutdown()

    print("\n传好了：https://steamcommunity.com/sharedfiles/filedetails/?id=%d" % plan["item_id"])
    if needs_agreement:
        print("账号还没接受创意工坊法律协议，接受之前条目对别人不可见：" + AGREEMENT_URL)


if __name__ == "__main__":
    main()
