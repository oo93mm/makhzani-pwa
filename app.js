const DB='makhzani-local-v1';
let products=[],events=[];
const $=s=>document.querySelector(s);
const money=n=>new Intl.NumberFormat('ar-IQ').format(Number(n)||0)+' د.ع';
const stamp=()=>new Date().toLocaleString('ar-IQ');
function load(){try{products=JSON.parse(localStorage.getItem(DB+'_p')||'[]');events=JSON.parse(localStorage.getItem(DB+'_e')||'[]')}catch{products=[];events=[]}}
function save(){localStorage.setItem(DB+'_p',JSON.stringify(products));localStorage.setItem(DB+'_e',JSON.stringify(events));render()}
function render(){
 $('#productsCount').textContent=products.length;
 $('#stockValue').textContent=money(products.reduce((s,p)=>s+p.buy*p.qty,0));
 const today=new Date().toDateString();
 $('#todaySales').textContent=money(events.filter(e=>e.type==='بيع'&&new Date(e.time).toDateString()===today).reduce((s,e)=>s+e.total,0));
 const q=$('#search').value.trim().toLowerCase();
 const shown=products.filter(p=>(p.name+' '+p.code+' '+p.note).toLowerCase().includes(q));
 $('#productList').innerHTML=shown.map(p=>`<article class="product">${p.photo?`<img src="${p.photo}" alt="">`:'<div class="placeholder">م</div>'}<div class="product-info"><strong>${esc(p.name)}</strong><small>${esc(p.code||'بدون كود')} · شراء ${money(p.buy)} · بيع ${money(p.sell)}</small><small>${esc(p.note||'')}</small></div><span class="stock">${p.qty} قطعة</span></article>`).join('');
 $('#emptyInventory').classList.toggle('hidden',shown.length>0);
 $('#saleProduct').innerHTML='<option value="">اختر المنتج</option>'+products.map(p=>`<option value="${p.id}">${esc(p.name)} — متوفر ${p.qty}</option>`).join('');
 $('#historyList').innerHTML=events.slice().reverse().map(e=>`<div class="event"><strong>${esc(e.type)}: ${esc(e.name)}</strong><div>${e.qty} قطعة · ${money(e.total)}</div><small>${esc(e.time)}</small></div>`).join('');
 $('#emptyHistory').classList.toggle('hidden',events.length>0);
}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
document.querySelectorAll('.tab').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.panel').forEach(x=>x.classList.toggle('hidden',x.id!==b.dataset.tab))}));
$('#addToggle').onclick=()=>$('#productForm').classList.toggle('hidden');
$('#cancelAdd').onclick=()=>$('#productForm').classList.add('hidden');
$('#search').oninput=render;
$('#productForm').onsubmit=async e=>{e.preventDefault();const f=e.currentTarget,d=new FormData(f);let photo='';const file=d.get('photo');if(file&&file.size){if(file.size>1200000){alert('حجم الصورة كبير. اختَر صورة أقل من 1.2MB.');return}photo=await new Promise((ok,no)=>{const r=new FileReader();r.onload=()=>ok(r.result);r.onerror=no;r.readAsDataURL(file)})}
products.push({id:crypto.randomUUID?crypto.randomUUID():String(Date.now()),name:d.get('name').trim(),code:d.get('code').trim(),note:d.get('note').trim(),buy:+d.get('buy'),sell:+d.get('sell'),qty:+d.get('qty'),photo});
events.push({type:'إضافة مخزون',name:d.get('name').trim(),qty:+d.get('qty'),total:(+d.get('buy'))*(+d.get('qty')),time:stamp()});save();f.reset();f.classList.add('hidden')};
$('#saleProduct').onchange=()=>{const p=products.find(x=>x.id===$('#saleProduct').value);$('#saleHint').textContent=p?`سعر البيع: ${money(p.sell)} — المتوفر: ${p.qty} قطعة`:'اختر منتجاً لعرض السعر والكمية المتوفرة.'};
$('#saleForm').onsubmit=e=>{e.preventDefault();const f=e.currentTarget,id=$('#saleProduct').value,p=products.find(x=>x.id===id),qty=+new FormData(f).get('qty');if(!p)return alert('اختَر منتجاً أولاً');if(qty<1||qty>p.qty)return alert('الكمية المطلوبة غير متوفرة');p.qty-=qty;events.push({type:'بيع',name:p.name,qty,total:qty*p.sell,time:stamp()});save();f.reset();$('#saleHint').textContent='تم تسجيل البيع وخصم الكمية.'};
load();render();
if('serviceWorker' in navigator && location.protocol!=='file:')navigator.serviceWorker.register('./sw.js').catch(()=>{});
