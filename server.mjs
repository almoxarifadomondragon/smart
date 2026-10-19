import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root = path.resolve(fileURLToPath(new URL('./public/', import.meta.url)));
const types = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png'};
http.createServer(async (req,res) => {
  try {
    const url = new URL(req.url,'http://localhost');
    const name = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
    const file = path.resolve(root,'.'+name);
    if (!file.startsWith(root+path.sep)) {res.writeHead(403).end();return;}
    const data = await readFile(file);
    res.writeHead(200,{'Content-Type':types[path.extname(file)] || 'application/octet-stream','X-Content-Type-Options':'nosniff','Cache-Control':'no-cache'}).end(data);
  } catch {res.writeHead(404).end('Arquivo não encontrado');}
}).listen(Number(process.env.PORT || 4173),'127.0.0.1',()=>console.log('Mondragon: http://localhost:4173'));
