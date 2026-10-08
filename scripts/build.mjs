import {mkdir,copyFile,writeFile} from 'node:fs/promises';
const url=process.env.SUPABASE_URL||'';
const key=process.env.SUPABASE_PUBLISHABLE_KEY||'';
if(!/^https:\/\/[\w-]+\.supabase\.co\/?$/.test(url)||!key||(!key.startsWith('sb_publishable_')&&!key.startsWith('eyJ')))throw Error('Faltan SUPABASE_URL y SUPABASE_PUBLISHABLE_KEY (solo clave pública).');
await mkdir('dist',{recursive:true});
for(const f of ['index.html','styles.css','app.js'])await copyFile(f,`dist/${f}`);
await writeFile('dist/config.js',`window.AULAEVAL_CONFIG=${JSON.stringify({url,key})};\n`);
console.log('Compilación lista en dist/ (solo credenciales públicas)');
