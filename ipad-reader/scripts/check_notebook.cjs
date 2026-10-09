/* Exercise a separate browser profile; never touch the user's books or notes. */
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_EXECUTABLE?{executablePath:process.env.BROWSER_EXECUTABLE}:{})});
 const context=await browser.newContext({viewport:{width:1180,height:820}}),page=await context.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));const root=path.resolve(__dirname,'..'),out=path.join(root,'Preview/test-results');fs.mkdirSync(out,{recursive:true});
 const b=name=>page.getByRole(/^笔记本(开始|插入|绘图|视图)$/.test(name)?'tab':'button',{name,exact:true}),read=()=>page.evaluate(()=>new Promise(resolve=>{const r=indexedDB.open('yejian-notebooks',1);r.onsuccess=()=>{const db=r.result,g=db.transaction('state').objectStore('state').get('library');g.onsuccess=()=>{resolve(g.result);db.close();};};}));
 const saved=()=>page.waitForFunction(()=>document.getElementById('nb-saved').textContent==='已保存在本机');
 const current=d=>d.notebooks.find(b=>b.id===d.notebookID).sections.find(s=>s.id===d.sectionID).pages.find(p=>p.id===d.pageID);
 const exportDownload=async(name,file)=>{await b('导出笔记本').click();const wait=page.waitForEvent('download');await b(name).click();await(await wait).saveAs(file);};
 await page.goto(process.argv[2]||'http://127.0.0.1:8877/');await page.locator('#paper-content p').first().waitFor();
 const readerBefore=await page.evaluate(()=>localStorage.getItem('yejian.reader.preview.v1'));
 await b('更多').click();await b('笔记本模式').click();await b('新建笔记本').waitFor();
 await page.screenshot({path:path.join(out,'notebook-navigation.png')});
 await b('收起笔记导航').click();assert.equal(await page.locator('.nb-nav-column').count(),1);await b('收起笔记导航').click();
 await page.screenshot({path:path.join(out,'notebook-drawing.png')});
 // Save a book, section and page using the visible dialogs.
 await b('笔记本视图').click();await b('导航').click();
 for(const [kind,title] of [['笔记本','测试笔记本'],['分区','绘画练习'],['页面','压力与图片 🖊']]){await b('新建'+kind).click();await page.getByLabel('笔记名称',{exact:true}).fill(title);await b('保存名称').click();}
 await b('收起笔记导航').click();await b('收起笔记导航').click();await b('笔记本绘图').click();
 // One continuous real mouse stroke; force fallback is fixed-width for a mouse.
 const rect=await page.locator('#nb-scroll').boundingBox();let x=rect.x+100,y=rect.y+270;
 await page.mouse.move(x,y);await page.mouse.down();for(let i=1;i<=30;i++)await page.mouse.move(x+i*8,y+Math.sin(i/3)*14);await page.mouse.up();await saved();
 let p=current(await read());assert.equal(p.strokes.length,1);assert.ok(p.strokes[0].points.length>20);assert.equal(p.inkData,null);
 await b('笔记撤销').click();await saved();assert.equal(current(await read()).strokes.length,0);await b('笔记重做').click();await saved();assert.equal(current(await read()).strokes.length,1);
 // Deterministic pen event samples test pressure serialization, not hardware.
 await page.locator('#nb-sheet').evaluate(svg=>{const r=svg.getBoundingClientRect(),base={bubbles:true,pointerId:91,pointerType:'pen',isPrimary:true,button:0};svg.dispatchEvent(new PointerEvent('pointerdown',{...base,clientX:r.left+100,clientY:r.top+410,pressure:.15}));for(let i=1;i<=15;i++)svg.dispatchEvent(new PointerEvent('pointermove',{...base,clientX:r.left+100+i*15,clientY:r.top+410,pressure:i/15}));svg.dispatchEvent(new PointerEvent('pointerup',{...base,clientX:r.left+325,clientY:r.top+410,pressure:0}));});
 await saved();p=current(await read());assert.equal(p.strokes.length,2);assert.ok(new Set(p.strokes[1].points.map(n=>n.width)).size>8);assert.ok(Math.abs(p.strokes[1].points[0].pressure-.15)<.000001);
 await b('笔记本插入').click();await b('文字').click();await page.getByLabel('笔记文字',{exact:true}).fill('文字与手写在同一张画布\n电机 & <公式> 🖊');await b('保存文字').click();await saved();
 const before=current(await read()).elements[0];
 let element=page.locator('[data-element]').first(),box=await element.boundingBox();await page.mouse.move(box.x+30,box.y+30);await page.mouse.down();await page.mouse.move(box.x+80,box.y+65,{steps:8});await page.mouse.up();await saved();p=current(await read());assert.ok(p.elements[0].x>before.x+20);assert.ok(p.elements[0].y>before.y+20);
 const oldWidth=p.elements[0].width,handle=await page.locator('.nb-handle').boundingBox();await page.mouse.move(handle.x+handle.width/2,handle.y+handle.height/2);await page.mouse.down();await page.mouse.move(handle.x+handle.width/2+40,handle.y+handle.height/2+30,{steps:5});await page.mouse.up();await saved();assert.ok(current(await read()).elements[0].width>oldWidth);
 const png=Buffer.from(await page.evaluate(()=>{const c=document.createElement('canvas');c.width=80;c.height=60;const g=c.getContext('2d');g.fillStyle='#36b9d4';g.fillRect(0,0,80,60);g.fillStyle='white';g.fillRect(10,10,60,40);return c.toDataURL('image/png').split(',')[1];}),'base64');
 await page.locator('#nb-image').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:png});await page.waitForFunction(()=>document.querySelectorAll('#nb-sheet image').length===1);await saved();assert.ok(current(await read()).elements.at(-1).dataURI.startsWith('data:image/png;base64,'));
 // Extending to the right/bottom keeps all prior points and object coordinates.
 p=current(await read());const ink=JSON.stringify(p.strokes);await page.locator('#nb-scroll').evaluate(s=>{s.scrollLeft=1e7;s.scrollTop=1e7;});await page.waitForFunction(()=>Number(document.getElementById('nb-sheet').getAttribute('width'))>1600);await saved();p=current(await read());assert.ok(p.width>1600&&p.height>2400);assert.equal(JSON.stringify(p.strokes),ink);
 await b('笔记本视图').click();await b('适合宽度').click();await b('隐藏笔记本工具栏').click();assert.equal(await b('笔记本绘图').count(),0);await page.screenshot({path:path.join(out,'notebook-focus.png')});await b('显示笔记本工具栏').click();
 const svgFile=path.join(out,'notebook-export.svg');await exportDownload('当前笔记页 · SVG',svgFile);const svg=fs.readFileSync(svgFile,'utf8');assert.ok(svg.includes('<path'));assert.ok(svg.includes('电机 &amp; &lt;公式&gt; 🖊'));assert.ok(svg.includes('<image'));
 const payload=JSON.parse(Buffer.from(svg.match(/<metadata id="yejian-notebook">([^<]+)<\/metadata>/)[1],'base64'));assert.equal(payload.engine,'yejian-notebook-page-v1');assert.deepEqual(payload.page,current(await read()));
 // Fixture is produced by the browser exporter and consumed by native tests.
 if(process.env.UPDATE_NOTEBOOK_FIXTURE==='1')fs.writeFileSync(path.join(root,'Resources/Fixtures/notebook-browser.svg'),svg);
 const beforeImport=cloneJSON(payload.page);await page.locator('#nb-file').setInputFiles(svgFile);await saved();p=current(await read());assert.notEqual(p.id,beforeImport.id);assert.deepEqual(p.strokes,beforeImport.strokes);assert.deepEqual(p.elements,beforeImport.elements);
 const backupFile=path.join(out,'notebook-backup.json');await exportDownload('完整笔记本备份 · JSON',backupFile);const backup=JSON.parse(fs.readFileSync(backupFile));assert.ok(backup.notebooks.some(b=>b.title==='测试笔记本'));
 await page.locator('#nb-file').setInputFiles(backupFile);await saved();assert.equal((await read()).notebooks.length,backup.notebooks.length*2);
 await page.reload();await page.locator('#paper-content p').first().waitFor();await b('更多').click();await b('笔记本模式').click();await b('笔记本绘图').waitFor();assert.equal((await read()).notebooks.length,backup.notebooks.length*2);
 assert.equal(await page.evaluate(()=>localStorage.getItem('yejian.reader.preview.v1')),readerBefore);
 await page.setViewportSize({width:820,height:1180});await page.screenshot({path:path.join(out,'notebook-portrait.png')});
 const readerAfter=JSON.parse(await page.evaluate(()=>localStorage.getItem('yejian.reader.preview.v1'))),original=JSON.parse(readerBefore);
 for(const key of ['books','notes','bookmarks','currentBook'])assert.deepEqual(readerAfter[key],original[key]);
 assert.deepEqual(errors,[]);await browser.close();
 console.log('PASS: three-level navigation, continuous pressure vectors, ink undo/redo, text drag/resize, embedded images, fixed origin/right-bottom growth, SVG restoration, complete JSON merge/reload, portrait/focus, reader isolation.');
})().catch(e=>{console.error(e);process.exit(1);});
function cloneJSON(v){return JSON.parse(JSON.stringify(v));}
