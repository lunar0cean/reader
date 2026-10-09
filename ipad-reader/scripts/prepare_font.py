"""Prepare the licensed Noto Serif SC source as a static, local reading font.

Input is Resources/Fonts/NotoSerifSC.ttf from google/fonts (OFL-1.1).
The generated TTF and WOFF2 share the same glyphs and metrics.
"""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

root = Path(__file__).resolve().parents[1]
font = instantiateVariableFont(TTFont(root / "Resources/Fonts/NotoSerifSC.ttf"), {"wght": 400}, inplace=True)
names = {1: "Yejian Serif", 2: "Regular", 4: "Yejian Serif Regular", 6: "YejianSerif-Regular", 16: "Yejian Serif", 17: "Regular"}
for record in font["name"].names:
    if record.nameID in names:
        record.string = names[record.nameID].encode(record.getEncoding())
font.save(root / "Resources/Fonts/YejianSerif-Regular.ttf")
assets = root / "Preview/assets"
assets.mkdir(exist_ok=True)
font.flavor = "woff2"
font.save(assets / "YejianSerif-Regular.woff2")
(assets / "OFL.txt").write_bytes((root / "Resources/Fonts/OFL.txt").read_bytes())
print("Prepared local TTF and WOFF2 reading fonts (weight 400).")
