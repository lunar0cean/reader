"""Reduce the reported PPTX to two regression pages; keep no notes or OLE binaries."""
from pathlib import Path
import zipfile, xml.etree.ElementTree as E, posixpath, argparse

root=Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
source=zipfile.ZipFile(args.source)
E.register_namespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
E.register_namespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
E.register_namespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
rels_ns='http://schemas.openxmlformats.org/package/2006/relationships'
target=root/'Resources'/'Fixtures'/'sample-legacy-math.pptx'
parts={}; pending=['ppt/slides/slide3.xml','ppt/slides/slide5.xml']
while pending:
    path=pending.pop()
    if path in parts: continue
    parts[path]=source.read(path)
    parent,filename=posixpath.split(path); rel=parent+'/_rels/'+filename+'.rels'
    if rel not in source.namelist(): continue
    r=E.fromstring(source.read(rel)); kept=[]
    for link in list(r):
        kind=link.attrib.get('Type','').rsplit('/',1)[-1]
        if kind not in ['slideLayout','slideMaster','theme','image'] or link.attrib.get('TargetMode')=='External': r.remove(link); continue
        dest=posixpath.normpath(posixpath.join(parent,link.attrib['Target']))
        if dest in source.namelist(): pending.append(dest)
    parts[rel]=E.tostring(r,encoding='utf-8',xml_declaration=True)
p=E.fromstring(source.read('ppt/presentation.xml'))
lst=p.find('{*}sldIdLst')
for node in list(lst): lst.remove(node)
for i,num in enumerate([3,5]): E.SubElement(lst,'{http://schemas.openxmlformats.org/presentationml/2006/main}sldId',{'id':str(256+i),'{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id':f'rId{i+1}'})
parts['ppt/presentation.xml']=E.tostring(p,encoding='utf-8',xml_declaration=True)
r=E.Element('{'+rels_ns+'}Relationships')
for i,num in enumerate([3,5]): E.SubElement(r,'{'+rels_ns+'}Relationship',{'Id':f'rId{i+1}','Type':'http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide','Target':f'slides/slide{num}.xml'})
parts['ppt/_rels/presentation.xml.rels']=E.tostring(r,encoding='utf-8',xml_declaration=True)
parts['[Content_Types].xml']=source.read('[Content_Types].xml')
with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as z:
    for name,data in parts.items(): z.writestr(name,data)
# Expose one tiny equation for malformed-record and pixel-output tests.
wmf=next(data for name,data in parts.items() if name.endswith('.wmf'))
(root/'Resources'/'Fixtures'/'sample-equation.wmf').write_bytes(wmf)
print('Regression fixture:',target.stat().st_size,'bytes,',len(parts),'parts.')
