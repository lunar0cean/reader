"""Bundle original demo texts for the native app and offline UI preview.

No network, GitHub token, email credential, or LLM call is needed.
The reader intentionally does not import the old daily-English system.
"""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]


def main():
    library = json.loads((ROOT / "Resources/demo-library.json").read_text(encoding="utf-8"))
    payload = json.dumps(library, ensure_ascii=False, indent=2)
    (ROOT / "Resources/library.json").write_text(payload + "\n", encoding="utf-8")
    (ROOT / "Preview/library.js").write_text("window.YEJIAN_LIBRARY = " + payload + ";\n", encoding="utf-8")
    print(f"Bundled {len(library)} original demo documents")


if __name__ == "__main__":
    main()
