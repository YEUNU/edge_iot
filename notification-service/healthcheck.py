"""Docker health: loop alive, cloud reads recent, no pending failed warnings."""
import json
import math
from pathlib import Path
import sys
import time


MAX_AGE = 120


def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def recent(stamp, now):
    return number(stamp) and 0 <= now - stamp < MAX_AGE


def healthy(status, now):
    if (not isinstance(status, dict) or not number(now)
            or not recent(status.get("lastPollAt"), now)
            or type(status.get("pendingRetries", 0)) is not int
            or status.get("pendingRetries", 0) != 0 or status.get("stateSaved", True) is not True):
        return False
    if "deviceCloudReads" not in status:
        return recent(status.get("lastCloudReadAt"), now)
    reads = status["deviceCloudReads"]
    started = status.get("startedAt")
    if not isinstance(reads, dict) or not reads or not number(started) or now < started:
        return False
    return all(recent(stamp, now) if stamp is not None else now - started < MAX_AGE
               for stamp in reads.values())


if __name__ == "__main__":
    try:
        ok = healthy(json.loads(Path(sys.argv[1]).read_text()), time.time())
    except (OSError, ValueError, TypeError):
        ok = False
    sys.exit(0 if ok else 1)
