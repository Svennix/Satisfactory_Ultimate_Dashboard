'use strict';
const $ = s => document.querySelector(s);
const fmtDur = s => {
  s = Math.max(0, Math.round(s));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s/60) + 'm';
  if (s < 86400) return Math.floor(s/3600) + 'h ' + Math.floor((s%3600)/60) + 'm';
  return Math.floor(s/86400) + 'd ' + Math.floor((s%86400)/3600) + 'h';
};
const fmtBytes = b => b < 1048576 ? (b/1024).toFixed(0)+' KB' : (b/1048576).toFixed(2)+' MB';
const ago = iso => { if(!iso) return '—'; const d=(Date.now()-new Date(iso))/1000;
  return d<60?'just now':d<3600?Math.floor(d/60)+'m ago':d<86400?Math.floor(d/3600)+'h ago':Math.floor(d/86400)+'d ago'; };
const asArray = x => x==null ? [] : (Array.isArray(x) ? x : [x]);

async function getJSON(u){ const r = await fetch(u + '?_=' + Date.now()); if(!r.ok) throw new Error(r.status); return r.json(); }
async function getJSONL(u){
  const r = await fetch(u + '?_=' + Date.now()); if(!r.ok) return [];
  const t = await r.text();
  return t.split('\n').filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
}

const charts = {};
function lineChart(id, label, color){
  const ctx = $(id).getContext('2d');
  return new Chart(ctx, {
    type:'line',
    data:{ labels:[], datasets:[{ label, data:[], borderColor:color, backgroundColor:color+'22',
      borderWidth:2, pointRadius:0, tension:.25, fill:true }] },
    options:{ animation:false, responsive:true, maintainAspectRatio:false,
      scales:{ x:{ ticks:{color:'#8b949e',maxTicksLimit:6}, grid:{color:'#1b212b'} },
               y:{ ticks:{color:'#8b949e'}, grid:{color:'#1b212b'}, beginAtZero:true } },
      plugins:{ legend:{display:false} } }
  });
}

function multiChart(id){
  const ctx = $(id).getContext('2d');
  return new Chart(ctx, {
    type:'line',
    data:{ labels:[], datasets:[
      { label:'CPU %', data:[], borderColor:'#ff8c1a', backgroundColor:'#ff8c1a22', borderWidth:2, pointRadius:0, tension:.25, yAxisID:'y' },
      { label:'RAM MB', data:[], borderColor:'#58a6ff', backgroundColor:'#58a6ff22', borderWidth:2, pointRadius:0, tension:.25, yAxisID:'y1' } ] },
    options:{ animation:false, responsive:true, maintainAspectRatio:false,
      scales:{ x:{ ticks:{color:'#8b949e',maxTicksLimit:6}, grid:{color:'#1b212b'} },
        y:{ position:'left', ticks:{color:'#ff8c1a'}, grid:{color:'#1b212b'}, beginAtZero:true },
        y1:{ position:'right', ticks:{color:'#58a6ff'}, grid:{display:false}, beginAtZero:true } },
      plugins:{ legend:{labels:{color:'#8b949e'}} } }
  });
}

function meter(id, pct, good){
  const el = $(id); el.style.width = Math.min(100,Math.max(0,pct)) + '%';
  el.style.background = good===false ? 'var(--danger)' : good==='warn' ? 'var(--warn)' : 'var(--accent)';
}

async function renderState(){
  const s = await getJSON('data/state.json');
  const sv = s.Server, m = s.Metrics, f = s.FunFacts;
  $('#sessionName').textContent = sv.SessionName || '—';
  $('#updatedAt').textContent = ago(s.UpdatedAt);
  $('#apiState').textContent = s.ApiOnline ? 'API: connected' : 'API: offline (log-only mode)';

  const online = sv.PlayersOnline ?? 0;
  $('#tOnline').textContent = online + ' / ' + (sv.PlayerLimit ?? 4);
  $('#tOnlineNames').textContent = asArray(s.OnlineNow).join(', ') || ' ';
  $('#livePip').classList.toggle('live', !!sv.Running);

  const tps = sv.TickRate;
  $('#tTps').textContent = tps==null ? '—' : tps.toFixed(1);
  meter('#tpsMeter', tps==null?0:(tps/30*100), tps==null?true:(tps>=25?true:tps>=15?'warn':false));

  $('#tCpu').textContent = (m.CpuPercent ?? 0) + '%';
  meter('#cpuMeter', m.CpuPercent ?? 0, (m.CpuPercent>85)?false:(m.CpuPercent>60)?'warn':true);
  $('#tRam').textContent = (m.RamMB ? (m.RamMB/1024).toFixed(2) : '0') + ' GB';
  $('#tRamSub').textContent = (m.RamPercent ?? 0) + '% of host';

  $('#tTier').textContent = sv.TechTier==null ? '—' : 'Tier ' + sv.TechTier;
  $('#tPhase').textContent = sv.GamePhaseName || (sv.GameDuration!=null ? fmtDur(sv.GameDuration)+' played' : ' ');
  $('#tUptime').textContent = fmtDur(sv.UptimeSec || 0);
  $('#tStarted').textContent = sv.StartedAt ? 'since ' + new Date(sv.StartedAt).toLocaleString([], {hour12:false}) : ' ';

  // fun facts
  const facts = [
    ['Unique players', f.UniquePlayers],
    ['Combined playtime', fmtDur(f.CombinedPlaytimeSec)],
    ['Top player', f.TopPlayer ? `${f.TopPlayer} (${fmtDur(f.TopPlayerSec)})` : '—'],
    ['Longest session', f.LongestSessionName ? `${f.LongestSessionName} — ${fmtDur(f.LongestSessionSec)}` : '—'],
    ['Peak concurrent', f.PeakConcurrent + (f.PeakAt ? ' on ' + new Date(f.PeakAt).toLocaleString([], {hour12:false}) : '')],
    ['Busiest day', f.BusiestDay || '—'],
    ['Busiest hour', f.BusiestHour==null ? '—' : (String(f.BusiestHour).padStart(2,'0')+':00')],
    ['Total sessions', f.TotalSessions],
    ['Save size', s.Save ? fmtBytes(s.Save.Bytes) : '—'],
    ['Game time', sv.GameDuration!=null ? fmtDur(sv.GameDuration) : '—'],
  ];
  $('#facts').innerHTML = facts.map(([k,v])=>`<li><span class="k">${k}</span><span class="v">${v}</span></li>`).join('');

  renderHeatmap(s.Heatmap);
}

async function renderPlayers(){
  const p = await getJSON('data/players.json');
  const rows = asArray(p.Players).map(pl => `<tr>
    <td><span class="dot ${pl.Online?'on':''}"></span></td>
    <td class="name">${esc(pl.Name)}</td>
    <td>${fmtDur(pl.TotalSeconds)}</td>
    <td>${pl.Sessions}</td>
    <td>${fmtDur(pl.LongestSec)}</td>
    <td>${fmtDur(pl.AvgSec)}</td>
    <td>${pl.Online?'<span style="color:var(--ok)">online</span>':ago(pl.LastSeen)}</td></tr>`).join('');
  $('#playersTable tbody').innerHTML = rows || '<tr><td colspan="7" class="dim">no players yet</td></tr>';
}

const esc = s => String(s).replace(/[&<>]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const escAttr = s => String(s).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

function renderHeatmap(grid){
  if(!grid) return;
  const days=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  let max=1; grid.forEach(r=>r.forEach(v=>{if(v>max)max=v}));
  let html = '<div></div>'; // corner
  for(let h=0;h<24;h++) html += `<div class="hh">${h%3===0?String(h).padStart(2,'0'):''}</div>`;
  for(let d=0;d<7;d++){
    html += `<div class="lbl">${days[d]}</div>`;
    for(let h=0;h<24;h++){
      const v=grid[d][h]||0, a=v/max;
      const col = v===0 ? '#0c0f14' : `rgba(255,140,26,${0.12+a*0.88})`;
      html += `<div class="hc" style="background:${col}" title="${days[d]} ${String(h).padStart(2,'0')}:00 — ${v} min"></div>`;
    }
  }
  $('#heatmap').innerHTML = html;
}

async function renderCharts(){
  const m = await getJSONL('data/metrics.jsonl');
  const sample = m.length>300 ? m.filter((_,i)=>i%Math.ceil(m.length/300)===0) : m;
  const labels = sample.map(x=>new Date(x.t).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',hour12:false}));
  upd(charts.tps, labels, [sample.map(x=>x.tps)]);
  upd(charts.online, labels, [sample.map(x=>x.online)]);
  upd(charts.sys, labels, [sample.map(x=>x.cpu), sample.map(x=>x.ram)]);

  const sv = await getJSONL('data/savesize.jsonl');
  const sl = sv.map(x=>new Date(x.t).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}));
  upd(charts.save, sl, [sv.map(x=>+(x.bytes/1048576).toFixed(3))]);
}
function upd(ch, labels, datas){ if(!ch) return; ch.data.labels=labels; datas.forEach((d,i)=>ch.data.datasets[i].data=d); ch.update('none'); }

async function renderBackups(){
  const b = await getJSON('data/backups.json');
  $('#bkCount').textContent = b.Count;
  $('#bkSize').textContent = fmtBytes(b.TotalBytes);
  $('#bkNewest').textContent = b.Newest ? ago(b.Newest) : '—';
  $('#bkNewestName').textContent = b.NewestName || ' ';
  $('#bkOldest').textContent = b.Oldest ? new Date(b.Oldest).toLocaleDateString() : '—';
  $('#bkNext').textContent = b.NextRun ? new Date(b.NextRun).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}) : '—';
  $('#bkRate').textContent = b.Runs ? Math.round(100*b.Successes/b.Runs)+'%' : '—';
  $('#bkRuns').textContent = b.Runs ? `${b.Successes}/${b.Runs} ok` : 'no runs yet';
  $('#bkPrune').textContent = b.WouldPrune;
  const p=b.Policy;
  $('#bkPolicy').textContent = `Keep every backup from the last ${p.RecentHours}h, then the newest one per day for ${p.Daily} days, per week for ${p.Weekly} weeks, and per month for ${p.Monthly} months. Everything else is pruned automatically after each backup.`;
  $('#bkDir').textContent = b.Dir;

  const badge = r => `<span class="tag ${r||'prune'}">${r||'prune'}</span>`;
  $('#bkTable tbody').innerHTML = asArray(b.Files).map(f=>`<tr>
    <td style="font-family:var(--mono)">${esc(f.Name)}</td>
    <td>${fmtBytes(f.Bytes)}</td>
    <td>${ago(f.Modified)}</td>
    <td>${badge(f.Reason)}</td></tr>`).join('') || '<tr><td colspan="4" class="dim">no backups yet</td></tr>';

  $('#bkHist tbody').innerHTML = asArray(b.History).map(h=>`<tr>
    <td><span class="dot ${h.Verdict==='SUCCESS'?'on':''}" style="${h.Verdict==='SUCCESS'?'':'background:var(--danger);box-shadow:0 0 7px var(--danger)'}"></span></td>
    <td>${esc(h.When)}</td><td>${esc(h.Duration)}</td><td>${esc(h.Trigger)}</td></tr>`).join('') || '<tr><td colspan="4" class="dim">no runs yet</td></tr>';

  const name = b.NewestName || '<backup>.sav';
  $('#bkRestore').innerHTML = `
    <p>Restores run from PowerShell on the server — deliberately not a web button, because loading a save replaces the world for everyone connected. They use the official upload API.</p>
    <ol>
      <li>Connect to the server (Netbird/RDP) and open PowerShell in <code>C:\\satisfactoryserver\\dashboard</code></li>
      <li>List backups: <code>.\\restore.ps1 -List</code></li>
      <li>Upload one to the server <em>without</em> switching the live world: <code>.\\restore.ps1 -Index 1</code></li>
      <li>Upload <em>and</em> load it live (replaces the current world): <code>.\\restore.ps1 -Index 1 -Load</code></li>
    </ol>
    <p class="muted">After an upload you can also load it from the in-game <strong>Server Manager → Manage Saves</strong>. Newest backup: <code>${esc(name)}</code></p>`;
}

let formDirty = false;
async function renderMaintenance(){
  const m = await getJSON('data/maintenance.json');
  const r = m.Restart || {};
  $('#mWatch').textContent = m.Watchdog ? 'ON' : 'off';
  $('#mWatch').style.color = m.Watchdog ? 'var(--ok)' : 'var(--dim)';
  $('#mNext').textContent = (r.Enabled && m.NextRestart) ? new Date(m.NextRestart).toLocaleString([], {weekday:'short',hour:'2-digit',minute:'2-digit',hour12:false}) : 'disabled';
  const freqLabel = {daily:'every day','2day':'every 2 days','3day':'every 3 days',weekly:'weekly'}[r.Frequency] || r.Frequency || '';
  $('#mFreq').textContent = r.Enabled ? `${freqLabel} at ${r.Time}` : ' ';
  $('#mUpd').textContent = r.Update ? 'on restart' : 'off';
  $('#mSteam').textContent = m.SteamCmdReady ? 'ready' : 'missing';
  $('#mSteam').style.color = m.SteamCmdReady ? 'var(--ok)' : 'var(--danger)';
  $('#mVersion').textContent = m.Version || 'unknown';
  $('#mVersionSub').textContent = m.VersionDetail && m.VersionDetail.Engine ? 'Engine '+m.VersionDetail.Engine : ' ';

  $('#mVerHist tbody').innerHTML = asArray(m.VersionHistory).map(v=>`<tr>
    <td>${new Date(v.t).toLocaleString([], {year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false})}</td>
    <td>${esc(v.version||'?')} ${v.kind==='initial'?'<span class="tag recent">first seen</span>':'<span class="tag daily">update</span>'}</td>
    <td>${esc(v.cl||'')}</td><td>${esc(v.build||'')}</td></tr>`).join('') || '<tr><td colspan="4" class="dim">no version records yet</td></tr>';

  if(!formDirty){
    $('#mEnabled').checked = !!r.Enabled;
    $('#mFrequency').value = r.Frequency || 'daily';
    $('#mTime').value = r.Time || '05:00';
    $('#mUpdate').checked = !!r.Update;
    $('#mLead').value = r.LeadMinutes ?? 30;
  }

  const lvlColor = l => l==='ERROR' ? 'var(--danger)' : l==='WARN' ? 'var(--warn)' : 'var(--dim)';
  $('#mEvents tbody').innerHTML = asArray(m.Events).map(e=>`<tr>
    <td>${new Date(e.When).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false})}</td>
    <td style="color:${lvlColor(e.Level)}">${esc(e.Level)}</td>
    <td>${esc(e.Category)}</td>
    <td style="font-family:var(--font)">${esc(e.Message)}</td></tr>`).join('') || '<tr><td colspan="4" class="dim">no events yet</td></tr>';
}

// schedule form
['mEnabled','mFrequency','mTime','mUpdate','mLead'].forEach(id=>{
  const el=document.getElementById(id); if(el) el.addEventListener('change', ()=>formDirty=true);
});
document.getElementById('saveSchedule')?.addEventListener('click', async ()=>{
  const out=$('#mScheduleResult'); out.textContent='…';
  const body={ action:'set-restart', token:$('#mToken').value,
    enabled:$('#mEnabled').checked, frequency:$('#mFrequency').value, time:$('#mTime').value,
    update:$('#mUpdate').checked, lead:parseInt($('#mLead').value||'30',10) };
  try{
    const r=await fetch('api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const j=await r.json();
    out.textContent = j.ok ? '✓ '+j.result : '✗ '+(j.error||'failed');
    out.style.color = j.ok ? 'var(--ok)' : 'var(--danger)';
    if(j.ok){ formDirty=false; setTimeout(refresh, 800); }
  }catch(e){ out.textContent='✗ '+e.message; }
});

let settingsDirty = false;
async function renderSettings(){
  const s = await getJSON('data/settings.json');
  if (settingsDirty) return;   // don't stomp edits in progress
  const set = (id,v) => { const e = document.getElementById(id); if (e) e.value = (v ?? ''); };
  set('cfgRoot',s.Root); set('cfgSaveDir',s.SaveDir); set('cfgBackupDir',s.BackupDir); set('cfgSteamCmd',s.SteamCmd);
  set('cfgChildProc',s.ChildProc); set('cfgTaskName',s.TaskName); set('cfgApiBase',s.ApiBase); set('cfgSteamAppId',s.SteamAppId);
  $('#cfgWatchdog').checked = !!s.Watchdog;
  set('cfgWebPort',s.WebPort); set('cfgWebBinds',(s.WebBinds||[]).join(', '));
  set('cfgKeepRecent',s.BackupKeepRecent); set('cfgKeepDaily',s.BackupKeepDaily);
  set('cfgKeepWeekly',s.BackupKeepWeekly); set('cfgKeepMonthly',s.BackupKeepMonthly);
  set('cfgWebhook',s.DiscordWebhook);
  const nm = s.NickMap || {};
  $('#cfgNickMap').value = Object.entries(nm).map(([k,v])=>`${k} = ${v}`).join('\n');
}

const settingsView = document.getElementById('view-settings');
if (settingsView) settingsView.addEventListener('input', ()=>settingsDirty=true);

document.getElementById('saveSettings')?.addEventListener('click', async ()=>{
  const out = $('#cfgResult'); out.textContent = '…';
  const binds = $('#cfgWebBinds').value.split(',').map(x=>x.trim()).filter(Boolean);
  const nick = {};
  $('#cfgNickMap').value.split('\n').forEach(l=>{
    const i = l.indexOf('='); if (i < 0) return;
    const k = l.slice(0,i).trim(), v = l.slice(i+1).trim();
    if (k && v) nick[k] = v;
  });
  const config = {
    Root:$('#cfgRoot').value, SaveDir:$('#cfgSaveDir').value, BackupDir:$('#cfgBackupDir').value, SteamCmd:$('#cfgSteamCmd').value,
    ChildProc:$('#cfgChildProc').value, TaskName:$('#cfgTaskName').value, ApiBase:$('#cfgApiBase').value, SteamAppId:$('#cfgSteamAppId').value,
    Watchdog:$('#cfgWatchdog').checked, WebPort:parseInt($('#cfgWebPort').value||'8081',10), WebBinds:binds,
    BackupKeepRecent:parseInt($('#cfgKeepRecent').value||'0',10), BackupKeepDaily:parseInt($('#cfgKeepDaily').value||'0',10),
    BackupKeepWeekly:parseInt($('#cfgKeepWeekly').value||'0',10), BackupKeepMonthly:parseInt($('#cfgKeepMonthly').value||'0',10),
    NickMap:nick
  };
  const body = { action:'set-config', token:$('#cfgToken').value, config, discordWebhook:$('#cfgWebhook').value, rotateToken:$('#cfgRotateToken').value };
  try{
    const r = await fetch('api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const j = await r.json();
    out.textContent = j.ok ? '✓ '+j.result : '✗ '+(j.error||'failed');
    out.style.color = j.ok ? 'var(--ok)' : 'var(--danger)';
    if (j.ok){ settingsDirty=false; $('#cfgRotateToken').value=''; setTimeout(refresh, 900); }
  }catch(e){ out.textContent = '✗ '+e.message; }
});

// ---- Discord Bot tab ----
let discordDirty = false;
async function renderDiscord(){
  const d = await getJSON('data/discord.json');
  const connected = d.Enabled && d.HasBotToken && d.ChannelSet && d.Connected;
  $('#dBot').textContent = !d.Enabled ? 'disabled' : !d.HasBotToken ? 'no token' : !d.ChannelSet ? 'no channel' : d.Connected ? 'online' : 'offline';
  $('#dBot').style.color = connected ? 'var(--ok)' : d.Enabled ? 'var(--danger)' : 'var(--dim)';
  $('#dBotSub').textContent = d.BotUser ? ('as '+d.BotUser) : ' ';
  $('#dToday').textContent = d.Today ?? 0;
  $('#dTotal').textContent = (d.TotalCommands ?? 0) + ' all-time';
  $('#dApprovedCount').textContent = d.ApprovedCount ?? 0;
  $('#dChannel').textContent = d.ChannelId || '—';
  $('#dPrefix').textContent = d.Prefix ? ('prefix '+d.Prefix) : ' ';
  $('#dPending').textContent = (d.Pending && d.Pending.length) ? d.Pending.length : '0';
  $('#dError').textContent = d.LastError ? ('⚠ last error: '+d.LastError) : '';
  $('#dWhoamiHint').textContent = (d.Prefix||'!')+'whoami';

  if(!discordDirty){
    $('#dEnabled').checked = !!d.Enabled;
    $('#dChannelId').value = d.ChannelId || '';
    $('#dPrefixIn').value = d.Prefix || '!';
    $('#dPoll').value = d.PollSeconds || 10;
    $('#dToken').placeholder = d.HasBotToken ? 'saved — paste to rotate' : 'paste to set';
    approvedList = asArray(d.Approved).map(u=>({Id:String(u.Id), Name:String(u.Name)}));
    renderApprovedTable();
  }

  $('#dUsers tbody').innerHTML = asArray(d.Users).map(u=>`<tr>
    <td><span class="dot ${u.Approved?'on':''}"></span></td>
    <td class="name">${esc(u.Name)}${u.Approved?'':' <span class="dim">(not approved)</span>'}</td>
    <td>${u.Total}</td>
    <td class="dim">${asArray(u.Commands).map(c=>`${esc(c.Command)}×${c.Count}`).join(', ')||'—'}</td>
    <td>${u.Denied?'<span style="color:var(--danger)">'+u.Denied+'</span>':'0'}</td></tr>`).join('')
    || '<tr><td colspan="5" class="dim">no commands yet</td></tr>';

  $('#dCmdTotals tbody').innerHTML = asArray(d.CommandTotals).map(c=>`<tr><td>${esc(c.Command)}</td><td>${c.Count}</td></tr>`).join('')
    || '<tr><td colspan="2" class="dim">none yet</td></tr>';

  const statusColor = s => ({denied:'var(--danger)',executed:'var(--ok)',ok:'var(--dim)',pending:'var(--warn)',unknown:'var(--warn)',expired:'var(--warn)',cancelled:'var(--dim)'}[s]||'var(--dim)');
  $('#dLog tbody').innerHTML = asArray(d.Recent).map(r=>`<tr>
    <td>${new Date(r.t).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false})}</td>
    <td>${esc(r.userName||r.userId)}</td>
    <td>${esc(r.command)}</td>
    <td class="dim">${esc(r.args||'')}</td>
    <td style="color:${statusColor(r.status)}">${esc(r.status)}</td></tr>`).join('')
    || '<tr><td colspan="5" class="dim">no commands logged yet</td></tr>';
}

const discordView = document.getElementById('view-discord');
if (discordView) discordView.addEventListener('input', ()=>discordDirty=true);

// approved-users editor (add / inline-edit / delete)
let approvedList = [];
function renderApprovedTable(){
  const tb = $('#dApprovedTable tbody');
  if(!tb) return;
  tb.innerHTML = approvedList.map((u,i)=>`<tr data-i="${i}">
    <td><input class="apName" data-i="${i}" value="${escAttr(u.Name)}" style="width:100%" autocomplete="off"></td>
    <td><input class="apId" data-i="${i}" value="${escAttr(u.Id)}" style="width:100%;font-family:var(--mono)" inputmode="numeric" autocomplete="off"></td>
    <td><button class="btn danger apDel" data-i="${i}" style="padding:4px 11px" title="remove">✕</button></td></tr>`).join('')
    || '<tr><td colspan="3" class="dim">no approved users yet — add one above</td></tr>';
}

document.getElementById('dAddApproved')?.addEventListener('click', ()=>{
  const out=$('#dAddResult');
  const id=$('#dNewId').value.trim(), name=$('#dNewName').value.trim();
  if(!/^\d{5,}$/.test(id)){ out.textContent='✗ enter a numeric Discord ID'; out.style.color='var(--danger)'; return; }
  if(approvedList.some(u=>String(u.Id)===id)){ out.textContent='✗ already on the list'; out.style.color='var(--danger)'; return; }
  approvedList.push({Id:id, Name:name||id});
  discordDirty=true; renderApprovedTable();
  $('#dNewId').value=''; $('#dNewName').value='';
  out.textContent='✓ added — remember to Save'; out.style.color='var(--ok)';
});

const apTableBody = document.querySelector('#dApprovedTable tbody');
if(apTableBody){
  apTableBody.addEventListener('click', e=>{
    const del=e.target.closest('.apDel'); if(!del) return;
    approvedList.splice(parseInt(del.dataset.i,10),1);
    discordDirty=true; renderApprovedTable();
  });
  apTableBody.addEventListener('input', e=>{
    const i=parseInt(e.target.dataset.i,10); if(isNaN(i)||!approvedList[i]) return;
    if(e.target.classList.contains('apName')) approvedList[i].Name=e.target.value;
    else if(e.target.classList.contains('apId')) approvedList[i].Id=e.target.value;
    discordDirty=true;
  });
}

document.getElementById('saveDiscord')?.addEventListener('click', async ()=>{
  const out=$('#dSaveResult'); out.textContent='…';
  const approved = approvedList
    .map(u=>({Id:String(u.Id).trim(), Name:(String(u.Name).trim()||String(u.Id).trim())}))
    .filter(u=>/^\d{5,}$/.test(u.Id));
  const body={ action:'set-discord', token:$('#dCtlToken').value,
    enabled:$('#dEnabled').checked, channel:$('#dChannelId').value.trim(),
    prefix:$('#dPrefixIn').value.trim()||'!', poll:parseInt($('#dPoll').value||'10',10),
    approved, botToken:$('#dToken').value };
  try{
    const r=await fetch('api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const j=await r.json();
    out.textContent = j.ok ? '✓ '+j.result : '✗ '+(j.error||'failed');
    out.style.color = j.ok ? 'var(--ok)' : 'var(--danger)';
    if(j.ok){ discordDirty=false; $('#dToken').value=''; setTimeout(refresh, 900); }
  }catch(e){ out.textContent='✗ '+e.message; }
});

// tabs
document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click', ()=>{
  document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
  t.classList.add('active');
  document.querySelectorAll('.view').forEach(v=>v.classList.add('hidden'));
  document.getElementById('view-'+t.dataset.view).classList.remove('hidden');
}));

// controls (works for any .ctl-row; finds its own token input + result span)
document.querySelectorAll('.btn[data-action]').forEach(b=>{
  b.addEventListener('click', async ()=>{
    const action=b.dataset.action, row=b.closest('.ctl-row');
    const token=row.querySelector('input')?.value||'', out=row.querySelector('.ctl-result');
    const confirmMsg={start:'Start the server?',stop:'Stop the server?',restart:'Restart the server now? Players online will be disconnected after the warn-lead.',update:'Update + restart now? The server will go down for the update.'};
    if(confirmMsg[action] && !confirm(confirmMsg[action])) return;
    if(out) out.textContent='…';
    try{
      const r=await fetch('api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,token})});
      const j=await r.json();
      if(out){ out.textContent = j.ok ? '✓ '+j.result : '✗ '+(j.error||'failed'); out.style.color = j.ok?'var(--ok)':'var(--danger)'; }
      setTimeout(refresh, 1500);
    }catch(e){ if(out) out.textContent='✗ '+e.message; }
  });
});

async function refresh(){
  try{ await renderState(); await renderPlayers(); await renderCharts(); await renderBackups(); await renderMaintenance(); await renderSettings(); }
  catch(e){ console.error(e); }
  try{ await renderDiscord(); }catch(e){ console.error(e); }
}
charts.tps = lineChart('#chartTps','TPS','#3fb950');
charts.online = lineChart('#chartOnline','Online','#58a6ff');
charts.sys = multiChart('#chartSys');
charts.save = lineChart('#chartSave','Save MB','#ff8c1a');
refresh();
setInterval(refresh, 10000);
