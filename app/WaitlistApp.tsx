"use client";

import { FormEvent, useEffect, useMemo, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { enablePush, pushSupported } from './push';
import { supabase } from './supabase';
import './admin-player.css';

type PlayerStatus = 'current' | 'waiting' | 'sitout' | 'rejoin' | 'left';
type Player = { id:string; user_id:string|null; first_name:string; last_name:string; display_name:string; status:PlayerStatus; queue_position:number|null; restricted:boolean; group_id:string|null };
type Game = { id:string; game_number:number; player_names:string[]; ended_at:string };
type Config = { game_number:number; max_players:number; mode:'regular'|'rejoin'|'teams' };
type GroupRequest = { id:string; requester_id:string; target_id:string; status:string; requester?:Player };
type Member = { user_id:string;email:string|null;phone:string|null;created_at:string;player_name:string|null };
type Notice = { title:string; message:string; confirm?:string; action?:()=>Promise<void> } | null;

const cleanName = (value:string) => value.replace(/[^\p{L}\s]/gu, '').replace(/\s+/g, ' ').trim();

export default function App() {
  const [user,setUser]=useState<User|null>(null);
  const [players,setPlayers]=useState<Player[]>([]);
  const [games,setGames]=useState<Game[]>([]);
  const [config,setConfig]=useState<Config>({game_number:1,max_players:12,mode:'regular'});
  const [screen,setScreen]=useState<'welcome'|'email'|'name'|'admin'|'queue'|'history'|'members'|'restricted'|'add-player'>('welcome');
  const [first,setFirst]=useState(''); const [last,setLast]=useState('');
  const [email,setEmail]=useState(''); const [authMode,setAuthMode]=useState<'signin'|'signup'>('signin');
  const [busy,setBusy]=useState(false); const [notice,setNotice]=useState<Notice>(null);
  const [editing,setEditing]=useState<string|null>(null); const [editName,setEditName]=useState('');
  const [notifications,setNotifications]=useState(
    typeof Notification !== 'undefined' && Notification.permission === 'granted',
  );
  const [admin,setAdmin]=useState(false); const [adminUser,setAdminUser]=useState(''); const [adminPassword,setAdminPassword]=useState('');
  const [groupRequests,setGroupRequests]=useState<GroupRequest[]>([]);
  const [rejoinResponse,setRejoinResponse]=useState<string|null>(null);
  const [dragging,setDragging]=useState<string|null>(null);const [dragOver,setDragOver]=useState<string|null>(null);
  const [members,setMembers]=useState<Member[]>([]);
  const [adminFirst,setAdminFirst]=useState(''); const [adminLast,setAdminLast]=useState('');

  const me=players.find(p=>p.user_id===user?.id);
  const current=useMemo(()=>players.filter(p=>p.status==='current').sort(byPosition),[players]);
  const waiting=useMemo(()=>players.filter(p=>p.status==='waiting'||p.status==='sitout').sort(byPosition),[players]);

  useEffect(()=>{ void boot(); },[]);
  async function boot(){
    let {data:{session}}=await supabase.auth.getSession();
    if(!session){const result=await supabase.auth.signInAnonymously(); if(result.error){setNotice({title:'Connection needed',message:result.error.message});return;} session=result.data.session;}
    setUser(session?.user??null); await refresh(session?.user??null);
    const channel=supabase.channel('live-waitlist')
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_players'},()=>void refresh())
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_config'},()=>void refresh())
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'past_games'},()=>void refresh())
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'waitlist_events'},payload=>{
        const event=payload.new as {message?:string}; if(event.message) setNotice({title:'Waitlist update',message:event.message});
      }).subscribe();
    return()=>{void supabase.removeChannel(channel)};
  }
  async function refresh(activeUser?:User|null){
    const [{data:p},{data:c},{data:g},{data:a},{data:r},{data:rejoin}]=await Promise.all([
      supabase.from('waitlist_players').select('*').neq('status','left').order('queue_position'),
      supabase.from('waitlist_config').select('game_number,max_players,mode').single(),
      supabase.from('past_games').select('*').order('game_number',{ascending:false}),
      supabase.from('admin_sessions').select('user_id').maybeSingle(),
      supabase.from('group_requests').select('*').eq('status','pending'),
      supabase.from('rejoin_responses').select('id').is('choice',null).gt('expires_at',new Date().toISOString()).order('created_at',{ascending:false}).limit(1).maybeSingle()
    ]);
    const playerRows=(p??[]) as Player[];setPlayers(playerRows); if(c)setConfig(c as Config); setGames((g??[]) as Game[]);setAdmin(Boolean(a));
    setGroupRequests(((r??[]) as GroupRequest[]).map(request=>({...request,requester:playerRows.find(player=>player.id===request.requester_id)})));
    setRejoinResponse(rejoin?.id??null);
    const uid=(activeUser??user)?.id; const own=(p??[]).find(item=>item.user_id===uid);
    if(own) setScreen('queue');
  }
  async function rpc(name:string,args:Record<string,unknown>={}){
    setBusy(true); const {data,error}=await supabase.rpc(name,args); setBusy(false);
    if(error){setNotice({title:'Could not complete that',message:error.message});return false;}
    if(data?.message)setNotice({title:'Done',message:data.message}); await refresh(); return true;
  }
  async function join(event:FormEvent){event.preventDefault(); const f=cleanName(first),l=cleanName(last); if(!f){setNotice({title:'Enter your name',message:'Your name needs to contain letters.'});return;}
    if(await rpc('join_waitlist',{p_first_name:f,p_last_name:l}))setScreen('queue');
  }
  function ask(title:string,message:string,confirm:string,action:()=>Promise<void>){setNotice({title,message,confirm,action});}
  async function turnOnNotifications(){setBusy(true);try{await enablePush();setNotifications(true);setNotice({title:'Notifications are on',message:"We’ll alert you when your game starts or needs a response."});}catch(error){setNotice({title:'Notifications unavailable',message:error instanceof Error?error.message:'Could not enable notifications.'});}setBusy(false);}
  async function saveName(player:Player){const parts=cleanName(editName).split(' ');const f=parts.shift()??'';const l=parts.join(' ');if(await rpc('rename_waitlist_player',{p_player_id:player.id,p_first_name:f,p_last_name:l}))setEditing(null);}
  async function logout(){await supabase.auth.signOut();setPlayers([]);setUser(null);setScreen('welcome');await boot();}
  function openEmailAuth(mode:'signin'|'signup'){setAuthMode(mode);setEmail('');if(mode==='signin'){setFirst('');setLast('');}setScreen('email');}
  async function emailSignIn(event:FormEvent){
    event.preventDefault();
    const address=email.trim().toLowerCase(); const f=cleanName(first); const l=cleanName(last);
    if(!address){setNotice({title:'Enter your email',message:'Enter the email address you want to use for OpenGym.'});return;}
    if(authMode==='signup'&&(!f||!l)){setNotice({title:'Enter your full name',message:'A first and last name are required when creating an account.'});return;}
    setBusy(true);
    const {error}=await supabase.auth.signInWithOtp({
      email:address,
      options:{emailRedirectTo:location.origin,shouldCreateUser:authMode==='signup',data:authMode==='signup'?{first_name:f,last_name:l}:undefined},
    });
    setBusy(false);
    if(error){setNotice({title:'Could not send the email',message:error.message});return;}
    setNotice({title:'Check your email',message:`We sent a secure sign-in link to ${address}. Open it on this device to continue.`});
  }
  async function openMembers(){const {data,error}=await supabase.rpc('admin_list_members');if(error)setNotice({title:'Members unavailable',message:error.message});else{setMembers((data??[]) as Member[]);setScreen('members')}}
  function confirmRestriction(player:Player){ask(player.restricted?'Unrestrict player?':'Restrict player?',player.restricted?`${player.display_name} will regain access to Next Game.`:`${player.display_name} will no longer be allowed to press Next Game.`,player.restricted?'Unrestrict':'Restrict',async()=>{await rpc('admin_restrict_player',{p_player_id:player.id,p_restricted:!player.restricted})})}
  async function adminLogin(event:FormEvent){event.preventDefault();if(await rpc('sign_in_waitlist_admin',{p_username:adminUser,p_password:adminPassword})){setAdmin(true);setScreen('queue');}}
  async function adminAddPlayer(event:FormEvent){
    event.preventDefault(); const f=cleanName(adminFirst),l=cleanName(adminLast);
    if(!f){setNotice({title:'Enter a player name',message:'The player name needs to contain letters.'});return;}
    if(await rpc('admin_add_player',{p_first_name:f,p_last_name:l})){setAdminFirst('');setAdminLast('');setScreen('queue');}
  }
  async function requestGroup(player:Player){await rpc('request_player_group',{p_target_id:player.id});}
  async function answerGroup(id:string,accept:boolean){await rpc('answer_player_group',{p_request_id:id,p_accept:accept});}
  async function movePlayer(playerId:string,status:'current'|'waiting',index:number){setDragging(null);setDragOver(null);await rpc('admin_move_player',{p_player_id:playerId,p_status:status,p_index:index});}
  async function answerRejoin(choice:'stay'|'leave'){if(rejoinResponse)await rpc('answer_rejoin_prompt',{p_response_id:rejoinResponse,p_choice:choice});setRejoinResponse(null);}
  async function advanceGame(){
    setBusy(true);const {data,error}=await supabase.rpc('end_current_game');
    if(error){setBusy(false);setNotice({title:'Could not start the next game',message:error.message});return;}
    const {data:newCurrent}=await supabase.from('waitlist_players').select('user_id').eq('status','current');
    const currentIds=(newCurrent??[]).map(row=>row.user_id);
    if(currentIds.length)await supabase.functions.invoke('send-push',{body:{userIds:currentIds,notification:{title:`Game ${data.game_number} has started`,body:'You are in the current game. Head to the court!',kind:'game_started',url:'/'}}});
    for(const prompt of data.rejoin_prompts??[]){await supabase.functions.invoke('send-push',{body:{userIds:[prompt.user_id],notification:{title:'Stay in the OpenGym waitlist?',body:'Choose Stay or Leave within five minutes.',kind:'rejoin',url:'/',responseId:prompt.response_id}}});}
    setBusy(false);setNotice({title:'Next game started',message:data.message});await refresh();
  }

  if(screen==='welcome')return <Shell><section className="auth-card"><Logo/><div className="auth-links"><button className="text-button" onClick={()=>openEmailAuth('signin')}>Sign in</button><span>or</span><button className="text-button" onClick={()=>openEmailAuth('signup')}>Create account</button></div><button className="hero-button" onClick={()=>setScreen('name')}>Continue as guest</button><button className="admin-link" onClick={()=>setScreen('admin')}>Admin</button><p className="fine">Join the live volleyball queue from your phone.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='email')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><span className="kicker">{authMode==='signup'?'CREATE ACCOUNT':'ACCOUNT SIGN IN'}</span><h1>{authMode==='signup'?'Create your OpenGym account':'Welcome back'}</h1><p>We’ll email you a secure link—no password needed.</p><form onSubmit={emailSignIn}>{authMode==='signup'&&<><label>First name<input autoFocus value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name" autoComplete="given-name" required/></label><label>Last name<input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last name" autoComplete="family-name" required/></label></>}<label>Email address<input autoFocus={authMode==='signin'} type="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" autoComplete="email" required/></label><button className="hero-button" disabled={busy}>{busy?'Sending…':'Email me a sign-in link'}</button></form><p className="fine">The link expires for your security.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='admin')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><span className="kicker">ADMIN ACCESS</span><h1>Manage OpenGym</h1><p>Sign in to choose a waitlist mode and manage players.</p><form onSubmit={adminLogin}><label>Username<input autoFocus value={adminUser} onChange={e=>setAdminUser(e.target.value)} autoCapitalize="none"/></label><label>Password<input type="password" value={adminPassword} onChange={e=>setAdminPassword(e.target.value)}/></label><button className="hero-button" disabled={busy}>Sign in</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(me?.status==='rejoin'&&rejoinResponse)return <Shell><section className="auth-card rejoin-card"><Logo/><span className="kicker">REJOIN WAITLIST</span><h1>Do you want to stay?</h1><p>Your position is saved. Choose within five minutes or you’ll automatically leave the waitlist.</p><div className="rejoin-actions"><button className="next" onClick={()=>void answerRejoin('stay')}>Stay</button><button className="danger" onClick={()=>void answerRejoin('leave')}>Leave</button></div></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='name')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><span className="kicker">PLAYER DETAILS</span><h1>What should we call you?</h1><p>Your name is added to the waitlist as soon as you continue.</p><form onSubmit={join}><label>First name<input autoFocus value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name"/></label><label>Last initial or name <em>optional</em><input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last initial or name"/></label><button className="hero-button" disabled={busy}>Join waitlist</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;

  return <Shell>
    <header className="topbar"><Logo compact/><div className="top-actions">{pushSupported()&&!notifications&&<button className="icon-button" onClick={turnOnNotifications}>Enable alerts</button>}<button className="icon-button" onClick={()=>ask('Log out?','This will remove you from the waitlist and sign you out.','Log out',async()=>{await rpc('leave_waitlist');await logout()})}>Log out</button></div></header>
    <main className="queue-page">
      <section className="game-heading"><div><span className="kicker">LIVE QUEUE {admin?'· ADMIN':''}</span><h1>Game {config.game_number}</h1></div><span className="live-pill"><i/>Live</span></section>
      {admin&&<section className="admin-tools"><select value={config.mode} onChange={e=>void rpc('admin_set_mode',{p_mode:e.target.value})}><option value="regular">Regular waitlist</option><option value="rejoin">Rejoin waitlist</option><option value="teams">Teams mode</option></select><button className="next-game-tool" disabled={busy||current.length===0} onClick={()=>ask('Start the next game?','This will notify all players and advance the entire queue to the next game.','Next game',advanceGame)}>Next game</button><button className="add-player-tool" onClick={()=>setScreen('add-player')}>＋ Add player</button><button onClick={()=>void rpc('admin_undo_last')}>↶ Undo</button><button onClick={()=>setScreen('restricted')}>Restricted</button><button onClick={()=>void openMembers()}>Members</button><button className="reset-tool" onClick={()=>ask('Reset the entire waitlist?','This removes every player and clears past games. The admin can undo this action.','Reset',async()=>{await rpc('admin_reset_waitlist')})}>Reset</button></section>}
      <QueueCard title={`Game ${config.game_number}`} subtitle={`${current.length} playing`} status="current" players={current} start={1} me={me} admin={admin} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} requestGroup={requestGroup} restrict={confirmRestriction} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/>
      <QueueCard title="Waitlist" subtitle={waiting.length?`${waiting.length} waiting`:'No one waiting'} status="waiting" players={waiting} start={current.length+1} me={me} admin={admin} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} game={config.game_number} max={config.max_players} requestGroup={requestGroup} restrict={confirmRestriction} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/>
      {groupRequests.filter(request=>players.find(p=>p.id===request.target_id)?.user_id===user?.id).map(request=><section className="request-card" key={request.id}><strong>{request.requester?.display_name??'A player'} wants to group with you</strong><p>Accepting may move you back to the furthest group member’s position.</p><div><button className="next" onClick={()=>void answerGroup(request.id,true)}>Accept</button><button className="neutral" onClick={()=>void answerGroup(request.id,false)}>Decline</button></div></section>)}
      {me&&me.status!=='left'&&<section className="my-actions"><span>Your actions</span><div>{me.status==='current'&&<button className="next" disabled={busy||me.restricted} onClick={()=>ask('Start the next game?',`This will notify all players that ${me.display_name} advanced the queue. This cannot be quietly undone.`,'Next game',advanceGame)}>Next game</button>}<button className="neutral" disabled={busy} onClick={()=>ask('Sit out one game?',"You’ll skip one game, then receive priority for the following game.",'Sit out',async()=>{await rpc('sit_out_one_game')})}>Sit out</button><button className="danger" disabled={busy} onClick={()=>ask('Leave the waitlist?','This removes you from the current game or queue. You can join again later.','Leave',async()=>{await rpc('leave_waitlist')})}>Leave</button></div></section>}
      {me?.status==='left'&&<button className="hero-button join-again" onClick={()=>setScreen('name')}>Join again</button>}
      <button className="history-button" onClick={()=>setScreen('history')}>Past games <span>→</span></button>
      <p className="projection-note">Queue positions update live on every connected phone.</p>
    </main>
    {screen==='history'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><span className="kicker">GAME HISTORY</span><h2>Past games</h2>{games.length===0?<p>No completed games yet.</p>:games.map(game=><article className="past-game" key={game.id}><strong>Game {game.game_number}</strong><p>{game.player_names.join(', ')}</p></article>)}</div></div>}
    {screen==='restricted'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><span className="kicker">ADMIN</span><h2>Restricted players</h2>{players.filter(p=>p.restricted).length===0?<p>No restricted players.</p>:players.filter(p=>p.restricted).map(player=><article className="past-game member-row" key={player.id}><strong>{player.display_name}</strong><button onClick={()=>void rpc('admin_restrict_player',{p_player_id:player.id,p_restricted:false})}>Unrestrict</button></article>)}</div></div>}
    {screen==='add-player'&&<div className="drawer"><div className="drawer-card add-player-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><span className="kicker">ADMIN</span><h2>Add a player</h2><p>Add a walk-in player directly to the live queue. They do not need an account.</p><form onSubmit={adminAddPlayer}><label>First name<input autoFocus value={adminFirst} onChange={e=>setAdminFirst(e.target.value)} placeholder="First name"/></label><label>Last initial or name <em>optional</em><input value={adminLast} onChange={e=>setAdminLast(e.target.value)} placeholder="Last initial or name"/></label><button className="hero-button" disabled={busy}>{busy?'Adding…':'Add to waitlist'}</button></form></div></div>}
    {screen==='members'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><span className="kicker">ADMIN</span><h2>Members</h2>{members.length===0?<p>No accounts have been created yet.</p>:members.map(member=><article className="past-game" key={member.user_id}><strong>{member.player_name??member.email??member.phone??'Member'}</strong><p>{member.email??member.phone??'Verified account'} · Joined {new Date(member.created_at).toLocaleDateString()}</p></article>)}</div></div>}
    {notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
}

function byPosition(a:Player,b:Player){return (a.queue_position??Number.MAX_SAFE_INTEGER)-(b.queue_position??Number.MAX_SAFE_INTEGER)}
function Shell({children}:{children:React.ReactNode}){return <div className="app-shell">{children}</div>}
function Logo({compact=false}:{compact?:boolean}){return <div className={`logo ${compact?'compact':''}`}><span>OG</span><div><strong>OpenGym</strong>{!compact&&<small>VOLLEYBALL WAITLIST</small>}</div></div>}
function QueueCard({title,subtitle,status,players,start,me,admin=false,editing,editName,setEditing,setEditName,saveName,requestGroup,restrict,dragging,dragOver,setDragging,setDragOver,movePlayer,game,max}:{title:string;subtitle:string;status:'current'|'waiting';players:Player[];start:number;me?:Player;admin?:boolean;editing:string|null;editName:string;setEditing:(v:string|null)=>void;setEditName:(v:string)=>void;saveName:(p:Player)=>void;requestGroup:(p:Player)=>Promise<void>;restrict:(p:Player)=>void|Promise<unknown>;dragging:string|null;dragOver:string|null;setDragging:(v:string|null)=>void;setDragOver:(v:string|null)=>void;movePlayer:(id:string,status:'current'|'waiting',index:number)=>Promise<void>;game?:number;max?:number}){
 return <section className={`queue-card ${dragging?'is-dragging':''}`} onDragOver={e=>e.preventDefault()} onDrop={e=>{e.preventDefault();if(dragging)void movePlayer(dragging,status,players.length)}}><header><h2>{title}</h2><span>{subtitle}</span></header><div>{players.length===0?<p className="empty">Players will appear here.</p>:players.map((player,index)=>{const own=player.user_id===me?.user_id;const projection=game&&max?game+Math.floor((start+index-1)/max):null;return <article draggable={admin} onDragStart={e=>{setDragging(player.id);e.dataTransfer.effectAllowed='move'}} onDragEnd={()=>{setDragging(null);setDragOver(null)}} onDragOver={e=>{e.preventDefault();e.stopPropagation();setDragOver(player.id)}} onDrop={e=>{e.preventDefault();e.stopPropagation();if(dragging)void movePlayer(dragging,status,index)}} className={`player-row ${own?'own':''} ${player.group_id?'grouped':''} ${dragging===player.id?'dragging':''} ${dragOver===player.id&&dragging!==player.id?'drop-space':''}`} key={player.id}><span className="position">{start+index}</span><div className="player-name">{(own||admin)&&<button className="pencil" aria-label="Edit player name" onClick={()=>{setEditing(player.id);setEditName(`${player.first_name} ${player.last_name}`.trim())}}>✎</button>}{editing===player.id?<input className="inline-name" autoFocus value={editName} onChange={e=>setEditName(e.target.value)} onBlur={()=>void saveName(player)} onKeyDown={e=>{if(e.key==='Enter')void saveName(player);if(e.key==='Escape')setEditing(null)}}/>:<><strong>{player.display_name}{player.restricted&&(own||admin)?' (restricted)':''}</strong>{own&&projection&&<small>Projected: Game {projection}</small>}{player.status==='sitout'&&<small>Sitting out next game</small>}</>}</div>{own&&<span className="you">You</span>}{!own&&me&&!admin&&<button className="group-button" onClick={()=>void requestGroup(player)}>Group</button>}{admin&&<button className="restrict-button" onClick={()=>void restrict(player)}>{player.restricted?'Unrestrict':'Restrict'}</button>}</article>})}</div></section>
}
function Modal({notice,close,busy}:{notice:Exclude<Notice,null>;close:()=>void;busy:boolean}){return <div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)close()}}><section className="modal" role="dialog" aria-modal="true"><span className="modal-mark">OG</span><h2>{notice.title}</h2><p>{notice.message}</p><div className="modal-actions">{notice.action&&<button className="danger" disabled={busy} onClick={async()=>{await notice.action?.();close()}}>{notice.confirm}</button>}<button className="neutral" onClick={close}>{notice.action?'Cancel':'OK'}</button></div></section></div>}
