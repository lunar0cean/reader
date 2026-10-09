from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import struct
import zlib

out = Path(__file__).resolve().parents[1] / 'Resources' / 'Fixtures' / 'sample-slides.pptx'
root = 'http://schemas.openxmlformats.org'
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

image = (b'\x89PNG\r\n\x1a\n'
         + chunk(b'IHDR', struct.pack('>IIBBBBB', 128, 64, 8, 6, 0, 0, 0))
         + chunk(b'IDAT', zlib.compress((b'\0' + bytes([24, 117, 201, 255]) * 128) * 64))
         + chunk(b'IEND', b''))
with ZipFile(out, 'w', ZIP_DEFLATED) as z:
    z.writestr('ppt/presentation.xml', f'<p:presentation xmlns:p="{root}/presentationml/2006/main" xmlns:r="{root}/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>')
    z.writestr('ppt/_rels/presentation.xml.rels', f'<Relationships xmlns="{root}/package/2006/relationships"><Relationship Id="rId1" Target="slides/slide1.xml" Type="{root}/officeDocument/2006/relationships/slide"/></Relationships>')
    z.writestr('ppt/slides/slide1.xml', f'''<p:sld xmlns:p="{root}/presentationml/2006/main" xmlns:a="{root}/drawingml/2006/main" xmlns:r="{root}/officeDocument/2006/relationships"><p:cSld><p:spTree>
    <p:sp><p:spPr><a:xfrm><a:off x="254000" y="508000"/><a:ext cx="8128000" cy="1016000"/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:rPr sz="2400"/><a:t>Slide text can be copied</a:t></a:r></a:p></p:txBody></p:sp>
    <p:pic><p:blipFill><a:blip r:embed="rId2"/></p:blipFill><p:spPr><a:xfrm><a:off x="1016000" y="2032000"/><a:ext cx="5080000" cy="2540000"/></a:xfrm></p:spPr></p:pic>
    </p:spTree></p:cSld></p:sld>''')
    z.writestr('ppt/slides/_rels/slide1.xml.rels', f'<Relationships xmlns="{root}/package/2006/relationships"><Relationship Id="rId2" Target="../media/image1.png" Type="{root}/officeDocument/2006/relationships/image"/></Relationships>')
    z.writestr('ppt/media/image1.png', image)
print(out)
