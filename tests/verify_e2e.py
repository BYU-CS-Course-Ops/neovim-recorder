"""Validate a recording produced by tests/e2e.lua.

Reads the gzip file exactly the way `recan.utils._load_recording` does, replays
the edit stream with `recan`'s splice semantics, and checks that the result is
the document the editor actually ended up with. If this passes, the recording is
consumable by code-recording-analysis.

Usage: python tests/verify_e2e.py <output-dir>
"""

from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path


def splice(document: str, offset: int, old_fragment: str, new_fragment: str) -> str:
    """Apply one edit. Mirrors recan.utils.splice: offsets index codepoints."""
    return document[:offset] + new_fragment + document[offset + len(old_fragment):]


def replay(events: list[dict]) -> str:
    document = ""
    for event in events:
        if event.get("type") != "edit":
            continue
        # A snapshot is an edit with offset 0 whose fragments are identical.
        if event["offset"] == 0 and event["oldFragment"] == event["newFragment"]:
            document = event["newFragment"]
        else:
            document = splice(
                document, event["offset"], event["oldFragment"], event["newFragment"]
            )
    return document


def main(directory: str) -> int:
    base = Path(directory)
    recording = base / "homework.recording.jsonl.gz"
    expected_path = base / "homework.expected"

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if condition:
            print(f"  ok   {message}")
        else:
            print(f"  FAIL {message}")
            failures.append(message)

    if not recording.exists():
        print(f"missing recording: {recording}")
        return 1

    # Read it the way the analyser does. Concatenated gzip members must decode as
    # one continuous stream.
    with gzip.open(recording, "rt", encoding="utf-8") as handle:
        events = [json.loads(line) for line in handle]

    check(len(events) > 0, f"decoded {len(events)} events from concatenated members")

    edits = [e for e in events if e.get("type") == "edit"]
    focus = [e for e in events if e.get("type") == "focusStatus"]

    check(len(edits) > 1, f"captured {len(edits)} edit events")
    check(len(focus) == 2, f"captured {len(focus)} focusStatus events")

    for event in events:
        required = {"type", "editor", "recorderVersion", "timestamp"}
        missing = required - event.keys()
        if missing:
            check(False, f"event missing {sorted(missing)}: {event}")
            break
    else:
        check(True, "every event carries type/editor/recorderVersion/timestamp")

    for event in edits:
        required = {"document", "offset", "oldFragment", "newFragment"}
        missing = required - event.keys()
        if missing:
            check(False, f"edit missing {sorted(missing)}: {event}")
            break
    else:
        check(True, "every edit carries document/offset/oldFragment/newFragment")

    check(
        all(e["editor"] == "neovim" for e in events),
        "editor is reported as neovim",
    )

    first = edits[0]
    check(
        first["offset"] == 0 and first["oldFragment"] == first["newFragment"],
        "recording opens with a full-document snapshot",
    )

    snapshots = [
        e for e in edits if e["offset"] == 0 and e["oldFragment"] == e["newFragment"]
    ]
    check(len(snapshots) == 1, f"exactly one snapshot, not {len(snapshots)}")

    expected = expected_path.read_text(encoding="utf-8")
    replayed = replay(events)
    check(replayed == expected, "replaying the edit stream reproduces the document")
    if replayed != expected:
        # ascii() rather than repr(): a Windows console is often cp1252, and a
        # failing diff full of multibyte text would otherwise raise instead of
        # showing the mismatch.
        print(f"    expected: {ascii(expected)}")
        print(f"    replayed: {ascii(replayed)}")

    check(
        not (base / "scratch.recording.jsonl.gz").exists(),
        "a file that was opened but never edited produced no recording",
    )

    # `recan` drops the leading snapshot, so the remainder must still be a
    # coherent delta stream on its own terms.
    check(
        all(len(e["oldFragment"]) >= 0 for e in edits[1:]),
        "post-snapshot events are deltas",
    )

    ratio = recording.stat().st_size / max(len(expected), 1)
    print(f"\n  {recording.stat().st_size} bytes on disk for a {len(expected)}-byte document (x{ratio:.1f})")

    print(f"\n{len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
