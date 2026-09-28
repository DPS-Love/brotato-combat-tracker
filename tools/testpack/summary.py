"""把测试驱动写的 results.json 汇总成几行：各项检查、每个来源的数字、承伤与治疗。"""
import json
import os
import sys

path = os.path.join(os.environ.get("APPDATA", ""), "BrotatoBCTTest", "bct_test", "results.json")
if len(sys.argv) > 1:
    path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = json.load(f)

for name, check in d.get("checks", {}).items():
    print("%-18s %s  %s" % (name, "OK  " if check["ok"] else "FAIL", str(check["detail"])[:160]))
for note in d.get("notes", []):
    print("note:", note)
print("locale:", d.get("locale"), " mods:", d.get("mods"))
totals = d.get("last_wave_totals")
if totals:
    print("totals (eff / incl. overkill): damage %s  taken %s  healing %s  duration %.2f" % (
        totals["0"], totals["1"], totals["2"], d.get("last_wave_duration", 0)))
for src, v in sorted(d.get("last_wave_sources", {}).items(), key=lambda x: -x[1][0]):
    print("  OUT   %-32s eff %-8s total %-8s hits %-5s crits %-4s dims %s" % (src, v[0], v[1], v[2], v[3], v[4]))
for src, v in sorted(d.get("last_wave_taken", {}).items(), key=lambda x: -x[1][0]):
    print("  TAKEN %-32s eff %-8s hits %-5s dodges %s" % (src, v[0], v[1], v[2]))
for src, v in sorted(d.get("last_wave_heal", {}).items(), key=lambda x: -x[1]):
    print("  HEAL  %-32s %s" % (src, v))
if "snapshot_bytes" in d:
    print("snapshot bytes:", d["snapshot_bytes"])
for k, v in sorted(d.get("perf", {}).items()):
    print("perf %-26s %s" % (k, round(v, 2) if isinstance(v, float) else v))
