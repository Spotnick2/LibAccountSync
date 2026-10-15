r"""Print the LibAccountSync probe's log from every account's SavedVariables.

The probe (/fp las ..., a ForeverProbe module) appends to
LibAccountSyncProbeDB.log, which the client writes to
WTF\Account\<account>\SavedVariables\LibAccountSyncProbe.lua on /reload and on
logout - not before. So /reload each character after a round.

A probe line is ForeverProbe's stamp (GetTime uptime, run number), then the
wall clock and the character: "123.4 #5 23:10:01 Malas-Realm send ...". The
host's own lines in the module's log (a procedure's STEP lines, SCREENSHOT)
have the stamp only; their wall clock is worked out from the uptime, using a
line of the same run that has both. Logs from before the ForeverProbe
migration start with the wall clock.

    python Tools/read-wirelog.py                # everything
    python Tools/read-wirelog.py --since 23:10  # from a time on
    python Tools/read-wirelog.py --wtf "D:\...\WTF"

--since keeps a line whose time can't be worked out, rather than drop a
procedure's outcome unseen.

Modelled on AltStable's Tools/AltStableProbe/read-wirelog.py.
"""
import argparse
import glob
import os
import re

DEFAULT_WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF"

# ForeverProbe's stamp: uptime (one decimal), " C" in combat, the run number.
STAMP = re.compile(r"^(\d+(?:\.\d+)?)(?: C)? #(\d+) ")
# The wall clock where the probe writes it: just after the stamp, or at the
# start of a line from before the migration. Never searched for elsewhere: a
# STEP line's detail can hold a time of its own.
CLOCK = re.compile(r"^(?:\d+(?:\.\d+)?(?: C)? #\d+ )?(\d\d):(\d\d):(\d\d) ")


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


def clocks(lines):
    """Each line's wall clock as HH:MM:SS, or None when nothing gives one.

    A line without its own clock gets one from its uptime, offset by the
    first line of the same run that carries both (uptime and clock are read
    within the same frame there)."""
    parsed, offsets = [], {}
    for line in lines:
        s, c = STAMP.match(line), CLOCK.match(line)
        up, run = (float(s.group(1)), s.group(2)) if s else (None, None)
        secs = int(c.group(1)) * 3600 + int(c.group(2)) * 60 + int(c.group(3)) if c else None
        if secs is not None and up is not None and run not in offsets:
            offsets[run] = secs - up
        parsed.append((secs, up, run))
    out = []
    for secs, up, run in parsed:
        if secs is None and up is not None and run in offsets:
            secs = int(round(up + offsets[run])) % 86400
        out.append(None if secs is None else "%02d:%02d:%02d" % (secs // 3600, secs // 60 % 60, secs % 60))
    return out


def since_filter(lines, since):
    if not since:
        return lines
    return [l for l, c in zip(lines, clocks(lines)) if c is None or c[:len(since)] >= since]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--wtf", default=DEFAULT_WTF)
    ap.add_argument("--since", help="HH:MM[:SS]; only lines from then on")
    a = ap.parse_args(argv)
    pattern = os.path.join(a.wtf, "Account", "*", "SavedVariables", "LibAccountSyncProbe.lua")
    files = sorted(glob.glob(pattern))
    if not files:
        print("no LibAccountSyncProbe.lua under " + a.wtf + " (did you /reload after the round?)")
        return
    for path in files:
        account = path.split(os.sep)[-3]
        lines = since_filter(log_lines(path), a.since)
        print("== account %s: %d lines ==" % (account, len(lines)))
        for l in lines:
            print("  " + l)


if __name__ == "__main__":
    main()
