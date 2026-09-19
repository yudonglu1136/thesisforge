#!/usr/bin/env python3
"""Create a consistent private runtime backup without changing the live database."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3


def verify_compressed_copy(backup, compressed):
    original_digest, decoded_digest = hashlib.sha256(), hashlib.sha256()
    original_bytes = decoded_bytes = 0
    with Path(backup).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            original_digest.update(chunk)
            original_bytes += len(chunk)
    # Reading to EOF also validates the gzip trailer/CRC, including a resumed
    # backup whose compression was interrupted before manifest generation.
    with gzip.open(compressed, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            decoded_digest.update(chunk)
            decoded_bytes += len(chunk)
    if decoded_bytes != original_bytes or decoded_digest.digest() != original_digest.digest():
        raise ValueError("Compressed backup does not reproduce the integrity-checked SQLite copy")
    return {"uncompressedSha256": original_digest.hexdigest(), "uncompressedBytes": original_bytes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--finalize-existing", action="store_true", help="Revalidate an existing private backup and finish its interrupted manifest")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output_dir.resolve()
    if (output.exists() and not args.finalize_existing) or output == source.parent or output == Path("/"):
        raise ValueError("A new, dedicated output directory is required")
    os.umask(0o077)
    if not args.finalize_existing:
        output.mkdir(mode=0o700)
    backup = output / "runtime.sqlite"
    if not args.finalize_existing:
        with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as src:
            with sqlite3.connect(backup) as dst:
                src.backup(dst, pages=2048, sleep=0.05)
    elif not backup.is_file() or (output / "manifest.json").exists():
        raise ValueError("Finalize requires an existing backup without a completed manifest")
    with sqlite3.connect(backup.as_uri() + "?mode=ro", uri=True) as dst:
        if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Backup integrity check failed")
        names = [row[0] for row in dst.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        counts = {name: dst.execute('SELECT count(*) FROM "' + name.replace('"', '""') + '"').fetchone()[0] for name in names}
    compressed = output / "runtime.sqlite.gz"
    if not compressed.exists():
        with backup.open("rb") as src, compressed.open("xb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
    elif not args.finalize_existing:
        raise FileExistsError("Refusing to overwrite compressed backup")
    decoded_verification = verify_compressed_copy(backup, compressed)
    hasher = hashlib.sha256()
    with compressed.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    result = {"integrity": "ok", "source": str(source), "backup": str(backup),
              "compressed": str(compressed), "sha256": digest, "bytes": compressed.stat().st_size,
              "tableCounts": counts, "compressedCopyVerified": True, **decoded_verification}
    (output / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
