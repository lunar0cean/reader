"""Prepare the generated icon and pinned, licensed math font resources."""
from pathlib import Path
from PIL import Image
import json, argparse

root=Path(__file__).resolve().parents[1]/'Resources'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='Opaque square icon artwork')
parser.add_argument('--download-fonts', action='store_true', help='Fetch pinned licensed math resources')
args=parser.parse_args(); source=args.source
icons=root/'Assets.xcassets'/'AppIcon.appiconset'; icons.mkdir(parents=True,exist_ok=True)
image=Image.open(source).convert('RGB')
slots=[]
for points,scale,idiom in [(20,1,'ipad'),(20,2,'ipad'),(29,1,'ipad'),(29,2,'ipad'),(40,1,'ipad'),(40,2,'ipad'),(76,1,'ipad'),(76,2,'ipad'),(83.5,2,'ipad'),(1024,1,'ios-marketing')]:
    pixels=int(points*scale); name=f'book-{pixels}.png'
    image.resize((pixels,pixels),Image.LANCZOS).save(icons/name)
    slots.append({'size':f'{points:g}x{points:g}','idiom':idiom,'scale':f'{scale}x','filename':name})
(icons/'Contents.json').write_text(json.dumps({'images':slots,'info':{'version':1,'author':'xcode'}},indent=2)+'\n',encoding='utf-8')
(root/'Assets.xcassets'/'Contents.json').write_text('{"info":{"version":1,"author":"xcode"}}\n',encoding='utf-8')
fonts=root/'Fonts'; fonts.mkdir(exist_ok=True)
for name,url in [
    ('STIXTwoMath-Regular.otf','https://raw.githubusercontent.com/stipub/stixfonts/v2.13/fonts/static_otf/STIXTwoMath-Regular.otf'),
    ('STIX-OFL.txt','https://raw.githubusercontent.com/stipub/stixfonts/v2.13/OFL.txt'),
    ('Adobe-Symbol-Mapping.txt','https://unicode.org/Public/MAPPINGS/VENDORS/ADOBE/symbol.txt')]:
    if args.download_fonts:
        import requests
        response=requests.get(url,timeout=60); response.raise_for_status(); (fonts/name).write_bytes(response.content)
print('Icon slots and math font prepared.')
