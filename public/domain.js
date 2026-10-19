export const pad = n => String(n).padStart(6,'0');
export function parseQuantity(raw) {
  const text = String(raw ?? '').trim();
  if (!/^\d+(?:[.,]\d{1,2})?$/.test(text)) throw new Error('Informe uma quantidade positiva com até 2 casas decimais. Ex.: 1,00.');
  const value = Number(text.replace(',','.'));
  if (!Number.isFinite(value) || value <= 0 || value > 999999) throw new Error('A quantidade deve ser maior que zero e no máximo 999999.');
  return value;
}
export const formatQty = value => Number(value).toLocaleString('pt-BR',{useGrouping:false,minimumFractionDigits:2,maximumFractionDigits:2});
export const totalQty = items => items.reduce((sum,item)=>sum+Math.round(item.qty*100),0)/100;
export function manifestCsv(doc) {
  const rows = [['Separação','BMA','Projeto','Estação','Quantidade','Pedido de compras','Item do pedido','Prefixo QR','Caixa','Leitura','Almoxarife'],
    ...doc.items.map(i=>[pad(doc.number),i.code,i.project,i.station,formatQty(i.qty),i.purchase_order||'',i.purchase_order_item||'',i.qr_prefix||'',doc.boxes.find(b=>b.id===i.box)?.name,new Date(i.scanned_at).toLocaleString('pt-BR',{dateStyle:'short',timeStyle:'short'}),i.operator])];
  return '\ufeff'+rows.map(row=>row.map(v=>'"'+String(v??'').replace(/^[=+@-]/,"'$&").replace(/"/g,'""')+'"').join(';')).join('\r\n');
}
export function validatePurchase(order='',line='') {
  if (!order && !line) return;
  if (!/^\d{1,40}$/.test(order) || !/^\d{1,20}$/.test(line)) throw new Error('Preencha o número do pedido de compras e o item do pedido usando apenas números.');
}
export function parseCode(raw) {
  const code = raw.trim().toUpperCase();
  if (!/^BMA\d{7}$/.test(code)) throw new Error('Informe um código BMA seguido de 7 números. Ex.: BMA0001979.');
  return code;
}
export function parseQR(raw) {
  const text = raw.trim();
  if (/^BMA\d{7}$/i.test(text)) return {code:parseCode(text)};
  if (text.includes('$')) {
    const parts = text.split('$').map(part=>part.trim());
    if (parts.length!==7 || parts.some(part=>!part)) throw new Error('QR incompleto: esperado prefixo$BMA$projeto$estação$quantidade$pedido$item.');
    const [qr_prefix,rawCode,project,station,rawQty,purchase_order,purchase_order_item] = parts;
    if (qr_prefix.length>80 || project.length>120 || station.length>120) throw new Error('QR contém campos muito longos.');
    validatePurchase(purchase_order,purchase_order_item);
    return {code:parseCode(rawCode),project,station,qty:parseQuantity(rawQty),purchase_order,purchase_order_item,qr_prefix};
  }
  let values;
  try { values = JSON.parse(text); } catch {
    values = {};
    for (const part of text.split(/[;\n|]+/)) {
      const match = part.match(/^\s*([^:=]+)\s*[:=]\s*(.+?)\s*$/);
      if (match) values[match[1].trim().toLowerCase()] = match[2];
    }
  }
  if (!values || typeof values !== 'object') throw new Error('Formato do QR code não reconhecido.');
  values = Object.fromEntries(Object.entries(values).map(([k,v])=>[k.toLowerCase(),v]));
  const code = parseCode(String(values.bma ?? values.codigo ?? values['código'] ?? values.code ?? ''));
  const project = String(values.projeto ?? values.project ?? '').trim();
  const station = String(values['estação'] ?? values.estacao ?? values.station ?? '').trim();
  const qty = parseQuantity(values.quantidade ?? values.qty ?? 1);
  const purchase_order = String(values.purchase_order ?? values.pedido ?? '').trim();
  const purchase_order_item = String(values.purchase_order_item ?? values.item_pedido ?? '').trim();
  validatePurchase(purchase_order,purchase_order_item);
  return {code,project,station,qty,...(purchase_order?{purchase_order,purchase_order_item}:{})};
}
export function validateManifest(doc) {
  if (!doc.project?.trim() || !doc.station?.trim()) throw new Error('Preencha o projeto e a estação.');
  if (!doc.items.length) throw new Error('Adicione ao menos um item.');
  if (!doc.boxes.length) throw new Error('Crie ao menos uma caixa.');
  for (const item of doc.items) {
    parseCode(item.code);
    if (!item.project?.trim() || !item.station?.trim()) throw new Error('Todos os itens precisam ter projeto e estação.');
    parseQuantity(item.qty);
    validatePurchase(item.purchase_order,item.purchase_order_item);
    if (!doc.boxes.some(box=>box.id===item.box)) throw new Error('Todos os itens precisam estar em uma caixa.');
  }
  if (doc.boxes.some(box=>!doc.items.some(item=>item.box===box.id))) throw new Error('Remova as caixas vazias antes de confirmar.');
  return true;
}
