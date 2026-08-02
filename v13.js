"use strict";

const V13_MOCK_MANGAS=[
  {id:"mock-1",title:"Цаг хугацааны цэцэг",genres:["Romance","Fantasy"],cover_url:"assets/mock-1.svg",description:"Өнгөрснөө өөрчлөх боломж олдсон нэгэн бүсгүйн түүх."},
  {id:"mock-2",title:"Шөнийн гэрээ",genres:["Mystery","Drama"],cover_url:"assets/mock-2.svg",description:"Нууц гэрээ, алдагдсан дурсамжийн мөрөөр."},
  {id:"mock-3",title:"Эргэн ирсэн гүнж",genres:["Historical","Romance"],cover_url:"assets/mock-3.svg",description:"Хаант улсын хувь заяаг өөрчлөх хоёр дахь амьдрал."},
  {id:"mock-4",title:"Ногоон сарны нууц",genres:["Fantasy","Adventure"],cover_url:"assets/mock-4.svg",description:"Сарны гэрэлд нээгддэг эртний хаалга."},
  {id:"mock-5",title:"Хайрын протокол",genres:["School Life","Comedy"],cover_url:"assets/mock-5.svg",description:"Хайрыг алгоритмаар тооцож болох уу?"},
  {id:"mock-6",title:"Zero Day",genres:["Action","Sci-Fi"],cover_url:"assets/mock-6.svg",description:"Хотыг бүхэлд нь өөрчлөх кибер халдлага."}
];

let v13ChapterFiles=[];
let v13RejectRequestId=null;
let v13CoverObjectUrl=null;
let v13GamificationLoaded=false;
let v13HashOpened=false;

function v13Init(){
  setupPasswordToggle();
  setupMobileNavigation();
  renderGuestMockCatalog();
  setupProtectionDeterrence();
  setupReaderControls();
  setupCoverPreview();
  setupGenrePicker();
  setupChapterDropzone();
  setupLegalUi();
  setupAdminRejectDialog();
  installFunctionEnhancements();
  renderSkeletons();
  setTimeout(()=>{if(typeof db==="undefined"||!db)document.body.classList.add("database-offline")},1000);
}

function setupPasswordToggle(){
  const btn=document.getElementById("passwordToggle"),input=document.getElementById("password");
  if(!btn||!input)return;
  btn.addEventListener("click",()=>{const show=input.type==="password";input.type=show?"text":"password";btn.textContent=show?"Нуух":"Харах";btn.setAttribute("aria-label",show?"Нууц үг нуух":"Нууц үг харуулах")});
}

function setupMobileNavigation(){
  const btn=document.getElementById("mobileNavToggle"),nav=document.getElementById("mainNav");
  if(!btn||!nav)return;
  const sync=()=>btn.classList.toggle("hidden",nav.classList.contains("hidden"));
  new MutationObserver(sync).observe(nav,{attributes:true,attributeFilter:["class"]});sync();
  btn.addEventListener("click",()=>nav.classList.toggle("mobile-open"));
  nav.addEventListener("click",()=>nav.classList.remove("mobile-open"));
}

function renderGuestMockCatalog(){
  const root=document.getElementById("guestDemoGrid");if(!root)return;
  root.innerHTML=V13_MOCK_MANGAS.map(m=>`<article class="guest-demo-card" data-mock-manga="${m.id}"><img src="${m.cover_url}" alt="${m.title}" loading="lazy"><h3>${m.title}</h3><p>${m.genres.join(" · ")}</p></article>`).join("");
  root.addEventListener("click",e=>{const card=e.target.closest("[data-mock-manga]");if(!card)return;const m=V13_MOCK_MANGAS.find(x=>x.id===card.dataset.mockManga);if(!m)return;const dialog=document.getElementById("mangaDialog"),detail=document.getElementById("mangaDetail");detail.innerHTML=`<div class="manga-detail-hero"><img class="detail-backdrop" src="${m.cover_url}" alt=""><div class="detail-shade"></div><img class="detail-cover" src="${m.cover_url}" alt="${m.title}"><div class="detail-copy"><span class="eyebrow">Demo preview</span><h2>${m.title}</h2><div class="tag-row">${m.genres.map(g=>`<span class="tag">${g}</span>`).join("")}</div><p>${m.description}</p><div class="mock-mode-banner">Энэ бол туршилтын өгөгдөл. Бодит бүлэг уншихын тулд Supabase холболт болон нэвтрэлт шаардлагатай.</div></div></div>`;dialog.showModal()});
}

function renderSkeletons(){
  ["latestGrid","top10Grid","completedGrid"].forEach(id=>{const el=document.getElementById(id);if(!el||el.children.length)return;el.setAttribute("aria-busy","true");el.innerHTML=Array.from({length:id==="top10Grid"?5:4},()=>'<div><div class="skeleton-card"></div><div class="skeleton-line"></div><div class="skeleton-line short"></div></div>').join("")});
}
function clearSkeletonState(){["latestGrid","top10Grid","completedGrid","libraryGrid"].forEach(id=>document.getElementById(id)?.setAttribute("aria-busy","false"))}

function setupProtectionDeterrence(){
  const reader=document.getElementById("readerOverlay");if(!reader)return;
  const warn=()=>{const n=document.getElementById("readerProtectionNotice");if(!n)return;n.classList.remove("hidden");setTimeout(()=>n.classList.add("hidden"),1800)};
  reader.addEventListener("contextmenu",e=>{if(e.target.closest(".reader-page")){e.preventDefault();warn()}});
  reader.addEventListener("dragstart",e=>{if(e.target.closest(".reader-page"))e.preventDefault()});
  document.addEventListener("keydown",e=>{if(reader.classList.contains("hidden"))return;const key=e.key.toLowerCase();if((e.ctrlKey||e.metaKey)&&["s","p","u"].includes(key)){e.preventDefault();warn()}if(key==="printscreen")warn()});
  document.addEventListener("visibilitychange",()=>reader.classList.toggle("capture-shield",document.hidden&&!reader.classList.contains("hidden")));
}

function updateReaderWatermark(){
  const wm=document.getElementById("readerWatermark");if(!wm)return;
  const identity=state?.user?.email||state?.profile?.display_name||"MangaVerse";
  const stamp=new Date().toLocaleString("mn-MN");
  const svg=`<svg xmlns='http://www.w3.org/2000/svg' width='330' height='190'><g transform='rotate(-24 165 95)'><text x='18' y='82' fill='white' font-size='14' font-family='Arial'>${escapeXml(identity)}</text><text x='18' y='104' fill='white' font-size='10' font-family='Arial'>${escapeXml(stamp)}</text></g></svg>`;
  wm.style.backgroundImage=`url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
}
function escapeXml(v){return String(v).replace(/[<>&'\"]/g,c=>({"<":"&lt;",">":"&gt;","&":"&amp;","'":"&apos;",'"':"&quot;"}[c]))}

function setupReaderControls(){
  const reader=document.getElementById("readerOverlay"),themeBtn=document.getElementById("readerThemeBtn"),range=document.getElementById("readerWidthRange"),full=document.getElementById("readerFullscreenBtn");if(!reader)return;
  const themes=["dark","light","sepia"];let theme=localStorage.getItem("mangaverse-reader-theme")||"dark";
  const apply=()=>{reader.dataset.readerTheme=theme;themeBtn.textContent=theme==="dark"?"☾ Dark":theme==="light"?"☀ Light":"◐ Sepia"};apply();
  themeBtn?.addEventListener("click",()=>{theme=themes[(themes.indexOf(theme)+1)%themes.length];localStorage.setItem("mangaverse-reader-theme",theme);apply()});
  range?.addEventListener("input",()=>reader.style.setProperty("--reader-max-width",`${range.value}%`));
  full?.addEventListener("click",async()=>{try{if(!document.fullscreenElement)await reader.requestFullscreen();else await document.exitFullscreen()}catch{showToast("Fullscreen горим нээгдсэнгүй.","error")}});
}

function prepareReaderImages(){
  const images=[...document.querySelectorAll(".reader-page")];
  images.forEach((img,i)=>{img.draggable=false;img.loading=i<3?"eager":"lazy";img.decoding="async"});
  const preload=(index)=>{for(let i=index+1;i<=Math.min(images.length-1,index+2);i++){const url=images[i].src;if(!url)continue;const im=new Image();im.src=url;im.decode?.().catch(()=>{})}};
  const observer=new IntersectionObserver(entries=>entries.forEach(entry=>{if(entry.isIntersecting){const i=images.indexOf(entry.target);preload(i)}}),{root:document.getElementById("readerOverlay"),rootMargin:"700px 0px"});
  images.forEach(img=>observer.observe(img));
}

function setupCoverPreview(){
  const input=document.getElementById("mangaCover"),img=document.getElementById("mangaCoverPreviewImage"),placeholder=document.querySelector("#mangaCoverPreview .cover-preview-placeholder");if(!input||!img)return;
  input.addEventListener("change",()=>{if(v13CoverObjectUrl)URL.revokeObjectURL(v13CoverObjectUrl);const f=input.files?.[0];if(!f){img.classList.add("hidden");placeholder?.classList.remove("hidden");return}v13CoverObjectUrl=URL.createObjectURL(f);img.src=v13CoverObjectUrl;img.classList.remove("hidden");placeholder?.classList.add("hidden")});
}

function setupGenrePicker(){
  const root=document.getElementById("genrePicker"),input=document.getElementById("mangaGenres");if(!root||!input)return;
  const sync=()=>{const set=new Set(input.value.split(",").map(x=>x.trim()).filter(Boolean));root.querySelectorAll("[data-genre]").forEach(b=>b.classList.toggle("active",set.has(b.dataset.genre)))};
  root.addEventListener("click",e=>{const b=e.target.closest("[data-genre]");if(!b)return;const values=new Set(input.value.split(",").map(x=>x.trim()).filter(Boolean));values.has(b.dataset.genre)?values.delete(b.dataset.genre):values.add(b.dataset.genre);input.value=[...values].join(", ");sync()});input.addEventListener("input",sync);sync();
}

function setupChapterDropzone(){
  const input=document.getElementById("quickChapterPages"),zone=document.getElementById("chapterDropzone"),list=document.getElementById("chapterSortList");if(!input||!zone||!list)return;
  const accept=files=>{const valid=[...files].filter(f=>f.type.startsWith("image/"));v13ChapterFiles=[...v13ChapterFiles,...valid].slice(0,250);syncChapterInput();renderChapterFiles()};
  input.addEventListener("change",()=>{v13ChapterFiles=[...input.files];renderChapterFiles()});
  zone.addEventListener("click",()=>input.click());zone.addEventListener("keydown",e=>{if(e.key==="Enter"||e.key===" "){e.preventDefault();input.click()}});
  ["dragenter","dragover"].forEach(t=>zone.addEventListener(t,e=>{e.preventDefault();zone.classList.add("dragover")}));["dragleave","drop"].forEach(t=>zone.addEventListener(t,e=>{e.preventDefault();zone.classList.remove("dragover")}));zone.addEventListener("drop",e=>accept(e.dataTransfer.files));
  list.addEventListener("click",e=>{const b=e.target.closest("[data-remove-file]");if(!b)return;v13ChapterFiles.splice(Number(b.dataset.removeFile),1);syncChapterInput();renderChapterFiles()});
  list.addEventListener("dragstart",e=>{const item=e.target.closest("[data-file-index]");if(!item)return;item.classList.add("dragging");e.dataTransfer.setData("text/plain",item.dataset.fileIndex)});
  list.addEventListener("dragend",e=>e.target.closest("[data-file-index]")?.classList.remove("dragging"));
  list.addEventListener("dragover",e=>e.preventDefault());
  list.addEventListener("drop",e=>{e.preventDefault();const from=Number(e.dataTransfer.getData("text/plain")),target=e.target.closest("[data-file-index]");if(!target||Number.isNaN(from))return;const to=Number(target.dataset.fileIndex);const [moved]=v13ChapterFiles.splice(from,1);v13ChapterFiles.splice(to,0,moved);syncChapterInput();renderChapterFiles()});
}
function syncChapterInput(){const input=document.getElementById("quickChapterPages");if(!input)return;try{const dt=new DataTransfer();v13ChapterFiles.forEach(f=>dt.items.add(f));input.files=dt.files}catch{}}
function renderChapterFiles(){
  const list=document.getElementById("chapterSortList"),summary=document.getElementById("chapterFileSummary");if(!list)return;
  summary.textContent=v13ChapterFiles.length?`${v13ChapterFiles.length} зураг · чирж дарааллыг солино`:'Зураг сонгоогүй';
  list.innerHTML=v13ChapterFiles.map((f,i)=>`<article class="chapter-sort-item" draggable="true" data-file-index="${i}"><img src="${URL.createObjectURL(f)}" alt="${i+1}-р зураг"><span>${i+1}</span><button type="button" data-remove-file="${i}" aria-label="Устгах">×</button></article>`).join("");
}
function clearChapterFiles(){v13ChapterFiles=[];syncChapterInput();renderChapterFiles()}

function setupLegalUi(){document.getElementById("openDmcaBtn")?.addEventListener("click",()=>document.getElementById("dmcaDialog")?.showModal())}

function setupAdminRejectDialog(){
  document.getElementById("adminRejectForm")?.addEventListener("submit",async e=>{e.preventDefault();const reason=document.getElementById("adminRejectReason").value.trim(),msg=document.getElementById("adminRejectMessage");if(!reason){setMessage(msg,"Татгалзсан шалтгаанаа бичнэ үү.","error");return}const btn=e.currentTarget.querySelector('button[type="submit"]');setButtonLoading(btn,true,"Хадгалж байна...");try{const{error}=await db.rpc("review_membership_request",{p_request_id:v13RejectRequestId,p_approve:false,p_admin_note:reason});if(error)throw error;document.getElementById("adminRejectDialog").close();showToast("Хүсэлтэд татгалзлаа.","success");await Promise.all([loadAdminRequests(),loadAdminDashboard()])}catch(err){setMessage(msg,err.message||"Төлөв өөрчилж чадсангүй.","error")}finally{setButtonLoading(btn,false)}})
}

function installFunctionEnhancements(){
  if(typeof loadHomeSections==="function"){
    const original=loadHomeSections;loadHomeSections=async function(...args){renderSkeletons();try{return await original.apply(this,args)}finally{clearSkeletonState()}}
  }
  if(typeof toggleFavorite==="function"){
    const original=toggleFavorite;toggleFavorite=async function(id){const target=document.querySelector(`[data-favorite="${CSS.escape(id)}"]`);target?.classList.add("v13-pop");const before=state.favoriteIds.has(id);await original(id);const now=state.favoriteIds.has(id);showToast(now&&!before?"Амжилттай хадгаллаа.":!now&&before?"Хадгалснаас хаслаа.":"Хадгалах төлөв шинэчлэгдлээ.","success");if(now&&!before)awardGamification("favorite_manga",id);setTimeout(()=>target?.classList.remove("v13-pop"),450)}
  }
  if(typeof openReader==="function"){
    const original=openReader;openReader=async function(...args){await original.apply(this,args);updateReaderWatermark();prepareReaderImages();const chapterId=state.reader?.chapter?.id;if(chapterId)awardGamification("read_chapter",chapterId)}
  }
  if(typeof submitChapterComment==="function"){
    const original=submitChapterComment;submitChapterComment=async function(e){const chapterId=state.reader?.chapter?.id;await original(e);if(chapterId&&!document.getElementById("chapterCommentBody")?.value)awardGamification("comment",chapterId)}
  }
  if(typeof quickCreateChapter==="function"){
    const original=quickCreateChapter;quickCreateChapter=async function(e){await original(e);if(!document.getElementById("createChapterDialog")?.open)clearChapterFiles()}
  }
  if(typeof resetCreateMangaDialog==="function"){
    const original=resetCreateMangaDialog;resetCreateMangaDialog=function(...args){const result=original.apply(this,args);document.getElementById("mangaCoverPreviewImage")?.classList.add("hidden");document.querySelector("#mangaCoverPreview .cover-preview-placeholder")?.classList.remove("hidden");document.querySelectorAll("#genrePicker button").forEach(b=>b.classList.remove("active"));return result}
  }
  if(typeof loadStudio==="function"){
    const original=loadStudio;loadStudio=async function(...args){const result=await original.apply(this,args);await loadTranslatorStats();return result}
  }
  if(typeof renderAdminRequests==="function")renderAdminRequests=renderAdminRequestsV13;
  if(typeof reviewMembershipRequest==="function"){
    const original=reviewMembershipRequest;reviewMembershipRequest=async function(id,approve){if(approve)return original(id,true);v13RejectRequestId=id;document.getElementById("adminRejectReason").value="";setMessage(document.getElementById("adminRejectMessage"));document.getElementById("adminRejectDialog").showModal()}
  }
  if(typeof openManga==="function"){
    const original=openManga;openManga=async function(id){await original(id);if(state.currentManga){updateDynamicMeta(state.currentManga);history.replaceState({},"",`#manga/${encodeURIComponent(state.currentManga.slug||state.currentManga.id)}`)}}
  }
  if(typeof showView==="function"){
    const original=showView;showView=function(view){const result=original(view);if(view==="profile")loadGamification();if(view==="studio")loadTranslatorStats();return result}
  }
  if(typeof handleSession==="function"){
    const original=handleSession;handleSession=async function(session){const result=await original(session);if(session){await awardGamification("daily_login",session.user.id);loadGamification();openMangaFromHash()}return result}
  }
}

async function awardGamification(type,entityId){if(!db||!state?.user)return;try{await db.rpc("award_gamification",{p_event_type:type,p_entity_id:entityId})}catch{}}
async function loadGamification(){
  if(!db||!state?.user)return;try{const{data,error}=await db.rpc("get_my_gamification");if(error)throw error;renderGamification(data||{})}catch(err){console.warn("Gamification:",err.message)}
}
function renderGamification(data){
  const xp=Number(data.total_xp||0),rank=data.rank||"Шинэков",next=Number(data.next_rank_xp||100),base=Number(data.rank_base_xp||0),progress=next>base?Math.min(100,Math.max(0,(xp-base)/(next-base)*100)):100;
  document.getElementById("gamificationRank").textContent=rank;document.getElementById("gamificationXp").textContent=`${xp} XP`;document.getElementById("gamificationXpBar").style.width=`${progress}%`;document.getElementById("gamificationNextRank").textContent=next>xp?`Дараагийн цол хүртэл ${next-xp} XP.`:"Хамгийн дээд цолыг авсан байна.";
  const q=data.quests||{};const quests=[{name:"3 бүлэг унших",value:Number(q.reads||0),goal:3},{name:"1 сэтгэгдэл үлдээх",value:Number(q.comments||0),goal:1},{name:"1 манга хадгалах",value:Number(q.favorites||0),goal:1}];
  document.getElementById("dailyQuestList").innerHTML=quests.map(x=>`<div class="daily-quest ${x.value>=x.goal?"done":""}"><strong>${x.value>=x.goal?"✓ ":""}${x.name}</strong><span>${Math.min(x.value,x.goal)}/${x.goal}</span></div>`).join("")
}

async function loadTranslatorStats(){
  if(!db||state?.profile?.role!=="translator")return;try{const{data,error}=await db.rpc("get_my_team_stats");if(error)throw error;const s=data||{};const map={translatorMetricMangas:s.mangas,translatorMetricChapters:s.chapters,translatorMetricReads:s.reads,translatorMetricFavorites:s.favorites,translatorMetricComments:s.comments,translatorMetricSuperLikes:s.super_likes};for(const[id,val]of Object.entries(map)){const el=document.getElementById(id);if(el)el.textContent=Number(val||0).toLocaleString("mn-MN")}}catch(err){console.warn("Team stats:",err.message)}
}

function renderAdminRequestsV13(){
  const root=document.getElementById("adminRequests");if(!root)return;const filter=document.getElementById("adminRequestFilter")?.value||"all",items=filter==="all"?state.adminRequests:state.adminRequests.filter(r=>r.status===filter);if(!items.length){root.innerHTML='<div class="empty-state"><div class="empty-icon">✓</div><h3>Хүсэлт алга</h3><p>Шинэ төлбөрийн хүсэлт ирэхэд энд харагдана.</p></div>';return}
  root.innerHTML=`<div class="admin-request-table-wrap"><table class="admin-request-table"><thead><tr><th>Хэрэглэгч</th><th>Багц / дүн</th><th>Огноо</th><th>Төлөв</th><th>Гүйлгээ</th><th>Үйлдэл</th></tr></thead><tbody>${items.map(r=>{const plan=state.membershipPlans.find(p=>p.code===r.plan_code),meta=membershipStatusMeta(r.status);return`<tr><td><strong>${escapeHTML(r.display_name)}</strong><br><small>${escapeHTML(r.sender_name||"")}</small></td><td>${escapeHTML(plan?.name||r.plan_code)}<br><strong>${escapeHTML(formatMoney(r.amount_mnt))}</strong></td><td>${escapeHTML(formatDate(r.created_at))}<br><small>${escapeHTML(r.transfer_date||"")}</small></td><td><span class="status-pill ${meta.className}">${meta.label}</span>${r.admin_note?`<br><small>${escapeHTML(r.admin_note)}</small>`:""}</td><td>${escapeHTML(r.transfer_reference||"")}</td><td><div class="admin-table-actions"><button class="btn btn-ghost" type="button" data-open-receipt="${escapeHTML(r.receipt_path)}">Баримт</button>${r.status==="pending"?`<button class="btn btn-primary" type="button" data-review-request="${escapeHTML(r.id)}" data-review-action="approve">Зөвшөөрөх</button><button class="btn btn-danger" type="button" data-review-request="${escapeHTML(r.id)}" data-review-action="reject">Татгалзах</button>`:""}</div></td></tr>`}).join("")}</tbody></table></div>`
}

function updateDynamicMeta(manga){
  document.title=`${manga.title} — MangaVerse`;const desc=(manga.description||"Монгол орчуулгатай манга").slice(0,160);setMeta("meta[name='description']","content",desc);setMeta("meta[property='og:title']","content",`${manga.title} — MangaVerse`);setMeta("meta[property='og:description']","content",desc);setMeta("meta[property='og:image']","content",manga.cover_url||"");setMeta("meta[name='twitter:title']","content",`${manga.title} — MangaVerse`);setMeta("meta[name='twitter:description']","content",desc)
}
function setMeta(selector,attr,value){const el=document.querySelector(selector);if(el)el.setAttribute(attr,value)}
function restoreBaseMeta(){document.title="MangaVerse — Монгол манга платформ";history.replaceState({},"",location.pathname+location.search)}
function openMangaFromHash(){if(v13HashOpened||!location.hash.startsWith("#manga/"))return;const slug=decodeURIComponent(location.hash.slice(7));const manga=state.mangas.find(m=>(m.slug||m.id)===slug);if(manga){v13HashOpened=true;openManga(manga.id)}}

document.addEventListener("DOMContentLoaded",v13Init);
document.getElementById("mangaDialog")?.addEventListener("close",restoreBaseMeta);
