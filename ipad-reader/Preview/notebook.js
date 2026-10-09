/* Independent notebook mode. Its SVG/JSON schema is shared with PencilKit. */
(() => {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg', clone = v => structuredClone(v), uid = () => crypto.randomUUID();
  const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
  const num = n => Number(n).toFixed(3), colors = ['#202124','#36B9D4','#67B33E','#E47B35','#8030A7','#DD485E'];
  const icon = name => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
  const btn = (name, action, symbol, extra = '') => `<button type="button" aria-label="${name}" data-nb="${action}" ${extra}>${symbol ? icon(symbol) : esc(name)}</button>`;
  let doc = clone(window.YEJIAN_NOTEBOOK_DEMO), tab = '绘图', nav = 2, tool = 'pen', color = colors[0], width = 3, zoom = 1, finger = false, recovery;
  let selected = null, gesture = null, history = new Map(), ready, db, saveChain = Promise.resolve(), saveFailed = false, noticeTimer;
  const touches = new Map();
  const root = document.createElement('section'); root.className = 'nb-app'; root.id = 'notebook-app'; root.hidden = true;
  root.setAttribute('aria-label','笔记本模式');
  root.innerHTML = `<header class="nb-header">${btn('返回阅读器','close','book')}${btn('搜索笔记本','search','search')}<strong id="nb-title"></strong>${btn('导出笔记本','export-menu','export')}${btn('笔记本设置','settings-menu','settings')}${btn('隐藏笔记本工具栏','focus','focus')}</header>
    <div class="nb-tabs" role="tablist">${['开始','插入','绘图','视图'].map(t=>`<button role="tab" data-nb="tab" data-value="${t}" aria-label="笔记本${t}">${t}</button>`).join('')}</div>
    <div class="nb-ribbon" id="nb-ribbon"></div><div class="nb-main"><nav class="nb-navigation" id="nb-navigation" aria-label="笔记本分区页面"></nav><div class="nb-scroll" id="nb-scroll"><div class="nb-space" id="nb-space"><svg xmlns="${NS}" class="nb-sheet" id="nb-sheet" aria-label="笔记本压感画布"></svg></div></div>${btn('收起笔记导航','navigation','sidebar','class="nb-nav-toggle"')}</div>
    <footer class="nb-footer"><span id="nb-saved">已保存在本机</span><span id="nb-status"></span></footer>${btn('显示笔记本工具栏','focus','focus','class="nb-restore" hidden')}
    <div class="nb-menu" id="nb-menu" hidden></div><input type="file" id="nb-file" accept=".svg,.json,image/png,image/jpeg,image/webp,image/gif" hidden><input type="file" id="nb-image" accept="image/png,image/jpeg,image/webp,image/gif" hidden>
    <dialog id="nb-name-dialog"><form id="nb-name-form"><h2 id="nb-name-title"></h2><input type="text" id="nb-name" maxlength="500" aria-label="笔记名称" required><div class="nb-dialog-actions">${btn('取消','cancel-name')}<button type="submit">保存名称</button></div></form></dialog>
    <dialog id="nb-text-dialog"><form id="nb-text-form"><h2>文字笔记</h2><textarea id="nb-text" maxlength="100000" aria-label="笔记文字" required></textarea><div class="nb-dialog-actions">${btn('取消','cancel-text')}<button type="submit">保存文字</button></div></form></dialog>
    <dialog id="nb-search-dialog"><h2>搜索笔记</h2><input type="text" id="nb-query" aria-label="搜索笔记内容" placeholder="页面、分区、文字…"><div class="nb-search-results" id="nb-results"></div><div class="nb-dialog-actions">${btn('关闭搜索','cancel-search')}</div></dialog><div class="nb-notice" id="nb-notice" role="status" hidden></div>`;
  document.body.append(root);
  const $ = id => document.getElementById(id), book = () => doc.notebooks.find(b=>b.id===doc.notebookID);
  const section = () => book().sections.find(s=>s.id===doc.sectionID), page = () => section().pages.find(p=>p.id===doc.pageID);
  const stack = () => { if(!history.has(doc.pageID))history.set(doc.pageID,{undo:[],redo:[]}); return history.get(doc.pageID); };
  const info = message => { $('nb-notice').textContent=message; $('nb-notice').hidden=false; clearTimeout(noticeTimer); noticeTimer=setTimeout(()=>$('nb-notice').hidden=true,4000); };
  function persist() {
    const snapshot = clone(doc); $('nb-saved').textContent='保存中…';
    saveChain = saveChain.catch(()=>{}).then(async()=>{
      await ready;
      if(!db)throw Error('本地存储不可用');
      await new Promise((resolve,reject)=>{const tx=db.transaction('state','readwrite'),store=tx.objectStore('state');if(recovery)store.put(recovery,'recovery');store.put(snapshot,'library');tx.oncomplete=()=>{recovery=null;resolve();};tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});
      saveFailed=false; $('nb-saved').textContent='已保存在本机';
    }).catch(()=>{saveFailed=true;$('nb-saved').textContent='保存失败，请导出备份';info('笔记未能保存到本机，请先导出完整备份。');});
  }
  function validPage(p) {
    const finite=(v,lo=0,hi=10000000)=>typeof v==='number'&&Number.isFinite(v)&&v>=lo&&v<=hi;
    const hex=s=>typeof s==='string'&&/^#[a-f0-9]{6}$/i.test(s), str=(s,max)=>typeof s==='string'&&s.length<=max;
    if(!p||!str(p.id,500)||!p.id||!str(p.title,500)||!str(p.created,100)||!finite(p.width,600)||!finite(p.height,600)||!['white','cream','dark'].includes(p.paper)||!['blank','grid','lined'].includes(p.pattern)||!Array.isArray(p.strokes)||p.strokes.length>100000||!Array.isArray(p.elements)||p.elements.length>10000)throw Error('笔记页的尺寸或内容无效');
    let points=0; const ids=new Set();
    for(const s of p.strokes) {
      if(!str(s.id,500)||!s.id||ids.has(s.id)||!['pen','pencil','marker'].includes(s.tool)||!hex(s.color)||!Array.isArray(s.transform)||s.transform.length!==6||!s.transform.every(n=>finite(n,-10000000))||!Array.isArray(s.points)||!s.points.length||(points+=s.points.length)>2000000)throw Error('笔迹数据无效');
      ids.add(s.id);
      for(const n of s.points)if(!finite(n.x)||!finite(n.y)||!finite(n.pressure,0,20)||!finite(n.width,.01,256)||!finite(n.height,.01,256)||!finite(n.time)||!finite(n.opacity,0,1)||!finite(n.azimuth,-100,100)||!finite(n.altitude,-100,100))throw Error('压感采样无效');
    }
    ids.clear();
    for(const e of p.elements) {
      if(!str(e.id,500)||!e.id||ids.has(e.id)||!['text','image'].includes(e.kind)||!finite(e.x)||!finite(e.y)||!finite(e.width,20,100000)||!finite(e.height,20,100000)||!finite(e.fontSize,12,128)||!hex(e.color)||!str(e.text,100000)||typeof e.bold!=='boolean')throw Error('文字或图片对象无效');
      ids.add(e.id);
      if(e.kind==='image'&&(!str(e.dataURI,14000000)||!/^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$/.test(e.dataURI)))throw Error('图片必须为内嵌位图');
    }
    if(p.inkData!=null&&(!str(p.inkData,140000000)||!/^[A-Za-z0-9+/=]+$/.test(p.inkData)))throw Error('原生笔迹数据无效');
    return p;
  }
  function validDocument(d) {
    if(!d||d.engine!=='yejian-notebook-v1'||d.version!==1||!Array.isArray(d.notebooks)||!d.notebooks.length||d.notebooks.length>500)throw Error('不是有效的笔记本备份');
    const ids=new Set();let count=0;
    for(const b of d.notebooks){
      if(typeof b.id!=='string'||!b.id||b.id.length>500||typeof b.title!=='string'||b.title.length>500||!/^#[a-f0-9]{6}$/i.test(b.color)||ids.has(b.id)||!Array.isArray(b.sections)||!b.sections.length)throw Error('笔记本结构无效');ids.add(b.id);
      for(const s of b.sections){
        if(typeof s.id!=='string'||!s.id||s.id.length>500||typeof s.title!=='string'||s.title.length>500||ids.has(s.id)||!Array.isArray(s.pages)||!s.pages.length)throw Error('分区结构无效');ids.add(s.id);
        for(const p of s.pages){if(ids.has(p.id)||++count>10000)throw Error('笔记页重复或过多');ids.add(p.id);validPage(p);}
      }
    }
    if(!d.notebooks.find(b=>b.id===d.notebookID)?.sections.find(s=>s.id===d.sectionID)?.pages.some(p=>p.id===d.pageID))throw Error('当前笔记页不存在');return d;
  }
  ready = new Promise(resolve=>{
    const request=indexedDB.open('yejian-notebooks',1);
    request.onupgradeneeded=()=>request.result.createObjectStore('state');
    request.onerror=()=>{saveFailed=true;resolve();};
    request.onsuccess=()=>{db=request.result;const get=db.transaction('state').objectStore('state').get('library');get.onsuccess=()=>{try{if(get.result)doc=validDocument(get.result);}catch{recovery=get.result;saveFailed=true;info('已有笔记本数据异常，原数据另存备份；请先导出检查。');}resolve();};get.onerror=()=>resolve();};
  });
  function outline(points) {
    if(points.length===1){const p=points[0];return `M${num(p.x-p.width/2)} ${num(p.y)}a${num(p.width/2)} ${num(p.height/2)} 0 1 0 ${num(p.width)} 0a${num(p.width/2)} ${num(p.height/2)} 0 1 0 -${num(p.width)} 0Z`;}
    const left=[],right=[];
    points.forEach((p,i)=>{const a=points[Math.max(0,i-1)],b=points[Math.min(points.length-1,i+1)],dx=b.x-a.x,dy=b.y-a.y,len=Math.max(.0001,Math.hypot(dx,dy)),nx=-dy/len,ny=dx/len,r=Math.max(.05,Math.hypot(p.width*nx,p.height*ny)/2);left.push(`${num(p.x+nx*r)} ${num(p.y+ny*r)}`);right.push(`${num(p.x-nx*r)} ${num(p.y-ny*r)}`);});
    return `M${left.join('L')}L${right.reverse().join('L')}Z`;
  }
  function inkSVG(s, live=false) {
    const opacity=s.tool==='marker'?.28:Math.max(.05,s.points.reduce((a,p)=>a+p.opacity,0)/s.points.length);
    const caps=[s.points[0],s.points.at(-1)].map(p=>`<ellipse cx="${num(p.x)}" cy="${num(p.y)}" rx="${num(p.width/2)}" ry="${num(p.height/2)}"/>`).join('');
    return `<g class="nb-ink" data-ink="${esc(s.id)}" ${live?'id="nb-live"':''} fill="${s.color}" opacity="${num(opacity)}" transform="matrix(${s.transform.map(num).join(' ')})"><path d="${outline(s.points)}"/>${caps}</g>`;
  }
  function elementsSVG(p) {
    return p.elements.map(e=>`<g class="nb-element" data-element="${esc(e.id)}">`+(e.kind==='image'?`<image x="${num(e.x)}" y="${num(e.y)}" width="${num(e.width)}" height="${num(e.height)}" href="${esc(e.dataURI)}" preserveAspectRatio="xMidYMid meet"/>`:
      `<text font-family="sans-serif" font-size="${num(e.fontSize)}" font-weight="${e.bold?700:400}" fill="${e.color}">${e.text.split('\n').map((line,i)=>`<tspan x="${num(e.x)}" y="${num(e.y+e.fontSize+i*e.fontSize*1.4)}">${esc(line)}</tspan>`).join('')}</text>`)+`<rect x="${num(e.x)}" y="${num(e.y)}" width="${num(e.width)}" height="${num(e.height)}" fill="transparent"/>`+'</g>').join('');
  }
  function paperSVG(p) {
    const bg=p.paper==='dark'?'#202124':p.paper==='cream'?'#F8F1DF':'#FFFFFF',fg=p.paper==='dark'?'#EEEEEE':'#202124';
    return `<defs><pattern id="nb-grid" width="32" height="32" patternUnits="userSpaceOnUse"><path d="M0 32H32${p.pattern==='grid'?'M32 0V32':''}" fill="none" stroke="#A5A5A5" stroke-opacity=".22"/></pattern></defs><rect width="100%" height="100%" fill="${bg}"/>${p.pattern==='blank'?'':'<rect width="100%" height="100%" fill="url(#nb-grid)"/>'}<text x="64" y="100" font-family="sans-serif" font-size="48" fill="${fg}">${esc(p.title)}</text><path d="M64 128H1100" stroke="#bbb"/><text x="64" y="163" font-family="sans-serif" font-size="18" fill="#888">${esc(p.created.slice(0,10))}</text>`;
  }
  function base64(s){const bytes=new TextEncoder().encode(s);let v='';for(let i=0;i<bytes.length;i+=32768)v+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(v);}
  function exportSVG(p){validPage(p);return `<svg xmlns="${NS}" width="${p.width}" height="${p.height}" viewBox="0 0 ${p.width} ${p.height}"><metadata id="yejian-notebook">${base64(JSON.stringify({engine:'yejian-notebook-page-v1',version:1,page:p}))}</metadata>${paperSVG(p)}${elementsSVG(p)}${p.strokes.map(s=>inkSVG(s)).join('')}</svg>`;}
  function size(){const p=page(),svg=$('nb-sheet');svg.setAttribute('viewBox',`0 0 ${p.width} ${p.height}`);svg.setAttribute('width',p.width);svg.setAttribute('height',p.height);svg.style.width=`${p.width}px`;svg.style.height=`${p.height}px`;svg.style.transform=`scale(${zoom})`;$('nb-space').style.width=`${p.width*zoom}px`;$('nb-space').style.height=`${p.height*zoom}px`;}
  function grow(x,y){const p=page(),w=p.width,h=p.height;if(x>p.width-180)p.width=Math.min(10000000,Math.ceil((x+700)/1024)*1024);if(y>p.height-180)p.height=Math.min(10000000,Math.ceil((y+700)/1024)*1024);if(p.width!==w||p.height!==h){size();return true;}return false;}
  function renderSheet(){const p=page();$('nb-sheet').innerHTML=paperSVG(p)+elementsSVG(p)+p.strokes.map(s=>inkSVG(s)).join('');size();selectionOutline();$('nb-sheet').classList.toggle('selecting',tool==='select');$('nb-status').textContent=`${p.strokes.length} 笔 · 左上固定，向右 / 向下扩展`;$('nb-sheet').setAttribute('data-stroke-count',p.strokes.length);}
  function selectionOutline(){root.querySelector('#nb-selection-group')?.remove();if(!selected)return;let box;
    if(selected.kind==='element'){const e=page().elements.find(e=>e.id===selected.id);if(e)box={x:e.x,y:e.y,width:e.width,height:e.height};}
    else {const el=Array.from(root.querySelectorAll('[data-ink]')).find(e=>e.dataset.ink===selected.id);if(el){const b=el.getBBox(),s=page().strokes.find(s=>s.id===selected.id),m=s.transform;const corners=[[b.x,b.y],[b.x+b.width,b.y],[b.x,b.y+b.height],[b.x+b.width,b.y+b.height]].map(([x,y])=>[m[0]*x+m[2]*y+m[4],m[1]*x+m[3]*y+m[5]]);const xs=corners.map(a=>a[0]),ys=corners.map(a=>a[1]);box={x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...xs)-Math.min(...xs),height:Math.max(...ys)-Math.min(...ys)};}}
    if(box)$('nb-sheet').insertAdjacentHTML('beforeend',`<g id="nb-selection-group"><rect class="nb-selection" x="${box.x}" y="${box.y}" width="${box.width}" height="${box.height}"/>${selected.kind==='element'?`<rect class="nb-handle" data-resize="true" x="${box.x+box.width-9}" y="${box.y+box.height-9}" width="18" height="18"/>`:''}</g>`);
  }
  function navigation(){const column=(title,items,type,add)=>`<div class="nb-nav-column"><div class="nb-nav-title">${esc(title)}</div><div class="nb-nav-items">${items.map(i=>`<button class="nb-row ${i.id===doc[type+'ID']?'active':''}" data-nb="select-${type}" data-id="${esc(i.id)}">${type==='notebook'?`<span class="nb-book-dot" style="--swatch:${i.color}"></span>`:''}${esc(i.title)}</button>`).join('')}</div>${btn(`新建${add}`,`add-${type}`,null,'class="nb-add"')}</div>`;
    $('nb-navigation').hidden=nav===0;$('nb-navigation').classList.toggle('pages-only',nav===1);
    root.style.setProperty('--nb-nav-width',(nav===2?Math.min(600,innerWidth*.64):nav===1?Math.min(220,innerWidth*.3):0)+'px');
    root.classList.toggle('nb-has-nav',nav>0);
    $('nb-navigation').innerHTML=(nav===2?column('笔记本',doc.notebooks,'notebook','笔记本')+column(book().title,book().sections,'section','分区'):'')+column(section().title,section().pages,'page','页面');
  }
  const selectedElement=()=>selected?.kind==='element'?page().elements.find(e=>e.id===selected.id):null;
  function ribbon(){root.querySelectorAll('[role=tab]').forEach(b=>b.setAttribute('aria-selected',b.dataset.value===tab));const h=stack(),divider='<span class="nb-divider"></span>';
    let html=btn('笔记撤销','undo','undo',h.undo.length?'':'disabled')+btn('笔记重做','redo','redo',h.redo.length?'':'disabled')+divider;
    if(tab==='绘图'){html+=[['选择','select','note'],['钢笔','pen','pen'],['铅笔','pencil','pen'],['荧光笔','marker','marker'],['橡皮','eraser','eraser']].map(([n,t,i])=>btn('笔记'+n,'tool',i,`data-value="${t}" class="${tool===t?'active':''}" aria-pressed="${tool===t}"`)).join('')+divider+colors.map(c=>`<button class="nb-color ${color===c?'active':''}" aria-label="笔记颜色 ${c}" data-nb="color" data-value="${c}"><span style="--swatch:${c}"></span></button>`).join('')+`<label><input id="nb-width" type="range" min="1" max="12" step=".5" value="${width}" aria-label="笔记笔宽"><span>${width}</span></label>`;}
    else if(tab==='插入')html+=btn('文字','text','note')+btn('图片','image','grid')+btn('文件 / SVG','import','import');
    else if(tab==='开始'){const e=selectedElement(),disabled=e?.kind==='text'?'':'disabled';html+=btn('文字','text','note')+btn('编辑','edit-text',null,disabled)+btn('加粗','bold',null,disabled)+btn('减小字号','smaller',null,disabled)+btn('增大字号','larger',null,disabled)+btn('删除选中对象','delete',null,selected?'':'disabled');}
    else html+=btn('导航','navigation','sidebar')+btn('适合宽度','fit',null)+btn('缩小','zoom-out',null)+`<span>${Math.round(zoom*100)}%</span>`+btn('放大','zoom-in',null)+`<label>纸张颜色<select id="nb-paper" aria-label="笔记纸张颜色">${[['白纸','white'],['米色','cream'],['深色','dark']].map(([n,v])=>`<option value="${v}" ${page().paper===v?'selected':''}>${n}</option>`).join('')}</select></label><label>纸张样式<select id="nb-pattern" aria-label="笔记纸张样式">${[['空白','blank'],['横线','lined'],['方格','grid']].map(([n,v])=>`<option value="${v}" ${page().pattern===v?'selected':''}>${n}</option>`).join('')}</select></label><label><input type="checkbox" id="nb-finger" ${finger?'checked':''}>手指绘画</label>`;
    $('nb-ribbon').innerHTML=html;
  }
  function render(){if(root.hidden)return;$('nb-title').textContent=book().title;navigation();renderSheet();ribbon();}
  function change(fn){const before=clone(page());fn(page());record(before);render();persist();}
  function record(before){if(JSON.stringify(before)===JSON.stringify(page()))return;const h=stack();h.undo.push(before);if(h.undo.length>40)h.undo.shift();h.redo=[];}
  function replace(p){const s=section(),index=s.pages.findIndex(x=>x.id===doc.pageID);s.pages[index]=p;selected=null;render();persist();}
  function select(bid,sid,pid){cancelGesture();doc.notebookID=bid;doc.sectionID=sid||book().sections[0].id;doc.pageID=pid||section().pages[0].id;selected=null;zoom=1;render();$('nb-scroll').scrollTo(0,0);persist();}
  let nameKind,renaming=false,editID;
  function naming(kind,rename=false){nameKind=kind;renaming=rename;const names={notebook:'笔记本',section:'分区',page:'页面'};$('nb-name-title').textContent=(rename?'重命名':'新建')+names[kind];$('nb-name').value=rename?(kind==='notebook'?book():kind==='section'?section():page()).title:'';$('nb-name-dialog').showModal();$('nb-name').focus();}
  function newPage(title){return {id:uid(),title,created:new Date().toISOString(),width:1600,height:2400,paper:'white',pattern:'blank',strokes:[],elements:[],inkData:null};}
  function newText(edit=false){const e=edit?selectedElement():null;editID=e?.id;$('nb-text').value=e?.text||'';$('nb-text-dialog').showModal();$('nb-text').focus();}
  function download(data,name,type){const url=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
  function setZoom(z,x=0,y=0){const scroll=$('nb-scroll'),a=(scroll.scrollLeft+x)/zoom,b=(scroll.scrollTop+y)/zoom;zoom=Math.min(3,Math.max(.2,z));size();scroll.scrollLeft=a*zoom-x;scroll.scrollTop=b*zoom-y;if(tab==='视图')ribbon();}
  root.addEventListener('click',event=>{event.stopPropagation();const b=event.target.closest('[data-nb]');if(!b)return;const a=b.dataset.nb,v=b.dataset.value; if(!a.endsWith('menu'))$('nb-menu').hidden=true;
    switch(a){
      case 'close':cancelGesture();root.hidden=true;$('app').inert=false;$('app').removeAttribute('aria-hidden');break;
      case 'tab':tab=v;ribbon();break;
      case 'navigation':nav=nav===2?1:nav===1?0:2;navigation();break;
      case 'focus':root.classList.toggle('nb-focus');root.querySelector('.nb-restore').hidden=!root.classList.contains('nb-focus');break;
      case 'tool':tool=v;selected=null;renderSheet();ribbon();break;
      case 'color':color=v;if(['select','eraser'].includes(tool))tool='pen';renderSheet();ribbon();break;
      case 'undo':{const h=stack();if(h.undo.length){h.redo.push(clone(page()));replace(h.undo.pop());}break;}
      case 'redo':{const h=stack();if(h.redo.length){h.undo.push(clone(page()));replace(h.redo.pop());}break;}
      case 'text':newText();break;case 'edit-text':newText(true);break;
      case 'image':$('nb-image').click();break;case 'import':$('nb-file').click();break;
      case 'bold':case 'smaller':case 'larger':change(()=>{const e=selectedElement();if(e){if(a==='bold')e.bold=!e.bold;else e.fontSize=Math.min(128,Math.max(12,e.fontSize+(a==='larger'?2:-2)));}});break;
      case 'delete':change(p=>{if(selected?.kind==='element')p.elements=p.elements.filter(e=>e.id!==selected.id);else {p.strokes=p.strokes.filter(s=>s.id!==selected?.id);p.inkData=null;}selected=null;});break;
      case 'fit':setZoom($('nb-scroll').clientWidth/1100);$('nb-scroll').scrollTo(0,0);break;case 'zoom-in':setZoom(zoom*1.2);break;case 'zoom-out':setZoom(zoom/1.2);break;
      case 'select-notebook':select(b.dataset.id);break;case 'select-section':select(doc.notebookID,b.dataset.id);break;case 'select-page':select(doc.notebookID,doc.sectionID,b.dataset.id);break;
      case 'add-notebook':case 'add-section':case 'add-page':naming(a.slice(4));break;
      case 'rename-notebook':case 'rename-section':case 'rename-page':naming(a.slice(7),true);break;
      case 'svg':download(exportSVG(page()),'页间-笔记页.svg','image/svg+xml');break;
      case 'backup':download(JSON.stringify(doc,null,2),'页间-笔记本.json','application/json');break;
      case 'export-menu':$('nb-menu').innerHTML=btn('当前笔记页 · SVG','svg')+btn('完整笔记本备份 · JSON','backup')+btn('导入 SVG / 备份 / 图片','import');$('nb-menu').hidden=!$('nb-menu').hidden;break;
      case 'settings-menu':$('nb-menu').innerHTML=['notebook','section','page'].map((k,i)=>btn('重命名'+['笔记本','分区','页面'][i],'rename-'+k)).join('');$('nb-menu').hidden=!$('nb-menu').hidden;break;
      case 'search':$('nb-search-dialog').showModal();$('nb-query').focus();search();break;
      case 'cancel-name':$('nb-name-dialog').close();break;case 'cancel-text':$('nb-text-dialog').close();break;case 'cancel-search':$('nb-search-dialog').close();break;
      case 'result':select(b.dataset.book,b.dataset.section,b.dataset.id);$('nb-search-dialog').close();break;
    }
  });
  root.addEventListener('input',e=>{if(e.target.id==='nb-width'){width=Number(e.target.value);e.target.nextElementSibling.textContent=width;}if(e.target.id==='nb-query')search();});
  root.addEventListener('change',e=>{if(e.target.id==='nb-finger')finger=e.target.checked;if(e.target.id==='nb-paper')change(p=>p.paper=e.target.value);if(e.target.id==='nb-pattern')change(p=>p.pattern=e.target.value);});
  $('nb-name-form').addEventListener('submit',e=>{e.preventDefault();const title=$('nb-name').value.trim();if(!title)return;
    if(renaming){(nameKind==='notebook'?book():nameKind==='section'?section():page()).title=title;render();persist();}
    else if(nameKind==='page'){const p=newPage(title);section().pages.push(p);select(doc.notebookID,doc.sectionID,p.id);}
    else if(nameKind==='section'){const s={id:uid(),title,pages:[newPage('无标题页面')]};book().sections.push(s);select(doc.notebookID,s.id);}
    else {const b={id:uid(),title,color,sections:[{id:uid(),title:'新分区 1',pages:[newPage('无标题页面')]}]};doc.notebooks.push(b);select(b.id);}
    $('nb-name-dialog').close();
  });
  $('nb-text-form').addEventListener('submit',e=>{e.preventDefault();const text=$('nb-text').value;if(!text.trim())return;
    change(p=>{let el=p.elements.find(e=>e.id===editID);if(el)el.text=text;else {el={id:uid(),kind:'text',x:Math.max(80,$('nb-scroll').scrollLeft/zoom+80),y:Math.max(220,$('nb-scroll').scrollTop/zoom+80),width:600,height:Math.max(140,text.split('\n').length*40),text,fontSize:28,color,bold:false,dataURI:null};p.elements.push(el);grow(el.x+el.width+200,el.y+el.height+200);}selected={kind:'element',id:el.id};tool='select';});$('nb-text-dialog').close();
  });
  function search(){const q=$('nb-query').value.trim().toLocaleLowerCase(),results=[];for(const b of doc.notebooks)for(const s of b.sections)for(const p of s.pages)if((b.title+s.title+p.title+p.elements.filter(e=>e.kind==='text').map(e=>e.text).join('')).toLocaleLowerCase().includes(q))results.push(`<button data-nb="result" data-book="${esc(b.id)}" data-section="${esc(s.id)}" data-id="${esc(p.id)}"><span>${esc(p.title)}</span><small>${esc(b.title)} / ${esc(s.title)}</small></button>`);$('nb-results').innerHTML=results.slice(0,100).join('')||'<p>没有找到相关笔记。</p>';}
  async function importFile(file){
    if(file.size>150*1024*1024)throw Error('笔记文件超过 150 MB');
    if(/\.(svg|json)$/i.test(file.name)){
      const text=await file.text();
      if(/\.svg$/i.test(file.name)){
        if(/<!DOCTYPE|<!ENTITY/i.test(text))throw Error('SVG 文件无效');const xml=new DOMParser().parseFromString(text,'image/svg+xml'),metadata=xml.querySelector('metadata[id="yejian-notebook"]');
        if(xml.querySelector('parsererror')||!metadata)throw Error('该 SVG 没有页间可编辑笔记数据');
        const transfer=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(metadata.textContent.trim()),c=>c.charCodeAt(0))));
        if(transfer.engine!=='yejian-notebook-page-v1'||transfer.version!==1)throw Error('SVG 笔记版本不受支持');
        const p=clone(validPage(transfer.page));p.id=uid();section().pages.push(p);select(doc.notebookID,doc.sectionID,p.id);info('SVG 已恢复为可编辑笔记页');
      }else {
        const incoming=validDocument(JSON.parse(text));for(const b of incoming.notebooks){b.id=uid();for(const s of b.sections){s.id=uid();for(const p of s.pages)p.id=uid();}doc.notebooks.push(b);}select(doc.notebooks.at(-1).id);info('已作为新笔记本导入，原笔记保留');
      }
    }else{
      if(file.size>20*1024*1024||!/^image\/(png|jpeg|gif|webp)$/.test(file.type))throw Error('请选择 20 MB 以内的 PNG、JPEG、GIF 或 WebP 图片');
      const image=await createImageBitmap(file),scale=Math.min(1,2048/Math.max(image.width,image.height)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.width*scale));canvas.height=Math.max(1,Math.round(image.height*scale));canvas.getContext('2d').drawImage(image,0,0,canvas.width,canvas.height);image.close();const dataURI=canvas.toDataURL('image/png');if(dataURI.length>14000000)throw Error('图片处理后超过 10 MB');
      change(p=>{const el={id:uid(),kind:'image',x:80+$('nb-scroll').scrollLeft/zoom,y:220+$('nb-scroll').scrollTop/zoom,width:620,height:Math.max(40,620*canvas.height/canvas.width),text:'',fontSize:28,color:colors[0],bold:false,dataURI};p.elements.push(el);selected={kind:'element',id:el.id};tool='select';grow(el.x+el.width+200,el.y+el.height+200);});
    }
  }
  for(const id of ['nb-file','nb-image'])$(id).addEventListener('change',async e=>{try{if(e.target.files[0])await importFile(e.target.files[0]);}catch(error){info(error.message);}finally{e.target.value='';}});
  function point(e){const rect=$('nb-sheet').getBoundingClientRect();return {x:Math.min(10000000,Math.max(0,(e.clientX-rect.left)/zoom)),y:Math.min(10000000,Math.max(0,(e.clientY-rect.top)/zoom))};}
  function sample(e){const p=point(e),pressure=e.pointerType==='pen'?Math.max(0,Math.min(1,e.pressure)):1,base=tool==='marker'?Math.max(15,width*4):width;return {...p,pressure,width:Math.max(.1,base*(.25+.75*pressure)),height:Math.max(.1,base*(.25+.75*pressure)),time:Math.max(0,(e.timeStamp-gesture.started)/1000),opacity:1,azimuth:e.azimuthAngle||0,altitude:e.altitudeAngle||Math.PI/2};}
  function cancelGesture(){if(gesture?.before)replace(gesture.before);gesture=null;touches.clear();}
  $('nb-sheet').addEventListener('pointerdown',e=>{
    if(e.pointerType==='touch'&&gesture?.pointerType==='pen')return;
    if(e.button!==0)return;const svg=$('nb-sheet');touches.set(e.pointerId,{x:e.clientX,y:e.clientY});if(e.isTrusted)svg.setPointerCapture(e.pointerId);
    if(touches.size===2){if(gesture?.before)replace(gesture.before);const t=[...touches.values()];gesture={kind:'pinch',distance:Math.hypot(t[0].x-t[1].x,t[0].y-t[1].y),zoom};return;}
    if(touches.size>2)return;
    const p=point(e),before=clone(page());
    if(e.pointerType==='touch'&&!finger){gesture={kind:'pan',id:e.pointerId,x:e.clientX,y:e.clientY,left:$('nb-scroll').scrollLeft,top:$('nb-scroll').scrollTop};return;}
    if(tool==='select'){
      const target=e.target.closest('[data-element],[data-ink]');if(!e.target.closest('[data-resize]'))selected=target?{id:target.dataset.element||target.dataset.ink,kind:target.dataset.element?'element':'ink'}:null;
      gesture=selected?{kind:e.target.closest('[data-resize]')?'resize':'move',id:e.pointerId,before,start:p,selected:clone(selected)}:null;selectionOutline();ribbon();return;
    }
    gesture={kind:tool==='eraser'?'erase':'ink',id:e.pointerId,pointerType:e.pointerType,before,started:e.timeStamp};
    if(tool==='eraser'){erase(p);return;}
    const s={id:uid(),tool,color,points:[sample(e)],transform:[1,0,0,1,0,0]};gesture.stroke=s;svg.insertAdjacentHTML('beforeend',inkSVG(s,true));e.preventDefault();
  });
  function erase(p){page().strokes=page().strokes.filter(s=>!s.points.some(n=>{const m=s.transform;return Math.hypot(m[0]*n.x+m[2]*n.y+m[4]-p.x,m[1]*n.x+m[3]*n.y+m[5]-p.y)<Math.max(14,n.width);}));page().inkData=null;renderSheet();}
  $('nb-sheet').addEventListener('pointermove',e=>{
    if(!gesture)return;if(touches.has(e.pointerId))touches.set(e.pointerId,{x:e.clientX,y:e.clientY});
    if(gesture.kind==='pinch'){if(touches.size!==2)return;const t=[...touches.values()],rect=$('nb-scroll').getBoundingClientRect();setZoom(gesture.zoom*Math.hypot(t[0].x-t[1].x,t[0].y-t[1].y)/Math.max(1,gesture.distance),(t[0].x+t[1].x)/2-rect.left,(t[0].y+t[1].y)/2-rect.top);return;}
    if(gesture.id!==e.pointerId)return;
    if(gesture.kind==='pan'){$('nb-scroll').scrollLeft=gesture.left+gesture.x-e.clientX;$('nb-scroll').scrollTop=gesture.top+gesture.y-e.clientY;return;}
    const p=point(e);
    if(gesture.kind==='ink'){for(const event of e.getCoalescedEvents?.().length?e.getCoalescedEvents():[e]){const n=sample(event),last=gesture.stroke.points.at(-1);if(Math.hypot(n.x-last.x,n.y-last.y)>.1||n.pressure!==last.pressure)gesture.stroke.points.push(n);}$('nb-live').innerHTML=`<path d="${outline(gesture.stroke.points)}"/>`;grow(p.x,p.y);}
    else if(gesture.kind==='erase')erase(p);
    else {const dx=p.x-gesture.start.x,dy=p.y-gesture.start.y,id=gesture.selected.id;
      if(gesture.selected.kind==='element'){const el=page().elements.find(e=>e.id===id),old=gesture.before.elements.find(e=>e.id===id);if(gesture.kind==='resize'){el.width=Math.min(100000,Math.max(60,old.width+dx));el.height=Math.min(100000,Math.max(40,old.height+dy));}else {el.x=Math.max(0,old.x+dx);el.y=Math.max(0,old.y+dy);}grow(el.x+el.width,el.y+el.height);}
      else {const s=page().strokes.find(s=>s.id===id),old=gesture.before.strokes.find(s=>s.id===id);s.transform[4]=Math.max(-Math.min(...old.points.map(n=>old.transform[0]*n.x+old.transform[2]*n.y)),old.transform[4]+dx);s.transform[5]=Math.max(-Math.min(...old.points.map(n=>old.transform[1]*n.x+old.transform[3]*n.y)),old.transform[5]+dy);page().inkData=null;grow(p.x,p.y);}
      renderSheet();
    }
    const rect=$('nb-scroll').getBoundingClientRect();if(e.clientX>rect.right-28)$('nb-scroll').scrollLeft+=14;if(e.clientY>rect.bottom-28)$('nb-scroll').scrollTop+=14;e.preventDefault();
  });
  const end=e=>{touches.delete(e.pointerId);if(!gesture)return;if(gesture.kind==='pinch'){if(touches.size===0)gesture=null;return;}if(gesture.id!==e.pointerId)return;const g=gesture;gesture=null;if(g.kind==='ink'){page().strokes.push(g.stroke);page().inkData=null;}if(g.before){record(g.before);render();persist();}};
  $('nb-sheet').addEventListener('pointerup',end);$('nb-sheet').addEventListener('pointercancel',()=>cancelGesture());
  $('nb-sheet').addEventListener('dblclick',e=>{if(tool!=='select')return;const id=e.target.closest('[data-element]')?.dataset.element;if(id&&page().elements.find(e=>e.id===id)?.kind==='text'){selected={kind:'element',id};newText(true);}});
  $('nb-scroll').addEventListener('scroll',()=>{if(root.hidden||gesture?.kind==='ink')return;const s=$('nb-scroll');if(grow((s.scrollLeft+s.clientWidth)/zoom,(s.scrollTop+s.clientHeight)/zoom))persist();});
  $('nb-scroll').addEventListener('wheel',e=>{if(e.ctrlKey){e.preventDefault();const r=$('nb-scroll').getBoundingClientRect();setZoom(zoom*Math.exp(-e.deltaY*.003),e.clientX-r.left,e.clientY-r.top);}},{passive:false});
  window.addEventListener('keydown',e=>{if(root.hidden)return;e.stopImmediatePropagation();if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName)||root.querySelector('dialog[open]'))return;if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='z'){e.preventDefault();root.querySelector(`[data-nb="${e.shiftKey?'redo':'undo'}"]`)?.click();}if(e.key==='Escape'){selected=null;$('nb-menu').hidden=true;root.classList.remove('nb-focus');root.querySelector('.nb-restore').hidden=true;render();}},true);
  $('open-notebooks').addEventListener('click',async e=>{e.stopPropagation();await ready;$('more-menu').hidden=true;root.hidden=false;$('app').inert=true;$('app').setAttribute('aria-hidden','true');zoom=1;render();if(saveFailed)info('本地存储需要检查，请先导出备份。');});
})();
