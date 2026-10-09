/* Local format engines. Original files are retained alongside the reading snapshot. */
import {unzipSync} from './vendor/fflate.mjs';
const id=()=>crypto.randomUUID();
export function base64(bytes){let text='';for(let i=0;i<bytes.length;i+=16384)text+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(text);}
export const unbase64=text=>Uint8Array.from(atob(text),c=>c.charCodeAt(0));
const decode=bytes=>{try{return new TextDecoder('utf-8',{fatal:true}).decode(bytes);}catch{return new TextDecoder('gb18030').decode(bytes);}};
const titleOf=name=>name.replace(/\.[^.]+$/,'');
function xml(bytes){const text=decode(bytes);if(text.includes('<!ENTITY'))throw Error('EPUB XML 包含不支持的实体。');const doc=new DOMParser().parseFromString(text,'application/xml');if(doc.querySelector('parsererror'))throw Error('EPUB XML 结构无效。');return doc;}
const nodes=(doc,name)=>[...doc.getElementsByTagNameNS('*',name)];
export function resourcePath(href,base=''){
 if(!href||href.startsWith('/')||href.includes(':')||href.includes('\\'))return null;
 let path;try{path=decodeURIComponent(href.split('#')[0].split('?')[0]);}catch{return null;}
 if(path.startsWith('/')||path.includes('\\'))return null;
 if(!path)return base||null;
 const parts=base?base.split('/').slice(0,-1):[];
 for(const part of path.split('/')){if(!part||part==='.')continue;if(part==='..'){if(!parts.length)return null;parts.pop();}else parts.push(part);}
 return parts.join('/')||null;
}
export function extractHTML(html,article=true){
 // Detached DOM is never inserted into the reader; only strings and decoded image assets are rendered.
 const doc=new DOMParser().parseFromString(html,'text/html'),title=doc.title,heading=doc.querySelector('h1,h2')?.textContent.trim(),author=doc.querySelector('meta[name=author]')?.content;
 doc.querySelectorAll('script,style,noscript,iframe,object,embed,form,button,template,head,[hidden],[aria-hidden=true]').forEach(e=>e.remove());
 if(article)doc.querySelectorAll('nav,aside,footer,header,[role=navigation],[role=banner]').forEach(e=>e.remove());
 const candidates=article?[...doc.querySelectorAll('article,main,[role=main]')]:[],root=candidates.sort((a,b)=>b.textContent.length-a.textContent.length)[0]||doc.body;
 const blocks=[];let buffer='';const blockTags=new Set(['P','DIV','SECTION','ARTICLE','MAIN','H1','H2','H3','H4','H5','H6','LI','BLOCKQUOTE','PRE','TR','FIGURE','FIGCAPTION']);
 const flush=()=>{const text=buffer.replace(/\s+/g,' ').trim();if(text)blocks.push({text});buffer='';};
 function walk(node){if(node.nodeType===3){buffer+=node.textContent;return;}if(node.nodeType!==1)return;
  if(blockTags.has(node.tagName))flush();if(node.tagName==='BR'){flush();return;}
  if(['TD','TH'].includes(node.tagName))buffer+=' ';
  if(node.tagName==='IMG'||node.localName==='image'){flush();const image=node.getAttribute('src')||node.getAttribute('xlink:href');if(image)blocks.push({image,text:node.getAttribute('alt')||''});return;}
  node.childNodes.forEach(walk);if(blockTags.has(node.tagName))flush();
 }
 walk(root);flush();if(blocks.length>1&&blocks[0].text===heading&&!blocks[0].image)blocks.shift();return {title,heading,author,blocks};
}
async function article(bytes,name,source=null){
 const extracted=extractHTML(decode(bytes)),paragraphs=[],images={},assets={},imageSizes={};let count=0,total=0;
 for(const block of extracted.blocks){
  if(block.image){
   let data,mime;
   if(/^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+=*$/.test(block.image)&&block.image.length<=3*1024*1024){const split=block.image.indexOf(',');mime=block.image.slice(5,split-7);data=unbase64(block.image.slice(split+1));}
   else if(source&&count<12){
    let url;try{url=new URL(block.image,source);}catch{}
    if(url?.protocol==='https:'&&!url.username&&!url.password){count++;try{const result=await fetchBytes(url,['image/png','image/jpeg','image/gif','image/webp'],2*1024*1024);data=result.bytes;mime=result.mime;}catch{}}
   }
   if(data&&total+data.length<=12*1024*1024){let bitmap;try{bitmap=await createImageBitmap(new Blob([data],{type:mime}));}catch{}
    if(bitmap){const key=`web-image-${paragraphs.length}`;total+=data.length;assets[key]=`data:${mime};base64,${base64(data)}`;imageSizes[key]={width:bitmap.width,height:bitmap.height};bitmap.close();images[paragraphs.length]=key;paragraphs.push('\uFFFC');continue;}
   }
   paragraphs.push(`[插图：${block.text||'网页图片'}]`);
  }else if(block.text)paragraphs.push(block.text);
 }
 if(!paragraphs.length)throw Error('没有找到文章正文；动态和登录页面暂不支持。');
 return {id:id(),title:extracted.title||titleOf(name),author:extracted.author||(source?new URL(source).host:'网页文章'),format:'WEB',color:'sage',source,
 chapters:[{id:'article',title:extracted.heading||extracted.title||titleOf(name),paragraphs,href:source,images}],assets,imageSizes,original:base64(bytes),originalName:name,originalMime:'text/html',importedAt:new Date().toISOString(),
 importWarnings:extracted.blocks.some((b,i)=>b.image&&!images[i])?['部分网页图片未保存，显示替代说明；原 HTML 一并备份。']:[]};
}
async function epub(bytes,name){
 let total=0,count=0;
 const files=unzipSync(bytes,{filter:file=>{count++;total+=file.originalSize;if(count>20000||file.originalSize>20*1024*1024||total>100*1024*1024)throw Error('EPUB 解压内容过大。');return true;}});
 const read=path=>{if(!files[path])throw Error(`EPUB 缺少资源：${path}`);return files[path];};
 const container=xml(read('META-INF/container.xml')),path=resourcePath(nodes(container,'rootfile')[0]?.getAttribute('full-path')||'');if(!path)throw Error('EPUB 容器无效。');
 const packageDoc=xml(read(path));
 if(nodes(packageDoc,'meta').some(e=>e.getAttribute('property')==='rendition:layout'&&e.textContent.includes('pre-paginated')))throw Error('本版先支持可重排 EPUB，固定版式请暂用 PDF。');
 if(files['META-INF/encryption.xml']){const algorithms=nodes(xml(files['META-INF/encryption.xml']),'EncryptionMethod').map(e=>e.getAttribute('Algorithm'));if(algorithms.some(a=>!['http://www.idpf.org/2008/embedding','http://ns.adobe.com/pdf/enc#RC'].includes(a)))throw Error('此 EPUB 含 DRM 加密内容，暂不能打开。');}
 const items=nodes(packageDoc,'item'),manifest=new Map(items.map(e=>[e.id,e])),spine=nodes(packageDoc,'itemref').filter(e=>e.getAttribute('linear')!=='no');if(!spine.length)throw Error('EPUB 没有章节顺序。');
 const titles=new Map(),nav=items.find(e=>(e.getAttribute('properties')||'').split(' ').includes('nav'));
 if(nav){const navPath=resourcePath(nav.getAttribute('href'),path),doc=new DOMParser().parseFromString(decode(read(navPath)),'text/html');for(const a of doc.querySelectorAll('nav a')){const target=resourcePath(a.getAttribute('href'),navPath);if(target&&!titles.has(target))titles.set(target,a.textContent.trim());}}
 if(!titles.size){const ncx=items.find(e=>e.getAttribute('media-type')==='application/x-dtbncx+xml');if(ncx){const navPath=resourcePath(ncx.getAttribute('href'),path),doc=xml(read(navPath));for(const point of nodes(doc,'navPoint')){const href=[...point.children].find(e=>e.localName==='content')?.getAttribute('src'),target=href&&resourcePath(href,navPath),label=[...point.children].find(e=>e.localName==='navLabel')?.textContent.trim();if(target&&!titles.has(target))titles.set(target,label);}}}
 const assets={},imageSizes={},chapters=[],warnings=[];
 for(let index=0;index<spine.length;index++){
  const item=manifest.get(spine[index].getAttribute('idref')),href=item&&resourcePath(item.getAttribute('href'),path);
  if(!href||!['application/xhtml+xml','text/html'].includes(item.getAttribute('media-type')))throw Error('EPUB 的章节资源无效。');
  const extracted=extractHTML(decode(read(href)),false),paragraphs=[],images={};
  for(const block of extracted.blocks){
   if(block.image){const key=resourcePath(block.image,href),ext=key?.split('.').at(-1).toLowerCase(),mime={png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',gif:'image/gif',webp:'image/webp'}[ext];
    if(key&&files[key]&&mime){const blob=new Blob([files[key]],{type:mime});let bitmap;try{bitmap=await createImageBitmap(blob);}catch{}
     if(bitmap){assets[key]=`data:${mime};base64,${base64(files[key])}`;imageSizes[key]={width:bitmap.width,height:bitmap.height};bitmap.close();images[paragraphs.length]=key;paragraphs.push('\uFFFC');continue;}
    }
    paragraphs.push(`[插图：${block.text||block.image}]`);warnings.push('部分插图格式暂不能显示；原资源保存在 EPUB 原文件中。');
   }else if(block.text)paragraphs.push(block.text);
  }
  if(!paragraphs.length)paragraphs.push('本章节没有可提取正文。');
  chapters.push({id:`spine-${index}`,title:titles.get(href)||extracted.heading||`第 ${index+1} 章`,paragraphs,href,images});
 }
 return {id:id(),title:nodes(packageDoc,'title')[0]?.textContent.trim()||titleOf(name),author:nodes(packageDoc,'creator')[0]?.textContent.trim()||'作者未标注',format:'EPUB',color:'sage',source:null,chapters,assets,imageSizes,original:base64(bytes),originalName:name,originalMime:'application/epub+zip',importedAt:new Date().toISOString(),importWarnings:[...new Set(warnings)]};
}
const pdfCache=new Map();let pdfModule;
async function pdfEngine(){pdfModule ||= import('./vendor/pdfjs/pdf.mjs');const lib=await pdfModule;lib.GlobalWorkerOptions.workerSrc=new URL('./vendor/pdfjs/pdf.worker.mjs',import.meta.url).href;return lib;}
async function pdfDocument(book){
 if(!pdfCache.has(book.id)){
  const lib=await pdfEngine(),original=book.original;
  const task=lib.getDocument({data:unbase64(original),isEvalSupported:false,useSystemFonts:true,cMapUrl:new URL('./vendor/pdfjs/cmaps/',import.meta.url).href,cMapPacked:true,standardFontDataUrl:new URL('./vendor/pdfjs/standard_fonts/',import.meta.url).href});
  task.onPassword=()=>task.destroy();pdfCache.set(book.id,task.promise.catch(error=>{pdfCache.delete(book.id);throw error;}));
 }
 return pdfCache.get(book.id);
}
export function resetPDFCache(){for(const task of pdfCache.values())task.then(doc=>doc.destroy()).catch(()=>{});pdfCache.clear();}
async function pdf(bytes,name){
 const book={id:id(),title:titleOf(name),author:'从此设备导入',format:'PDF',color:'clay',source:null,chapters:[],original:base64(bytes),originalName:name,originalMime:'application/pdf',importedAt:new Date().toISOString()};
 const doc=await pdfDocument(book);if(!doc.numPages||doc.numPages>2000)throw Error('本版支持 2000 页以内的 PDF。');
 const metadata=await doc.getMetadata();book.title=metadata.info?.Title||book.title;book.author=metadata.info?.Author||book.author;let scans=0;
 for(let i=0;i<doc.numPages;i++){const page=await doc.getPage(i+1),content=await page.getTextContent(),paragraphs=[];let buffer='';for(const item of content.items){if(!('str'in item))continue;buffer+=item.str+(item.hasEOL?'':' ');if(item.hasEOL){if(buffer.trim())paragraphs.push(buffer.trim());buffer='';}}if(buffer.trim())paragraphs.push(buffer.trim());if(!paragraphs.length){paragraphs.push('');scans++;}book.chapters.push({id:`pdf-${i}`,title:`第 ${i+1} 页`,paragraphs});}
 book.importWarnings=scans?[`${scans} 页没有文字，仍可阅读和手写；检索需后续 OCR。`]:[];return book;
}
export async function renderPDF(book,index,canvas,size){
 const doc=await pdfDocument(book);if(doc.numPages!==book.chapters.length)throw Error('PDF 原件与页码索引不一致。');
 const page=await doc.getPage(index+1),natural=page.getViewport({scale:1}),scale=Math.min(size.width/natural.width,size.height/natural.height),viewport=page.getViewport({scale});
 const output=2;canvas.width=Math.floor(size.width*output);canvas.height=Math.floor(size.height*output);canvas.style.width=size.width+'px';canvas.style.height=size.height+'px';
 const context=canvas.getContext('2d');context.fillStyle='#fff';context.fillRect(0,0,canvas.width,canvas.height);
 const dx=(size.width-viewport.width)/2,dy=(size.height-viewport.height)/2;
 await page.render({canvasContext:context,viewport,transform:[output,0,0,output,dx*output,dy*output]}).promise;canvas.dataset.rendered='true';
}
export async function importBook(file){
 if(!file.size||file.size>50*1024*1024)throw Error('文件为空或超过 50 MB。');const bytes=new Uint8Array(await file.arrayBuffer()),ext=file.name.split('.').at(-1).toLowerCase();
 if(ext==='epub')return epub(bytes,file.name);if(ext==='pdf')return pdf(bytes,file.name);if(['html','htm'].includes(ext))return article(bytes,file.name);
 if(ext==='txt'){const paragraphs=new TextDecoder('utf-8',{fatal:true}).decode(bytes).split(/\r?\n/).map(p=>p.trim()).filter(Boolean);if(!paragraphs.length)throw Error('TXT 没有正文。');return {id:id(),title:titleOf(file.name),author:'从此设备导入',format:'TXT',color:'clay',source:null,chapters:[{id:'text',title:'正文',paragraphs}],original:base64(bytes),originalName:file.name,originalMime:'text/plain',importedAt:new Date().toISOString()};}
 throw Error('请选择 EPUB、PDF、TXT、HTML 或页间备份。');
}
async function fetchBytes(url,accepted,limit){
 let response;try{response=await fetch(url,{credentials:'omit',signal:AbortSignal.timeout(25000)});}catch{throw Error('网页暂无法获取。浏览器预览受跨域限制，可导入 HTML 文件；原生版不受此浏览器限制。');}
 const mime=response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
 if(!response.ok||!accepted.includes(mime)||!response.url.startsWith('https://'))throw Error('网址未返回支持的网页或图片格式。');
 const reader=response.body.getReader(),chunks=[];let length=0;
 for(;;){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>limit){await reader.cancel();throw Error('文章或图片超过支持的大小。');}chunks.push(value);}
 const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return {bytes,mime,url:response.url};
}
export async function importURL(text){
 let url;try{url=new URL(text);}catch{throw Error('请输入完整的 https:// 文章网址。');}if(url.protocol!=='https:'||url.username||url.password)throw Error('请输入完整的 https:// 文章网址。');
 const result=await fetchBytes(url,['text/html','application/xhtml+xml'],5*1024*1024);
 return article(result.bytes,'article.html',result.url||url.href);
}
