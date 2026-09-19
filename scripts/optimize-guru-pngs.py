"""Lossless PNG encoding optimization; never changes portraits or dimensions.

Run in an isolated tooling venv with zopfli==0.4.3 and Pillow==12.3.0.
Default is check-only. --apply requires a new private backup directory.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct

from PIL import Image
import zopfli.png


def chunks(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset = 8
    while offset < len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        yield data[offset + 4:offset + 8].decode("ascii"), data[offset + 8:offset + 8 + size]
        offset += size + 12
    assert offset == len(data)


def pixels(data):
    with Image.open(io.BytesIO(data)) as image:
        assert image.size == (144, 144)
        return image.convert("RGBA").tobytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup-dir", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent / "web" / "guru-avatars"
    if args.apply:
        if not args.backup_dir or args.backup_dir.exists():
            parser.error("--apply requires a new --backup-dir")
        args.backup_dir.mkdir(mode=0o700, parents=True)
    rows = []
    for file in sorted(root.glob("*.png")):
        original = file.read_bytes()
        # Preserve every ancillary chunk (including original color profiles).
        metadata = [(k, v) for k, v in chunks(original) if k not in {"IHDR", "PLTE", "IDAT", "IEND", "tRNS"}]
        optimized = zopfli.png.optimize(original, lossy_transparent=False, lossy_8bit=False,
                                        keepchunks=list(dict.fromkeys(k for k, _ in metadata)),
                                        num_iterations=15, num_iterations_large=5)
        assert pixels(original) == pixels(optimized), f"Pixel change: {file.name}"
        assert metadata == [(k, v) for k, v in chunks(optimized) if k not in {"IHDR", "PLTE", "IDAT", "IEND", "tRNS"}], f"Metadata change: {file.name}"
        changed = len(optimized) < len(original)
        if args.apply and changed:
            assert file.read_bytes() == original, f"Concurrent edit: {file.name}"
            shutil.copy2(file, args.backup_dir / file.name)
            temporary = args.backup_dir / (file.name + ".optimized")
            temporary.write_bytes(optimized)
            os.chmod(temporary, file.stat().st_mode & 0o777)
            # Backup may be on a different volume; leave original intact until
            # the fully validated candidate is copied to a sibling temp file.
            sibling = file.with_suffix(".png.optimizing")
            with sibling.open("xb") as output:
                output.write(optimized)
            os.chmod(sibling, file.stat().st_mode & 0o777)
            os.replace(sibling, file)
        rows.append({"file": file.name, "beforeBytes": len(original), "afterBytes": min(len(original), len(optimized)),
                     "pixelsSha256": hashlib.sha256(pixels(original)).hexdigest(), "changed": changed})
        print(f"{file.name}: {len(original)} -> {min(len(original), len(optimized))}", flush=True)
    report = {"mode": "apply" if args.apply else "check", "lossless": True,
              "beforeBytes": sum(r["beforeBytes"] for r in rows), "afterBytes": sum(r["afterBytes"] for r in rows), "files": rows}
    if args.apply:
        (args.backup_dir / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
