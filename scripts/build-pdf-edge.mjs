import {build} from 'esbuild';
import {readFile,writeFile} from 'node:fs/promises';
await build({
 entryPoints:['supabase/functions/import-pdf-order/index.ts'],
 outfile:'tmp/pdf-edge-bundle.js',
 bundle:true,
 format:'esm',
 platform:'neutral',
 target:'esnext',
 external:['https://*','node:*'],
 minify:true,
 legalComments:'inline'
});
const htmlEscape=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const bundle=await readFile('tmp/pdf-edge-bundle.js','utf8');
const migration=await readFile('supabase/migrations/20261123120000_pdf_order_import.sql','utf8');
const lookup=await readFile('supabase/migrations/20261123121000_pdf_box_lookup.sql','utf8');
await writeFile('tmp/pdf-edge-deploy.html','<!doctype html><meta charset="utf-8"><title>Artefatos de implantação SMART</title><label>Edge Function<textarea id="edge">'+htmlEscape(bundle)+'</textarea></label><label>Migração SQL<textarea id="migration">'+htmlEscape(migration)+'</textarea></label><label>Consulta BPZ<textarea id="lookup">'+htmlEscape(lookup)+'</textarea></label>');
console.log('Edge Function empacotada em tmp/pdf-edge-bundle.js');
