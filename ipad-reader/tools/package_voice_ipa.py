"""Locally add owned speech assets to an unsigned reader IPA before sideload signing."""
import argparse
import shutil
import sys
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("assets", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.ipa.resolve() == args.output.resolve():
        parser.error("Output must be a new file")
    with ZipFile(args.ipa) as archive:
        app = next((n[:-len("/Info.plist")] for n in archive.namelist()
                    if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")), None)
        if not app:
            parser.error("IPA does not contain an app")
        if any(n.startswith(app + "/VoiceModels/") for n in archive.namelist()):
            parser.error("IPA already includes VoiceModels")
    files = sorted(p for folder in ("models", "voices", "voice", "bert")
                   for p in (args.assets / folder).rglob("*")
                   if p.is_file() and p.suffix.lower() in (".onnx", ".bin", ".gsvpack"))
    if not files:
        parser.error("No speech assets found")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.ipa, args.output)
    with ZipFile(args.output, "a", compression=ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
        for path in files:
            relative = path.relative_to(args.assets).as_posix()
            archive.write(path, app + "/VoiceModels/" + relative)
            print(relative, flush=True)
    print(f"Created: {args.output} ({args.output.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
