/* Original notebook examples, shared by the native app and web preview. */
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..');let index=0;
const stroke=(xy,color='#202124',tool='pen',width=3)=>{
 // PencilKit treats points as spline controls. Sample straight diagram edges
 // densely so importing them does not turn rectangular circuits into loops.
 const samples=[xy[0]];
 for(let i=1;i<xy.length;i++){const a=xy[i-1],b=xy[i],steps=Math.max(1,Math.ceil(Math.hypot(b[0]-a[0],b[1]-a[1])/6));for(let j=1;j<=steps;j++)samples.push([a[0]+(b[0]-a[0])*j/steps,a[1]+(b[1]-a[1])*j/steps]);}
 return {id:`demo-ink-${++index}`,tool,color,transform:[1,0,0,1,0,0],points:samples.map(([x,y],i)=>({x,y,pressure:0.3+0.7*Math.sin((i+1)/(samples.length+1)*Math.PI),width:width*(0.45+0.55*Math.sin((i+1)/(samples.length+1)*Math.PI)),height:width,time:i*0.03,opacity:1,azimuth:0,altitude:Math.PI/2}))};
};
const text=(id,x,y,width,height,value,fontSize=28,bold=false,color='#202124')=>({id,kind:'text',x,y,width,height,text:value,fontSize,bold,color});
const page=(id,title)=>({id,title,created:'2026-10-04T11:30:00Z',width:1600,height:2400,paper:'white',pattern:'blank',strokes:[],elements:[]});
const main=page('notebook-page-motor','感应电机');
main.elements=[text('heading',80,230,1000,90,'旋转磁场与转子',40,true),text('equation',80,330,900,100,'同步转速  nₛ = 60 f / p',34),text('note',80,440,900,100,'把原理写下来，再画出自己的理解。\n文字、图片和手写放在同一张自由画布上。',26),text('circuit-label',80,650,800,70,'等效电路 · 课堂草图',34,true),text('r1',360,760,100,50,'R₁',25),text('x1',560,760,150,50,'X₁',25),text('branch',565,1010,250,70,'励磁支路',24,false,'#8030A7'),text('canvas-note',80,1220,1000,100,'左上角固定。向右、向下继续写，画布自动扩展。\n用选择工具移动文字和图片；原生套索还可移动笔迹。',26)];
main.strokes.push(stroke([[80,298],[350,298],[600,298]],'#36B9D4','marker',35));
main.strokes.push(stroke([[180,840],[320,840],[320,820],[410,820],[410,860],[320,860],[320,840],[460,840]]));
main.strokes.push(stroke([[460,840],[475,822],[490,860],[505,822],[520,860],[535,822],[550,860],[565,840],[850,840],[850,1100],[180,1100],[180,840]]));
main.strokes.push(stroke([[610,840],[610,930],[590,930],[590,1000],[630,1000],[630,930],[610,930],[610,1100]]));
main.strokes.push(stroke(Array.from({length:55},(_,i)=>[1000+i*6,875+75*Math.sin(i/9)]),'#36B9D4','pen',8));
const pages=[main,page('notebook-page-formula','公式整理'),page('notebook-page-sketch','随手画'),page('notebook-page-review','复习问题'),page('notebook-page-summary','课后总结')];
const doc={engine:'yejian-notebook-v1',version:1,notebooks:[{id:'notebook-motor',title:'电机',color:'#8030A7',sections:[{id:'section-class',title:'课堂笔记',pages},{id:'section-draft',title:'草稿',pages:[page('draft-1','草图 1')]}]},{id:'notebook-drawing',title:'绘画',color:'#DD485E',sections:[{id:'section-drawing',title:'灵感',pages:[page('drawing-1','新画页')]}]}],notebookID:'notebook-motor',sectionID:'section-class',pageID:main.id};
fs.writeFileSync(path.join(root,'Resources/notebook.json'),JSON.stringify(doc,null,2)+'\n');
fs.writeFileSync(path.join(root,'Preview/notebook-data.js'),'window.YEJIAN_NOTEBOOK_DEMO = '+JSON.stringify(doc)+';\n');
