"""
Generate the Free Pascal include files from the canonical Python core.

This keeps ``app/unwrap.py`` the single source of truth for the substitution
table (a project invariant) and prevents the native port from drifting:

  * ``plugin/src/Charmap.inc``   -- the 256-byte CHARMAP as a Pascal array.
  * ``plugin/tests/Golden.inc``  -- a real Oracle-wrapped golden vector
                                    (base64 body + expected source) mirrored
                                    from ``tests/test_unwrap.py``.

Run from anywhere:

    python plugin/tools/gen_charmap.py

Re-run it whenever the table or the golden vector changes; the build scripts
call it first so a fresh checkout always has up-to-date includes.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from app.unwrap import CHARMAP  # noqa: E402


def _load_golden() -> tuple[str, str]:
    """Pull the golden vector from tests/test_unwrap.py (single source of truth)."""
    spec = importlib.util.spec_from_file_location(
        "_golden_src", ROOT / "tests" / "test_unwrap.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.GOLDEN_B64, module.GOLDEN_SOURCE


GOLDEN_B64, GOLDEN_SOURCE = _load_golden()

SRC_DIR = ROOT / "plugin" / "src"
TESTS_DIR = ROOT / "plugin" / "tests"

_AUTOGEN = (
    "{ AUTO-GENERATED from app/unwrap.py by plugin/tools/gen_charmap.py. }\n"
    "{ DO NOT EDIT BY HAND -- re-run the generator instead.             }\n"
)


def _pascal_string(text: str) -> str:
    """Render a Python str as a Pascal string literal (control chars as #n)."""
    parts: list[str] = []
    buf = ""
    for ch in text:
        code = ord(ch)
        if ch == "'":
            buf += "''"
        elif 32 <= code < 127:
            buf += ch
        else:
            if buf:
                parts.append("'" + buf + "'")
                buf = ""
            parts.append("#" + str(code))
    if buf:
        parts.append("'" + buf + "'")
    return "+".join(parts) if parts else "''"


def _emit_charmap() -> str:
    lines = [_AUTOGEN, "const", "  CHARMAP: array[0..255] of Byte = ("]
    for row_start in range(0, 256, 16):
        row = CHARMAP[row_start:row_start + 16]
        cells = ", ".join(f"${b:02x}" for b in row)
        comma = "," if row_start + 16 < 256 else ""
        lines.append(f"    {cells}{comma}")
    lines.append("  );")
    return "\n".join(lines) + "\n"


def _emit_golden() -> str:
    return (
        _AUTOGEN
        + "const\n"
        + f"  GOLDEN_B64 = {_pascal_string(GOLDEN_B64)};\n"
        + f"  GOLDEN_SOURCE = {_pascal_string(GOLDEN_SOURCE)};\n"
    )


def main() -> int:
    SRC_DIR.mkdir(parents=True, exist_ok=True)
    TESTS_DIR.mkdir(parents=True, exist_ok=True)

    charmap_inc = SRC_DIR / "Charmap.inc"
    golden_inc = TESTS_DIR / "Golden.inc"

    charmap_inc.write_text(_emit_charmap(), encoding="ascii", newline="\r\n")
    golden_inc.write_text(_emit_golden(), encoding="ascii", newline="\r\n")

    # Sanity: the table must be a permutation of 0..255.
    assert sorted(CHARMAP) == list(range(256)), "CHARMAP is not a permutation!"

    print(f"wrote {charmap_inc.relative_to(ROOT)}")
    print(f"wrote {golden_inc.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
