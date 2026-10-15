"""test_wirelog.py: Tools/read-wirelog.py's --since keeps a procedure's
outcomes. ForeverProbe writes its STEP lines into the probe's log with the
uptime stamp only, so their wall clock comes from a line of the same run that
has both (Codex on #24). tests/mutate.lua points LIBACCT_WIRELOG_MUTANT at a
mutated copy.

    python -I tests/test_wirelog.py      (from the repo root)
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile

path = os.environ.get("LIBACCT_WIRELOG_MUTANT") or "Tools/read-wirelog.py"
spec = importlib.util.spec_from_loader("wirelog", loader=None)
W = importlib.util.module_from_spec(spec)
exec(compile(open(path, encoding="utf-8").read(), path, "exec"), W.__dict__)

passed, failed = 0, 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("  FAIL: " + msg)


LOG = [
    "100.0 #3 23:09:50 Malas-Classic Beta PvE loaded (2 loads)",   # run 3: the clock is 23:09:50 at uptime 100
    "105.0 #3 STEP check 3/13 DONE",                                # 23:09:55
    "110.0 #3 STEP check 3/13 CHECK PASS: 1, nil",                  # 23:10:00
    "120.0 #3 STEP check started 2026-10-15 01:00:00",              # 23:10:10, not 01:00:00
    "130.0 C #3 STEP check 4/13 CHECK FAIL: 0 sent",                # in combat: 23:10:20
    "5.0 #4 STEP check resumed at 5/13",                            # run 4, before its first clock line: 23:11:59
    "6.0 #4 23:12:00 Malas-Classic Beta PvE loaded (3 loads)",      # run 4's clock comes later
    "4.0 #4 STEP check 4/13 DONE",                                  # before it in time: 23:11:58
    "23:05:00 Malas-Classic Beta PvE an old line",                  # before the migration
    "23:11:00 Malas-Classic Beta PvE a later old line",
]

c = W.clocks(LOG)
check(c[0] == "23:09:50", "a probe line's own clock: " + str(c[0]))
check(c[1] == "23:09:55", "a STEP line's clock from its run's offset: " + str(c[1]))
check(c[2] == "23:10:00", "  and the next: " + str(c[2]))
check(c[3] == "23:10:10", "a time inside a STEP line's detail is not its clock: " + str(c[3]))
check(c[4] == "23:10:20", "a combat stamp is read: " + str(c[4]))
check(c[5] == "23:11:59", "an earlier line of a run gets the run's offset too: " + str(c[5]))
check(c[7] == "23:11:58", "  " + str(c[7]))
check(c[8] == "23:05:00" and c[9] == "23:11:00", "lines from before the migration keep their clock")
check(W.clocks(["7.0 #9 STEP a run with no clock line"]) == [None], "no clock in the run: unknown")

kept = W.since_filter(LOG, "23:10")
check(LOG[2] in kept and LOG[3] in kept and LOG[4] in kept, "--since keeps the STEP outcomes after it")
check(LOG[1] not in kept and LOG[0] not in kept, "--since drops the lines before it")
check(LOG[8] not in kept and LOG[9] in kept, "--since filters old lines by their clock")
check(W.since_filter(["7.0 #9 STEP x"], "23:10") == ["7.0 #9 STEP x"], "--since keeps a line of unknown time")
check(W.since_filter(LOG, None) == LOG, "no --since: everything")

# End to end: a SavedVariables file as the client writes it.
with tempfile.TemporaryDirectory() as wtf:
    sv = os.path.join(wtf, "Account", "ACC1", "SavedVariables")
    os.makedirs(sv)
    with open(os.path.join(sv, "LibAccountSyncProbe.lua"), "w", encoding="utf-8") as f:
        f.write("\nLibAccountSyncProbeDB = {\n[\"log\"] = {\n")
        for i, line in enumerate(LOG[:5]):
            f.write('"%s", -- [%d]\n' % (line.replace("\\", "\\\\").replace('"', '\\"'), i + 1))
        f.write("},\n[\"loads\"] = 2,\n}\n")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        W.main(["--wtf", wtf, "--since", "23:10"])
    text = out.getvalue()
    check("== account ACC1: 3 lines ==" in text, "main prints the account and the kept count: " + text.splitlines()[0])
    check("CHECK PASS: 1, nil" in text and "CHECK FAIL: 0 sent" in text, "  with the procedure's outcomes")

print("test_wirelog: %d passed, %d failed" % (passed, failed))
sys.exit(0 if failed == 0 else 1)
