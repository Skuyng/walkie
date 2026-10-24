const http=require('http'),fs=require('fs'),path=require('path'),{WebSocketServer}=require('ws');
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript','.json':'application/manifest+json','.png':'image/png'};
const srv=http.createServer((q,r)=>{let p=q.url.split('?')[0];if(p=='/')p='/index.html';const f=path.join(__dirname,'public',path.normalize(p));
fs.readFile(f,(e,d)=>{if(e){r.writeHead(404);return r.end()}r.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream','Cache-Control':'no-cache'});r.end(d)})});
const wss=new WebSocketServer({server:srv});
function bc(room,data,except,bin){for(const c of wss.clients)if(c!==except&&c.room===room&&c.readyState===1)c.send(data,{binary:bin})}
function users(room){return [...wss.clients].filter(c=>c.room===room).map(c=>c.name)}
wss.on('connection',ws=>{ws.isAlive=true;ws.on('pong',()=>ws.isAlive=true);
ws.on('message',(d,isBin)=>{if(isBin){if(ws.room)bc(ws.room,d,ws,true);return}
let m;try{m=JSON.parse(d)}catch{return}
if(m.t=='join'){ws.room=String(m.room).slice(0,40).toLowerCase();ws.name=String(m.name).slice(0,30);bc(ws.room,JSON.stringify({t:'users',users:users(ws.room)}),null,false)}
else if(ws.room&&(m.t=='start'||m.t=='stop'))bc(ws.room,JSON.stringify({t:m.t,name:ws.name}),ws,false)});
ws.on('close',()=>{if(ws.room){bc(ws.room,JSON.stringify({t:'stop',name:ws.name}),null,false);bc(ws.room,JSON.stringify({t:'users',users:users(ws.room)}),null,false)}})});
setInterval(()=>{for(const c of wss.clients){if(!c.isAlive)c.terminate();c.isAlive=false;c.ping()}},20000);
const port=process.env.PORT||8080;srv.listen(port,()=>console.log('listening '+port));
