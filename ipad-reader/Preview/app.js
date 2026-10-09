/* Local reader preview. Networking only when explicitly importing an article URL. */
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const NS = 'http://www.w3.org/2000/svg';
  const STORAGE = 'yejian.reader.preview.v1';
  const uid = () => globalThis.crypto?.randomUUID?.() || `id-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const icon = name => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
  const el = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node; };
  const clone = value => JSON.parse(JSON.stringify(value));
  const defaults = () => ({schema: 3, books: clone(window.YEJIAN_LIBRARY), currentBook: window.YEJIAN_LIBRARY[0].id, bookState: {}, notes: [], bookmarks: [], theme: 'paper'});
  let state = defaults();
  function validate(value) {
    if (!value || ![1,2,3].includes(value.schema) || !Array.isArray(value.books) || value.books.length < 1 || value.books.length > 100) throw Error('无法识别这个备份版本。');
    const ids = new Set();
    for (const book of value.books) {
      if (typeof book.id !== 'string' || ids.has(book.id) || typeof book.title !== 'string' || !Array.isArray(book.chapters) || !book.chapters.length) throw Error('书籍数据不完整。');
      ids.add(book.id);
      if (book.original !== undefined && (typeof book.original !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(book.original) || book.original.length > 70*1024*1024)) throw Error('原文件数据无效。');
      if (book.format === 'PDF' && (!book.original || book.chapters.length > 2000)) throw Error('PDF 原件或页码不完整。');
      for (const [key,data] of Object.entries(book.assets || {})) if (typeof data !== 'string' || !/^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+=*$/.test(data)) throw Error('插图资源无效。');
      for (const c of book.chapters) for (const [index,key] of Object.entries(c.images || {})) if (c.paragraphs[Number(index)] !== '\uFFFC' || !book.assets?.[key] || !book.imageSizes?.[key] || !Number.isFinite(book.imageSizes[key].width) || !Number.isFinite(book.imageSizes[key].height) || book.imageSizes[key].width <= 0 || book.imageSizes[key].height <= 0) throw Error('插图定位或尺寸无效。');
      for (const c of book.chapters) if (typeof c.id !== 'string' || typeof c.title !== 'string' || !Array.isArray(c.paragraphs) || !c.paragraphs.every(p => typeof p === 'string')) throw Error('章节数据不完整。');
    }
    if (!value.bookState || typeof value.bookState !== 'object' || !Array.isArray(value.notes) || !Array.isArray(value.bookmarks)) throw Error('定位与笔记数据不完整。');
    for (const bs of Object.values(value.bookState)) {
      if (!bs || !bs.style || !Number.isFinite(bs.style.size) || bs.style.size < 17 || bs.style.size > 36 || !Number.isFinite(bs.style.leading) || bs.style.leading < 1.15 || bs.style.leading > 2.2 || !Number.isFinite(bs.style.margin) || bs.style.margin < 16 || bs.style.margin > 90 || !['serif','sans'].includes(bs.style.font) || !bs.ink) throw Error('版式数据无效。');
      for (const strokes of [...Object.values(bs.ink), ...Object.values(bs.spreadInk || {})]) {
        if (!Array.isArray(strokes)) throw Error('笔迹数据无效。');
        for (const s of strokes) if (!s || typeof s.id !== 'string' || !/^#[0-9a-f]{6}$/i.test(s.color) || !['pen','marker'].includes(s.tool) || !Array.isArray(s.points) || s.points.some(p => !Array.isArray(p) || p.length !== 2 || !p.every(Number.isFinite))) throw Error('笔迹数据无效。');
      }
    }
    for (const n of value.notes) if (typeof n.id !== 'string' || typeof n.text !== 'string' || typeof n.bookId !== 'string' || !n.anchor || typeof n.anchor.chapterId !== 'string' || !Number.isInteger(n.anchor.paragraph) || (n.position && (!Number.isFinite(n.position.x) || !Number.isFinite(n.position.y) || typeof n.pageId !== 'string'))) throw Error('文字笔记定位无效。');
    for (const b of value.bookmarks) if (typeof b.bookId !== 'string' || !b.anchor || typeof b.anchor.chapterId !== 'string' || !Number.isInteger(b.anchor.paragraph)) throw Error('书签定位无效。');
    if (!ids.has(value.currentBook)) value.currentBook = value.books[0].id;
    if (!['paper','sepia','night'].includes(value.theme)) value.theme = 'paper';
    for (const b of Object.values(value.bookState)) {
      if (b.pageSize && (!Number.isFinite(b.pageSize.width) || !Number.isFinite(b.pageSize.height) || b.pageSize.width < 320 || b.pageSize.width > 2048 || b.pageSize.height < 320 || b.pageSize.height > 5000)) throw Error('书页尺寸无效。');
      if (b.style.weight !== undefined && ![400,500,600,700].includes(b.style.weight)) throw Error('字体粗细无效。');
      if (b.style.align !== undefined && !['justify','left'].includes(b.style.align)) throw Error('文本对齐无效。');
    }
    value.schema = 3;
    return value;
  }
  let storageError = false;
  try { const raw = localStorage.getItem(STORAGE); if (raw) state = validate(JSON.parse(raw)); } catch { storageError = true; }
  let pages = [], pageIndex = 0, mode = 'read', tool = 'pen', color = '#445d7b', zoom = 1, scale = 1, inkVisible = true;
  let view = 'reader', panel = 'assistant', side = 'toc', currentStroke = null, undoStacks = {}, redoStacks = {}, gestureBefore = null;
  let editingNote = null, pendingPosition = null, lastAnswer = null, toastTimer = null;
  const rightPaper = $('paper-right');
  let renderedSpread = null, initialized = false;
  const formats = () => import('./formats.js');
  let databasePromise;
  function database() {
    return databasePromise ||= new Promise((resolve,reject)=>{
      const request=indexedDB.open('yejian-reader',1);
      request.onupgradeneeded=()=>request.result.createObjectStore('state');
      request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    });
  }
  async function storedState() { const db=await database();return new Promise((resolve,reject)=>{const request=db.transaction('state').objectStore('state').get('library');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);}); }
  let saving=Promise.resolve();
  function persistSnapshot(snapshot){saving=saving.catch(()=>{}).then(async()=>{const db=await database();await new Promise((resolve,reject)=>{const tx=db.transaction('state','readwrite');tx.objectStore('state').put(snapshot,'library');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});}).catch(()=>toast('本地存储不可用或已满，请导出完整备份。'));}
  const isSpread = () => $('reader-scroll').clientWidth > $('reader-scroll').clientHeight && $('reader-scroll').clientWidth >= 700;
  const pairStart = () => pageIndex - pageIndex % 2;
  const spreadStart = () => isSpread() ? pairStart() : pageIndex;
  const book = () => state.books.find(b => b.id === state.currentBook) || state.books[0];
  function bs() { return state.bookState[book().id] ||= {style:{size:22,leading:1.45,margin:44,font:'sans',fontVersion:2,weight:400,align:'justify'},paginationVersion:4,ink:{},spreadInk:{},page:0}; }
  const page = () => pages[pageIndex];
  const pageSize = () => bs().pageSize || {width:680,height:920};
  const spreadKey = () => `${pages[pairStart()].id}|${pages[pairStart()+1]?.id || ''}`;
  function strokes() {
    const b=bs(),key=spreadKey(); b.spreadInk ||= {};
    if (!Object.hasOwn(b.spreadInk,key)) {
      const left=pages[pairStart()],right=pages[pairStart()+1];
      b.spreadInk[key]=[...clone(b.ink[left.id] || []),...clone(right ? b.ink[right.id] || [] : []).map(s=>({...s,points:s.points.map(([x,y])=>[x+pageSize().width,y])}))];
      delete b.ink[left.id]; if(right)delete b.ink[right.id];
    }
    return b.spreadInk[key];
  }
  const anchored = () => book().format==='PDF' || [...Object.values(bs().ink),...Object.values(bs().spreadInk || {})].some(v=>v.length) || state.notes.some(n=>n.bookId===book().id&&n.position);
  const sourceAnchor = (chapterId,paragraph,offset=0) => {
    const chapter=book().chapters.find(c=>c.id===chapterId);
    return {chapterId,paragraph,offset,href:chapter?.href,pdfPage:book().format==='PDF'?book().chapters.indexOf(chapter):undefined,quote:chapter?.paragraphs[paragraph]};
  };
  const currentAnchor = () => page() ? sourceAnchor(page().chapterId,page().paragraphs[0].index,page().paragraphs[0].offset || 0) : null;
  function toast(text) { $('toast').textContent = text; $('toast').classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').classList.remove('show'), 4000); }
  function save() {
    const snapshot=clone(state),serialized=JSON.stringify(snapshot);
    persistSnapshot(snapshot);
    // Keep small libraries compatible with the previous preview and its tests.
    if(serialized.length < 4*1024*1024){try{localStorage.setItem(STORAGE,serialized);storageError=false;}catch{storageError=true;}}
  }
  function applyTypography() {
    const s=bs().style;
    document.documentElement.style.setProperty('--page-font',s.size+'px');
    document.documentElement.style.setProperty('--page-leading',s.leading);
    document.documentElement.style.setProperty('--page-margin',s.margin+'px');
    document.documentElement.style.setProperty('--body-weight',s.weight || 400);
    document.documentElement.style.setProperty('--text-align',s.align || 'justify');
    document.documentElement.style.setProperty('--body-font',s.font==='serif' ? (s.fontVersion===2 ? '"Yejian Serif","Songti SC","STSong","SimSun",serif' : '"Songti SC","STSong","SimSun",serif') : '"PingFang SC","Microsoft YaHei",sans-serif');
    $('app').classList.toggle('legacy-pages',bs().paginationVersion<4);
    $('app').classList.toggle('legacy-layout',bs().paginationVersion===1);
  }
  function paginate(anchor=null) {
    pages=[];
    if(book().format==='PDF'){
      bs().pageSize={width:680,height:920};
      pages=book().chapters.map((chapter,index)=>({id:`${book().id}:pdf:${index}`,chapterId:chapter.id,title:chapter.title,pdfPage:index,opening:false,paragraphs:chapter.paragraphs.map((text,index)=>({text,index,offset:0}))}));
      pageIndex=Math.max(0,Math.min(Number(bs().page)||0,pages.length-1));return;
    }
    const b=bs(),style=b.style;
    if(!b.paginationVersion){b.paginationVersion=anchored()?1:4;style.fontVersion=anchored()?1:2;}
    applyTypography();
    if(b.paginationVersion<4){
      const budget=Math.floor((b.paginationVersion===1?820:b.paginationVersion===2?445:330)*(21/style.size)**2*(1.95/style.leading)*((680-2*style.margin)/560));
      for(const chapter of book().chapters){
        let chunk=[],length=0;
        const append=()=>pages.push({id:`${book().id}:${chapter.id}:${chunk[0].index}`,chapterId:chapter.id,title:chapter.title,opening:true,paragraphs:chunk});
        chapter.paragraphs.forEach((text,index)=>{const cost=/[\u4e00-\u9fff]/.test(text)?text.length:text.length*.48;if(chunk.length&&length+cost>budget){append();chunk=[];length=0;}chunk.push({text,index,offset:0});length+=cost;});
        if(!chunk.length)chunk.push({text:'这一章还没有正文。',index:0,offset:0});append();
      }
    } else {
      const size=pageSize(),measure=el('div','paper-content');
      Object.assign(measure.style,{position:'fixed',left:'-10000px',top:'0',width:`${size.width-2*style.margin}px`,height:'auto',visibility:'hidden',inset:'auto'});
      document.body.append(measure);
      for(const chapter of book().chapters){
        let chunk=[],used=0,opening=true;
        const capacity=()=>size.height-(opening?124:44)-44;
        const append=()=>{if(!chunk.length)return;pages.push({id:`${book().id}:${chapter.id}:${chunk[0].index}:${chunk[0].offset}`,chapterId:chapter.id,title:chapter.title,opening,paragraphs:chunk});chunk=[];used=0;opening=false;};
        chapter.paragraphs.forEach((text,index)=>{
          if(chapter.images?.[index]) {
            const key=chapter.images[index],dims=book().imageSizes[key],ratio=Math.min((size.width-2*style.margin)/dims.width,(size.height-220)/dims.height,1),height=dims.height*ratio+style.size*.85;
            if(chunk.length&&used+height>capacity())append();
            chunk.push({text,index,offset:0,image:key});used+=height;return;
          }
          const chars=Array.from(text || ' ');let offset=0,position=0;
          while(position<chars.length){
            const paragraph=el('p',position?'continued':'');measure.replaceChildren(paragraph);
            const remaining=capacity()-used;
            const heightFor=count=>{paragraph.textContent=chars.slice(position,position+count).join('');return paragraph.getBoundingClientRect().height+style.size*.85;};
            let count=chars.length-position;
            if(heightFor(count)>remaining){
              let lo=0,hi=count;
              while(lo<hi){const mid=Math.ceil((lo+hi)/2);if(heightFor(mid)<=remaining)lo=mid;else hi=mid-1;}
              count=lo;
            }
            if(!count&&chunk.length){append();continue;}
            if(!count)count=1;
            const fragment=chars.slice(position,position+count).join('');
            used+=heightFor(count);chunk.push({text:fragment,index,offset});offset+=fragment.length;position+=count;
            if(position<chars.length)append();
          }
        });append();
      }
      measure.remove();
    }
    pageIndex=Math.min(Math.max(0,Number(b.page)||0),pages.length-1);
    if(anchor){const index=pages.findIndex(p=>p.chapterId===anchor.chapterId&&p.paragraphs.some(t=>t.index===anchor.paragraph&&t.offset<=(anchor.offset||0)&&t.offset+t.text.length>(anchor.offset||0)));if(index>=0)pageIndex=index;}
  }
  function renderSidebar() {
    $('contents-title').textContent=book().title;$('toc').replaceChildren();
    if(side==='toc')book().chapters.forEach(chapter=>{
      const index=pages.findIndex(p=>p.chapterId===chapter.id),button=el('button',page().chapterId===chapter.id?'active':'');
      button.append(el('span','',chapter.title),el('span','',String(index+1)));button.onclick=()=>{pageIndex=index;showView('reader');renderPage();$('app').classList.remove('sidebar-open');};$('toc').append(button);
    });
    else if(side==='marks'){
      const add=el('button','', '+ 为当前页添加书签');add.onclick=bookmark;$('toc').append(add);
      state.bookmarks.filter(b=>b.bookId===book().id).forEach(mark=>{const chapter=book().chapters.find(c=>c.id===mark.anchor.chapterId);const button=el('button','',`${chapter?.title || '原文'} · 第 ${mark.anchor.paragraph+1} 段`);button.onclick=()=>jump(book().id,mark.anchor);$('toc').append(button);});
    }else{
      const notes=state.notes.filter(n=>n.bookId===book().id);
      notes.forEach(note=>{const button=el('button','',note.text);button.onclick=()=>jump(note.bookId,note.anchor);$('toc').append(button);});
      if(!notes.length)$('toc').append(el('p','empty-state','保存的摘录与笔记会出现在这里。'));
    }
  }
  function configureViewport() {
    if(bs().paginationVersion<4||anchored())return false;
    const width=Math.max(320,Math.min(2048,Math.floor($('reader-scroll').clientWidth/(isSpread()?2:1)))),height=Math.max(320,Math.min(2400,$('reader-scroll').clientHeight));
    if(bs().pageSize?.width===width&&bs().pageSize?.height===height)return false;
    const anchor=currentAnchor();bs().pageSize={width,height};paginate(anchor);return true;
  }
  function fitPage() {
    if(view!=='reader')return;
    if(configureViewport() || renderedSpread!==isSpread()){renderPage();return;}
    const size=pageSize(),visibleWidth=size.width*(isSpread()?2:1);
    scale=Math.min($('reader-scroll').clientWidth/visibleWidth,$('reader-scroll').clientHeight/size.height);
    const object=$('book-object');
    Object.assign(object.style,{width:`${size.width*2}px`,height:`${size.height}px`,transform:`scale(${scale})`,left:`${!isSpread()&&pageIndex%2 ? -size.width*scale : 0}px`});
    Object.assign($('page-wrap').style,{width:`${visibleWidth*scale}px`,height:`${size.height*scale}px`});
    document.documentElement.style.setProperty('--page-width',size.width+'px');document.documentElement.style.setProperty('--page-height',size.height+'px');
    rightPaper.style.left=size.width+'px';
    $('ink-layer').setAttribute('viewBox',`0 0 ${size.width*2} ${size.height}`);
    document.documentElement.style.setProperty('--print-scale',String(1000/visibleWidth));
  }
  function renderPage() {
    finishGesture();bs().page=pageIndex;applyTypography();renderedSpread=isSpread();
    $('breadcrumb').textContent=book().title;$('book-author').textContent=book().author;
    for(const [index,suffix] of [[pairStart(),''],[pairStart()+1,'-right']]){
      const shown=pages[index],content=$('paper-content'+suffix),paper=$(suffix?'paper-right':'paper');content.replaceChildren();content.dataset.book=book().title;
      paper.classList.toggle('opening',!!shown?.opening);paper.classList.toggle('pdf-page',book().format==='PDF');if(!shown)continue;
      if(shown.pdfPage!==undefined){const canvas=el('canvas','pdf-canvas');canvas.setAttribute('aria-label',`PDF 第 ${shown.pdfPage+1} 页`);content.append(canvas);const currentBook=book();formats().then(f=>f.renderPDF(currentBook,shown.pdfPage,canvas,pageSize())).catch(error=>{if(canvas.isConnected)toast(error.message);});continue;}
      if(shown.opening || bs().paginationVersion<4){const number=book().chapters.findIndex(c=>c.id===shown.chapterId)+1;content.append(el('span','chapter-number',String(number)),el('h1','',shown.title.replace(/^第.{1,4}章[\s　]*/,'')));}
      shown.paragraphs.forEach(p=>{const paragraph=el(p.image?'figure':'p',p.image?'reader-image':p.offset?'continued':'',p.image?undefined:p.text);
        if(p.image){const image=el('img');image.src=book().assets[p.image];image.alt='书中插图';const dims=book().imageSizes[p.image],size=pageSize(),ratio=Math.min((size.width-2*bs().style.margin)/dims.width,(size.height-220)/dims.height,1);image.width=dims.width*ratio;image.height=dims.height*ratio;paragraph.append(image);}paragraph.dataset.chapter=shown.chapterId;paragraph.dataset.paragraph=p.index;paragraph.dataset.offset=p.offset || 0;content.append(paragraph);});
    }
    if(bs().paginationVersion<4){const height=Math.max(920,...['paper-content','paper-content-right'].map(id=>$(id).offsetTop+$(id).offsetHeight+74));bs().pageSize={width:680,height};}
    const start=spreadStart();$('page-status').textContent=isSpread()?`${start+1}–${Math.min(start+2,pages.length)} 于 ${pages.length}`:`${pageIndex+1} 于 ${pages.length}`;
    $('progress').max=pages.length-1;$('progress').value=pageIndex;
    document.querySelector('[data-action="prev"]').disabled=start===0;document.querySelector('[data-action="next"]').disabled=start+(isSpread()?2:1)>=pages.length;
    renderInk();renderSidebar();renderNotes();fitPage();save();
  }
  function pathFor(stroke) {
    const p=document.createElementNS(NS,'path');
    p.setAttribute('d',stroke.points.map((xy,i)=>(i?'L':'M')+xy.map(v=>v.toFixed(2)).join(' ')).join(' '));
    p.setAttribute('stroke',stroke.color); p.setAttribute('stroke-width',stroke.tool==='marker'?'19':'2.6'); p.setAttribute('opacity',stroke.tool==='marker'?'.24':'1'); p.dataset.strokeId=stroke.id;
    return p;
  }
  function renderInk() {
    const layer=$('ink-layer');layer.replaceChildren(...strokes().map(pathFor));layer.style.visibility=inkVisible?'visible':'hidden';
    for(const [index,suffix] of [[pairStart(),''],[pairStart()+1,'-right']]){
      const shown=pages[index],texts=$('text-layer'+suffix);texts.replaceChildren();texts.style.visibility=inkVisible?'visible':'hidden';
      state.notes.filter(n=>shown&&n.bookId===book().id&&n.pageId===shown.id&&n.position).forEach(note=>{const button=el('button','page-note',note.text);button.style.left=note.position.x+'px';button.style.top=note.position.y+'px';button.setAttribute('aria-label',`编辑笔记：${note.text.slice(0,25)}`);button.onclick=()=>openNote(note);texts.append(button);});
    }
    document.querySelector('[data-action="undo"]').disabled=!undoStacks[spreadKey()]?.length;document.querySelector('[data-action="redo"]').disabled=!redoStacks[spreadKey()]?.length;
  }
  function remember(before){(undoStacks[spreadKey()] ||= []).push(clone(before));redoStacks[spreadKey()]=[];}
  function point(event){const rect=$('ink-layer').getBoundingClientRect();return [(event.clientX-rect.left)/scale,(event.clientY-rect.top)/scale];}
  function beginPointer(event){
    if(mode!=='annotate'||event.button!==0)return;
    event.preventDefault();const xy=point(event),target=pairStart()+(xy[0]>=pageSize().width?1:0);if(!pages[target])return;
    pageIndex=target;bs().page=pageIndex;
    if(tool==='text'){pendingPosition={x:Math.max(0,Math.min(xy[0]-(target%2)*pageSize().width,pageSize().width-120)),y:xy[1]};openNote();return;}
    event.currentTarget.setPointerCapture(event.pointerId);gestureBefore=clone(strokes());
    if(tool==='eraser'){currentStroke={erasing:true};eraseAt(xy);return;}
    currentStroke={id:uid(),tool,color,points:[xy,[xy[0]+.05,xy[1]+.05]]};strokes().push(currentStroke);renderInk();
  }
  function eraseAt(xy){
    const distance=(p,a,b)=>{const dx=b[0]-a[0],dy=b[1]-a[1],t=Math.max(0,Math.min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/(dx*dx+dy*dy||1)));return Math.hypot(p[0]-a[0]-t*dx,p[1]-a[1]-t*dy);};
    bs().spreadInk[spreadKey()]=strokes().filter(s=>!s.points.some((a,i)=>distance(xy,a,s.points[i+1]||a)<16));renderInk();
  }
  function movePointer(event){
    if(!currentStroke)return;event.preventDefault();const coalesced=event.getCoalescedEvents?.();const events=coalesced?.length ? coalesced : [event];
    for(const sample of events){const xy=point(sample);if(currentStroke.erasing)eraseAt(xy);else currentStroke.points.push(xy);}
    if(!currentStroke.erasing){const node=$('ink-layer').querySelector(`[data-stroke-id="${currentStroke.id}"]`);if(node)node.setAttribute('d',pathFor(currentStroke).getAttribute('d'));}
  }
  function finishGesture(){if(!currentStroke)return;remember(gestureBefore);currentStroke=null;gestureBefore=null;save();renderInk();}
  function turnPage(direction){
    finishGesture();
    pageIndex=Math.max(0,Math.min(pages.length-1,spreadStart()+direction*(isSpread()?2:1)));
    renderPage();
  }
  function bookmark(){
    const anchor={chapterId:page().chapterId,paragraph:page().paragraphs[0].index};
    if(!state.bookmarks.some(b=>b.bookId===book().id&&b.anchor.chapterId===anchor.chapterId&&b.anchor.paragraph===anchor.paragraph))state.bookmarks.push({bookId:book().id,anchor});
    save();renderSidebar();toast('已添加书签');
  }
  const layer=$('ink-layer');layer.addEventListener('pointerdown',beginPointer);layer.addEventListener('pointermove',movePointer);layer.addEventListener('pointerup',finishGesture);layer.addEventListener('pointercancel',finishGesture);layer.addEventListener('lostpointercapture',finishGesture);
  function setMode(value){finishGesture();mode=value;$('book-object').classList.toggle('annotating',mode==='annotate');$('pen-tray').hidden=mode!=='annotate';$('annotation-toggle').setAttribute('aria-pressed',mode==='annotate');if(mode==='annotate'&&!inkVisible){inkVisible=true;renderInk();}}
  function showView(value){view=value;$('reader-view').hidden=value!=='reader';$('library-view').hidden=value!=='library';document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('selected',b.dataset.view===view));if(value==='library')renderLibrary();else requestAnimationFrame(fitPage);}
  function showPanel(value){panel=value;$('assistant-panel').hidden=value!=='assistant';$('notes-panel').hidden=value!=='notes';document.querySelectorAll('[data-panel]').forEach(b=>b.classList.toggle('active',b.dataset.panel===panel));}
  function openBook(id){state.currentBook=id;paginate();lastAnswer=null;$('conversation').replaceChildren();renderPage();showView('reader');$('app').classList.remove('sidebar-open');answer('这一页讲了什么？',true);}
  function jump(bookId,anchor){if(state.currentBook!==bookId)openBook(bookId);const i=pages.findIndex(p=>p.chapterId===anchor.chapterId&&(book().format==='PDF'||p.paragraphs.some(t=>t.index===anchor.paragraph&&t.offset<=(anchor.offset||0)&&t.offset+t.text.length>(anchor.offset||0))));if(i<0){toast('找不到此处原文。');return;}pageIndex=i;showView('reader');renderPage();const target=Array.from(document.querySelectorAll('.paper-content p')).find(p=>p.dataset.chapter===anchor.chapterId&&Number(p.dataset.paragraph)===anchor.paragraph);target?.classList.add('flash');setTimeout(()=>target?.classList.remove('flash'),2600);$('app').classList.remove('inspector-open','sidebar-open');toast('已回到引用的原文');}
  function renderLibrary(){const filter=$('book-search').value.trim().toLowerCase();$('books-grid').replaceChildren();state.books.filter(b=>(b.title+' '+b.author).toLowerCase().includes(filter)).forEach(b=>{const button=el('button','book-item');const cover=el('div',`book-cover ${b.color||'sage'}`);cover.append(el('span','cover-label',b.format),el('span','cover-title',b.title),el('span','cover-bottom','页 间 藏 书'));button.append(cover,el('h3','',b.title),el('p','',b.author));button.onclick=()=>openBook(b.id);$('books-grid').append(button);});if(!$('books-grid').children.length)$('books-grid').append(el('p','empty-state','没有找到这本书。'));}
  function renderNotes(){const list=$('notes-list');list.replaceChildren();const notes=state.notes.filter(n=>n.bookId===book().id);if(!notes.length)list.append(el('p','empty-state','圈住一句喜欢的话，\n或留下一点此刻的想法。'));notes.slice().reverse().forEach(note=>{const card=el('div','note-card');card.append(el('small','',note.kind==='answer'?'阅读助手 · 保存的摘录':'文字笔记'),el('p','',note.text));const c=book().chapters.find(c=>c.id===note.anchor.chapterId);const location=el('button','note-location',`${c?.title||'原文'} · 第 ${note.anchor.paragraph+1} 段 ↗`);location.onclick=()=>jump(note.bookId,note.anchor);card.append(location);const actions=el('div','note-actions');const edit=el('button','note-delete','编辑');edit.onclick=()=>openNote(note);const del=el('button','note-delete','删除');del.onclick=()=>{state.notes=state.notes.filter(n=>n.id!==note.id);save();renderNotes();renderInk();renderSidebar();};actions.append(edit,del);card.append(actions);list.append(card);});}
  function openNote(note=null){editingNote=note;if(note)pendingPosition=note.position||null;$('note-text').value=note?.text||'';$('note-dialog').showModal();$('note-text').focus();}
  $('note-form').addEventListener('submit',event=>{event.preventDefault();const text=$('note-text').value.trim();if(!text)return;if(editingNote)editingNote.text=text;else state.notes.push({id:uid(),bookId:book().id,text,kind:'text',anchor:currentAnchor(),pageId:page().id,position:pendingPosition,created:new Date().toISOString()});pendingPosition=null;editingNote=null;$('note-dialog').close();save();renderNotes();renderInk();renderSidebar();toast('想法已留在这一页');});
  function answer(question,initial=false){if(!question.trim())return;const current=page();let chosen=current.paragraphs.find(p=>p.text&&p.text!=='\uFFFC');if(!chosen){$('conversation').replaceChildren(el('p','empty-state','此页没有可提取文字，仍可手写；检索需后续 OCR。'));return;}if(/笔记|写字|批注|圈|留/.test(question))chosen=current.paragraphs.find(p=>/笔记|笔迹|写字|圈画/.test(p.text))||chosen;else if(/结尾|最后/.test(question))chosen=current.paragraphs.at(-1);const anchor=sourceAnchor(current.chapterId,chosen.index);lastAnswer={bookId:book().id,anchor,text:chosen.text};const q=el('div','message-question',question);const a=el('div','answer');const label=el('div','answer-label');label.innerHTML=icon('spark');label.append(document.createTextNode('页间 · 原文摘录示例'));a.append(label,el('p','','这里先展示与你的问题相关的原文。接入 AI 后，解释和总结会在这个位置出现，并保留同样的引用跳转。'),el('blockquote','',chosen.text));const cite=el('button','citation');const title=el('span','citation-title');title.innerHTML=icon('link');title.append(document.createTextNode(`${current.title} · 第 ${chosen.index+1} 段 ↗`));cite.append(title,el('span','citation-quote',chosen.text));cite.onclick=()=>jump(lastAnswer.bookId,anchor);a.append(cite);const saveButton=el('button','save-answer');saveButton.innerHTML=icon('note');saveButton.append(document.createTextNode('保存为笔记'));const response=clone(lastAnswer);saveButton.onclick=()=>{if(saveButton.disabled)return;state.notes.push({id:uid(),bookId:response.bookId,text:response.text,kind:'answer',anchor:response.anchor,created:new Date().toISOString()});save();renderSidebar();renderNotes();saveButton.textContent='✓ 已保存到笔记';saveButton.disabled=true;toast('摘录与原文位置已一起保存');};a.append(saveButton);$('conversation').replaceChildren(q,a);if(!initial)$('question').value='';}
  $('ask-form').addEventListener('submit',event=>{event.preventDefault();answer($('question').value);});
  function settings(){
    const s=bs().style;
    for(const [id,value] of [['font-size',s.size],['line-height',s.leading],['page-margin',s.margin],['font-family',s.font],['font-weight',s.weight||400],['text-align',s.align||'justify']]){$(id).value=value;$(id).disabled=anchored();}
    document.querySelectorAll('[data-adjust]').forEach(button=>button.disabled=anchored());
    $('font-output').value=s.size;$('line-output').value=Math.round(s.leading*100)+'%';$('margin-output').value=s.margin;
    if(!$('settings-dialog').open)$('settings-dialog').show();
  }
  function updateSetting(key,value){if(anchored())return;const anchor=currentAnchor();bs().style[key]=value;paginate(anchor);renderPage();settings();}
  for(const [id,key] of [['font-size','size'],['line-height','leading'],['page-margin','margin'],['font-family','font'],['font-weight','weight'],['text-align','align']])$(id).addEventListener('input',()=>updateSetting(key,['font','align'].includes(key)?$(id).value:Number($(id).value)));
  function theme(value){state.theme=value;document.body.classList.toggle('night-theme',value==='night');document.body.classList.toggle('sepia-theme',value==='sepia');document.querySelectorAll('[data-theme]').forEach(b=>b.classList.toggle('selected',b.dataset.theme===value));save();}
  function download(name,text,type){const blob=new Blob([text],{type});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}
  const filename=()=>book().title.replace(/[<>:"/\\|?*]/g,'_').slice(0,60);
  const xml=value=>String(value).replace(/[<>&"']/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]));
  function exportData(kind){if(kind==='original'){if(!book().original){toast('示例书没有导入原文件');return;}formats().then(f=>download(book().originalName||'original.bin',f.unbase64(book().original),book().originalMime||'application/octet-stream'));}else if(kind==='backup')download('页间-完整备份.json',JSON.stringify(state,null,2),'application/json');else if(kind==='markdown'){let text=`# ${book().title}\n\n${book().author}\n\n`;const notes=state.notes.filter(n=>n.bookId===book().id);for(const n of notes){const c=book().chapters.find(c=>c.id===n.anchor.chapterId);text+=`## ${c?.title||'原文'} · 第 ${n.anchor.paragraph+1} 段\n\n${n.text}\n\n> ${(c?.paragraphs[n.anchor.paragraph]||'').replace(/\n/g,'\n> ')}\n\n定位：book=${book().id}; chapter=${n.anchor.chapterId}; paragraph=${n.anchor.paragraph}\n\n`;}if(!notes.length)text+='尚未添加文字笔记。手写笔迹请导出 SVG 或完整备份。\n';download(filename()+'-笔记.md',text,'text/markdown;charset=utf-8');}else if(kind==='svg'){const size=pageSize(),offset=(pageIndex%2)*size.width,paths=strokes().map(s=>pathFor(s).outerHTML).join('');const notes=state.notes.filter(n=>n.bookId===book().id&&n.pageId===page().id&&n.position).map(n=>`<text x="${n.position.x+8}" y="${n.position.y+26}" fill="#445d7b" font-size="18">${n.text.split('\n').map((t,i)=>`<tspan x="${n.position.x+8}" dy="${i?27:0}">${xml(t)}</tspan>`).join('')}</text>`).join('');download(filename()+`-第${pageIndex+1}页-笔记.svg`,`<svg xmlns="${NS}" width="${size.width}" height="${size.height}" viewBox="0 0 ${size.width} ${size.height}"><g transform="translate(${-offset} 0)">${paths}</g>${notes}</svg>`,'image/svg+xml');}else if(kind==='print'){$('export-dialog').close();window.print();return;}$('export-dialog').close();toast('已生成导出文件');}
  async function importFiles(files) {
    for(const file of files){try{
      toast('正在导入…');
      if(file.name.toLowerCase().endsWith('.json')){
        if(file.size>200*1024*1024)throw Error('备份超过 200 MB。');const restored=validate(JSON.parse(await file.text()));
        (await formats()).resetPDFCache();state=restored;undoStacks={};redoStacks={};theme(state.theme);openBook(state.currentBook);toast('完整备份已恢复');
      }else{
        const imported=await (await formats()).importBook(file);state.books.push(imported);openBook(imported.id);toast(imported.importWarnings?.[0]||`${imported.format} 已导入并保存在本机`);
      }
    }catch(error){toast(error.message);}}
    save();
  }
  $('file-input').addEventListener('change',async()=>{await importFiles([...$('file-input').files]);$('file-input').value='';});
  $('web-import-form').addEventListener('submit',async event=>{
    event.preventDefault();const button=event.submitter;button.disabled=true;
    try{toast('正在保存文章…');const imported=await (await formats()).importURL($('article-url').value.trim());state.books.push(imported);openBook(imported.id);$('web-import-dialog').close();$('article-url').value='';toast('网页正文与来源已保存，可离线阅读');}catch(error){toast(error.message);}finally{button.disabled=false;}
  });
  $('book-search').addEventListener('input',renderLibrary);
  $('progress').addEventListener('input',()=>{pageIndex=Number($('progress').value);renderPage();});
  $('text-search').addEventListener('input',()=>{
    const query=$('text-search').value.trim().toLowerCase();$('search-results').replaceChildren();if(!query)return;
    for(const chapter of book().chapters)chapter.paragraphs.forEach((text,index)=>{if(!text.toLowerCase().includes(query))return;const button=el('button');button.append(el('small','',chapter.title),document.createTextNode(text));button.onclick=()=>{$('search-dialog').close();jump(book().id,sourceAnchor(chapter.id,index));};$('search-results').append(button);});
    if(!$('search-results').children.length)$('search-results').append(el('p','empty-state','没有找到匹配的原文。'));
  });
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');
    if(!$('more-menu').contains(event.target)&&button?.dataset.action!=='more')$('more-menu').hidden=true;
    if(!event.target.closest('#settings-dialog')&&button?.dataset.action!=='appearance')$('settings-dialog').close();
    if(!event.target.closest('#search-dialog')&&button?.dataset.action!=='search')$('search-dialog').close();
    if(!button)return;const d=button.dataset;
    if($('more-menu').contains(button))$('more-menu').hidden=true;
    if(d.view){showView(d.view);return;}if(d.panel){showPanel(d.panel);return;}
    if(d.side){side=d.side;document.querySelectorAll('[data-side]').forEach(b=>b.classList.toggle('active',b.dataset.side===side));renderSidebar();return;}
    if(d.tool){tool=d.tool;document.querySelectorAll('[data-tool]').forEach(b=>{b.classList.toggle('active',b.dataset.tool===tool);b.setAttribute('aria-pressed',b.dataset.tool===tool);});return;}
    if(d.color){color=d.color;document.querySelectorAll('[data-color]').forEach(b=>{b.classList.toggle('selected',b.dataset.color===color);b.setAttribute('aria-pressed',b.dataset.color===color);});return;}
    if(d.theme){theme(d.theme);return;}if(d.question){answer(d.question);return;}if(d.export){exportData(d.export);return;}
    if(d.adjust){const range=d.adjust==='size'?[17,36]:[1.15,2.2];updateSetting(d.adjust,Math.min(range[1],Math.max(range[0],Math.round((bs().style[d.adjust]+Number(d.delta))*100)/100)));return;}
    switch(d.action){
      case 'library':showView(view==='library'?'reader':'library');break;
      case 'sidebar':$('app').classList.toggle('sidebar-open');renderSidebar();break;
      case 'inspector':$('app').classList.toggle('inspector-open');showPanel('assistant');break;
      case 'appearance':settings();break;
      case 'search':$('search-dialog').show();$('text-search').focus();break;
      case 'more':$('more-menu').hidden=!$('more-menu').hidden;break;
      case 'annotate':setMode(mode==='read'?'annotate':'read');break;
      case 'export':$('export-dialog').showModal();break;
      case 'import':$('file-input').click();break;
      case 'web-import':$('web-import-dialog').showModal();$('article-url').focus();break;
      case 'close-web-import':$('web-import-dialog').close();break;
      case 'focus':setMode('read');$('app').classList.add('focus');break;
      case 'notes':showPanel('notes');$('app').classList.add('inspector-open');break;
      case 'add-note':pendingPosition=null;openNote();break;
      case 'close-note':$('note-dialog').close();pendingPosition=null;break;
      case 'bookmark':bookmark();break;
      case 'prev':case 'next':turnPage(d.action==='next'?1:-1);break;
      case 'hide-ink':inkVisible=!inkVisible;button.setAttribute('aria-pressed',inkVisible);renderInk();break;
      case 'undo':if(undoStacks[spreadKey()]?.length){(redoStacks[spreadKey()]||=[]).push(clone(strokes()));bs().spreadInk[spreadKey()]=undoStacks[spreadKey()].pop();save();renderInk();}break;
      case 'redo':if(redoStacks[spreadKey()]?.length){(undoStacks[spreadKey()]||=[]).push(clone(strokes()));bs().spreadInk[spreadKey()]=redoStacks[spreadKey()].pop();save();renderInk();}break;
    }
  });
  let readPointer=null;
  $('reader-scroll').addEventListener('pointerdown',event=>{if(mode==='read'&&!event.target.closest('button'))readPointer={x:event.clientX,y:event.clientY};});
  $('reader-scroll').addEventListener('pointerup',event=>{if(!readPointer||mode!=='read')return;const dx=event.clientX-readPointer.x,dy=event.clientY-readPointer.y;readPointer=null;if(Math.abs(dx)>45&&Math.abs(dx)>Math.abs(dy)){turnPage(dx<0?1:-1);return;}if(Math.hypot(dx,dy)<12&&!event.target.closest('button')&&!window.getSelection()?.toString())$('app').classList.toggle('focus');});
  window.addEventListener('keydown',event=>{if(document.querySelector('dialog[open]')||['INPUT','TEXTAREA','SELECT'].includes(event.target.tagName))return;if(event.key==='ArrowRight'||event.key==='ArrowLeft'){event.preventDefault();turnPage(event.key==='ArrowRight'?1:-1);}if(event.key==='Escape'){$('app').classList.remove('sidebar-open','inspector-open','focus');$('more-menu').hidden=true;}});
  new ResizeObserver(()=>{if(initialized)fitPage();}).observe($('reader-scroll'));
  (async()=>{
    try{const stored=await storedState();if(stored)state=validate(stored);}catch{storageError=true;}
    await document.fonts.ready;initialized=true;
    configureViewport();paginate();renderPage();theme(state.theme);showPanel(panel);answer('为什么要在书页上写字？',true);
    if(storageError)toast('本地保存不可用，请导出备份以保留数据。');
  })();
})();
