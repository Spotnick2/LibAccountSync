r"""Print the LibAccountSync probe's log from every account's SavedVariables.

The probe (/lasprobe ...) appends to LibAccountSyncProbeDB.log, which the
client writes to WTF\Account\<account>\SavedVariables\LibAccountSyncProbe.lua
on /reload and on logout - not before. So /reload each character after a round.

    python Tools/read-wirelog.py                # everything
    python Tools/read-wirelog.py --since 23:10  # from a time on
    python Tools/read-wirelog.py --wtf "D:\...\WTF"

Modelled on AltStable's Tools/AltStableProbe/read-wirelog.py.
"""
import argparse
import glob
import os
import re

DEFAULT_WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF"


def log_lines(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    start = text.find('["log"] = {')
    if start < 0:
        return []
    # The table ends at the first line that is not one of its string entries.
    out = []
    for raw in text[start:].splitlines()[1:]:
        m = re.match(r'^\s*"(.*)",\s*(?:--.*)?$', raw)
        if not m:
            break
        line = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
        out.append(re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wtf", default=DEFAULT_WTF)
    ap.add_argument("--since", help="HH:MM[:SS]; only lines from then on")
    a = ap.parse_args()
    pattern = os.path.join(a.wtf, "Account", "*", "SavedVariables", "LibAccountSyncProbe.lua")
    files = sorted(glob.glob(pattern))
    if not files:
        print("no LibAccountSyncProbe.lua under " + a.wtf + " (did you /reload after the round?)")
        return
    for path in files:
        account = path.split(os.sep)[-3]
        lines = [l for l in log_lines(path) if not a.since or l[:len(a.since)] >= a.since]
        print("== account %s: %d lines ==" % (account, len(lines)))
        for l in lines:
            print("  " + l)


if __name__ == "__main__":
    main()
