"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { enablePush, pushSupported } from './push';
import { supabase } from './supabase';
import { translateUiText, type AppLanguage } from './i18n';
import './admin-player.css';

type PlayerStatus = 'current' | 'waiting' | 'sitout' | 'rejoin' | 'left';
type Player = { id:string; user_id:string|null; first_name:string; last_name:string; display_name:string; status:PlayerStatus; queue_position:number|null; restricted:boolean; group_id:string|null; is_host:boolean };
type Game = { id:string; game_number:number; player_names:string[]; ended_at:string };
type Config = { game_number:number; max_players:number; mode:'regular'|'rejoin'|'teams'; geofence_enabled:boolean; geofence_radius_m:number };
type GroupRequest = { id:string; requester_id:string; target_id:string; status:string; requester?:Player };
type SubstituteRequest = { id:string; requester_id:string; target_id:string; status:string; requester?:Player };
type GroupNotification = { id:string; user_id:string; message:string; read_at:string|null };
type Member = { user_id:string;email:string|null;phone:string|null;created_at:string;player_name:string|null };
type AdminRejoin = { id:string;display_name:string;queue_position:number;expires_at:string };
type AdminEvent = { id:number;actor_name:string;event_type:string;message:string;created_at:string };
type GeofenceReturn = { id:string;removed_at:string;saved_position_until:string;expires_at:string };
type Notice = { title:string; message:string; confirm?:string; action?:()=>Promise<void>; onClose?:()=>void; actionTone?:'danger'|'success'; cancelTone?:'neutral'|'danger'; cancelLabel?:string; cancelAction?:()=>Promise<void>; blocking?:boolean; requestId?:string } | null;
type OnboardingStage = 'idle'|'disclaimer'|'tutorial';
const TUTORIAL_VERSION = 2;

const cleanName = (value:string) => value.replace(/[^\p{L}\s]/gu, '').replace(/\s+/g, ' ').trim();
const blockedNameTerms = [
  'fuck','fuk','fck','shit','bitch','btch','cunt','dick','pussy','asshole','whore','slut',
  'nigger','nigga','nigha','niga','niger','faggot','fagot','fag','retard','kike','chink','spic','wetback',
  'porn','rape','rapist','nazi','hitler','stalin','yourmom','urmom','yomama','yourmama',
];
function normalizedNameForms(value:string){
  const leet=value.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLocaleLowerCase()
    .replace(/[@4]/g,'a').replace(/[8]/g,'b').replace(/[3]/g,'e').replace(/[69]/g,'g')
    .replace(/[!1|]/g,'i').replace(/[0]/g,'o').replace(/[$5]/g,'s').replace(/[7+]/g,'t');
  const spaced=leet.replace(/[^a-z]+/g,' ').trim();
  const compact=spaced.replace(/\s/g,'').replace(/(.)\1{2,}/g,'$1$1');
  return {tokens:spaced.split(' ').filter(Boolean),compact};
}
function oneEditAway(value:string,target:string){
  if(Math.abs(value.length-target.length)>1)return false;
  let i=0,j=0,edits=0;
  while(i<value.length&&j<target.length){
    if(value[i]===target[j]){i++;j++;continue;}
    if(++edits>1)return false;
    if(value.length>target.length)i++;else if(target.length>value.length)j++;else{i++;j++;}
  }
  return edits+(i<value.length?1:0)+(j<target.length?1:0)<=1;
}
function isInappropriateName(value:string){
  const {tokens,compact}=normalizedNameForms(value);
  return blockedNameTerms.some(term=>compact.includes(term)||tokens.some(token=>term.length>=5&&token.length>=4&&oneEditAway(token,term)));
}
const inappropriateNameNotice = {title:'Choose a different name',message:'This name is not allowed. Please enter an appropriate name.'};
function preventNativeTouchScroll(event:TouchEvent){event.preventDefault();}

export default function App() {
  const [user,setUser]=useState<User|null>(null);
  const [players,setPlayers]=useState<Player[]>([]);
  const [games,setGames]=useState<Game[]>([]);
  const [config,setConfig]=useState<Config>({game_number:1,max_players:12,mode:'regular',geofence_enabled:false,geofence_radius_m:150});
  const [screen,setScreen]=useState<'welcome'|'email'|'name'|'admin'|'queue'|'history'|'player-history'|'members'|'restricted'|'add-player'|'offline-rejoin'|'admin-history'>('welcome');
  const [first,setFirst]=useState(''); const [last,setLast]=useState('');
  const [email,setEmail]=useState(''); const [authMode,setAuthMode]=useState<'signin'|'signup'>('signin');
  const [busy,setBusy]=useState(false); const [notice,setNotice]=useState<Notice>(null);
  const [editing,setEditing]=useState<string|null>(null); const [editName,setEditName]=useState('');
  const [notifications,setNotifications]=useState(
    typeof Notification !== 'undefined' && Notification.permission === 'granted',
  );
  const [admin,setAdmin]=useState(false); const [adminUser,setAdminUser]=useState(''); const [adminPassword,setAdminPassword]=useState('');
  const [groupRequests,setGroupRequests]=useState<GroupRequest[]>([]);
  const [substituteRequests,setSubstituteRequests]=useState<SubstituteRequest[]>([]);
  const [rejoinResponse,setRejoinResponse]=useState<string|null>(null); const [rejoinChecked,setRejoinChecked]=useState(false);
  const [dragging,setDragging]=useState<string|null>(null);const [dragOver,setDragOver]=useState<string|null>(null);
  const [members,setMembers]=useState<Member[]>([]);
  const [adminFirst,setAdminFirst]=useState(''); const [adminLast,setAdminLast]=useState('');
  const [adminRejoins,setAdminRejoins]=useState<AdminRejoin[]>([]); const [adminEvents,setAdminEvents]=useState<AdminEvent[]>([]); const [playerEvents,setPlayerEvents]=useState<AdminEvent[]>([]); const [historySearch,setHistorySearch]=useState('');
  const [ownPlayer,setOwnPlayer]=useState<Player|null>(null);
  const [forceRejoin,setForceRejoin]=useState(false);
  const [onboarding,setOnboarding]=useState<OnboardingStage>('idle'); const [tutorialStep,setTutorialStep]=useState(0);
  const [facilityMenu,setFacilityMenu]=useState(false);
  const [adminGrouping,setAdminGrouping]=useState(false); const [adminGroupIds,setAdminGroupIds]=useState<string[]>([]);
  const [adminSubstituting,setAdminSubstituting]=useState(false); const [playerSubstituting,setPlayerSubstituting]=useState(false); const [substituteIds,setSubstituteIds]=useState<string[]>([]);
  const [language,setLanguage]=useState<AppLanguage>('en'); const translationMemory=useRef(new WeakMap<Text,{original:string;applied:string}>());
  const [geofenceReturn,setGeofenceReturn]=useState<GeofenceReturn|null>(null); const [returnClock,setReturnClock]=useState(Date.now());
  const [permissionPlayer,setPermissionPlayer]=useState<Player|null>(null); const [hostAppointmentNotice,setHostAppointmentNotice]=useState<string|null>(null); const [hostTutorial,setHostTutorial]=useState(false); const [hostTutorialStep,setHostTutorialStep]=useState(0);
  const geofenceRemovalInProgress=useRef(false); const expiredRejoinHandled=useRef(false); const lastResumeRefresh=useRef(0); const adminMoveInProgress=useRef(false); const handledNotificationIds=useRef(new Set<string>()); const ownHostStatus=useRef(false); const ownPlayerIdRef=useRef<string|null>(null); const hostTrackedUserId=useRef<string|null>(null); const hostTransitionHandledAt=useRef(0); const hostAppointmentActive=useRef(false);
  const rejoinLookupAttempts=useRef(0);

  const activeMe=players.find(p=>p.user_id===user?.id)??null;
  // The live queue is authoritative. A cached inactive record must never hide
  // the normal controls when this user is already back in the game or waitlist.
  const me=activeMe??ownPlayer;
  ownPlayerIdRef.current=me?.id??ownPlayer?.id??null;
  const host=Boolean(me?.is_host&&!admin); const operator=admin||host;
  const current=useMemo(()=>players.filter(p=>p.status==='current').sort(byPosition),[players]);
  const waiting=useMemo(()=>players.filter(p=>p.status==='waiting'||p.status==='sitout').sort(byPosition),[players]);
  const projectedGames=useMemo(()=>projectQueueGames(waiting,config.game_number,config.max_players),[waiting,config.game_number,config.max_players]);
  const tutorialNeedsDemo=onboarding==='tutorial'&&tutorialStep===5&&!admin&&Boolean(me)&&waiting.every(player=>player.id===me?.id);
  const tutorialWaiting=tutorialNeedsDemo?[...waiting,{id:'tutorial-demo-player',user_id:null,first_name:'Demo',last_name:'Player',display_name:'Demo Player',status:'waiting' as PlayerStatus,queue_position:(waiting.at(-1)?.queue_position??current.length)+1,restricted:false,group_id:null,is_host:false}]:waiting;

  useEffect(()=>{ void boot(); },[]);
  useEffect(()=>{
    if(!user||admin)return;let stopped=false;
    const check=async()=>{const {data}=await supabase.from('waitlist_players').select('is_host').eq('user_id',user.id).neq('status','left').order('updated_at',{ascending:false}).limit(1).maybeSingle();if(!stopped&&data)syncOwnHostStatus(Boolean(data.is_host),user.id)};
    const timer=window.setInterval(()=>void check(),1500);return()=>{stopped=true;window.clearInterval(timer)};
  },[user?.id,admin]);
  useEffect(()=>{
    if(!user||admin)return;let stopped=false;
    // Realtime is the fastest path, but mobile browsers can suspend or miss a
    // channel event. Poll every unread player notification as a reliable
    // fallback so host, group, substitute, and operator messages appear
    // without requiring a refresh.
    const check=async()=>{const {data}=await supabase.from('group_notifications').select('id,user_id,message,read_at').eq('user_id',user.id).is('read_at',null).order('created_at',{ascending:true}).limit(1).maybeSingle();if(stopped||!data)return;const notification=data as GroupNotification;showPlayerNotification(notification,user.id);await supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',notification.id)};
    void check();const timer=window.setInterval(()=>void check(),800);return()=>{stopped=true;window.clearInterval(timer)};
  },[user?.id,admin]);
  useEffect(()=>{
    if(!user)return;let stopped=false;let refreshing=false;
    // Keep pending group/substitute requests synchronized even when a device's
    // realtime connection has been paused by the operating system.
    const sync=async()=>{if(stopped||refreshing)return;refreshing=true;try{await refresh(user)}finally{refreshing=false}};
    const timer=window.setInterval(()=>void sync(),1000);return()=>{stopped=true;window.clearInterval(timer)};
  },[user?.id]);
  useEffect(()=>{
    const substituting=adminSubstituting||playerSubstituting;
    const selecting=adminGrouping||substituting;
    document.body.classList.toggle('admin-group-selecting',selecting);
    document.querySelectorAll<HTMLElement>('[data-player-id]').forEach(row=>row.classList.toggle('admin-group-selected',adminGroupIds.includes(row.dataset.playerId??'')));
    document.querySelectorAll<HTMLElement>('[data-player-id]').forEach(row=>row.classList.toggle('substitute-selected',substituteIds.includes(row.dataset.playerId??'')));
    if(!selecting)return()=>document.body.classList.remove('admin-group-selecting');
    const blockDrag=(event:PointerEvent)=>{const target=event.target as HTMLElement;if(target.closest('[data-player-id]')&&!target.closest('button,input'))event.preventDefault();};
    const selectPlayer=(event:MouseEvent)=>{const target=event.target as HTMLElement;if(target.closest('button,input'))return;const row=target.closest<HTMLElement>('[data-player-id]');if(!row)return;event.preventDefault();event.stopPropagation();const player=players.find(item=>item.id===row.dataset.playerId);if(!player)return;if(substituting){if(playerSubstituting&&player.id===me?.id)return;setSubstituteIds(currentIds=>currentIds.includes(player.id)?currentIds.filter(id=>id!==player.id):adminSubstituting?(currentIds.length>=2?currentIds:[...currentIds,player.id]):[player.id]);return;}const related=player.group_id?players.filter(item=>item.group_id===player.group_id):[player];setAdminGroupIds(currentIds=>{const removing=related.every(item=>currentIds.includes(item.id));const next=removing?currentIds.filter(id=>!related.some(item=>item.id===id)):[...new Set([...currentIds,...related.map(item=>item.id)])];if(next.length>6){setNotice({title:'Maximum group size',message:'A group can contain up to six players.'});return currentIds;}return next;});};
    document.addEventListener('pointerdown',blockDrag,true);document.addEventListener('click',selectPlayer,true);
    return()=>{document.body.classList.remove('admin-group-selecting');document.removeEventListener('pointerdown',blockDrag,true);document.removeEventListener('click',selectPlayer,true);};
  },[adminGrouping,adminSubstituting,playerSubstituting,adminGroupIds,substituteIds,players,me?.id]);
  useEffect(()=>{
    if(!user||!me||admin||config.mode==='teams'||onboarding!=='idle'||me.status==='left'||me.status==='rejoin')return;
    if(user.user_metadata?.opengym_tutorial_version!==TUTORIAL_VERSION)setOnboarding('disclaimer');
  },[user?.id,user?.user_metadata?.opengym_tutorial_version,me?.id,me?.status,admin,config.mode,onboarding]);
  useEffect(()=>{const saved=localStorage.getItem('opengym-language');if(saved==='en'||saved==='es'||saved==='zh-CN')setLanguage(saved)},[]);
  useEffect(()=>{
    localStorage.setItem('opengym-language',language);document.documentElement.lang=language;
    const applyText=(node:Text)=>{
      const parent=node.parentElement;if(!parent||parent.closest('script,style'))return;
      let state=translationMemory.current.get(node);
      if(!state){state={original:node.data,applied:node.data};translationMemory.current.set(node,state)}else if(node.data!==state.applied)state.original=node.data;
      const translated=translateUiText(state.original,language);state.applied=translated;if(node.data!==translated)node.data=translated;
    };
    const scan=(root:Node)=>{if(root.nodeType===Node.TEXT_NODE){applyText(root as Text);return}const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let node=walker.nextNode();while(node){applyText(node as Text);node=walker.nextNode()}};
    scan(document.body);
    const observer=new MutationObserver(records=>{for(const record of records){if(record.type==='characterData')applyText(record.target as Text);for(const node of record.addedNodes)scan(node)}});
    observer.observe(document.body,{subtree:true,childList:true,characterData:true});return()=>observer.disconnect();
  },[language]);
  useEffect(()=>{
    const refreshAfterReturn=()=>{
      if(document.visibilityState!=='visible')return;
      const now=Date.now();
      if(now-lastResumeRefresh.current<1_000)return;
      lastResumeRefresh.current=now;
      void refresh(user);
    };
    document.addEventListener('visibilitychange',refreshAfterReturn);
    window.addEventListener('pageshow',refreshAfterReturn);
    window.addEventListener('focus',refreshAfterReturn);
    window.addEventListener('online',refreshAfterReturn);
    return()=>{
      document.removeEventListener('visibilitychange',refreshAfterReturn);
      window.removeEventListener('pageshow',refreshAfterReturn);
      window.removeEventListener('focus',refreshAfterReturn);
      window.removeEventListener('online',refreshAfterReturn);
    };
  },[user?.id]);
  useEffect(()=>{
    const closeDrawerFromBackdrop=(event:MouseEvent)=>{
      const target=event.target;
      if(target instanceof HTMLElement&&target.classList.contains('drawer'))setScreen('queue');
    };
    document.addEventListener('click',closeDrawerFromBackdrop);
    return()=>document.removeEventListener('click',closeDrawerFromBackdrop);
  },[]);
  useEffect(()=>{
    if(!me||me.status==='left'||me.status==='rejoin'||admin||config.mode==='teams'||!config.geofence_enabled||!navigator.geolocation)return;
    let active=true;
    const watch=navigator.geolocation.watchPosition(async position=>{
      if(!active)return;
      const result=await verifyLocation(position.coords.latitude,position.coords.longitude);
      if(!result)return;
      if(result.inside||geofenceRemovalInProgress.current)return;
      geofenceRemovalInProgress.current=true;
      const {data,error}=await supabase.rpc('remove_self_for_geofence');
      geofenceRemovalInProgress.current=false;
      if(error){setNotice({title:'Location update failed',message:error.message});return;}
      setGeofenceReturn(data as GeofenceReturn);setReturnClock(Date.now());await refresh();
    },()=>{}, {enableHighAccuracy:true,maximumAge:15_000,timeout:20_000});
    return()=>{active=false;navigator.geolocation.clearWatch(watch);geofenceRemovalInProgress.current=false;};
  },[me?.id,me?.status,admin,config.mode,config.geofence_enabled]);
  useEffect(()=>{if(!geofenceReturn)return;const timer=window.setInterval(()=>setReturnClock(Date.now()),1000);return()=>window.clearInterval(timer)},[geofenceReturn?.id]);
  useEffect(()=>{
    if(me?.status!=='rejoin'||rejoinResponse||!rejoinChecked){if(me?.status!=='rejoin')expiredRejoinHandled.current=false;return;}
    if(rejoinLookupAttempts.current<5){
      rejoinLookupAttempts.current+=1;
      setRejoinChecked(false);
      const retry=window.setTimeout(()=>void refresh(),250);
      return()=>window.clearTimeout(retry);
    }
    if(expiredRejoinHandled.current)return;
    expiredRejoinHandled.current=true;
    void (async()=>{
      const {error}=await supabase.rpc('leave_waitlist');
      if(error){expiredRejoinHandled.current=false;setNotice({title:'Could not update the waitlist',message:error.message});return;}
      await refresh();
      setNotice({title:'Rejoin time expired',message:'You did not rejoin within the allotted time, so you were removed from the waitlist.',onClose:()=>setScreen('queue')});
    })();
  },[me?.status,rejoinResponse,rejoinChecked]);
  async function boot(){
    let {data:{session}}=await supabase.auth.getSession();
    if(!session){const result=await supabase.auth.signInAnonymously(); if(result.error){setNotice({title:'Connection needed',message:result.error.message});return;} session=result.data.session;}
    setUser(session?.user??null); await refresh(session?.user??null);
    if(session?.user){
      const {data:unread}=await supabase.from('group_notifications').select('id,user_id,message,read_at').eq('user_id',session.user.id).is('read_at',null).order('created_at',{ascending:true}).limit(1).maybeSingle();
      if(unread){const notification=unread as GroupNotification;showPlayerNotification(notification,session.user.id);await supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',notification.id);}
    }
    const channel=supabase.channel('live-waitlist')
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_players'},payload=>{
        const changed=payload.new as Player;const isOwnChange=changed.user_id===session.user.id||changed.id===ownPlayerIdRef.current;
        if(isOwnChange){setOwnPlayer(changed);setForceRejoin(!['current','waiting','sitout'].includes(changed.status));ownPlayerIdRef.current=changed.id;syncOwnHostStatus(Boolean(changed.is_host),session.user.id);if(changed.status==='rejoin'){rejoinLookupAttempts.current=0;setRejoinChecked(false);window.setTimeout(()=>void refresh(),150);}}
        setPlayers(items=>{
          const affectsOwn=changed.user_id===session.user.id||items.some(player=>player.id===changed.id&&player.user_id===session.user.id);
          if(affectsOwn&&changed.status==='left')return items.filter(player=>player.id!==changed.id);
          return items.map(player=>player.id===changed.id?changed:player);
        });
        const inactiveOwn=isOwnChange&&!['current','waiting','sitout'].includes(changed.status);
        if(!adminMoveInProgress.current&&!inactiveOwn)void refresh();
      })
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_config'},()=>void refresh())
      .on('postgres_changes',{event:'*',schema:'public',table:'group_requests'},()=>void refresh())
      .on('postgres_changes',{event:'*',schema:'public',table:'substitute_requests'},()=>void refresh())
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'group_notifications'},payload=>{
        const notification=payload.new as GroupNotification;
        if(notification.user_id===session?.user.id){showPlayerNotification(notification,session.user.id);void supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',notification.id);}
      })
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'past_games'},()=>void refresh())
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'waitlist_events'},payload=>{
        const event=payload.new as {actor_user_id?:string;event_type?:string;message?:string};
        if(event.event_type==='host_appointed'||event.event_type==='host_removed')return;
        const quietEvents=new Set(['join','leave','add_player','admin_leave','admin_rejoin','admin_sitout','admin_move','admin_group','admin_group_remove','admin_substitute','admin_undo','admin_redo','geofence_leave','geofence_return']);
        if(event.actor_user_id!==session?.user.id&&event.message&&!quietEvents.has(event.event_type??''))setNotice({title:'Waitlist update',message:event.message});
      }).subscribe();
    return()=>{void supabase.removeChannel(channel)};
  }
  async function refresh(activeUser?:User|null){
    const [{data:p},{data:c},{data:g},{data:a},{data:r},{data:s},{data:rejoin,error:rejoinError},{data:geo}]=await Promise.all([
      supabase.from('waitlist_players').select('*').neq('status','left').order('queue_position'),
      supabase.from('waitlist_config').select('game_number,max_players,mode,geofence_enabled,geofence_radius_m').single(),
      supabase.from('past_games').select('*').order('game_number',{ascending:false}),
      supabase.from('admin_sessions').select('user_id').maybeSingle(),
      supabase.from('group_requests').select('*').eq('status','pending'),
      supabase.from('substitute_requests').select('*').eq('status','pending'),
      supabase.from('rejoin_responses').select('id').is('choice',null).gt('expires_at',new Date().toISOString()).order('created_at',{ascending:false}).limit(1).maybeSingle(),
      supabase.from('geofence_return_prompts').select('id,removed_at,saved_position_until,expires_at').is('resolved_at',null).gt('expires_at',new Date().toISOString()).order('removed_at',{ascending:false}).limit(1).maybeSingle()
    ]);
    const playerRows=(p??[]) as Player[];setPlayers(playerRows); if(c)setConfig(c as Config); setGames((g??[]) as Game[]);setAdmin(Boolean(a));
    const activeUid=(activeUser??user)?.id;const activeHost=Boolean(playerRows.find(item=>item.user_id===activeUid)?.is_host);if(activeUid)syncOwnHostStatus(activeHost,activeUid);
    if(a||activeHost){const {data:offline}=await supabase.rpc('admin_list_offline_rejoins');setAdminRejoins((offline??[]) as AdminRejoin[]);}else setAdminRejoins([]);
    setGroupRequests(((r??[]) as GroupRequest[]).map(request=>({...request,requester:playerRows.find(player=>player.id===request.requester_id)})));
    setSubstituteRequests(((s??[]) as SubstituteRequest[]).map(request=>({...request,requester:playerRows.find(player=>player.id===request.requester_id)})));
    setRejoinResponse(rejoin?.id??null);setRejoinChecked(!rejoinError);if(rejoin?.id)rejoinLookupAttempts.current=0;
    setGeofenceReturn((geo as GeofenceReturn|null)??null);
    const uid=(activeUser??user)?.id; let own=playerRows.find(item=>item.user_id===uid)??null;
    if(uid&&!own){const {data:storedOwn}=await supabase.from('waitlist_players').select('*').eq('user_id',uid).maybeSingle();own=(storedOwn as Player|null)??null;}
    if(own){setOwnPlayer(own);setForceRejoin(false);setScreen('queue');}
    else if(ownPlayerIdRef.current){setOwnPlayer(previous=>previous?{...previous,status:'left'}:previous);setForceRejoin(true);}
  }
  async function rpc(name:string,args:Record<string,unknown>={},showSuccess=true){
    setBusy(true); const {data,error}=await supabase.rpc(name,args); setBusy(false);
    if(error){setNotice({title:'Could not complete that',message:error.message});return false;}
    if(data?.message&&showSuccess)setNotice({title:'Done',message:data.message}); await refresh(); return true;
  }
  async function join(event:FormEvent){event.preventDefault(); const f=cleanName(first),l=cleanName(last); if(!f){setNotice({title:'Enter your name',message:'Your name needs to contain letters.'});return;}
    if(isInappropriateName(`${first} ${last}`)){setNotice(inappropriateNameNotice);return;}
    if(!await requireOnSite())return;
    if(await rpc('join_waitlist',{p_first_name:f,p_last_name:l},false)){setScreen('queue');if(config.mode!=='teams'&&user?.user_metadata?.opengym_tutorial_version!==TUTORIAL_VERSION)setOnboarding('disclaimer');}
  }
  async function completeTutorial(){
    if(!user){setOnboarding('idle');setTutorialStep(0);return;}
    const {data,error}=await supabase.auth.updateUser({data:{opengym_tutorial_completed:true,opengym_tutorial_version:TUTORIAL_VERSION}});
    if(data.user)setUser(data.user);
    if(error)setNotice({title:'Tutorial completed',message:'Your tutorial choice could not be saved to your account, but you can continue using the waitlist.'});
    setOnboarding('idle');setTutorialStep(0);
  }
  function getPosition(){return new Promise<GeolocationPosition>((resolve,reject)=>{if(!navigator.geolocation){reject(new Error('Location is not supported on this device.'));return;}navigator.geolocation.getCurrentPosition(resolve,reject,{enableHighAccuracy:true,maximumAge:10_000,timeout:20_000});});}
  async function verifyLocation(latitude:number,longitude:number){const {data,error}=await supabase.rpc('verify_facility_location',{p_latitude:latitude,p_longitude:longitude});if(error)return null;return data as {configured:boolean;inside:boolean;distance_m:number;radius_m:number};}
  async function requireOnSite(){
    if(!config.geofence_enabled)return true;
    setBusy(true);
    try{const position=await getPosition();const result=await verifyLocation(position.coords.latitude,position.coords.longitude);setBusy(false);if(!result){setNotice({title:'Location check failed',message:'We could not verify the facility location. Please try again.'});return false;}if(!result.inside){setNotice({title:'You must be at the facility',message:`You are about ${Math.round(result.distance_m)} meters from the OpenGym check-in area. Move inside the facility and try again.`});return false;}return true;}catch{setBusy(false);setNotice({title:'Location permission needed',message:'Allow location access to join or rejoin the waitlist. OpenGym only checks whether you are inside the facility area.'});return false;}
  }
  async function setFacilityLocation(){setFacilityMenu(value=>!value);}
  async function chooseFacility(code:'PHR'|'NA'){
    if(await rpc('admin_select_facility',{p_facility_code:code},false)){
      setFacilityMenu(false);
      setNotice(code==='PHR'?{title:'Pacific Highlands Ranch selected',message:'Players must be within about 150 meters of 5977 Village Center Loop Rd, San Diego, CA 92130.'}:{title:'Facility location disabled',message:'Players can join without an on-site location check.'});
    }
  }
  function ask(title:string,message:string,confirm:string,action:()=>Promise<void>,actionTone:'danger'|'success'='danger',cancelTone:'neutral'|'danger'='neutral'){setNotice({title,message,confirm,action,actionTone,cancelTone});}
  function showPlayerNotification(notification:GroupNotification,activeUserId=user?.id){
    if(handledNotificationIds.current.has(notification.id))return;handledNotificationIds.current.add(notification.id);
    if(notification.message.startsWith('HOST_APPOINTED|')&&Date.now()-hostTransitionHandledAt.current<10000)return;
    if(notification.message.startsWith('HOST_APPOINTED|')){if(!hostAppointmentActive.current){hostAppointmentActive.current=true;setPlayers(items=>items.map(player=>player.user_id===activeUserId?{...player,is_host:true}:player));setHostAppointmentNotice(notification.message.split('|')[1]||'The admin appointed you as a Session Host.')}return;}
    if(notification.message.startsWith('HOST_REMOVED|')){hostAppointmentActive.current=false;setPlayers(items=>items.map(player=>player.user_id===activeUserId?{...player,is_host:false}:player));setHostAppointmentNotice(null);setHostTutorial(false);setNotice({title:'Host permissions removed',message:notification.message.split('|')[1]||'Your Session Host permissions were removed.'});return;}
    if(notification.message.startsWith('OPERATOR_ACTION|')){setNotice({title:'An admin or host updated your player',message:notification.message.split('|')[1]||'An admin or host performed an action on your player.',cancelLabel:'Okay'});return;}
    setNotice({title:notification.message.includes('wants to group with you')?'Group request':'Group update',message:notification.message});
  }
  async function clearUnreadHostNotifications(activeUserId:string,prefix:string){
    const {data}=await supabase.from('group_notifications').select('id,message').eq('user_id',activeUserId).is('read_at',null).order('created_at',{ascending:false}).limit(10);
    const ids=((data??[]) as Pick<GroupNotification,'id'|'message'>[]).filter(item=>item.message.startsWith(prefix)).map(item=>item.id);
    await Promise.all(ids.map(id=>supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',id)));
  }
  function syncOwnHostStatus(isHost:boolean,activeUserId:string){
    if(hostTrackedUserId.current!==activeUserId){hostTrackedUserId.current=activeUserId;ownHostStatus.current=isHost;return;}
    const wasHost=ownHostStatus.current;if(wasHost===isHost)return;ownHostStatus.current=isHost;
    if(isHost){hostTransitionHandledAt.current=Date.now();hostAppointmentActive.current=true;setPlayers(items=>items.map(player=>player.user_id===activeUserId?{...player,is_host:true}:player));setHostAppointmentNotice('The admin appointed you as a Session Host.');window.setTimeout(()=>void clearUnreadHostNotifications(activeUserId,'HOST_APPOINTED|'),250);return;}
    hostAppointmentActive.current=false;setHostAppointmentNotice(null);setHostTutorial(false);setNotice({title:'Host permissions removed',message:'The admin removed your Session Host permissions.'});window.setTimeout(()=>void clearUnreadHostNotifications(activeUserId,'HOST_REMOVED|'),250);
  }
  function acknowledgeHostAppointment(){
    hostAppointmentActive.current=false;setHostAppointmentNotice(null);setNotice(null);setOnboarding('idle');setScreen('queue');
    window.setTimeout(()=>{setHostTutorialStep(0);setHostTutorial(true)},120);
  }
  async function turnOnNotifications(){setBusy(true);try{await enablePush();setNotifications(true);setNotice({title:'Notifications are on',message:"We’ll alert you when your game starts or needs a response."});}catch(error){setNotice({title:'Notifications unavailable',message:error instanceof Error?error.message:'Could not enable notifications.'});}setBusy(false);}
  async function saveName(player:Player){if(isInappropriateName(editName)){setNotice(inappropriateNameNotice);return;}const parts=cleanName(editName).split(' ');const f=parts.shift()??'';const l=parts.join(' ');if(await rpc('rename_waitlist_player',{p_player_id:player.id,p_first_name:f,p_last_name:l}))setEditing(null);}
  async function logout(){await supabase.auth.signOut();setPlayers([]);setUser(null);setScreen('welcome');await boot();}
  async function startGuestFlow(){
    setBusy(true);
    const signOutResult=await supabase.auth.signOut();
    if(signOutResult.error){setBusy(false);setNotice({title:'Could not start guest mode',message:signOutResult.error.message});return;}
    const signInResult=await supabase.auth.signInAnonymously();
    if(signInResult.error||!signInResult.data.user){setBusy(false);setNotice({title:'Could not start guest mode',message:signInResult.error?.message??'Please try again.'});return;}
    setAdmin(false);setAdminGrouping(false);setAdminGroupIds([]);setOwnPlayer(null);setUser(signInResult.data.user);
    await refresh(signInResult.data.user);
    setScreen('name');setBusy(false);
  }
  function openEmailAuth(mode:'signin'|'signup'){setAuthMode(mode);setEmail('');if(mode==='signin'){setFirst('');setLast('');}setScreen('email');}
  async function emailSignIn(event:FormEvent){
    event.preventDefault();
    const address=email.trim().toLowerCase(); const f=cleanName(first); const l=cleanName(last);
    if(!address){setNotice({title:'Enter your email',message:'Enter the email address you want to use for OpenGym.'});return;}
    if(authMode==='signup'&&(!f||!l)){setNotice({title:'Enter your full name',message:'A first and last name are required when creating an account.'});return;}
    if(authMode==='signup'&&isInappropriateName(`${first} ${last}`)){setNotice(inappropriateNameNotice);return;}
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
  async function openAdminHistory(){const {data,error}=await supabase.rpc('admin_list_waitlist_history');if(error)setNotice({title:'History unavailable',message:error.message});else{setAdminEvents((data??[]) as AdminEvent[]);setScreen('admin-history')}}
  async function openPlayerHistory(){if(!user)return;const {data,error}=await supabase.from('waitlist_events').select('id,actor_name,event_type,message,created_at').eq('actor_user_id',user.id).order('created_at',{ascending:false}).limit(100);if(error)setNotice({title:'History unavailable',message:error.message});else{setPlayerEvents((data??[]) as AdminEvent[]);setScreen('player-history')}}
  function confirmRestriction(player:Player){ask(player.restricted?'Unrestrict player?':'Restrict player?',player.restricted?`${player.display_name} will regain access to Next Game.`:`${player.display_name} will no longer be allowed to press Next Game.`,player.restricted?'Unrestrict':'Restrict',async()=>{await rpc('admin_restrict_player',{p_player_id:player.id,p_restricted:!player.restricted})})}
  function confirmHostChange(player:Player){
    setPermissionPlayer(null);
    if(player.is_host){ask(`Remove ${player.display_name} as host?`,`${player.display_name} will immediately lose the Session Host controls.`,'Yes',async()=>{await rpc('admin_set_session_host',{p_player_id:player.id,p_is_host:false})},'danger');return;}
    ask(`Appoint ${player.display_name} as host?`,'This gives them temporary permission to advance games, add and move players, manage groups, substitutions, rejoin requests, and session history.','Yes',async()=>{await rpc('admin_set_session_host',{p_player_id:player.id,p_is_host:true})},'success');
  }
  function chooseRestriction(player:Player){setPermissionPlayer(null);confirmRestriction(player)}
  function confirmAdminSitOut(player:Player){ask(`Sit out ${player.display_name}?`,`${player.display_name} will skip one game and then return with priority for the following game.`,'Sit out',async()=>{await rpc('admin_set_player_sitout',{p_player_id:player.id})})}
  function confirmAdminLeave(player:Player){ask(`Remove ${player.display_name}?`,`${player.display_name} will leave the current game or waitlist. The admin can undo this action.`,'Remove',async()=>{await rpc('admin_leave_player',{p_player_id:player.id},false)})}
  async function adminLogin(event:FormEvent){event.preventDefault();if(await rpc('sign_in_waitlist_admin',{p_username:adminUser,p_password:adminPassword})){setAdmin(true);setScreen('queue');}}
  async function adminAddPlayer(event:FormEvent){
    event.preventDefault(); const f=cleanName(adminFirst),l=cleanName(adminLast);
    if(!f){setNotice({title:'Enter a player name',message:'The player name needs to contain letters.'});return;}
    if(isInappropriateName(`${adminFirst} ${adminLast}`)){setNotice(inappropriateNameNotice);return;}
    if(await rpc('admin_add_player',{p_first_name:f,p_last_name:l},false)){setAdminFirst('');setAdminLast('');}
  }
  async function answerOfflineRejoin(player:AdminRejoin,stay:boolean){
    await rpc('admin_answer_offline_rejoin',{p_player_id:player.id,p_stay:stay},false);
  }
  async function requestGroup(player:Player){
    if(!me)return;
    const projectedGame=projectedGameForGrouping(me.id,player.id);
    ask(
      `Group up with ${player.display_name}? (Current game: Game ${config.game_number})`,
      `Grouping may move you back to the furthest group member’s position. If accepted, you are projected to play in Game ${projectedGame}.`,
      'Send request',
      async()=>{if(await rpc('request_player_group',{p_target_id:player.id},false))setNotice({title:'Group request sent',message:`Your request was sent to ${player.display_name}.`});}
    );
  }
  async function answerGroup(id:string,accept:boolean){
    const request=groupRequests.find(item=>item.id===id);
    const requesterName=request?.requester?.display_name??'the player';
    if(await rpc('answer_player_group',{p_request_id:id,p_accept:accept},false)){
      setNotice({title:accept?'Group accepted':'Group request declined',message:accept?`You are now grouped with ${requesterName}. (Current game: Game ${config.game_number})`:'The group request was declined.'});
    }
  }
  async function removeGroupMember(player:Player){await rpc('remove_player_from_group',{p_target_id:player.id});}
  function confirmLeaveOwnGroup(){ask('Leave your group?','You will keep your current queue position and become an individual player.','Leave Group',async()=>{await rpc('leave_player_group')});}
  async function adminRemoveGroupMember(player:Player){await rpc('admin_remove_player_from_group',{p_target_id:player.id});}
  function confirmMySitOut(){
    const groupMembers=me?.group_id?players.filter(player=>player.id!==me.id&&player.group_id===me.group_id):[];
    const groupIsPlaying=groupMembers.some(player=>player.status==='current');
    const groupPlaysNext=groupMembers.some(player=>projectedGames.get(player.id)===config.game_number+1);
    if(groupIsPlaying||groupPlaysNext){
      const groupTiming=groupIsPlaying?'in the current game':'scheduled for the next game';
      ask(
        'Sit out and leave your group?',
        `Your group is ${groupTiming}. If you sit out, you will leave the group and continue as an individual. You will still have priority for the game after that.`,
        'Continue',
        async()=>{await rpc('sit_out_and_leave_group');}
      );
      return;
    }
    ask('Sit out one game?',"You’ll skip one game, then receive priority for the following game.",'Sit out',async()=>{await rpc('sit_out_one_game')});
  }
  function startAdminGrouping(){
    cancelSubstitute();setNotice({title:'Create a group',message:'Select between two and six players to become a team. Tap each player card, then choose Done.',onClose:()=>{setAdminGroupIds([]);setAdminGrouping(true);}});
  }
  function cancelAdminGrouping(){setAdminGrouping(false);setAdminGroupIds([]);}
  function startAdminSubstitute(){cancelAdminGrouping();setNotice({title:'Substitute players',message:'Choose exactly two players to swap positions. Each selected player will have a blue border.',onClose:()=>{setSubstituteIds([]);setAdminSubstituting(true);}});}
  function cancelSubstitute(){setAdminSubstituting(false);setPlayerSubstituting(false);setSubstituteIds([]);}
  function previewAdminSubstitute(){
    if(substituteIds.length!==2){setNotice({title:'Choose two players',message:'Select exactly two players to swap positions.'});return;}
    const selected=substituteIds.map(id=>players.find(player=>player.id===id)).filter((player):player is Player=>Boolean(player));
    ask('Swap these players?',`${selected[0].display_name} and ${selected[1].display_name} will permanently swap positions. Either player will leave their existing group.`,'Continue',async()=>{if(await rpc('admin_substitute_players',{p_first_id:selected[0].id,p_second_id:selected[1].id})){cancelSubstitute();}},'success','danger');
  }
  function startPlayerSubstitute(){ask('Request a substitute?','Substituting sends a request to permanently swap your position with another player.','Continue',async()=>{setSubstituteIds([]);setPlayerSubstituting(true);},'success','danger');}
  function previewPlayerSubstitute(){
    const target=players.find(player=>player.id===substituteIds[0]);if(!target){setNotice({title:'Choose a player',message:'Select one player you want to swap positions with.'});return;}
    ask(`Substitute with ${target.display_name}?`,`This will send ${target.display_name} a request to permanently swap positions with you.`,'Continue',async()=>{if(await rpc('request_player_substitute',{p_target_id:target.id},false)){cancelSubstitute();setNotice({title:'Substitute request sent',message:`Your request was sent to ${target.display_name}.`});}},'success','danger');
  }
  async function answerSubstitute(id:string,accept:boolean){await rpc('answer_player_substitute',{p_request_id:id,p_accept:accept});}
  function previewAdminGroup(){
    const selected=players.filter(player=>adminGroupIds.includes(player.id)).sort(byPosition);
    if(selected.length<2){setNotice({title:'Select more players',message:'Choose at least two players before creating the group.'});return;}
    const furthestPosition=Math.max(...selected.map(player=>player.queue_position??1));
    const firstPosition=Math.max(1,furthestPosition);
    const lastPosition=firstPosition+selected.length-1;
    const projectedGame=config.game_number+Math.floor((lastPosition-1)/config.max_players);
    const range=firstPosition===lastPosition?`${firstPosition}`:`${firstPosition}-${lastPosition}`;
    ask(
      'Create this group?',
      `These players will move together to positions ${range} and are projected to play in Game ${projectedGame}. (Current Game: Game ${config.game_number})`,
      'Continue',
      async()=>{if(await rpc('admin_group_players',{p_player_ids:selected.map(player=>player.id)},false)){cancelAdminGrouping();}},
      'success',
      'danger',
    );
  }
  function projectedGameForGrouping(requesterId:string,targetId:string){
    const requester=players.find(player=>player.id===requesterId);
    const target=players.find(player=>player.id===targetId);
    const groupIds=new Set([requester?.group_id,target?.group_id].filter((id):id is string=>Boolean(id)));
    const groupedIds=new Set(players.filter(player=>player.id===requesterId||player.id===targetId||(player.group_id&&groupIds.has(player.group_id))).map(player=>player.id));
    const active=[...current,...waiting];
    const furthestIndex=active.reduce((furthest,player,index)=>groupedIds.has(player.id)?Math.max(furthest,index):furthest,0);
    return config.game_number+Math.floor(furthestIndex/config.max_players);
  }
  function projectedGameAfterGrouping(request:GroupRequest){return projectedGameForGrouping(request.requester_id,request.target_id);}
  useEffect(()=>{
    const incoming=groupRequests.find(request=>players.find(player=>player.id===request.target_id)?.user_id===user?.id);
    if(!incoming)return;
    setNotice(existing=>{
      if(existing?.requestId===incoming.id)return existing;
      const requester=incoming.requester?.display_name??'A player';
      return {
        requestId:incoming.id,
        blocking:true,
        title:`${requester} wants to group with you (Current game: Game ${config.game_number})`,
        message:`Accepting may move you back to the furthest group member’s position. If you accept, you are projected to play in Game ${projectedGameAfterGrouping(incoming)}.`,
        confirm:'Accept',
        actionTone:'success',
        action:async()=>{await answerGroup(incoming.id,true)},
        cancelLabel:'Decline',
        cancelAction:async()=>{await answerGroup(incoming.id,false)},
      };
    });
  },[groupRequests,players,user?.id,config.game_number]);
  useEffect(()=>{
    const incoming=substituteRequests.find(request=>players.find(player=>player.id===request.target_id)?.user_id===user?.id);if(!incoming)return;
    setNotice(existing=>{if(existing?.requestId===`substitute:${incoming.id}`)return existing;const requester=incoming.requester?.display_name??'A player';return{requestId:`substitute:${incoming.id}`,blocking:true,title:'Permanent substitute request',message:`${requester} wants to substitute with you. Accepting permanently swaps your positions.`,confirm:'Accept',actionTone:'success',action:async()=>{await answerSubstitute(incoming.id,true)},cancelLabel:'Decline',cancelTone:'danger',cancelAction:async()=>{await answerSubstitute(incoming.id,false)}};});
  },[substituteRequests,players,user?.id]);
  async function movePlayer(playerId:string,status:'current'|'waiting',index:number){
    setDragging(null);setDragOver(null);
    const movingPlayer=players.find(player=>player.id===playerId);
    const movingMembers=movingPlayer?.group_id
      ? players.filter(player=>player.group_id===movingPlayer.group_id)
      : movingPlayer?[movingPlayer]:[];
    const movingOutOfGame=movingPlayer?.status==='current'&&status==='waiting';
    if(!movingPlayer||movingMembers.length===0)return;
    const beforeMove=players;
    setPlayers(previewAdminMove(players,playerId,status,index,config.max_players));
    adminMoveInProgress.current=true;setBusy(true);
    const {error:moveError}=await supabase.rpc('admin_move_player',{p_player_id:playerId,p_status:status,p_index:index});
    if(moveError){adminMoveInProgress.current=false;setBusy(false);setPlayers(beforeMove);setNotice({title:'Could not move that player',message:moveError.message});await refresh();return;}
    if(movingOutOfGame){
      const excludedIds=new Set(movingMembers.map(player=>player.id));
      const {data:freshRows,error:freshError}=await supabase.from('waitlist_players').select('*').in('status',['current','waiting']).order('queue_position');
      if(freshError){adminMoveInProgress.current=false;setBusy(false);setNotice({title:'The player moved, but the game could not refill',message:freshError.message});await refresh();return;}
      const freshPlayers=(freshRows??[]) as Player[];
      let openSpots=Math.max(config.max_players-freshPlayers.filter(player=>player.status==='current').length,0);
      const freshWaiting=freshPlayers.filter(player=>player.status==='waiting');
      const seenBlocks=new Set<string>();
      for(const candidate of freshWaiting){
        if(excludedIds.has(candidate.id))continue;
        const blockKey=candidate.group_id??candidate.id;
        if(seenBlocks.has(blockKey))continue;
        seenBlocks.add(blockKey);
        const blockSize=candidate.group_id?freshWaiting.filter(player=>player.group_id===candidate.group_id).length:1;
        if(blockSize<=openSpots){
          const {error:fillError}=await supabase.rpc('admin_move_player',{p_player_id:candidate.id,p_status:'current',p_index:config.max_players});
          if(fillError){adminMoveInProgress.current=false;setBusy(false);setNotice({title:'The player moved, but the game could not refill',message:fillError.message});await refresh();return;}
          openSpots-=blockSize;
        }
        if(openSpots===0)break;
      }
    }
    adminMoveInProgress.current=false;setBusy(false);await refresh();
  }
  function showRejoinOnly(){setOwnPlayer(previous=>previous?{...previous,status:'left'}:previous);setForceRejoin(true);setPlayers(items=>items.filter(player=>player.user_id!==user?.id));}
  async function answerRejoin(choice:'stay'|'leave'){if(choice==='stay'&&!await requireOnSite())return;if(rejoinResponse&&await rpc('answer_rejoin_prompt',{p_response_id:rejoinResponse,p_choice:choice})&&choice==='leave')showRejoinOnly();setRejoinResponse(null);}
  async function leaveOwnWaitlist(){if(await rpc('leave_waitlist',{},false))showRejoinOnly();}
  async function rejoinAtBack(){if(!me)return;if(!await requireOnSite())return;if(await rpc('join_waitlist',{p_first_name:me.first_name,p_last_name:me.last_name},false))setForceRejoin(false);}
  async function returnToFacility(){
    if(!geofenceReturn)return;setBusy(true);
    try{
      const position=await getPosition();
      const {data,error}=await supabase.rpc('return_after_geofence',{p_prompt_id:geofenceReturn.id,p_latitude:position.coords.latitude,p_longitude:position.coords.longitude});
      setBusy(false);
      if(error){setNotice({title:'Could not rejoin',message:error.message});return;}
      if(!data?.inside){setNotice({title:'You are still too far away',message:'Move back inside the OpenGym facility area, then press “I’m back!” again.'});return;}
      setGeofenceReturn(null);await refresh();setNotice({title:'Welcome back',message:data.message});
    }catch{setBusy(false);setNotice({title:'Location permission needed',message:'Allow location access so OpenGym can confirm that you are back at the facility.'});}
  }
  async function advanceGame(){
    setBusy(true);const {data,error}=await supabase.rpc('end_current_game');
    if(error){setBusy(false);setNotice({title:'Could not start the next game',message:error.message});return;}
    const {data:newCurrent}=await supabase.from('waitlist_players').select('user_id').eq('status','current');
    const currentIds=(newCurrent??[]).map(row=>row.user_id).filter((id):id is string=>Boolean(id)&&id!==user?.id);
    if(currentIds.length)await supabase.functions.invoke('send-push',{body:{userIds:currentIds,notification:{title:`Game ${data.game_number} has started`,body:'You are in the current game. Head to the court!',kind:'game_started',url:'/'}}});
    for(const prompt of data.rejoin_prompts??[]){await supabase.functions.invoke('send-push',{body:{userIds:[prompt.user_id],notification:{title:'Rejoin the OpenGym waitlist?',body:'Choose Rejoin or Leave within five minutes.',kind:'rejoin',url:'/',responseId:prompt.response_id}}});}
    setBusy(false);await refresh();
  }

  if(screen==='welcome')return <Shell><section className="auth-card"><Logo/><button className="hero-button" disabled={busy} onClick={()=>void startGuestFlow()}>{busy?'Starting guest mode…':'Continue as guest'}</button><button className="admin-link" onClick={()=>setScreen('admin')}>Admin</button><p className="fine">Join the live volleyball queue from your phone.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='email')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><span className="kicker">{authMode==='signup'?'CREATE ACCOUNT':'ACCOUNT SIGN IN'}</span><h1>{authMode==='signup'?'Create your OpenGym account':'Welcome back'}</h1><p>We’ll email you a secure link—no password needed.</p><form onSubmit={emailSignIn}>{authMode==='signup'&&<><label>First name<input autoFocus value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name" autoComplete="given-name" required/></label><label>Last name<input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last name" autoComplete="family-name" required/></label></>}<label>Email address<input autoFocus={authMode==='signin'} type="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" autoComplete="email" required/></label><button className="hero-button" disabled={busy}>{busy?'Sending…':'Email me a sign-in link'}</button></form><p className="fine">The link expires for your security.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='admin')return <Shell><section className="auth-card"><div className="admin-access-heading"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><span className="kicker">ADMIN ACCESS</span></div><h1>Manage OpenGym</h1><p>Sign in to choose a waitlist mode and manage players.</p><form onSubmit={adminLogin}><label>Username<input autoFocus value={adminUser} onChange={e=>setAdminUser(e.target.value)} autoCapitalize="none"/></label><label>Password<input type="password" value={adminPassword} onChange={e=>setAdminPassword(e.target.value)}/></label><button className="hero-button" disabled={busy}>Sign in</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(!admin&&geofenceReturn){const remaining=Math.max(0,Math.ceil((new Date(geofenceReturn.expires_at).getTime()-returnClock)/1000));const saved=new Date(geofenceReturn.saved_position_until).getTime()>returnClock;return <Shell><section className="auth-card geofence-return-card"><Logo/><span className="kicker">RETURN TO THE GYM</span><h1>You’re too far away</h1><p>It seems you moved too far from the gym, so you were taken off the waitlist. Go back to the facility and press “I’m back!” below. If this looks like a mistake, please let an admin know.</p><div className="return-countdown"><strong>{formatCountdown(remaining)}</strong><span>left to return</span></div><p className="return-position-note">{saved?'Your previous position is saved for the first minute.':'Your saved-position minute has ended. You can still rejoin at the back.'}</p><button className="hero-button rejoin-at-back" disabled={busy||remaining===0} onClick={()=>void returnToFacility()}>{remaining===0?'Return window expired':busy?'Checking location…':"I’m back!"}</button></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>}
  if(me?.status==='rejoin'&&rejoinResponse)return <Shell><section className="auth-card rejoin-card"><Logo/><span className="kicker">REJOIN WAITLIST</span><h1>Do you want to rejoin?</h1><p>Your position is saved. Choose within five minutes or you’ll automatically leave the waitlist.</p><div className="rejoin-actions"><button className="next" onClick={()=>void answerRejoin('stay')}>Rejoin</button><button className="danger" onClick={()=>void answerRejoin('leave')}>Leave</button></div></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='name')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>← Go back</button><h1>What should we call you?</h1><p>Your name is added to the waitlist as soon as you continue.</p><form onSubmit={join}><label>First name<input value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name"/></label><label>Last initial or name<input value={last} onChange={e=>setLast(e.target.value)} placeholder="Optional: Last initial or name"/></label><button className="hero-button" disabled={busy}>Join waitlist</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;

  return <Shell>
    <header className="topbar"><Logo compact/><div className="top-actions">{pushSupported()&&!notifications&&<button className="icon-button" onClick={turnOnNotifications}>Enable alerts</button>}<button className="icon-button" onClick={()=>ask('Log out?','This will remove you from the waitlist and sign you out.','Log out',async()=>{await rpc('leave_waitlist',{},false);await logout()})}>Log out</button><label className="language-picker" aria-label="Change language"><span className="language-symbol" aria-hidden="true"><i>🌐</i><b>{language==='en'?'ENG':language==='es'?'ESP':'中文'}</b></span><select value={language} onChange={event=>setLanguage(event.target.value as AppLanguage)}><option value="en">English</option><option value="es">Español</option><option value="zh-CN">简体中文</option></select></label></div></header>
    <main className="queue-page">
      <section className="game-heading"><div><span className="kicker">LIVE QUEUE {admin?'· ADMIN':''}</span><h1>Game {config.game_number}</h1></div><span className="live-pill"><i/>Live</span></section>
      {admin&&facilityMenu&&<section className="facility-menu"><strong>Select facility</strong><p>Choose the affiliated recreation center for on-site check-in.</p><button className={config.geofence_enabled?'selected':''} onClick={()=>void chooseFacility('PHR')}><span>PHR</span><small>Pacific Highlands Ranch<br/>5977 Village Center Loop Rd, San Diego, CA 92130</small></button><button className={!config.geofence_enabled?'selected':''} onClick={()=>void chooseFacility('NA')}><span>N/A</span><small>No facility location requirement</small></button></section>}
      {adminGrouping&&<aside className="admin-group-toolbar"><span>{adminGroupIds.length}/6 selected</span><button className="group-cancel" onClick={cancelAdminGrouping}>Cancel</button><button className="group-done" onClick={previewAdminGroup}>Done</button></aside>}
      {(adminSubstituting||playerSubstituting)&&<aside className="admin-group-toolbar substitute-toolbar"><span>{substituteIds.length}/{adminSubstituting?2:1} selected</span><button className="group-cancel" onClick={cancelSubstitute}>Cancel</button><button className="group-done" onClick={adminSubstituting?previewAdminSubstitute:previewPlayerSubstitute}>Continue</button></aside>}
      {me&&!['current','waiting','sitout'].includes(me.status)&&<section className="my-actions"><span>Your actions</span><div><button className="rejoin-at-back top-rejoin-action" disabled={busy} onClick={()=>void rejoinAtBack()}>Rejoin</button></div></section>}
      {me&&['current','waiting','sitout'].includes(me.status)&&<section className={`my-actions ${onboarding==='tutorial'&&tutorialStep===0&&me.status!=='current'?'tutorial-focus':''}`}><span>Your actions</span><div><div className={`next-game-control ${me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)?'unavailable':''}`}><button className={`next ${me.status==='current'?'next-with-substitute':''} ${onboarding==='tutorial'&&tutorialStep===0?'tutorial-focus':''}`} disabled={busy||me.restricted||(me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0))} aria-disabled={me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)} onClick={()=>{if(me.status!=='current')return;ask('Start the next game?',`This will notify all players that ${me.display_name} advanced the queue. This cannot be quietly undone.`,'Next game',advanceGame)}}>Next game</button>{me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)&&<small>Only available when in a current game</small>}</div><button className="substitute-action" disabled={busy} onClick={playerSubstituting?cancelSubstitute:startPlayerSubstitute}>{playerSubstituting?'Cancel substitute':'Substitute'}</button><button className={`neutral ${onboarding==='tutorial'&&tutorialStep===1?'tutorial-focus':''}`} disabled={busy} onClick={confirmMySitOut}>Sit out</button><button className={`danger ${onboarding==='tutorial'&&tutorialStep===2?'tutorial-focus':''}`} disabled={busy} onClick={()=>ask('Leave the waitlist?','This removes you from the current game or queue. You can join again later.','Leave',leaveOwnWaitlist)}>Leave</button></div></section>}
      {operator&&<section className={`admin-tools ${host?'host-tools':''}`}>{host&&<span className="host-actions-title">Host Actions</span>}{admin&&<select value={config.mode} onChange={e=>void rpc('admin_set_mode',{p_mode:e.target.value})}><option value="regular">Regular waitlist</option><option value="rejoin">Rejoin waitlist</option><option value="teams">Teams mode</option></select>}<button className="next-game-tool" disabled={busy||current.length===0} onClick={()=>ask('Start the next game?','This will notify all players and advance the entire queue to the next game.','Next game',advanceGame)}>Next game</button><button className="add-player-tool" onClick={()=>setScreen('add-player')}>＋ Add player</button>{admin&&<button className="facility-tool" onClick={()=>void setFacilityLocation()}>{config.geofence_enabled?'Update facility location':'Set facility location'}</button>}<button className={adminRejoins.length?'rejoin-tool attention':'rejoin-tool'} onClick={()=>setScreen('offline-rejoin')}>Rejoin requests{adminRejoins.length?` (${adminRejoins.length})`:''}</button><button className={`group-create-tool ${adminGrouping?'active':''}`} onClick={adminGrouping?cancelAdminGrouping:startAdminGrouping}>{adminGrouping?'Cancel Grouping':'Create Group'}</button><div className="undo-redo-controls" aria-label="Undo and redo"><button aria-label="Undo last session action" onClick={()=>void rpc('admin_undo_last')}>Undo</button><button aria-label="Redo last undone session action" onClick={()=>void rpc('admin_redo_last')}>Redo</button></div><button className={`substitute-tool ${adminSubstituting?'active':''}`} onClick={adminSubstituting?cancelSubstitute:startAdminSubstitute}>{adminSubstituting?'Cancel substitute':'Substitute'}</button>{admin&&<button className="history-tool" onClick={()=>void openAdminHistory()}>History</button>}{admin&&<button className="members-tool" onClick={()=>void openMembers()}>Members</button>}{admin&&<button className="reset-tool" onClick={()=>ask('Reset the entire waitlist?','This removes every player and clears past games. The admin can undo this action.','Reset waitlist',async()=>{await rpc('admin_reset_waitlist')})}>Reset waitlist</button>}</section>}
      <QueueCard title={`Game ${config.game_number}`} subtitle={`${current.length} playing`} status="current" players={current} start={1} me={me} admin={admin} operator={operator} spotlight={onboarding==='tutorial'&&tutorialStep===3} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} requestGroup={requestGroup} leaveGroup={removeGroupMember} leaveOwnGroup={confirmLeaveOwnGroup} adminLeaveGroup={adminRemoveGroupMember} permissions={setPermissionPlayer} adminSitOut={confirmAdminSitOut} adminLeave={confirmAdminLeave} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/>
      <QueueCard title="Waitlist" subtitle={tutorialWaiting.length?`${tutorialWaiting.length} waiting`:'No one waiting'} status="waiting" players={tutorialWaiting} start={current.length+1} me={me} admin={admin} operator={operator} spotlight={onboarding==='tutorial'&&tutorialStep===4} groupSpotlight={onboarding==='tutorial'&&tutorialStep===5} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} projections={projectedGames} requestGroup={requestGroup} leaveGroup={removeGroupMember} leaveOwnGroup={confirmLeaveOwnGroup} adminLeaveGroup={adminRemoveGroupMember} permissions={setPermissionPlayer} adminSitOut={confirmAdminSitOut} adminLeave={confirmAdminLeave} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/>
      {!admin&&<button className={`history-button your-history-button ${host?'history-tool':''}`} onClick={()=>void openPlayerHistory()}>{host?'Action History':'Your history'} <span>→</span></button>}
      <button className="history-button" onClick={()=>setScreen('history')}>Past games <span>→</span></button>
      <p className="projection-note">Queue positions update live on every connected phone.</p>
    </main>
    {onboarding==='disclaimer'&&<WaitlistDisclaimer mode={config.mode} language={language} acknowledge={()=>{setTutorialStep(0);setOnboarding('tutorial')}}/>}
    {onboarding==='tutorial'&&(
      <TutorialCoach step={tutorialStep} next={()=>tutorialStep<tutorialSteps.length-1?setTutorialStep(step=>step+1):void completeTutorial()} back={()=>setTutorialStep(step=>Math.max(0,step-1))} skip={()=>void completeTutorial()}/>
    )}
    {screen==='history'&&<div className="drawer"><div className="drawer-card history-drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><h2>Past games</h2>{games.length===0?<p>No completed games yet.</p>:<div className="past-games-grid">{games.map(game=><article className="past-game" key={game.id}><strong>Game {game.game_number}</strong><ol>{game.player_names.map((name,index)=><li key={`${game.id}-${index}`}>{name}</li>)}</ol></article>)}</div>}</div></div>}
    {screen==='player-history'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><h2>{host?'Action History':'Your history'}</h2>{playerEvents.length===0?<p>{host?'You have no host actions yet.':'You have no join or leave activity yet.'}</p>:playerEvents.map(event=><article className="past-game history-row" key={event.id}><strong>{event.message}</strong><p>{new Date(event.created_at).toLocaleString()}</p></article>)}</div></div>}
    {screen==='restricted'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('members')}>← Back to members</button><h2>Restricted members</h2>{players.filter(p=>p.restricted).length===0?<p>No restricted members.</p>:players.filter(p=>p.restricted).map(player=><article className="past-game member-row" key={player.id}><strong>{player.display_name}</strong><button onClick={()=>void rpc('admin_restrict_player',{p_player_id:player.id,p_restricted:false})}>Unrestrict</button></article>)}</div></div>}
    {screen==='add-player'&&<div className="drawer"><div className="drawer-card add-player-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><h2>Add a player</h2><p>Add a walk-in player directly to the live queue. They do not need an account.</p><form onSubmit={adminAddPlayer}><label>First name<input autoFocus value={adminFirst} onChange={e=>setAdminFirst(e.target.value)} placeholder="First name"/></label><label>Last initial or name <em>optional</em><input value={adminLast} onChange={e=>setAdminLast(e.target.value)} placeholder="Last initial or name"/></label><button className="hero-button" disabled={busy}>{busy?'Adding…':'Add to waitlist'}</button></form></div></div>}
    {screen==='offline-rejoin'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><h2>Rejoin requests</h2><p>These players have 15 minutes to return to the admin. Rejoining restores their saved queue position.</p>{adminRejoins.length===0?<p>No players are waiting to rejoin.</p>:adminRejoins.map(player=><article className="past-game offline-rejoin-row" key={player.id}><div><strong>{player.display_name}</strong><p>Saved position {player.queue_position} · expires {new Date(player.expires_at).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})}</p></div><div><button className="next" onClick={()=>void answerOfflineRejoin(player,true)}>Rejoin</button><button className="danger" onClick={()=>ask(`Remove ${player.display_name}?`,'They will lose their saved position and must be added again normally.','Remove',async()=>{await answerOfflineRejoin(player,false)})}>Remove</button></div></article>)}</div></div>}
    {screen==='admin-history'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><input className="history-search" type="search" value={historySearch} onChange={e=>setHistorySearch(e.target.value)} placeholder="Looking for something?" aria-label="Search waitlist history"/><h2>Waitlist history</h2>{adminEvents.length===0?<p>No waitlist activity yet.</p>:adminEvents.filter(event=>`${event.message} ${event.actor_name} ${event.event_type}`.toLocaleLowerCase().includes(historySearch.trim().toLocaleLowerCase())).map(event=><article className="past-game history-row" key={event.id}><strong>{event.message}</strong><p>{new Date(event.created_at).toLocaleString()}</p></article>)}</div></div>}
    {screen==='members'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>← Back to waitlist</button><h2>Members</h2><button className="restricted-members-button" onClick={()=>setScreen('restricted')}>Restricted Members</button>{members.length===0?<p>No accounts have been created yet.</p>:members.map(member=><article className="past-game" key={member.user_id}><strong>{member.player_name??member.email??member.phone??'Member'}</strong><p>{member.email??member.phone??'Verified account'} · Joined {new Date(member.created_at).toLocaleDateString()}</p></article>)}</div></div>}
    {permissionPlayer&&<PermissionsModal player={permissionPlayer} close={()=>setPermissionPlayer(null)} hostAction={()=>confirmHostChange(permissionPlayer)} restrictAction={()=>chooseRestriction(permissionPlayer)}/>}
    {hostTutorial&&<HostTutorial step={hostTutorialStep} next={()=>hostTutorialStep<hostTutorialSteps.length-1?setHostTutorialStep(value=>value+1):setHostTutorial(false)} back={()=>setHostTutorialStep(value=>Math.max(0,value-1))} skip={()=>setHostTutorial(false)}/>}
    {hostAppointmentNotice&&<HostAppointmentModal message={hostAppointmentNotice} start={acknowledgeHostAppointment}/>}
    {notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
}

function previewAdminMove(source:Player[],playerId:string,targetStatus:'current'|'waiting',targetIndex:number,maxPlayers:number){
  const moving=source.find(player=>player.id===playerId);if(!moving)return source;
  const movingMembers=(moving.group_id?source.filter(player=>player.group_id===moving.group_id):[moving]).sort(byPosition);
  const movingIds=new Set(movingMembers.map(player=>player.id));
  let current=source.filter(player=>player.status==='current'&&!movingIds.has(player.id)).sort(byPosition);
  let waiting=source.filter(player=>(player.status==='waiting'||player.status==='sitout')&&!movingIds.has(player.id)).sort(byPosition);
  const originalTarget=source.filter(player=>player.status===targetStatus||(targetStatus==='waiting'&&player.status==='sitout')).sort(byPosition);
  const removedBefore=originalTarget.slice(0,targetIndex).filter(player=>movingIds.has(player.id)).length;
  const insertion=Math.max(0,Math.min(targetIndex-removedBefore,targetStatus==='current'?current.length:waiting.length));
  const movedBlock=movingMembers.map(player=>({...player,status:targetStatus,queue_position:null}));
  if(targetStatus==='current')current.splice(insertion,0,...movedBlock);else waiting.splice(insertion,0,...movedBlock);
  if(current.length>maxPlayers){const overflow=current.splice(maxPlayers);waiting=[...overflow.map(player=>({...player,status:'waiting' as PlayerStatus})),...waiting];}
  if(current.length<maxPlayers){
    const excluded=moving.status==='current'&&targetStatus==='waiting'?movingIds:new Set<string>();
    for(let cursor=0;cursor<waiting.length&&current.length<maxPlayers;){
      const candidate=waiting[cursor];const block=candidate.group_id?waiting.filter(player=>player.group_id===candidate.group_id):[candidate];
      if(block.some(player=>excluded.has(player.id))||block.length>maxPlayers-current.length){cursor+=block.length;continue;}
      const blockIds=new Set(block.map(player=>player.id));waiting=waiting.filter(player=>!blockIds.has(player.id));current.push(...block.map(player=>({...player,status:'current' as PlayerStatus})));cursor=0;
    }
  }
  const active=[...current,...waiting].map((player,index)=>({...player,queue_position:index+1}));
  const activeIds=new Set(active.map(player=>player.id));return [...active,...source.filter(player=>!activeIds.has(player.id)&&!movingIds.has(player.id))];
}
function projectQueueGames(players:Player[],currentGame:number,maxPlayers:number){
  const blocks:Array<{members:Player[]}>=[];const blockById=new Map<string,{members:Player[]}>();
  for(const player of players){const key=player.group_id??player.id;let block=blockById.get(key);if(!block){block={members:[]};blockById.set(key,block);blocks.push(block)}block.members.push(player)}
  const projections=new Map<string,number>();let remaining=[...blocks];let game=currentGame+1;
  while(remaining.length){let spots=maxPlayers;const deferred:typeof remaining=[];let selected=0;
    for(const block of remaining){if(block.members.length<=spots){for(const player of block.members)projections.set(player.id,game);spots-=block.members.length;selected+=block.members.length}else deferred.push(block)}
    if(selected===0){for(const player of deferred[0].members)projections.set(player.id,game);deferred.shift()}
    remaining=deferred;game++;
  }
  return projections;
}
function byPosition(a:Player,b:Player){return (a.queue_position??Number.MAX_SAFE_INTEGER)-(b.queue_position??Number.MAX_SAFE_INTEGER)}
function Shell({children}:{children:React.ReactNode}){const [theme,setTheme]=useState<'dark'|'light'>('dark');useEffect(()=>{const saved=localStorage.getItem('opengym-theme');setTheme(saved==='dark'||saved==='light'?saved:(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'));},[]);function toggleTheme(){const next=theme==='dark'?'light':'dark';setTheme(next);localStorage.setItem('opengym-theme',next)}const nextTheme=theme==='dark'?'light':'dark';return <div className={`app-shell theme-${theme}`}><button className="theme-switch" aria-label={`Switch to ${nextTheme} mode`} title={`Switch to ${nextTheme} mode`} onClick={toggleTheme}><span className="theme-track" aria-hidden="true"><i className="theme-thumb">{theme==='dark'?'☾':'☀'}</i></span></button>{children}</div>}
function Logo({compact=false}:{compact?:boolean}){return <div className={`logo ${compact?'compact':''}`}><span><img src="/open-gym-app-icon.png" alt=""/></span><div><strong>OpenGym</strong>{!compact&&<small>VOLLEYBALL WAITLIST</small>}</div></div>}
function WaitlistDisclaimer({mode,language,acknowledge}:{mode:Config['mode'];language:AppLanguage;acknowledge:()=>void}){
 const rejoin=mode==='rejoin';
 const title=language==='es'?`Esta es una lista ${rejoin?'de REINGRESO':'REGULAR'}`:language==='zh-CN'?`这是${rejoin?'重新加入':'普通'}等候名单`:`This is a ${mode.toUpperCase()} waitlist`;
 const details=language==='es'?(rejoin?'Después de jugar, vuelve a ingresar dentro de cinco minutos para conservar tu lugar.':'Permaneces en la fila hasta que tú o un administrador te retire.'):language==='zh-CN'?(rejoin?'比赛结束后，请在五分钟内重新加入以保留位置。':'你会保留在队列中，直到你或管理员将你移除。'):(rejoin?'After you play, rejoin within five minutes to keep your place.':'You stay in line until you or an admin removes you.');
 const permission=language==='es'?'Solo los jugadores del juego actual pueden presionar Siguiente juego.':language==='zh-CN'?'只有当前上场的球员可以点击“下一场”。':'Only current-game players can press Next Game.';
 return <div className="onboarding-backdrop"><section className="onboarding-card" role="dialog" aria-modal="true" aria-labelledby="waitlist-mode-title"><span className="onboarding-kicker">BEFORE YOU START</span><h2 id="waitlist-mode-title">{title}</h2><p>{details} <strong>{permission}</strong></p><button className="hero-button" onClick={acknowledge}>I acknowledge</button></section></div>;
}
const tutorialSteps=[
 {title:'Next Game affects everyone',message:'This button appears only when you are in the current game. Pressing it ends that game, advances the entire queue, and notifies every player—so use it only when the game is truly over.'},
 {title:'Sit Out affects only you',message:'Sit Out makes only you skip the next game. Everyone else keeps their order. After skipping one game, you receive priority for the following game.'},
 {title:'Leave removes only you',message:'Leave removes only your name from the current game or waitlist. Other players remain in order, and you can join again later.'},
 {title:'Who is playing now',message:'The players in this card are in the current game. Only they—and admins—can start the next game.'},
 {title:'Your place in line',message:'Your number is your queue position. When you are waiting, your projected game appears beside your name.'},
 {title:'Group Up',message:'Use Group Up beside another player when you want to play together.'},
];

const hostTutorialSteps=[
 {title:'Add Player',message:'Use Add Player to check in someone who does not have their phone.',target:'.add-player-tool'},
 {title:'Rejoin Requests',message:'Rejoin Requests are usually for players without a phone who joined through you. After they play, they can return to you and ask you to help them rejoin the waitlist.',target:'.rejoin-tool'},
 {title:'Create Group',message:'Use Create Group to select players who want to play together.',target:'.group-create-tool'},
 {title:'Substitute',message:'Use Substitute to select two players and permanently swap their positions.',target:'.substitute-tool'},
 {title:'Sit Out and Remove',message:'Use Sit Out beside a player to skip only that player for one game. Use Remove to take that player off the waitlist.',target:'.admin-player-actions'},
 {title:'History',message:'History shows when players joined, left, sat out, grouped, substituted, or changed games during this waitlist.',target:'.history-tool'},
];

function PermissionsModal({player,close,hostAction,restrictAction}:{player:Player;close:()=>void;hostAction:()=>void;restrictAction:()=>void}){return <div className="modal-backdrop" role="presentation"><section className="modal permissions-modal" role="dialog" aria-modal="true"><span className="modal-mark">OG</span><h2>Permissions for {player.display_name}</h2><p>Choose the permission change you want to make.</p><div className="permission-actions"><button className="next" onClick={hostAction}>{player.is_host?'Remove Host':'Appoint as Host'}</button><button className="danger" onClick={restrictAction}>{player.restricted?'Unrestrict':'Restrict'}</button><button className="neutral" onClick={close}>Cancel</button></div></section></div>}

function HostAppointmentModal({message,start}:{message:string;start:()=>void}){return <div className="modal-backdrop" role="presentation"><section className="modal" role="dialog" aria-modal="true"><span className="modal-mark">OG</span><h2>You are now a Session Host</h2><p>{message}</p><div className="modal-actions host-appointment-actions"><button className="next" onClick={start}>Host Tutorial</button></div></section></div>}

function useTutorialInteractionLock(){useEffect(()=>{document.body.classList.add('tutorial-locked');const lockedNodes=[...document.querySelectorAll<HTMLElement>('.theme-switch,.topbar,.queue-page')];lockedNodes.forEach(node=>{node.inert=true});const preventOutsideTutorial=(event:Event)=>{if(!(event.target as Element|null)?.closest?.('.tutorial-coach'))event.preventDefault()};const preventScrollKeys=(event:KeyboardEvent)=>{if((event.target as Element|null)?.closest?.('.tutorial-coach'))return;if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(event.key))event.preventDefault()};window.addEventListener('wheel',preventOutsideTutorial,{passive:false});window.addEventListener('touchmove',preventOutsideTutorial,{passive:false});window.addEventListener('keydown',preventScrollKeys,{capture:true});return()=>{document.body.classList.remove('tutorial-locked');lockedNodes.forEach(node=>{node.inert=false});window.removeEventListener('wheel',preventOutsideTutorial);window.removeEventListener('touchmove',preventOutsideTutorial);window.removeEventListener('keydown',preventScrollKeys,{capture:true})}},[])}
function HostTutorial({step,next,back,skip}:{step:number;next:()=>void;back:()=>void;skip:()=>void}){useTutorialInteractionLock();const item=hostTutorialSteps[step];const [placement,setPlacement]=useState<'top'|'bottom'>('bottom');useEffect(()=>{document.querySelectorAll('.host-tutorial-focus').forEach(node=>node.classList.remove('host-tutorial-focus'));const target=document.querySelector(item.target) as HTMLElement|null;if(!target)return;target.classList.add('host-tutorial-focus');target.scrollIntoView({behavior:'smooth',block:'center'});const frame=requestAnimationFrame(()=>setPlacement(target.getBoundingClientRect().top<window.innerHeight/2?'bottom':'top'));return()=>{cancelAnimationFrame(frame);target.classList.remove('host-tutorial-focus')}},[item.target]);return <><div className="tutorial-scrim"/><section className={`tutorial-coach host-tutorial host-tutorial-${placement}`} role="dialog" aria-modal="true"><div className="tutorial-progress"><span>HOST TOUR · {step+1} OF {hostTutorialSteps.length}</span><button onClick={skip}>Skip tutorial</button></div><h2>{item.title}</h2><p>{item.message}</p><div className="tutorial-actions">{step>0&&<button className="neutral" onClick={back}>Back</button>}<button className="next" onClick={next}>{step===hostTutorialSteps.length-1?'Finish':'Next'}</button></div></section></>}
function TutorialCoach({step,next,back,skip}:{step:number;next:()=>void;back:()=>void;skip:()=>void}){useTutorialInteractionLock();const item=tutorialSteps[step];useEffect(()=>{const frame=requestAnimationFrame(()=>{const target=step===4?document.querySelector('[data-drop-status="waiting"]'):step===5?document.querySelector('.tutorial-group-target'):document.querySelector('.tutorial-focus');target?.scrollIntoView({behavior:'smooth',block:step>=4?'end':'center'})});return()=>cancelAnimationFrame(frame)},[step]);return <><div className="tutorial-scrim"/><section className={`tutorial-coach ${step>=4?'tutorial-coach-contextual':''} ${step===4?'tutorial-coach-waitlist':''} ${step===5?'tutorial-coach-groups':''}`} role="dialog" aria-modal="true" aria-live="polite"><div className="tutorial-progress"><span>QUICK TOUR · {step+1} OF {tutorialSteps.length}</span><button onClick={skip}>Skip tutorial</button></div><h2>{item.title}</h2><p>{item.message}</p><div className="tutorial-actions">{step>0&&<button className="neutral" onClick={back}>Back</button>}<button className="next" onClick={next}>{step===tutorialSteps.length-1?'Finish':'Next'}</button></div></section></>}
function createPlayerDragPreview(player:Player,players:Player[],start:number){
 const movingPlayers=player.group_id?players.filter(candidate=>candidate.group_id===player.group_id):[player];
 const preview=document.createElement('div');preview.className='admin-drag-preview';preview.setAttribute('aria-hidden','true');
 if(movingPlayers.length>1){const label=document.createElement('div');label.className='admin-drag-preview-label';label.textContent=`Moving group · ${movingPlayers.length} players`;preview.appendChild(label);}
 for(const movingPlayer of movingPlayers){const row=document.createElement('div');row.className='admin-drag-preview-row';const position=document.createElement('span');position.textContent=String(start+players.indexOf(movingPlayer));const name=document.createElement('strong');name.textContent=movingPlayer.display_name;row.append(position,name);preview.appendChild(row);}
 return preview;
}
function setPlayerDragPreview(event:React.DragEvent<HTMLElement>,player:Player,players:Player[],start:number){
 const preview=createPlayerDragPreview(player,players,start);
 document.body.appendChild(preview);event.dataTransfer.setDragImage(preview,24,28);window.setTimeout(()=>preview.remove(),0);
}

function formatCountdown(totalSeconds:number){const minutes=Math.floor(totalSeconds/60);const seconds=totalSeconds%60;return `${minutes}:${String(seconds).padStart(2,'0')}`}
type DropPlacement={status:'current'|'waiting';index:number;marker:string|null};
function resolveDropPlacement(x:number,y:number):DropPlacement|null{
 const element=document.elementFromPoint(x,y);const row=element?.closest<HTMLElement>('[data-player-id]');const card=element?.closest<HTMLElement>('[data-drop-status]');
 if(!card)return null;const status=card.dataset.dropStatus as 'current'|'waiting';
 if(!row)return{status,index:Number(card.dataset.playerCount??0),marker:null};
 const groupId=row.dataset.groupId;let first=row,last=row;
 if(groupId){const grouped=[...card.querySelectorAll<HTMLElement>('[data-player-id]')].filter(item=>item.dataset.groupId===groupId);if(grouped.length){first=grouped[0];last=grouped[grouped.length-1];}}
 const before=y<(first.getBoundingClientRect().top+last.getBoundingClientRect().bottom)/2;const edge=before?first:last;
 const base=Number(edge.dataset.playerIndex);return{status,index:base+(before?0:1),marker:`${before?'before':'after'}:${edge.dataset.playerId}`};
}

function QueueCard({title,subtitle,status,players,start,me,admin=false,operator=false,spotlight=false,groupSpotlight=false,editing,editName,setEditing,setEditName,saveName,requestGroup,leaveGroup,leaveOwnGroup,adminLeaveGroup,permissions,adminSitOut,adminLeave,dragging,dragOver,setDragging,setDragOver,movePlayer,projections}:{title:string;subtitle:string;status:'current'|'waiting';players:Player[];start:number;me?:Player;admin?:boolean;operator?:boolean;spotlight?:boolean;groupSpotlight?:boolean;editing:string|null;editName:string;setEditing:(v:string|null)=>void;setEditName:(v:string)=>void;saveName:(p:Player)=>void;requestGroup:(p:Player)=>Promise<void>;leaveGroup:(p:Player)=>Promise<void>;leaveOwnGroup:()=>void;adminLeaveGroup:(p:Player)=>Promise<void>;permissions:(p:Player)=>void;adminSitOut:(p:Player)=>void;adminLeave:(p:Player)=>void;dragging:string|null;dragOver:string|null;setDragging:(v:string|null)=>void;setDragOver:(v:string|null)=>void;movePlayer:(id:string,status:'current'|'waiting',index:number)=>Promise<void>;projections?:Map<string,number>}){
 const draggingPlayer=players.find(player=>player.id===dragging);
 useEffect(()=>{if(!groupSpotlight)return;const button=document.querySelector<HTMLElement>('[data-drop-status="waiting"] .group-button');if(!button)return;button.classList.add('tutorial-focus','tutorial-group-target');return()=>button.classList.remove('tutorial-focus','tutorial-group-target')},[groupSpotlight,players.length]);
 const mobileDrag=useRef<{timer:number|null;active:boolean;preview:HTMLElement|null;startX:number;startY:number;lastX:number;lastY:number;frame:number|null}>({timer:null,active:false,preview:null,startX:0,startY:0,lastX:0,lastY:0,frame:null});
 const updateMobileTarget=(x:number,y:number)=>{setDragOver(resolveDropPlacement(x,y)?.marker??null);};
 const stopAutoScroll=()=>{if(mobileDrag.current.frame!==null){cancelAnimationFrame(mobileDrag.current.frame);mobileDrag.current.frame=null;}};
 const startAutoScroll=()=>{if(mobileDrag.current.frame!==null)return;const tick=()=>{if(!mobileDrag.current.active){mobileDrag.current.frame=null;return;}const y=mobileDrag.current.lastY;const edge=Math.min(110,window.innerHeight*.18);const direction=y<edge?-1:y>window.innerHeight-edge?1:0;if(direction){const strength=Math.max(.25,1-Math.min(y,window.innerHeight-y)/edge);window.scrollBy(0,direction*(5+13*strength));updateMobileTarget(mobileDrag.current.lastX,y);}mobileDrag.current.frame=requestAnimationFrame(tick)};mobileDrag.current.frame=requestAnimationFrame(tick);};
 useEffect(()=>{if(!operator)return;const beginDesktopDrag=(event:PointerEvent)=>{if(document.body.classList.contains('admin-group-selecting')||event.pointerType!=='mouse'||event.button!==0)return;const target=event.target as HTMLElement;if(target.closest('button,input'))return;const row=target.closest<HTMLElement>('[data-player-id]');if(!row||row.dataset.playerStatus!==status)return;const player=players.find(item=>item.id===row.dataset.playerId);if(!player)return;event.preventDefault();const state=mobileDrag.current;state.startX=state.lastX=event.clientX;state.startY=state.lastY=event.clientY;state.active=true;setDragging(player.id);row.setPointerCapture(event.pointerId);const preview=createPlayerDragPreview(player,players,start);preview.classList.add('mobile-admin-drag-preview');document.body.appendChild(preview);state.preview=preview;document.body.classList.add('mobile-admin-dragging');preview.style.transform=`translate3d(${event.clientX+14}px,${event.clientY+14}px,0)`;startAutoScroll();};document.addEventListener('pointerdown',beginDesktopDrag,{capture:true});return()=>document.removeEventListener('pointerdown',beginDesktopDrag,{capture:true});},[operator,players,start,status]);
 useEffect(()=>{if(!operator)return;const card=document.querySelector<HTMLElement>(`[data-drop-status="${status}"]`);if(!card)return;const buttons:HTMLButtonElement[]=[];for(const player of players){if(!player.group_id||players.filter(member=>member.group_id===player.group_id).length<2)continue;const row=card.querySelector<HTMLElement>(`[data-player-id="${player.id}"]`);const actions=row?.querySelector('.admin-player-actions');if(!row||!actions)continue;const button=document.createElement('button');button.type='button';button.className='admin-leave-group-button';button.textContent='Leave group';button.setAttribute('aria-label',`Remove ${player.display_name} from group`);button.onclick=()=>void adminLeaveGroup(player);row.insertBefore(button,actions);buttons.push(button);}return()=>buttons.forEach(button=>button.remove());},[operator,adminLeaveGroup,players,status]);
 const finishMobileDrag=(player:Player,x:number,y:number)=>{const state=mobileDrag.current;if(state.timer!==null)window.clearTimeout(state.timer);document.removeEventListener('touchmove',preventNativeTouchScroll);stopAutoScroll();if(state.active){const placement=resolveDropPlacement(x,y);if(placement)void movePlayer(player.id,placement.status,placement.index);}state.preview?.remove();document.body.classList.remove('mobile-admin-dragging');mobileDrag.current={timer:null,active:false,preview:null,startX:0,startY:0,lastX:0,lastY:0,frame:null};setDragging(null);setDragOver(null);};
 return <section data-drop-status={status} data-player-count={players.length} className={`queue-card ${dragging?'is-dragging':''} ${spotlight?'tutorial-focus':''}`} onDragOver={e=>{e.preventDefault();setDragOver(resolveDropPlacement(e.clientX,e.clientY)?.marker??null)}} onDrop={e=>{e.preventDefault();const placement=resolveDropPlacement(e.clientX,e.clientY);if(dragging&&placement)void movePlayer(dragging,placement.status,placement.index)}}><header><h2>{title}</h2><span>{subtitle}</span></header><div>{players.length===0?<p className="empty">Players will appear here.</p>:players.map((player,index)=>{const own=player.user_id===me?.user_id;const projection=projections?.get(player.id)??null;const sameGroupBefore=Boolean(player.group_id&&players[index-1]?.group_id===player.group_id);const sameGroupAfter=Boolean(player.group_id&&players[index+1]?.group_id===player.group_id);const hasGroupMember=Boolean(player.group_id&&players.some(other=>other.id!==player.id&&other.group_id===player.group_id));const groupClass=hasGroupMember?(!sameGroupBefore?'grouped group-start':!sameGroupAfter?'grouped group-end':'grouped group-middle'):'';const sameGroup=Boolean(me?.group_id&&player.group_id===me.group_id);const ownGroupStart=Boolean(!operator&&sameGroup&&!sameGroupBefore&&hasGroupMember);return <article data-player-id={player.id} data-player-status={status} data-player-index={index} data-group-id={player.group_id??''} draggable={operator} onPointerDown={e=>{if(!operator||e.pointerType==='mouse'||(e.target as HTMLElement).closest('button,input'))return;const row=e.currentTarget;const state=mobileDrag.current;state.startX=state.lastX=e.clientX;state.startY=state.lastY=e.clientY;document.addEventListener('touchmove',preventNativeTouchScroll,{passive:false});state.timer=window.setTimeout(()=>{state.active=true;setDragging(player.id);row.setPointerCapture(e.pointerId);const preview=createPlayerDragPreview(player,players,start);preview.classList.add('mobile-admin-drag-preview');document.body.appendChild(preview);state.preview=preview;document.body.classList.add('mobile-admin-dragging');navigator.vibrate?.(35);preview.style.transform=`translate3d(${state.lastX+14}px,${state.lastY+14}px,0)`;startAutoScroll();},280)}} onPointerMove={e=>{const state=mobileDrag.current;state.lastX=e.clientX;state.lastY=e.clientY;if(!state.active){if(Math.hypot(e.clientX-state.startX,e.clientY-state.startY)>16&&state.timer!==null){window.clearTimeout(state.timer);state.timer=null;document.removeEventListener('touchmove',preventNativeTouchScroll);}return;}e.preventDefault();if(state.preview)state.preview.style.transform=`translate3d(${e.clientX+14}px,${e.clientY+14}px,0)`;updateMobileTarget(e.clientX,e.clientY)}} onPointerUp={e=>finishMobileDrag(player,e.clientX,e.clientY)} onPointerCancel={e=>finishMobileDrag(player,e.clientX,e.clientY)} onDragStart={e=>{setDragging(player.id);e.dataTransfer.effectAllowed='move';setPlayerDragPreview(e,player,players,start)}} onDragEnd={()=>{setDragging(null);setDragOver(null)}} onDragOver={e=>{e.preventDefault();e.stopPropagation();setDragOver(resolveDropPlacement(e.clientX,e.clientY)?.marker??null)}} onDrop={e=>{e.preventDefault();e.stopPropagation();const placement=resolveDropPlacement(e.clientX,e.clientY);if(dragging&&placement)void movePlayer(dragging,placement.status,placement.index)}} className={`player-row ${operator?'admin-row':''} ${own?'own':''} ${ownGroupStart?'own-group-start':''} ${groupClass} ${draggingPlayer?.group_id?(player.group_id===draggingPlayer.group_id?'dragging':''):(dragging===player.id?'dragging':'')} ${dragOver===('before:'+player.id)&&dragging!==player.id?'drop-space-before':''} ${dragOver===('after:'+player.id)&&dragging!==player.id?'drop-space-after':''}`} key={player.id}>{ownGroupStart&&<span className="your-group-label">Your Group</span>}<span className="position">{start+index}</span><div className="player-name">{(own||admin)&&<button className="pencil" aria-label="Edit player name" onClick={()=>{setEditing(player.id);setEditName(`${player.first_name} ${player.last_name}`.trim())}}>✎</button>}{editing===player.id?<input className="inline-name" autoFocus value={editName} onChange={e=>setEditName(e.target.value)} onBlur={()=>void saveName(player)} onKeyDown={e=>{if(e.key==='Enter')void saveName(player);if(e.key==='Escape')setEditing(null)}}/>:<><strong>{player.display_name}{player.is_host?' (Host)':''}{player.restricted&&(own||admin)?' (restricted)':''}</strong>{(own||operator)&&projection&&<small>Projected: Game {projection}</small>}{player.status==='sitout'&&<small>Sitting out next game</small>}</>}</div>{own&&!admin&&hasGroupMember&&<button className="leave-own-group-button" onClick={leaveOwnGroup}>Leave Group</button>}{own&&<span className="you">You</span>}{!own&&me&&!operator&&(sameGroup?<button className="group-button remove-group-button" onClick={()=>void leaveGroup(player)}>Remove</button>:<button className="group-button" onClick={()=>void requestGroup(player)}>Group Up</button>)}{operator&&<div className="admin-player-actions"><button className="admin-sitout-button" onClick={()=>adminSitOut(player)}>Sit out</button><button className="admin-leave-button" onClick={()=>adminLeave(player)}>Leave</button>{admin&&<button className="restrict-button" onClick={()=>permissions(player)}>Permissions</button>}</div>}</article>})}</div></section>
}
function Modal({notice,close,busy}:{notice:Exclude<Notice,null>;close:()=>void;busy:boolean}){const dismiss=async()=>{close();await notice.cancelAction?.();notice.onClose?.()};return <div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget&&!notice.blocking&&!notice.onClose)void dismiss()}}><section className="modal" role="dialog" aria-modal="true"><span className="modal-mark">OG</span><h2>{notice.title}</h2><p>{notice.message}</p><div className="modal-actions">{notice.action&&<button className={notice.actionTone==='success'?'next':'danger'} disabled={busy} onClick={async()=>{close();await notice.action?.();notice.onClose?.()}}>{notice.confirm}</button>}<button className={notice.cancelTone==='danger'?'danger':'neutral'} disabled={busy} onClick={()=>void dismiss()}>{notice.cancelLabel??(notice.action?'Cancel':'OK')}</button></div></section></div>}
