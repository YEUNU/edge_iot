"""Docker health: loop alive, cloud reads recent, no pending failed warnings."""
import json
from pathlib import Path
import sys
import time


def healthy(status, now):
    return (0 <= now - status.get("lastPollAt", 0) < 120
            and 0 <= now - status.get("lastCloudReadAt", 0) < 120
            and status.get("pendingRetries", 0) == 0)


if __name__ == "__main__":
    try:
        ok = healthy(json.loads(Path(sys.argv[1]).read_text()), time.time())
    except (OSError, ValueError, TypeError):
        ok = False
    sys.exit(0 if ok else 1)
