"""Run local pgTAP tests with includes supported by Supabase CLI 2.117."""

from pathlib import Path
import re
import subprocess
import tempfile


TESTS = Path(__file__).resolve().parent
REPO = TESTS.parent.parent


def expand_includes(path: Path) -> str:
    path = path.resolve()
    if not path.is_relative_to(TESTS):
        raise ValueError(f"Test include outside tests directory: {path.name}")
    return re.sub(
        r"^\\ir\s+([^\n]+)$",
        lambda match: expand_includes(path.parent / match[1].strip()),
        path.read_text(),
        flags=re.MULTILINE,
    )


if __name__ == "__main__":
    sources = sorted((TESTS / "database").glob("*.test.sql"))
    if not sources:
        raise SystemExit("No database tests found")
    with tempfile.TemporaryDirectory(prefix="vango-pgtap-") as directory:
        expanded = []
        for source in sources:
            target = Path(directory) / source.name
            target.write_text(expand_includes(source))
            expanded.append(str(target))
        subprocess.run(["supabase", "test", "db", "--local", *expanded], cwd=REPO, check=True)
