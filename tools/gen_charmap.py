"""
Generate (or verify) the Free Pascal include files for the native plug-in.

The canonical substitution table lives in the Python core ``app/unwrap.py`` and
the golden vector in ``tests/test_unwrap.py`` -- project invariants. This script
keeps the native port from drifting from them:

  * ``src/Charmap.inc``   -- the 256-byte CHARMAP as a Pascal array.
  * ``tests/Golden.inc``  -- a real Oracle-wrapped golden vector (base64 body +
                             expected source) mirrored from tests/test_unwrap.py.

Two modes, picked automatically:

  * **generate** -- run inside the full monorepo (the canonical Python sources
    are reachable above the plug-in dir). The includes are regenerated from
    ``app/unwrap.py`` and ``tests/test_unwrap.py``.
  * **verify** -- run from a standalone checkout of just the plug-in (the
    published plug-in repo, where the Python sources are absent). Nothing is
    regenerated; instead the committed includes are checked for presence and the
    CHARMAP is confirmed to be a valid 0..255 permutation, then the script exits
    successfully so the build can proceed with the already-generated includes.

Run from anywhere:

    python tools/gen_charmap.py

The build scripts call it first, so a fresh checkout always has usable includes.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

# Directory holding tools/ src/ tests/ -- stable both in the monorepo
# (".../plugin") and in a standalone plug-in checkout (the repo root).
PLUGIN_DIR = Path(__file__).resolve().parents[1]
SRC_DIR = PLUGIN_DIR / "src"
TESTS_DIR = PLUGIN_DIR / "tests"

CHARMAP_INC = SRC_DIR / "Charmap.inc"
GOLDEN_INC = TESTS_DIR / "Golden.inc"

_AUTOGEN = (
    "{ AUTO-GENERATED from app/unwrap.py by plugin/tools/gen_charmap.py. }\n"
    "{ DO NOT EDIT BY HAND -- re-run the generator instead.             }\n"
)

# A "$xx" byte literal as emitted into Charmap.inc.
_BYTE_RE = re.compile(r"\$([0-9a-fA-F]{2})")


def _find_project_root() -> Path | None:
    """Locate the monorepo root, or ``None`` for a standalone plug-in checkout.

    Walks upward from the plug-in directory looking for the canonical Python
    sources, so the script works whether it lives at ``<root>/plugin/tools``
    (monorepo) or ``<repo>/tools`` (standalone, plug-in flattened to the root).
    """
    for candidate in (PLUGIN_DIR, *PLUGIN_DIR.parents):
        if (candidate / "app" / "unwrap.py").is_file() and (
            candidate / "tests" / "test_unwrap.py"
        ).is_file():
            return candidate
    return None


def _import_charmap(project_root: Path) -> list[int]:
    """Import the canonical CHARMAP from the Python core."""
    sys.path.insert(0, str(project_root))
    from app.unwrap import CHARMAP  # noqa: E402

    return list(CHARMAP)


def _load_golden(project_root: Path) -> tuple[str, str]:
    """Pull the golden vector from tests/test_unwrap.py (single source of truth)."""
    spec = importlib.util.spec_from_file_location(
        "_golden_src", project_root / "tests" / "test_unwrap.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.GOLDEN_B64, module.GOLDEN_SOURCE


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


def _emit_charmap(charmap: list[int]) -> str:
    lines = [_AUTOGEN, "const", "  CHARMAP: array[0..255] of Byte = ("]
    for row_start in range(0, 256, 16):
        row = charmap[row_start:row_start + 16]
        cells = ", ".join(f"${b:02x}" for b in row)
        comma = "," if row_start + 16 < 256 else ""
        lines.append(f"    {cells}{comma}")
    lines.append("  );")
    return "\n".join(lines) + "\n"


def _emit_golden(golden_b64: str, golden_source: str) -> str:
    return (
        _AUTOGEN
        + "const\n"
        + f"  GOLDEN_B64 = {_pascal_string(golden_b64)};\n"
        + f"  GOLDEN_SOURCE = {_pascal_string(golden_source)};\n"
    )


def _parse_charmap_inc(path: Path) -> list[int]:
    """Extract the 256 byte values from a generated Charmap.inc."""
    return [int(h, 16) for h in _BYTE_RE.findall(path.read_text(encoding="ascii"))]


def _generate(project_root: Path) -> int:
    """Regenerate both includes from the canonical Python sources."""
    charmap = _import_charmap(project_root)
    # Sanity: the table must be a permutation of 0..255.
    assert sorted(charmap) == list(range(256)), "CHARMAP is not a permutation!"
    golden_b64, golden_source = _load_golden(project_root)

    SRC_DIR.mkdir(parents=True, exist_ok=True)
    TESTS_DIR.mkdir(parents=True, exist_ok=True)
    CHARMAP_INC.write_text(_emit_charmap(charmap), encoding="ascii", newline="\r\n")
    GOLDEN_INC.write_text(
        _emit_golden(golden_b64, golden_source), encoding="ascii", newline="\r\n"
    )

    print(f"wrote {CHARMAP_INC.relative_to(PLUGIN_DIR)}")
    print(f"wrote {GOLDEN_INC.relative_to(PLUGIN_DIR)}")
    return 0


def _verify_standalone() -> int:
    """No canonical sources: confirm the committed includes are present and sane."""
    missing = [p for p in (CHARMAP_INC, GOLDEN_INC) if not p.is_file()]
    if missing:
        names = ", ".join(str(p.relative_to(PLUGIN_DIR)) for p in missing)
        print(
            "error: app/unwrap.py not found (standalone checkout) and the "
            f"committed includes are missing: {names}. Build inside the full "
            "monorepo to regenerate them.",
            file=sys.stderr,
        )
        return 1

    charmap = _parse_charmap_inc(CHARMAP_INC)
    if sorted(charmap) != list(range(256)):
        print(
            f"error: {CHARMAP_INC.relative_to(PLUGIN_DIR)} is not a valid "
            "256-byte permutation and cannot be regenerated without "
            "app/unwrap.py.",
            file=sys.stderr,
        )
        return 1

    print(
        "app/unwrap.py not found -- standalone checkout; using committed "
        "includes (CHARMAP verified as a 256-byte permutation)."
    )
    return 0


def main() -> int:
    project_root = _find_project_root()
    if project_root is None:
        return _verify_standalone()
    return _generate(project_root)


if __name__ == "__main__":
    raise SystemExit(main())
