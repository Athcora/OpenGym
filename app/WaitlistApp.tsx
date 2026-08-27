"use client";

import { FormEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { enablePush, pushSupported } from './push';
import { supabase } from './supabase';
import { translateUiText, type AppLanguage } from './i18n';
import './admin-player.css';

type PlayerStatus = 'current' | 'waiting' | 'sitout' | 'rejoin' | 'left';
type Player = { id:string; user_id:string|null; first_name:string; last_name:string; display_name:string; status:PlayerStatus; queue_position:number|null; restricted:boolean; group_id:string|null; team_id:string|null; is_host:boolean; court_number:number|null; sitout_priority?:boolean; sitout_from_game?:number|null };
type Game = { id:string; game_number:number; court_number:number; player_names:string[]; ended_at:string };
type Config = { game_number:number; max_players:number; court_count:number; mode:'regular'|'rejoin'|'teams'; geofence_enabled:boolean; geofence_radius_m:number; king_max_wins:number|null };
type Court = { court_number:number; game_number:number; started_at:string; team_mode?:'rotation'|'king'; team_max_wins?:number|null };
type KingTeam = { id:string;name:string;status:'waiting'|'current';queue_position:number;court_number:number|null;court_side:1|2|null;consecutive_wins:number;members:Player[] };
type GroupRequest = { id:string; requester_id:string; target_id:string; status:string; requester?:Player };
type SubstituteRequest = { id:string; requester_id:string; target_id:string; status:string; requester?:Player };
type GroupNotification = { id:string; user_id:string; message:string; read_at:string|null };
type Member = { user_id:string;email:string|null;phone:string|null;created_at:string;player_name:string|null };
type AdminRejoin = { id:string;display_name:string;queue_position:number;expires_at:string };
type AdminEvent = { id:number;actor_name:string;event_type:string;message:string;created_at:string };
type GeofenceReturn = { id:string;removed_at:string;saved_position_until:string;expires_at:string };
type RejoinResponse = { id:string;expires_at:string };
type Notice = { title:string; message:string; confirm?:string; action?:()=>Promise<void>; onClose?:()=>void; actionTone?:'danger'|'success'; cancelTone?:'neutral'|'danger'|'success'; cancelLabel?:string; cancelAction?:()=>Promise<void>; blocking?:boolean; requestId?:string } | null;
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
  const [config,setConfig]=useState<Config>({game_number:1,max_players:12,court_count:1,mode:'regular',geofence_enabled:false,geofence_radius_m:150,king_max_wins:2});
  const [courts,setCourts]=useState<Court[]>([{court_number:1,game_number:1,started_at:new Date(0).toISOString()}]);
  const [kingTeams,setKingTeams]=useState<KingTeam[]>([]);
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
  const [rejoinResponse,setRejoinResponse]=useState<RejoinResponse|null>(null); const [rejoinChecked,setRejoinChecked]=useState(false);
  const [dragging,setDragging]=useState<string|null>(null);const [dragOver,setDragOver]=useState<DropPlacement|null>(null);
  const [members,setMembers]=useState<Member[]>([]);
  const [adminFirst,setAdminFirst]=useState(''); const [adminLast,setAdminLast]=useState('');
  const [adminRejoins,setAdminRejoins]=useState<AdminRejoin[]>([]); const [adminEvents,setAdminEvents]=useState<AdminEvent[]>([]); const [playerEvents,setPlayerEvents]=useState<AdminEvent[]>([]); const [historySearch,setHistorySearch]=useState('');
  const [ownPlayer,setOwnPlayer]=useState<Player|null>(null);
  const [forceRejoin,setForceRejoin]=useState(false);
  const [onboarding,setOnboarding]=useState<OnboardingStage>('idle'); const [tutorialStep,setTutorialStep]=useState(0);
  const [facilityMenu,setFacilityMenu]=useState(false);
  const [adminGrouping,setAdminGrouping]=useState(false); const [adminGroupIds,setAdminGroupIds]=useState<string[]>([]);
  const [adminSubstituting,setAdminSubstituting]=useState(false); const [playerSubstituting,setPlayerSubstituting]=useState(false); const [substituteIds,setSubstituteIds]=useState<string[]>([]);
  const [language,setLanguage]=useState<AppLanguage>('en'); const translationMemory=useRef(new WeakMap<Text,{original:string;applied:string}>()); const translationAttributeMemory=useRef(new WeakMap<Element,Map<string,{original:string;applied:string}>>());
  const [geofenceReturn,setGeofenceReturn]=useState<GeofenceReturn|null>(null); const [returnClock,setReturnClock]=useState(Date.now());
  const [permissionPlayer,setPermissionPlayer]=useState<Player|null>(null); const [hostAppointmentNotice,setHostAppointmentNotice]=useState<string|null>(null); const [hostTutorial,setHostTutorial]=useState(false); const [hostTutorialStep,setHostTutorialStep]=useState(0);
  const [pendingNextGameEvent,setPendingNextGameEvent]=useState<{message:string}|null>(null);
  const geofenceRemovalInProgress=useRef(false); const expiredRejoinHandled=useRef(false); const lastResumeRefresh=useRef(0); const adminMoveInProgress=useRef(false); const handledNotificationIds=useRef(new Set<string>()); const ownHostStatus=useRef(false); const adminAccess=useRef(false); const ownPlayerIdRef=useRef<string|null>(null); const hostTrackedUserId=useRef<string|null>(null); const hostTransitionHandledAt=useRef(0); const hostAppointmentActive=useRef(false); const locationIntroShown=useRef(false); const courtCountInputRef=useRef<HTMLInputElement|null>(null); const refreshTimer=useRef<number|null>(null); const screenRef=useRef(screen); const realtimeChannel=useRef<ReturnType<typeof supabase.channel>|null>(null);
  const activeStatusRef=useRef<PlayerStatus|null>(null); const waitlistModeRef=useRef<Config['mode']>('regular');
  const rejoinLookupAttempts=useRef(0);
  useEffect(()=>{
    if(screen!=='name'){locationIntroShown.current=false;return;}
    if(!config.geofence_enabled||locationIntroShown.current)return;
    locationIntroShown.current=true;
    setNotice({title:'Location is required to join',message:'This facility requires location access before you can join the waitlist. OpenGym only uses your location to confirm that you are at the facilityâ€”it does not show your location to other players or continuously track where you go.',cancelLabel:'OK'});
  },[screen,config.geofence_enabled]);

  useEffect(()=>{
    const className='next-game-reversal-modal';
    document.body.classList.toggle(className,notice?.confirm==='Reverse');
    return()=>document.body.classList.remove(className);
  },[notice?.title]);
  useEffect(()=>{
    const commitWhenTappingOutside=(event:PointerEvent)=>{
      const input=courtCountInputRef.current;
      const target=event.target as Node|null;
      if(!input||!target||input.closest('.court-count-input')?.contains(target))return;
      if(input.value!==String(config.court_count))void commitCourtCount(input);
    };
    document.addEventListener('pointerdown',commitWhenTappingOutside);
    return()=>document.removeEventListener('pointerdown',commitWhenTappingOutside);
  },[config.court_count]);

  const activeMe=players.find(p=>p.user_id===user?.id)??null;
  // The live queue is authoritative. A cached inactive record must never hide
  // the normal controls when this user is already back in the game or waitlist.
  const me=activeMe??ownPlayer;
  ownPlayerIdRef.current=me?.id??ownPlayer?.id??null;
  const host=Boolean(me?.is_host&&!admin); const operator=admin||host;
  adminAccess.current=admin;
  activeStatusRef.current=activeMe?.status??null;waitlistModeRef.current=config.mode;
  screenRef.current=screen;
  const displayedPlayers=useMemo(()=>dragging&&dragOver?previewAdminMove(players,dragging,dragOver.status,dragOver.index,config.max_players,dragOver.courtNumber,dragOver.marker):players,[players,dragging,dragOver,config.max_players]);
  const savedQueuePositions=useMemo(()=>{
    const positions=new Map<string,number>();
    for(const court of courts){
      players.filter(player=>player.status==='current'&&(player.court_number??1)===court.court_number).sort(byPosition).forEach((player,index)=>positions.set(player.id,index+1));
    }
    players.filter(player=>player.status==='waiting'||player.status==='sitout').sort(byPosition).forEach((player,index)=>positions.set(player.id,index+13));
    return positions;
  },[players,courts]);
  const current=useMemo(()=>displayedPlayers.filter(p=>p.status==='current').sort(byPosition),[displayedPlayers]);
  const waiting=useMemo(()=>displayedPlayers.filter(p=>p.status==='waiting'||p.status==='sitout').sort(byPosition),[displayedPlayers]);
  const projections=useMemo(()=>projectCourtQueue(waiting,courts,config.game_number,config.max_players),[waiting,courts,config.game_number,config.max_players]);
  const projectedGames=useMemo(()=>new Map([...projections].map(([id,value])=>[id,value.game])),[projections]);
  const draggedPlayer=dragging?players.find(player=>player.id===dragging):null;
  const draggedCourtNumber=draggedPlayer?.status==='current'?(draggedPlayer.court_number??1):null;
  useLayoutEffect(()=>{if(dragging)restoreDragPickupViewport(dragging)},[dragging,draggedCourtNumber]);
  const tutorialNeedsDemo=onboarding==='tutorial'&&tutorialStep===5+(config.mode==='rejoin'?1:0)&&!admin&&Boolean(me)&&waiting.every(player=>player.id===me?.id);
  const tutorialWaiting=tutorialNeedsDemo?[...waiting,{id:'tutorial-demo-player',user_id:null,first_name:'Demo',last_name:'Player',display_name:'Demo Player',status:'waiting' as PlayerStatus,queue_position:(waiting.at(-1)?.queue_position??current.length)+1,restricted:false,group_id:null,team_id:null,is_host:false,court_number:null,sitout_priority:false,sitout_from_game:null}]:waiting;

  useEffect(()=>{let cleanup:(()=>void)|undefined;let stopped=false;void boot().then(remove=>{if(stopped)remove?.();else cleanup=remove});return()=>{stopped=true;cleanup?.();if(refreshTimer.current!==null)window.clearTimeout(refreshTimer.current)}},[]);
  useEffect(()=>{
    if(!user||admin)return;let stopped=false;
    // Realtime delivers notifications immediately. This slower visible-page
    // fallback only covers mobile browsers that suspended the websocket.
    const check=async()=>{const {data}=await supabase.from('group_notifications').select('id,user_id,message,read_at').eq('user_id',user.id).is('read_at',null).order('created_at',{ascending:true}).limit(1).maybeSingle();if(stopped||!data)return;const notification=data as GroupNotification;showPlayerNotification(notification,user.id);await supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',notification.id)};
    void check();const timer=window.setInterval(()=>{if(document.visibilityState==='visible')void check()},15_000);return()=>{stopped=true;window.clearInterval(timer)};
  },[user?.id,admin]);
  useEffect(()=>{
    if(!user)return;let stopped=false;let refreshing=false;
    // Realtime is primary. A low-frequency visible-page refresh is enough to
    // recover after a suspended or briefly disconnected mobile browser.
    const sync=async()=>{if(stopped||refreshing||document.visibilityState!=='visible')return;refreshing=true;try{await refresh(user)}finally{refreshing=false}};
    const timer=window.setInterval(()=>void sync(),30_000);return()=>{stopped=true;window.clearInterval(timer)};
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
    const applyAttributes=(element:Element)=>{
      const attributes=['placeholder','aria-label','title'];
      let states=translationAttributeMemory.current.get(element);if(!states){states=new Map();translationAttributeMemory.current.set(element,states);}
      for(const attribute of attributes){const value=element.getAttribute(attribute);if(value===null)continue;let state=states.get(attribute);if(!state){state={original:value,applied:value};states.set(attribute,state)}else if(value!==state.applied)state.original=value;const translated=translateUiText(state.original,language);state.applied=translated;if(value!==translated)element.setAttribute(attribute,translated);}
    };
    const scan=(root:Node)=>{if(root.nodeType===Node.TEXT_NODE){applyText(root as Text);return}if(root instanceof Element)applyAttributes(root);const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT|NodeFilter.SHOW_ELEMENT);let node=walker.nextNode();while(node){if(node.nodeType===Node.TEXT_NODE)applyText(node as Text);else applyAttributes(node as Element);node=walker.nextNode()}};
    scan(document.body);
    const observer=new MutationObserver(records=>{for(const record of records){if(record.type==='characterData')applyText(record.target as Text);else if(record.type==='attributes')applyAttributes(record.target as Element);for(const node of record.addedNodes)scan(node)}});
    observer.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['placeholder','aria-label','title']});return()=>observer.disconnect();
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
  useEffect(()=>{if(!geofenceReturn&&!rejoinResponse)return;setReturnClock(Date.now());const timer=window.setInterval(()=>setReturnClock(Date.now()),1000);return()=>window.clearInterval(timer)},[geofenceReturn?.id,rejoinResponse?.id]);
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
    if(realtimeChannel.current){await supabase.removeChannel(realtimeChannel.current);realtimeChannel.current=null;}
    const channel=supabase.channel(`live-waitlist-${session.user.id}-${Date.now()}`)
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_players'},payload=>{
        const changed=payload.new as Player;const isOwnChange=changed.user_id===session.user.id||changed.id===ownPlayerIdRef.current;
        if(isOwnChange){setOwnPlayer(changed);setForceRejoin(!['current','waiting','sitout'].includes(changed.status));ownPlayerIdRef.current=changed.id;syncOwnHostStatus(Boolean(changed.is_host),session.user.id);if(changed.status==='rejoin'){rejoinLookupAttempts.current=0;setRejoinChecked(false);window.setTimeout(()=>void refresh(),150);}}
        setPlayers(items=>{
          const affectsOwn=changed.user_id===session.user.id||items.some(player=>player.id===changed.id&&player.user_id===session.user.id);
          if(affectsOwn&&changed.status==='left')return items.filter(player=>player.id!==changed.id);
          return items.map(player=>player.id===changed.id?changed:player);
        });
        const inactiveOwn=isOwnChange&&!['current','waiting','sitout'].includes(changed.status);
        if(!adminMoveInProgress.current&&!inactiveOwn)scheduleRefresh();
      })
      .on('postgres_changes',{event:'*',schema:'public',table:'waitlist_config'},scheduleRefresh)
      .on('postgres_changes',{event:'*',schema:'public',table:'king_teams'},scheduleRefresh)
      .on('postgres_changes',{event:'*',schema:'public',table:'group_requests'},scheduleRefresh)
      .on('postgres_changes',{event:'*',schema:'public',table:'substitute_requests'},scheduleRefresh)
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'group_notifications'},payload=>{
        const notification=payload.new as GroupNotification;
        if(notification.user_id===session?.user.id){showPlayerNotification(notification,session.user.id);void supabase.from('group_notifications').update({read_at:new Date().toISOString()}).eq('id',notification.id);}
      })
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'past_games'},()=>{if(screenRef.current==='history')void loadPastGames()})
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'waitlist_events'},payload=>{
        const event=payload.new as {actor_user_id?:string;event_type?:string;message?:string};
        if(event.event_type==='host_appointed'||event.event_type==='host_removed')return;
        const quietEvents=new Set(['join','leave','add_player','admin_leave','admin_rejoin','admin_sitout','admin_move','admin_group','admin_group_remove','admin_substitute','admin_undo','admin_redo','geofence_leave','geofence_return']);
        if(event.event_type==='next_game'&&event.message){
          const ownPlayerStarted=event.actor_user_id===session?.user.id&&!adminAccess.current&&activeStatusRef.current!==null;
          if(ownPlayerStarted&&waitlistModeRef.current==='rejoin'){
            setNotice({title:'Next game started',message:`${event.message} **Donâ€™t forget to rejoin the queue if you plan to stay.**`,confirm:'Continue',actionTone:'success',action:async()=>{},cancelLabel:'Reverse',cancelTone:'danger',cancelAction:reverseNextGame});
            return;
          }
          if(waitlistModeRef.current==='rejoin'&&(activeStatusRef.current==='current'||activeStatusRef.current==='rejoin')){
            setNotice(null);
            setPendingNextGameEvent({message:event.message});
            return;
          }
          const canReverse=adminAccess.current||ownHostStatus.current||event.actor_user_id===session?.user.id;
          setNotice(canReverse?{title:'Next game started',message:event.message,confirm:'Reverse',actionTone:'danger',cancelLabel:'OK',action:reverseNextGame}:{title:'Waitlist update',message:event.message});
          return;
        }
        const quietSitOut=/sit[_-]?out/i.test(event.event_type??'');
        if(event.actor_user_id!==session?.user.id&&event.message&&!quietSitOut&&!quietEvents.has(event.event_type??''))setNotice({title:'Waitlist update',message:event.message});
      }).subscribe();
    realtimeChannel.current=channel;
    return()=>{if(realtimeChannel.current===channel)realtimeChannel.current=null;void supabase.removeChannel(channel)};
  }
  function scheduleRefresh(){if(refreshTimer.current!==null)window.clearTimeout(refreshTimer.current);refreshTimer.current=window.setTimeout(()=>{refreshTimer.current=null;void refresh()},250)}
  async function loadPastGames(){const {data,error}=await supabase.from('past_games').select('id,game_number,court_number,player_names,ended_at').order('game_number',{ascending:false}).limit(60);if(error){setNotice({title:'Past games unavailable',message:error.message});return;}setGames((data??[]) as Game[])}
  function openPastGames(){setScreen('history');void loadPastGames()}
  async function refresh(activeUser?:User|null){
    const [{data:p},{data:c},{data:courtRows},{data:teamRows},{data:a},{data:r},{data:s},{data:rejoin,error:rejoinError},{data:geo}]=await Promise.all([
      supabase.from('waitlist_players').select('id,user_id,first_name,last_name,display_name,status,queue_position,restricted,group_id,team_id,is_host,court_number,sitout_priority,sitout_from_game').neq('status','left').order('queue_position'),
      supabase.from('waitlist_config').select('game_number,max_players,court_count,mode,geofence_enabled,geofence_radius_m,king_max_wins').single(),
      supabase.from('waitlist_courts').select('*').order('court_number'),
      supabase.from('king_teams').select('id,name,status,queue_position,court_number,court_side,consecutive_wins').order('queue_position'),
      supabase.from('admin_sessions').select('user_id').maybeSingle(),
      supabase.from('group_requests').select('id,requester_id,target_id,status').eq('status','pending'),
      supabase.from('substitute_requests').select('id,requester_id,target_id,status').eq('status','pending'),
      supabase.from('rejoin_responses').select('id,expires_at').is('choice',null).gt('expires_at',new Date().toISOString()).order('created_at',{ascending:false}).limit(1).maybeSingle(),
      supabase.from('geofence_return_prompts').select('id,removed_at,saved_position_until,expires_at').is('resolved_at',null).gt('expires_at',new Date().toISOString()).order('removed_at',{ascending:false}).limit(1).maybeSingle()
    ]);
    const playerRows=(p??[]) as Player[];setPlayers(playerRows); if(c)setConfig(c as Config);setCourts((courtRows??[]) as Court[]);setAdmin(Boolean(a));
    setKingTeams(((teamRows??[]) as Omit<KingTeam,'members'>[]).map(team=>({...team,members:playerRows.filter(player=>player.team_id===team.id)})));
    const activeUid=(activeUser??user)?.id;const activeHost=Boolean(playerRows.find(item=>item.user_id===activeUid)?.is_host);if(activeUid)syncOwnHostStatus(activeHost,activeUid);
    if(a||activeHost){const {data:offline}=await supabase.rpc('admin_list_offline_rejoins');setAdminRejoins((offline??[]) as AdminRejoin[]);}else setAdminRejoins([]);
    setGroupRequests(((r??[]) as GroupRequest[]).map(request=>({...request,requester:playerRows.find(player=>player.id===request.requester_id)})));
    setSubstituteRequests(((s??[]) as SubstituteRequest[]).map(request=>({...request,requester:playerRows.find(player=>player.id===request.requester_id)})));
    setRejoinResponse((rejoin as RejoinResponse|null)??null);setRejoinChecked(!rejoinError);if(rejoin?.id)rejoinLookupAttempts.current=0;
    setGeofenceReturn((geo as GeofenceReturn|null)??null);
    const uid=(activeUser??user)?.id; let own=playerRows.find(item=>item.user_id===uid)??null;
    if(uid&&!own){const {data:storedOwn}=await supabase.from('waitlist_players').select('*').eq('user_id',uid).maybeSingle();own=(storedOwn as Player|null)??null;}
    if(own){
      setOwnPlayer(own);setForceRejoin(false);
      setScreen(openScreen=>['welcome','email','name','admin'].includes(openScreen)?'queue':openScreen);
    }
    else if(ownPlayerIdRef.current){setOwnPlayer(previous=>previous?{...previous,status:'left'}:previous);setForceRejoin(true);}
  }
  async function rpc(name:string,args:Record<string,unknown>={},showSuccess=true){
    setBusy(true); const {data,error}=await supabase.rpc(name,args); setBusy(false);
    if(error){setNotice({title:'Could not complete that',message:error.message});return false;}
    if(data?.message&&showSuccess)setNotice({title:'Done',message:data.message}); await refresh(); return true;
  }
  async function commitCourtCount(input:HTMLInputElement){
    const parsed=Number(input.value);
    const value=Number.isFinite(parsed)&&input.value!==''?Math.max(1,Math.min(12,Math.trunc(parsed))):config.court_count;
    input.value=String(value);
    if(value!==config.court_count)await rpc('admin_set_court_count',{p_court_count:value},false);
  }
  async function stepCourtCount(delta:number){
    const input=courtCountInputRef.current;
    if(!input)return;
    const current=Number(input.value)||Number(config.court_count)||1;
    const value=Math.max(1,Math.min(12,current+delta));
    if(value===current)return;
    input.value=String(value);
    await commitCourtCount(input);
  }
  async function finishJoin(f:string,l:string){if(await rpc('join_waitlist',{p_first_name:f,p_last_name:l},false)){if(config.mode==='teams'){const joined=players.find(player=>player.user_id===user?.id);const {data:fresh}=joined?{data:joined}:await supabase.from('waitlist_players').select('id').eq('user_id',user?.id).single();if(fresh?.id)await rpc('king_prepare_player',{p_player_id:fresh.id},false);}setScreen('queue');if(config.mode!=='teams'&&user?.user_metadata?.opengym_tutorial_version!==TUTORIAL_VERSION)setOnboarding('disclaimer');}}
  async function join(event:FormEvent){event.preventDefault(); const f=cleanName(first),l=cleanName(last); if(!f){setNotice({title:'Enter your name',message:'Your name needs to contain letters.'});return;}
    if(isInappropriateName(`${first} ${last}`)){setNotice(inappropriateNameNotice);return;}
    if(!await requireOnSite(()=>finishJoin(f,l)))return;
    await finishJoin(f,l);
  }
  async function completeTutorial(){
    if(!user){setOnboarding('idle');setTutorialStep(0);return;}
    const {data,error}=await supabase.auth.updateUser({data:{opengym_tutorial_completed:true,opengym_tutorial_version:TUTORIAL_VERSION}});
    if(data.user)setUser(data.user);
    if(error)setNotice({title:'Tutorial completed',message:'Your tutorial choice could not be saved to your account, but you can continue using the waitlist.'});
    setOnboarding('idle');setTutorialStep(0);
  }
  function getPosition(){return new Promise<GeolocationPosition>((resolve,reject)=>{if(!navigator.geolocation){reject(new Error('Location is not supported on this device.'));return;}navigator.geolocation.getCurrentPosition(resolve,reject,{enableHighAccuracy:false,maximumAge:5_000,timeout:30_000});});}
  async function locationPermissionState(){
    try{return (await navigator.permissions?.query({name:'geolocation'})).state as PermissionState;}
    catch{return 'unknown' as const;}
  }
  async function getPositionAfterPermissionChange(){
    try{return await getPosition();}
    catch(firstError){
      const state=await locationPermissionState();
      if(state==='granted'||state==='prompt'){
        await new Promise(resolve=>setTimeout(resolve,500));
        return getPosition();
      }
      throw firstError;
    }
  }
  async function verifyLocation(latitude:number,longitude:number){const {data,error}=await supabase.rpc('verify_facility_location',{p_latitude:latitude,p_longitude:longitude});if(error)return null;return data as {configured:boolean;inside:boolean;distance_m:number;radius_m:number};}
  function showTooFarNotice(result:{distance_m:number;radius_m:number},onAllowed?:()=>Promise<void>){
    const distance=Math.max(0,Math.round(result.distance_m));
    setNotice({title:'Move closer to the facility',message:`You are about ${distance} meters from the OpenGym check-in area. You need to be at or closer to the facility before you can join the waitlist. Move closer, then press â€œTry again.â€`,confirm:'Try again',action:()=>retryLocationPermission(onAllowed),actionTone:'success',cancelLabel:'Not now'});
  }
  function showLocationPermissionNotice(message='Allow location access to join or rejoin the waitlist. OpenGym only checks whether you are inside the facility area.',onAllowed?:()=>Promise<void>){
    setNotice({title:'Location permission needed',message,confirm:'Continue',action:()=>retryLocationPermission(onAllowed),actionTone:'success',cancelLabel:'Leave',cancelTone:'danger',cancelAction:async()=>{setScreen('welcome')}});
  }
  function blockedLocationInstructions(){
    const agent=navigator.userAgent;const ios=/iPhone|iPad|iPod/i.test(agent);const android=/Android/i.test(agent);const chrome=/CriOS|Chrome/i.test(agent);
    if(ios&&chrome)return '1) Tap the three dots in the top-right.\n2) Tap Settings.\n3) Tap Privacy and Security.\n4) Tap Delete Browsing Data and clear the saved browsing/site data.\n5) Return to playopengym.com, refresh, and choose Allow when Chrome asks for location.';
    if(android&&chrome)return '1) Tap the icon to the left of the address bar.\n2) Tap Permissions.\n3) Tap Location, then Allow.\n4) If Location is not shown, open â‹® â†’ Settings â†’ Site settings â†’ Location â†’ playopengym.com â†’ Allow.\n5) Return to OpenGym and press Reload after allowing.';
    if(ios)return '1) Tap the icon at the top that looks like two lines with a box above them.\n2) Tap the three dots in the bottom-right.\n3) Scroll all the way down.\n4) Change Location to Allow.\n5) Return to OpenGym and refresh the page.';
    if(chrome)return '1) Open the site-controls icon beside the address bar.\n2) Tap Site settings or Permissions.\n3) Tap Location, then Allow.\n4) Return to OpenGym and press Reload after allowing.';
    return '1) Open your browser settings for playopengym.com.\n2) Find the Location permission.\n3) Change Location to Allow.\n4) Return to OpenGym and refresh the page.';
  }
  async function retryLocationPermission(onAllowed?:()=>Promise<void>){
    setBusy(true);
    try{
      const position=await getPositionAfterPermissionChange();const result=await verifyLocation(position.coords.latitude,position.coords.longitude);setBusy(false);
      if(!result){setNotice({title:'Location check failed',message:'We could not verify the facility location. Please try again.'});return;}
      if(!result.inside){showTooFarNotice(result,onAllowed);return;}
      if(onAllowed){await onAllowed();return;}
      setNotice({title:'Location access allowed',message:'Location is ready. Press Join or Rejoin again to continue.'});
    }catch(error){
      setBusy(false);
      const denied=typeof error==='object'&&error!==null&&'code' in error&&(error as GeolocationPositionError).code===1;
      const permission=await locationPermissionState();
      const browserBlocked=denied&&permission==='denied';
      setNotice({
        title:browserBlocked?'Location is blocked':denied?'Phone location access needed':'Location check failed',
        message:browserBlocked
          ?blockedLocationInstructions()
          :denied
            ?'OpenGym still cannot receive a location from your phone even though the site may show Allow. Make sure Location Services are on for your phone and that Chrome has While Using the App access, then return here and press Allow location again.'
            :'We could not get your location. Check that Location Services are on, then try again.',
        confirm:browserBlocked?'Reload after allowing':'Try again',
        action:browserBlocked?async()=>{window.location.reload();}:()=>retryLocationPermission(onAllowed),
        actionTone:'success',cancelLabel:'Not now'
      });
    }
  }
  async function requireOnSite(onAllowed?:()=>Promise<void>){
    if(!config.geofence_enabled)return true;
    setBusy(true);
    try{const position=await getPosition();const result=await verifyLocation(position.coords.latitude,position.coords.longitude);setBusy(false);if(!result){setNotice({title:'Location check failed',message:'We could not verify the facility location. Please try again.'});return false;}if(!result.inside){showTooFarNotice(result,onAllowed);return false;}return true;}catch{setBusy(false);showLocationPermissionNotice(undefined,onAllowed);return false;}
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
    if(/sit[\s-]?out/i.test(notification.message))return;
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
  async function turnOnNotifications(){setBusy(true);try{await enablePush();setNotifications(true);setNotice({title:'Notifications are on',message:"Weâ€™ll alert you when your game starts or needs a response."});}catch(error){setNotice({title:'Notifications unavailable',message:error instanceof Error?error.message:'Could not enable notifications.'});}setBusy(false);}
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
  function confirmAdminSitOut(player:Player){
    if(player.status==='sitout'){void adminUnsit(player);return;}
    const skippedGame=player.status==='current'?config.game_number:(projectedGames.get(player.id)??config.game_number+1);
    const detail=player.status==='current'
      ?`${player.display_name} will leave Game ${config.game_number} now. That counts as the sit-out, and they will have priority for Game ${config.game_number+1}.`
      :`${player.display_name} will skip Game ${skippedGame} and have priority for Game ${skippedGame+1}.`;
    ask(`Sit out ${player.display_name}?`,detail,'Sit out',async()=>{await rpc('admin_set_player_sitout',{p_player_id:player.id,p_skip_game:skippedGame})});
  }
  async function adminUnsit(player:Player){await rpc('admin_unsit_player',{p_player_id:player.id},false)}
  function confirmAdminLeave(player:Player){ask(`Remove ${player.display_name}?`,`${player.display_name} will leave the current game or waitlist. The admin can undo this action.`,'Remove',async()=>{await rpc('admin_leave_player',{p_player_id:player.id},false)})}
  async function adminLogin(event:FormEvent){event.preventDefault();if(await rpc('sign_in_waitlist_admin',{p_username:adminUser,p_password:adminPassword})){setAdmin(true);setScreen('queue');}}
  async function adminAddPlayer(event:FormEvent){
    event.preventDefault(); const f=cleanName(adminFirst),l=cleanName(adminLast);
    if(!f){setNotice({title:'Enter a player name',message:'The player name needs to contain letters.'});return;}
    if(isInappropriateName(`${adminFirst} ${adminLast}`)){setNotice(inappropriateNameNotice);return;}
    if(config.mode==='teams'){
      setBusy(true);const {data,error}=await supabase.rpc('admin_add_player',{p_first_name:f,p_last_name:l});
      if(!error&&data?.player_id){const prepared=await supabase.rpc('king_prepare_player',{p_player_id:data.player_id});if(prepared.error){setBusy(false);setNotice({title:'Could not add that team player',message:prepared.error.message});return;}}
      setBusy(false);if(error){setNotice({title:'Could not add that player',message:error.message});return;}await refresh();setAdminFirst('');setAdminLast('');return;
    }
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
      `Grouping may move you back to the furthest group memberâ€™s position. If accepted, you are projected to play in Game ${projectedGame}.`,
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
    const skippedGame=me?.status==='current'?config.game_number:(me?projectedGames.get(me.id):null)??config.game_number+1;
    const groupMembers=me?.group_id?players.filter(player=>player.id!==me.id&&player.group_id===me.group_id):[];
    const groupIsPlaying=groupMembers.some(player=>player.status==='current');
    const groupPlaysNext=groupMembers.some(player=>projectedGames.get(player.id)===config.game_number+1);
    if(groupIsPlaying||groupPlaysNext){
      const groupTiming=groupIsPlaying?'in the current game':'scheduled for the next game';
      ask(
        'Sit out and leave your group?',
        me?.status==='current'
          ?`Your group is ${groupTiming}. You will leave the group and Game ${config.game_number}. That counts as your sit-out, and you will have priority for Game ${config.game_number+1}.`
          :`Your group is ${groupTiming}. You will leave the group, skip Game ${skippedGame}, and have priority for Game ${skippedGame+1}.`,
        'Continue',
        async()=>{await rpc('sit_out_and_leave_group',{p_skip_game:skippedGame});}
      );
      return;
    }
    const detail=me?.status==='current'
      ?`Leaving Game ${config.game_number} now counts as your sit-out. You will have priority for Game ${config.game_number+1}.`
      :`You will skip Game ${skippedGame} and have priority for Game ${skippedGame+1}.`;
    ask('Sit out one game?',detail,'Sit out',async()=>{await rpc('sit_out_one_game',{p_skip_game:skippedGame})});
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
    const lastPosition=furthestPosition;
    const firstPosition=Math.max(1,lastPosition-selected.length+1);
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
        message:`Accepting may move you back to the furthest group memberâ€™s position. If you accept, you are projected to play in Game ${projectedGameAfterGrouping(incoming)}.`,
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
  useEffect(()=>{
    if(!pendingNextGameEvent)return;
    if(me?.status==='rejoin'&&rejoinResponse){
      setNotice(null);
      return;
    }
    if(me?.status!=='current'&&me?.status!=='rejoin'){
      setNotice({title:'Waitlist update',message:pendingNextGameEvent.message});setPendingNextGameEvent(null);
    }
  },[pendingNextGameEvent,rejoinResponse?.id,me?.status]);
  async function movePlayer(playerId:string,status:'current'|'waiting',index:number,courtNumber:number|null=null){
    const restoreDropViewport=captureDropViewport(status,courtNumber);
    clearDragArtifacts();setDragging(null);setDragOver(null);
    const movingPlayer=players.find(player=>player.id===playerId);
    const movingMembers=movingPlayer?.group_id
      ? players.filter(player=>player.group_id===movingPlayer.group_id)
      : movingPlayer?[movingPlayer]:[];
    if(!movingPlayer||movingMembers.length===0)return;
    const beforeMove=players;
    setPlayers(previewAdminMove(players,playerId,status,index,config.max_players,courtNumber));
    restoreDropViewport();
    adminMoveInProgress.current=true;setBusy(true);
    const {error:moveError}=await supabase.rpc('admin_move_player',{p_player_id:playerId,p_status:status,p_index:index,p_court_number:courtNumber});
    if(moveError){adminMoveInProgress.current=false;setBusy(false);setPlayers(beforeMove);setNotice({title:'Could not move that player',message:moveError.message});await refresh();return;}
    adminMoveInProgress.current=false;setBusy(false);await refresh();
  }
  function showRejoinOnly(){setOwnPlayer(previous=>previous?{...previous,status:'left'}:previous);setForceRejoin(true);setPlayers(items=>items.filter(player=>player.user_id!==user?.id));}
  async function answerRejoin(choice:'stay'|'leave'){if(choice==='stay'&&!await requireOnSite(()=>answerRejoin('stay')))return;if(rejoinResponse&&await rpc('answer_rejoin_prompt',{p_response_id:rejoinResponse.id,p_choice:choice},false)&&choice==='leave')showRejoinOnly();setRejoinResponse(null);}
  async function leaveOwnWaitlist(){if(await rpc('leave_waitlist',{},false))showRejoinOnly();}
  async function rejoinAtBack(){if(!me)return;if(!await requireOnSite(rejoinAtBack))return;if(await rpc('join_waitlist',{p_first_name:me.first_name,p_last_name:me.last_name},false))setForceRejoin(false);}
  async function returnToFacility(){
    if(!geofenceReturn)return;setBusy(true);
    try{
      const position=await getPosition();
      const {data,error}=await supabase.rpc('return_after_geofence',{p_prompt_id:geofenceReturn.id,p_latitude:position.coords.latitude,p_longitude:position.coords.longitude});
      setBusy(false);
      if(error){setNotice({title:'Could not rejoin',message:error.message});return;}
      if(!data?.inside){setNotice({title:'You are still too far away',message:'Move back inside the OpenGym facility area, then press â€œIâ€™m back!â€ again.'});return;}
      setGeofenceReturn(null);await refresh();setNotice({title:'Welcome back',message:data.message});
    }catch{setBusy(false);showLocationPermissionNotice('Allow location access so OpenGym can confirm that you are back at the facility.',returnToFacility);}
  }
  async function advanceGame(courtNumber=me?.court_number??courts[0]?.court_number??1){
    setBusy(true);const {data,error}=await supabase.rpc('end_court_game',{p_court_number:courtNumber});
    if(error){setBusy(false);setNotice({title:'Could not start the next game',message:error.message});return;}
    const {data:newCurrent}=await supabase.from('waitlist_players').select('user_id').eq('status','current').eq('court_number',courtNumber);
    const currentIds=(newCurrent??[]).map(row=>row.user_id).filter((id):id is string=>Boolean(id)&&id!==user?.id);
    if(currentIds.length)await supabase.functions.invoke('send-push',{body:{userIds:currentIds,notification:{title:`Game ${data.game_number} has started`,body:'You are in the current game. Head to the court!',kind:'game_started',url:'/'}}});
    for(const prompt of data.rejoin_prompts??[]){await supabase.functions.invoke('send-push',{body:{userIds:[prompt.user_id],notification:{title:'Rejoin the OpenGym waitlist?',body:'Choose Rejoin or Leave within five minutes.',kind:'rejoin',url:'/',responseId:prompt.response_id}}});}
    setBusy(false);await refresh();
  }
  async function changeWaitlistMode(mode:Config['mode']){
    await rpc('set_open_gym_mode',{p_mode:mode},false);
  }
  async function joinKingTeam(teamId:string){
    if(!me)return;
    await rpc('join_king_team',{p_player_id:me.id,p_team_id:teamId},false);
  }
  function confirmJoinKingTeam(team:KingTeam,side:number){
    if(!me||team.id===me.team_id)return;
    setNotice({title:`Join Team ${side}?`,message:'Joining another team will remove you from your current team. Do you want to continue?',confirm:'Continue',actionTone:'success',action:()=>joinKingTeam(team.id),cancelLabel:'Cancel',cancelTone:'danger'});
  }
  async function setTeamCourtRules(courtNumber:number,mode:'rotation'|'king',maxWins:number|null){
    await rpc('set_team_court_rules',{p_court_number:courtNumber,p_team_mode:mode,p_max_wins:maxWins},false);
  }
  async function rotateTeamCourt(courtNumber:number){
    setBusy(true);const {data,error}=await supabase.rpc('end_team_rotation',{p_court_number:courtNumber});setBusy(false);
    if(error){setNotice({title:'Could not advance this court',message:error.message});return;}
    await refresh();
    setNotice({title:'Advancement complete',message:data?.message??'Both teams rotated out and the next two teams entered.',confirm:'Reverse',actionTone:'danger',action:reverseKingGame,cancelLabel:'Continue',cancelTone:'success'});
  }
  async function recordKingWinner(courtNumber:number,winnerId:string){
    setBusy(true);const {data,error}=await supabase.rpc('end_team_king_game',{p_court_number:courtNumber,p_winning_team_id:winnerId});setBusy(false);
    if(error){setNotice({title:'Could not advance King of the Court',message:error.message});return;}
    await refresh();
    setNotice({title:'Advancement complete',message:`${data?.winner??'The winning team'} advanced. If this was a mistake, reverse the advancement.`,confirm:'Reverse',actionTone:'danger',action:reverseKingGame,cancelLabel:'Continue',cancelTone:'success'});
  }
  async function reverseKingGame(){
    setBusy(true);const {data,error}=await supabase.rpc('reverse_king_game');setBusy(false);
    if(error){setNotice({title:'Could not reverse the advancement',message:error.message});return;}
    await refresh();setNotice({title:'Advancement reversed',message:data?.message??'The previous teams and game were restored.'});
  }
  function askKingWinner(courtNumber:number){
    const active=kingTeams.filter(team=>team.status==='current'&&team.court_number===courtNumber).sort((a,b)=>(a.court_side??1)-(b.court_side??1));
    if(active.length!==2){setNotice({title:'Two teams required',message:'This court needs two teams before its game can advance.'});return;}
    if(operator){
      setNotice({title:'Which team won?',message:'Select the team that won this game.',confirm:'Team 1',actionTone:'success',action:()=>recordKingWinner(courtNumber,active[0].id),cancelLabel:'Team 2',cancelTone:'success',cancelAction:()=>recordKingWinner(courtNumber,active[1].id),blocking:true});
      return;
    }
    const own=active.find(team=>team.id===me?.team_id);const opponent=active.find(team=>team.id!==me?.team_id);
    if(!own||!opponent)return;
    setNotice({title:'Did your team win?',message:`Your answer records the result for ${teamLabel(own)} against ${teamLabel(opponent)}.`,confirm:'Yes',actionTone:'success',action:()=>recordKingWinner(courtNumber,own.id),cancelLabel:'No',cancelTone:'danger',cancelAction:()=>recordKingWinner(courtNumber,opponent.id),blocking:true});
  }
  function confirmKingNext(courtNumber:number){
    const court=courts.find(item=>item.court_number===courtNumber);
    if((court?.team_mode??'rotation')==='rotation'){
      setNotice({title:`End the game on Court ${courtNumber}?`,message:'Both teams will rotate out and the next two waiting teams will enter.',confirm:'Continue',actionTone:'success',action:()=>rotateTeamCourt(courtNumber),cancelLabel:'Cancel',cancelTone:'danger'});
      return;
    }
    if(operator){askKingWinner(courtNumber);return;}
    setNotice({title:`End the game on Court ${courtNumber}?`,message:'This will record the winner and advance this court. Make sure the game is finished before continuing.',confirm:'Continue',actionTone:'success',action:async()=>askKingWinner(courtNumber),cancelLabel:'Cancel',cancelTone:'danger'});
  }
  function confirmTeamNext(courtNumber:number){
    confirmKingNext(courtNumber);
  }
  async function reverseNextGame(){
    setBusy(true);const {data,error}=await supabase.rpc('reverse_next_game');setBusy(false);
    if(error){setNotice({title:'Could not reverse the game',message:error.message});return;}
    await refresh();setNotice({title:'Next game reversed',message:data?.message??'The previous game and queue order have been restored.'});
  }

  if(screen==='welcome')return <Shell><section className="auth-card"><Logo/><button className="hero-button" disabled={busy} onClick={()=>void startGuestFlow()}>{busy?'Starting guest mode…':'Continue as guest'}</button><button className="admin-link" onClick={()=>setScreen('admin')}>Admin</button><p className="fine">Join the live volleyball queue from your phone.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='email')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>â† Go back</button><span className="kicker">{authMode==='signup'?'CREATE ACCOUNT':'ACCOUNT SIGN IN'}</span><h1>{authMode==='signup'?'Create your OpenGym account':'Welcome back'}</h1><p>Weâ€™ll email you a secure linkâ€”no password needed.</p><form onSubmit={emailSignIn}>{authMode==='signup'&&<><label>First name<input autoFocus value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name" autoComplete="given-name" required/></label><label>Last name<input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last name" autoComplete="family-name" required/></label></>}<label>Email address<input autoFocus={authMode==='signin'} type="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" autoComplete="email" required/></label><button className="hero-button" disabled={busy}>{busy?'Sendingâ€¦':'Email me a sign-in link'}</button></form><p className="fine">The link expires for your security.</p></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(screen==='admin')return <Shell><section className="auth-card"><div className="admin-access-heading"><button className="back" onClick={()=>setScreen('welcome')}>â† Go back</button><span className="kicker">ADMIN ACCESS</span></div><h1>Manage OpenGym</h1><p>Sign in to choose a waitlist mode and manage players.</p><form onSubmit={adminLogin}><label>Username<input autoFocus value={adminUser} onChange={e=>setAdminUser(e.target.value)} autoCapitalize="none"/></label><label>Password<input type="password" value={adminPassword} onChange={e=>setAdminPassword(e.target.value)}/></label><button className="hero-button" disabled={busy}>Sign in</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
  if(!admin&&geofenceReturn){const remaining=Math.max(0,Math.ceil((new Date(geofenceReturn.expires_at).getTime()-returnClock)/1000));const saved=new Date(geofenceReturn.saved_position_until).getTime()>returnClock;return <Shell><section className="auth-card geofence-return-card"><Logo/><span className="kicker">RETURN TO THE GYM</span><h1>Youâ€™re too far away</h1><p>It seems you moved too far from the gym, so you were taken off the waitlist. Go back to the facility and press â€œIâ€™m back!â€ below. If this looks like a mistake, please let an admin know.</p><div className="return-countdown"><strong>{formatCountdown(remaining)}</strong><span>left to return</span></div><p className="return-position-note">{saved?'Your previous position is saved for the first minute.':'Your saved-position minute has ended. You can still rejoin at the back.'}</p><button className="hero-button rejoin-at-back" disabled={busy||remaining===0} onClick={()=>void returnToFacility()}>{remaining===0?'Return window expired':busy?'Checking locationâ€¦':"Iâ€™m back!"}</button></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>}
  if(me?.status==='rejoin'&&rejoinResponse){const remaining=Math.max(0,Math.ceil((new Date(rejoinResponse.expires_at).getTime()-returnClock)/1000));return <Shell><section className="auth-card rejoin-card"><Logo/><span className="kicker">REJOIN WAITLIST</span><h1>Do you want to rejoin?</h1><p>{pendingNextGameEvent?`${pendingNextGameEvent.message} Do you want to rejoin? Your position is saved.`:'Your position is saved.'} Choose before the timer reaches zero or you’ll automatically leave the waitlist.</p><div className="return-countdown rejoin-countdown"><strong>{formatCountdown(remaining)}</strong><span>left to rejoin</span></div><div className="rejoin-actions"><button className="next" disabled={remaining===0} onClick={()=>{setPendingNextGameEvent(null);void answerRejoin('stay')}}>Rejoin</button><button className="danger" onClick={()=>{setPendingNextGameEvent(null);void answerRejoin('leave')}}>Leave</button></div></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>}
  if(screen==='name')return <Shell><section className="auth-card"><button className="back" onClick={()=>setScreen('welcome')}>â† Go back</button><h1>What should we call you?</h1><p>Your name is added to the waitlist as soon as you press “Join waitlist”</p><form onSubmit={join}><label><span className="field-label">First name <span className="required-marker">*</span></span><input required value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name"/></label><label><span className="field-label">Last initial or name <span className="optional-marker">(Optional)</span></span><input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last initial or name"/></label><button className="hero-button" disabled={busy}>Join waitlist</button></form></section>{notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;

  return <Shell>
    <header className="topbar"><Logo compact/><div className="top-actions">{pushSupported()&&!notifications&&<button className="icon-button" onClick={turnOnNotifications}>Enable alerts</button>}<button className="icon-button" onClick={()=>ask('Log out?','This will remove you from the waitlist and sign you out.','Log out',async()=>{await rpc('leave_waitlist',{},false);await logout()})}>Log out</button><label className="language-picker" aria-label="Change language"><span className="language-symbol" aria-hidden="true"><i>🌐</i><b>{language==='en'?'ENG':language==='es'?'ESP':'中文'}</b></span><select value={language} onChange={event=>setLanguage(event.target.value as AppLanguage)}><option value="en">English</option><option value="es">Español</option><option value="zh-CN">简体中文</option></select></label></div></header>
    <main className="queue-page">
      <section className="game-heading"><div><span className="kicker">{admin?'LIVE QUEUE · ADMIN':host?'LIVE QUEUE · HOST':'LIVE QUEUE'}</span><h1>{translateUiText(courts.length>1?`Game ${courts.map(court=>court.game_number).join(' · ')}`:`Game ${courts[0]?.game_number??config.game_number}`,language)}</h1></div><span className="live-pill"><i/>Live</span></section>
      {operator&&<section className="court-count-control"><label htmlFor="court-count"># of courts</label><div className="court-count-input"><input ref={courtCountInputRef} key={config.court_count} id="court-count" type="text" inputMode="numeric" pattern="[0-9]*" defaultValue={config.court_count} aria-label="Number of courts" onInput={event=>{event.currentTarget.value=event.currentTarget.value.replace(/\D/g,'').slice(0,2)}} onBlur={event=>void commitCourtCount(event.currentTarget)} onKeyDown={event=>{if(event.key==='Enter'){event.preventDefault();event.currentTarget.blur()}}}/><div className="court-count-steppers"><button type="button" aria-label="Increase courts" disabled={busy||config.court_count>=12} onClick={()=>void stepCourtCount(1)}>&uarr;</button><button type="button" aria-label="Decrease courts" disabled={busy||config.court_count<=1} onClick={()=>void stepCourtCount(-1)}>&darr;</button></div></div></section>}
      {admin&&facilityMenu&&<section className="facility-menu"><strong>Select facility</strong><p>Choose the affiliated recreation center for on-site check-in.</p><button className={config.geofence_enabled?'selected':''} onClick={()=>void chooseFacility('PHR')}><span>PHR</span><small>Pacific Highlands Ranch<br/>5977 Village Center Loop Rd, San Diego, CA 92130</small></button><button className={!config.geofence_enabled?'selected':''} onClick={()=>void chooseFacility('NA')}><span>N/A</span><small>No facility location requirement</small></button></section>}
      {adminGrouping&&<aside className="admin-group-toolbar"><span>{adminGroupIds.length}/6 selected</span><button className="group-cancel" onClick={cancelAdminGrouping}>Cancel</button><button className="group-done" onClick={previewAdminGroup}>Done</button></aside>}
      {(adminSubstituting||playerSubstituting)&&<aside className="admin-group-toolbar substitute-toolbar"><span>{substituteIds.length}/{adminSubstituting?2:1} selected</span><button className="group-cancel" onClick={cancelSubstitute}>Cancel</button><button className="group-done" onClick={adminSubstituting?previewAdminSubstitute:previewPlayerSubstitute}>Continue</button></aside>}
      {config.mode==='teams'&&<KingBoard teams={kingTeams} courts={courts} me={me} admin={admin} host={host} busy={busy} nextGame={confirmTeamNext} joinTeam={confirmJoinKingTeam} setCourtRules={setTeamCourtRules} adminSitOut={confirmAdminSitOut} adminLeave={confirmAdminLeave} permissions={setPermissionPlayer}/>}
      {config.mode==='teams'&&!admin&&me&&['current','waiting','sitout'].includes(me.status)&&<section className="my-actions"><span>Your actions</span><div><div className={`next-game-control ${me.status!=='current'?'unavailable':''}`}><button className="next next-with-substitute" disabled={busy||me.restricted||me.status!=='current'} onClick={()=>confirmKingNext(me.court_number??1)}>Next game</button>{me.status!=='current'&&<small>Only available when in a current game</small>}</div><button className="substitute-action" disabled={busy} onClick={playerSubstituting?cancelSubstitute:startPlayerSubstitute}>{playerSubstituting?'Cancel substitute':'Substitute'}</button><button className="neutral" disabled={busy} onClick={confirmMySitOut}>Sit out</button><button className="danger" disabled={busy} onClick={()=>ask('Leave the waitlist?','This removes you from the current game or queue. You can join again later.','Leave',leaveOwnWaitlist)}>Leave</button></div></section>}
      {config.mode==='teams'&&!admin&&me&&!['current','waiting','sitout'].includes(me.status)&&<section className="my-actions"><span>Your actions</span><div><button className="rejoin-at-back top-rejoin-action" disabled={busy} onClick={()=>void rejoinAtBack()}>Rejoin</button></div></section>}
      {config.mode==='teams'&&operator&&<section className={`admin-tools ${host?'host-tools':''}`}>{host&&<span className="host-actions-title">Host Actions</span>}{admin&&<select value={config.mode} onChange={e=>void changeWaitlistMode(e.target.value as Config['mode'])}><option value="regular">Regular waitlist</option><option value="rejoin">Rejoin waitlist</option><option value="teams">Teams mode</option></select>}{courts.length===1&&<button className="next-game-tool" disabled={busy||kingTeams.filter(team=>team.status==='current').length!==2} onClick={()=>confirmKingNext(courts[0]?.court_number??1)}>Next game</button>}<button className="add-player-tool" onClick={()=>setScreen('add-player')}>Add player</button>{admin&&<button className="facility-tool" onClick={()=>void setFacilityLocation()}>{config.geofence_enabled?'Update facility location':'Set facility location'}</button>}<button className={adminRejoins.length?'rejoin-tool attention':'rejoin-tool'} onClick={()=>setScreen('offline-rejoin')}>Rejoin requests{adminRejoins.length?` (${adminRejoins.length})`:''}</button><button className={`group-create-tool ${adminGrouping?'active':''}`} onClick={adminGrouping?cancelAdminGrouping:startAdminGrouping}>{adminGrouping?'Cancel Grouping':'Create Group'}</button><div className="undo-redo-controls" aria-label="Undo and redo"><button aria-label="Undo last session action" onClick={()=>void rpc('admin_undo_last')}>Undo</button><button aria-label="Redo last undone session action" onClick={()=>void rpc('admin_redo_last')}>Redo</button></div><button className={`substitute-tool ${adminSubstituting?'active':''}`} onClick={adminSubstituting?cancelSubstitute:startAdminSubstitute}>{adminSubstituting?'Cancel substitute':'Substitute'}</button>{admin&&<button className="history-tool" onClick={()=>void openAdminHistory()}>History</button>}{admin&&<button className="members-tool" onClick={()=>void openMembers()}>Members</button>}{admin&&<button className="reset-tool" onClick={()=>ask('Reset the entire waitlist?','This removes every player and clears past games.','Reset waitlist',async()=>{await rpc('admin_reset_waitlist')})}>Reset waitlist</button>}</section>}
      {config.mode!=='teams'&&!admin&&me&&!['current','waiting','sitout'].includes(me.status)&&<section className="my-actions"><span>Your actions</span><div><button className="rejoin-at-back top-rejoin-action" disabled={busy} onClick={()=>void rejoinAtBack()}>Rejoin</button></div></section>}
      {config.mode!=='teams'&&!admin&&me&&['current','waiting','sitout'].includes(me.status)&&<section className={`my-actions ${onboarding==='tutorial'&&tutorialStep===0&&me.status!=='current'?'tutorial-focus':''}`}><span>Your actions</span><div><div className={`next-game-control ${me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)?'unavailable':''}`}><button className={`next ${me.status==='current'?'next-with-substitute':''} ${onboarding==='tutorial'&&tutorialStep===0?'tutorial-focus':''}`} disabled={busy||me.restricted||(me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0))} aria-disabled={me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)} onClick={()=>{if(me.status!=='current')return;ask('Start the next game?',`This will notify all players that ${me.display_name} advanced the queue. This cannot be quietly undone.`,'Next game',advanceGame)}}>Next game</button>{me.status!=='current'&&!(onboarding==='tutorial'&&tutorialStep===0)&&<small>Only available when in a current game</small>}</div><button className="substitute-action" disabled={busy} onClick={playerSubstituting?cancelSubstitute:startPlayerSubstitute}>{playerSubstituting?'Cancel substitute':'Substitute'}</button><button className={`neutral ${onboarding==='tutorial'&&tutorialStep===1+(config.mode==='rejoin'?1:0)?'tutorial-focus':''}`} disabled={busy} onClick={confirmMySitOut}>Sit out</button><button className={`danger ${onboarding==='tutorial'&&tutorialStep===2+(config.mode==='rejoin'?1:0)?'tutorial-focus':''}`} disabled={busy} onClick={()=>ask('Leave the waitlist?','This removes you from the current game or queue. You can join again later.','Leave',leaveOwnWaitlist)}>Leave</button></div></section>}
      {config.mode!=='teams'&&operator&&<section className={`admin-tools ${host?'host-tools':''}`}>{host&&<span className="host-actions-title">Host Actions</span>}{admin&&<select value={config.mode} onChange={e=>void changeWaitlistMode(e.target.value as Config['mode'])}><option value="regular">Regular waitlist</option><option value="rejoin">Rejoin waitlist</option><option value="teams">Teams mode</option></select>}<button className="next-game-tool" disabled={busy||current.length===0} onClick={()=>ask('Start the next game?','This will notify all players and advance the entire queue to the next game.','Next game',advanceGame)}>Next game</button><button className="add-player-tool" onClick={()=>setScreen('add-player')}>Add player</button>{admin&&<button className="facility-tool" onClick={()=>void setFacilityLocation()}>{config.geofence_enabled?'Update facility location':'Set facility location'}</button>}<button className={adminRejoins.length?'rejoin-tool attention':'rejoin-tool'} onClick={()=>setScreen('offline-rejoin')}>Rejoin requests{adminRejoins.length?` (${adminRejoins.length})`:''}</button><button className={`group-create-tool ${adminGrouping?'active':''}`} onClick={adminGrouping?cancelAdminGrouping:startAdminGrouping}>{adminGrouping?'Cancel Grouping':'Create Group'}</button><div className="undo-redo-controls" aria-label="Undo and redo"><button aria-label="Undo last session action" onClick={()=>void rpc('admin_undo_last')}>Undo</button><button aria-label="Redo last undone session action" onClick={()=>void rpc('admin_redo_last')}>Redo</button></div><button className={`substitute-tool ${adminSubstituting?'active':''}`} onClick={adminSubstituting?cancelSubstitute:startAdminSubstitute}>{adminSubstituting?'Cancel substitute':'Substitute'}</button>{admin&&<button className="history-tool" onClick={()=>void openAdminHistory()}>History</button>}{admin&&<button className="members-tool" onClick={()=>void openMembers()}>Members</button>}{admin&&<button className="reset-tool" onClick={()=>ask('Reset the entire waitlist?','This removes every player and clears past games. The admin can undo this action.','Reset waitlist',async()=>{await rpc('admin_reset_waitlist')})}>Reset waitlist</button>}</section>}
      {config.mode!=='teams'&&courts.map((court,courtIndex)=>{const courtPlayers=current.filter(player=>(player.court_number??1)===court.court_number);const hiddenDuringDrag=draggedCourtNumber!==null&&court.court_number!==draggedCourtNumber;return <section className={`court-section ${hiddenDuringDrag?'drag-hidden-court':''}`} aria-hidden={hiddenDuringDrag||undefined} key={court.court_number}>{operator&&<button className="court-next-button" disabled={busy||courtPlayers.length===0} onClick={()=>ask(`Start next game on Court ${court.court_number}?`,`Only Court ${court.court_number} will advance and refill from the shared waitlist.`,'Next game',()=>advanceGame(court.court_number))}>Next game (Court {court.court_number})</button>}<QueueCard title={courts.length>1?`COURT ${court.court_number} - Game ${court.game_number}`:`Game ${court.game_number}`} subtitle={`${courtPlayers.length} playing`} status="current" players={courtPlayers} start={1} savedQueuePositions={savedQueuePositions} me={me} admin={admin} operator={operator} spotlight={onboarding==='tutorial'&&tutorialStep===3+(config.mode==='rejoin'?1:0)&&courtIndex===0} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} requestGroup={requestGroup} leaveGroup={removeGroupMember} leaveOwnGroup={confirmLeaveOwnGroup} adminLeaveGroup={adminRemoveGroupMember} permissions={setPermissionPlayer} adminSitOut={confirmAdminSitOut} adminLeave={confirmAdminLeave} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/></section>})}
      {config.mode!=='teams'&&<QueueCard title="Waitlist" subtitle={tutorialWaiting.length?`${tutorialWaiting.length} waiting`:'No one waiting'} status="waiting" players={tutorialWaiting} start={13} savedQueuePositions={savedQueuePositions} me={me} admin={admin} operator={operator} spotlight={onboarding==='tutorial'&&tutorialStep===4+(config.mode==='rejoin'?1:0)} groupSpotlight={onboarding==='tutorial'&&tutorialStep===5+(config.mode==='rejoin'?1:0)} editing={editing} editName={editName} setEditing={setEditing} setEditName={setEditName} saveName={saveName} projections={projectedGames} projectedCourts={courts.length>1?new Map([...projections].map(([id,value])=>[id,value.court])):undefined} requestGroup={requestGroup} leaveGroup={removeGroupMember} leaveOwnGroup={confirmLeaveOwnGroup} adminLeaveGroup={adminRemoveGroupMember} permissions={setPermissionPlayer} adminSitOut={confirmAdminSitOut} adminLeave={confirmAdminLeave} dragging={dragging} dragOver={dragOver} setDragging={setDragging} setDragOver={setDragOver} movePlayer={movePlayer}/>}
      {!admin&&<button className={`history-button your-history-button ${host?'history-tool':''}`} onClick={()=>void openPlayerHistory()}>{host?'Action History':'Your history'} <span>→</span></button>}
      <button className="history-button" onClick={openPastGames}>Past games <span>→</span></button>
      <p className="projection-note">Queue positions update live on every connected phone.</p>
    </main>
    {onboarding==='disclaimer'&&<WaitlistDisclaimer mode={config.mode} language={language} acknowledge={()=>{setTutorialStep(0);setOnboarding('tutorial')}}/>}
    {onboarding==='tutorial'&&(
      <TutorialCoach mode={config.mode} step={tutorialStep} next={()=>tutorialStep<getTutorialSteps(config.mode).length-1?setTutorialStep(step=>step+1):void completeTutorial()} back={()=>setTutorialStep(step=>Math.max(0,step-1))} skip={()=>void completeTutorial()}/>
    )}
    {screen==='history'&&<div className="drawer"><div className="drawer-card history-drawer-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><h2>Past games</h2>{games.length===0?<p>No completed games yet.</p>:<div className="past-games-grid">{games.map(game=><article className="past-game" key={game.id}><strong>Game {game.game_number}</strong><ol>{game.player_names.map((name,index)=><li key={`${game.id}-${index}`}>{name}</li>)}</ol></article>)}</div>}</div></div>}
    {screen==='player-history'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><h2>{host?'Action History':'Your history'}</h2>{playerEvents.length===0?<p>{host?'You have no host actions yet.':'You have no join or leave activity yet.'}</p>:playerEvents.map(event=><article className="past-game history-row" key={event.id}><strong>{event.message}</strong><p>{new Date(event.created_at).toLocaleString()}</p></article>)}</div></div>}
    {screen==='restricted'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('members')}>â† Back to members</button><h2>Restricted members</h2>{players.filter(p=>p.restricted).length===0?<p>No restricted members.</p>:players.filter(p=>p.restricted).map(player=><article className="past-game member-row" key={player.id}><strong>{player.display_name}</strong><button onClick={()=>void rpc('admin_restrict_player',{p_player_id:player.id,p_restricted:false})}>Unrestrict</button></article>)}</div></div>}
    {screen==='add-player'&&<div className="drawer"><div className="drawer-card add-player-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><h2>Add a player</h2><p>Add a walk-in player directly to the live queue. They do not need an account.</p><form onSubmit={adminAddPlayer}><label>First name<input autoFocus value={adminFirst} onChange={e=>setAdminFirst(e.target.value)} placeholder="First name"/></label><label>Last initial or name <em>optional</em><input value={adminLast} onChange={e=>setAdminLast(e.target.value)} placeholder="Last initial or name"/></label><button className="hero-button" disabled={busy}>{busy?'Addingâ€¦':'Add to waitlist'}</button></form></div></div>}
    {screen==='offline-rejoin'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><h2>Rejoin requests</h2><p>These players have 15 minutes to return to the admin. Rejoining restores their saved queue position.</p>{adminRejoins.length===0?<p>No players are waiting to rejoin.</p>:adminRejoins.map(player=><article className="past-game offline-rejoin-row" key={player.id}><div><strong>{player.display_name}</strong><p>Saved position {player.queue_position} Â· expires {new Date(player.expires_at).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})}</p></div><div><button className="next" onClick={()=>void answerOfflineRejoin(player,true)}>Rejoin</button><button className="danger" onClick={()=>ask(`Remove ${player.display_name}?`,'They will lose their saved position and must be added again normally.','Remove',async()=>{await answerOfflineRejoin(player,false)})}>Remove</button></div></article>)}</div></div>}
    {screen==='admin-history'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><input className="history-search" type="search" value={historySearch} onChange={e=>setHistorySearch(e.target.value)} placeholder="Looking for something?" aria-label="Search waitlist history"/><h2>Waitlist history</h2>{adminEvents.length===0?<p>No waitlist activity yet.</p>:adminEvents.filter(event=>`${event.message} ${event.actor_name} ${event.event_type}`.toLocaleLowerCase().includes(historySearch.trim().toLocaleLowerCase())).map(event=><article className="past-game history-row" key={event.id}><strong>{event.message}</strong><p>{new Date(event.created_at).toLocaleString()}</p></article>)}</div></div>}
    {screen==='members'&&<div className="drawer"><div className="drawer-card"><button className="back" onClick={()=>setScreen('queue')}>â† Back to waitlist</button><h2>Members</h2><button className="restricted-members-button" onClick={()=>setScreen('restricted')}>Restricted Members</button>{members.length===0?<p>No accounts have been created yet.</p>:members.map(member=><article className="past-game" key={member.user_id}><strong>{member.player_name??member.email??member.phone??'Member'}</strong><p>{member.email??member.phone??'Verified account'} Â· Joined {new Date(member.created_at).toLocaleDateString()}</p></article>)}</div></div>}
    {permissionPlayer&&<PermissionsModal player={permissionPlayer} close={()=>setPermissionPlayer(null)} hostAction={()=>confirmHostChange(permissionPlayer)} restrictAction={()=>chooseRestriction(permissionPlayer)}/>}
    {hostTutorial&&<HostTutorial step={hostTutorialStep} next={()=>hostTutorialStep<hostTutorialSteps.length-1?setHostTutorialStep(value=>value+1):setHostTutorial(false)} back={()=>setHostTutorialStep(value=>Math.max(0,value-1))} skip={()=>setHostTutorial(false)}/>}
    {hostAppointmentNotice&&<HostAppointmentModal message={hostAppointmentNotice} start={acknowledgeHostAppointment}/>}
    {notice&&<Modal notice={notice} close={()=>setNotice(null)} busy={busy}/>}</Shell>;
}

function previewAdminMove(source:Player[],playerId:string,targetStatus:'current'|'waiting',targetIndex:number,maxPlayers:number,targetCourtNumber:number|null=null,targetMarker:string|null=null){
  const moving=source.find(player=>player.id===playerId);if(!moving)return source;
  const movingMembers=(moving.group_id?source.filter(player=>player.group_id===moving.group_id):[moving]).sort(byPosition);
  const movingIds=new Set(movingMembers.map(player=>player.id));
  const sourceCourt=moving.court_number??targetCourtNumber??1;const targetCourt=targetStatus==='current'?(targetCourtNumber??sourceCourt):sourceCourt;
  const otherCourts=source.filter(player=>player.status==='current'&&player.court_number!==sourceCourt&&!movingIds.has(player.id));
  let current=source.filter(player=>player.status==='current'&&player.court_number===targetCourt&&!movingIds.has(player.id)).sort(byPosition);
  let waiting=source.filter(player=>(player.status==='waiting'||player.status==='sitout')&&!movingIds.has(player.id)).sort(byPosition);
  const originalTarget=source.filter(player=>targetStatus==='current'?(player.status==='current'&&player.court_number===targetCourt):(player.status==='waiting'||player.status==='sitout')).sort(byPosition);
  const removedBefore=originalTarget.slice(0,targetIndex).filter(player=>movingIds.has(player.id)).length;
  const targetList=targetStatus==='current'?current:waiting;const [markerSide,markerId]=targetMarker?.split(':')??[];const markerIndex=markerId?targetList.findIndex(player=>player.id===markerId):-1;
  const insertion=Math.max(0,Math.min(markerIndex>=0?markerIndex+(markerSide==='after'?1:0):targetIndex-removedBefore,targetList.length));
  const movedBlock=movingMembers.map(player=>({...player,status:targetStatus,court_number:targetStatus==='current'?targetCourt:null,queue_position:insertion+1}));
  if(targetStatus==='current')current.splice(insertion,0,...movedBlock);else waiting.splice(insertion,0,...movedBlock);
  if(current.length>maxPlayers){const overflow=current.splice(maxPlayers);waiting=[...overflow.map(player=>({...player,status:'waiting' as PlayerStatus})),...waiting];}
  if(current.length<maxPlayers){
    const excluded=moving.status==='current'&&targetStatus==='waiting'?movingIds:new Set<string>();
    for(let cursor=0;cursor<waiting.length&&current.length<maxPlayers;){
      const candidate=waiting[cursor];const block=candidate.group_id?waiting.filter(player=>player.group_id===candidate.group_id):[candidate];
      if(block.some(player=>excluded.has(player.id))||block.length>maxPlayers-current.length){cursor+=block.length;continue;}
      const blockIds=new Set(block.map(player=>player.id));waiting=waiting.filter(player=>!blockIds.has(player.id));current.push(...block.map(player=>({...player,status:'current' as PlayerStatus,court_number:targetCourt})));cursor=0;
    }
  }
  // `current` and `waiting` already contain the exact preview insertion order.
  // Re-sorting here used the dragged player's temporary null queue_position and
  // pushed its highlighted placeholder to the bottom even though nearby rows
  // previewed the correct shift.
  const orderedOtherCourts=[...otherCourts].sort((a,b)=>(a.court_number??1)-(b.court_number??1)||byPosition(a,b));
  const active=[...orderedOtherCourts,...current,...waiting].map((player,index)=>({...player,queue_position:index+1}));
  const activeIds=new Set(active.map(player=>player.id));return [...active,...source.filter(player=>!activeIds.has(player.id)&&!movingIds.has(player.id))];
}
function projectQueueGames(players:Player[],currentGame:number,maxPlayers:number){
  const blocks:Array<{members:Player[]}>=[];const blockById=new Map<string,{members:Player[]}>();
  for(const player of players){const key=player.group_id??player.id;let block=blockById.get(key);if(!block){block={members:[]};blockById.set(key,block);blocks.push(block)}block.members.push(player)}
  const projections=new Map<string,number>();let remaining=[...blocks];let game=currentGame+1;
  while(remaining.length){let spots=maxPlayers;const deferred:typeof remaining=[];let selected=0;
    const eligible=remaining.filter(block=>block.members.every(player=>player.status!=='sitout'||game>(player.sitout_from_game??currentGame)));
    const eligibleIds=new Set(eligible);const ordered=[...eligible].sort((a,b)=>Number(b.members.some(player=>player.sitout_priority))-Number(a.members.some(player=>player.sitout_priority)));
    for(const block of ordered){if(block.members.length<=spots){for(const player of block.members)projections.set(player.id,game);spots-=block.members.length;selected+=block.members.length}else deferred.push(block)}
    for(const block of remaining)if(!eligibleIds.has(block))deferred.push(block);
    if(selected===0&&eligible.length){const block=eligible[0];for(const player of block.members)projections.set(player.id,game);const index=deferred.indexOf(block);if(index>=0)deferred.splice(index,1)}
    remaining=deferred;game++;
  }
  return projections;
}
function projectCourtQueue(players:Player[],courts:Court[],currentGame:number,maxPlayers:number){
  const schedule=courts.length?[...courts].sort((a,b)=>a.game_number-b.game_number):[{court_number:1,game_number:currentGame,started_at:''}];
  const blocks:Array<{members:Player[]}>=[];const byBlock=new Map<string,{members:Player[]}>();
  for(const player of players){const key=player.group_id??player.id;let block=byBlock.get(key);if(!block){block={members:[]};byBlock.set(key,block);blocks.push(block)}block.members.push(player)}
  const result=new Map<string,{game:number;court:number}>();let remaining=[...blocks];let nextGame=Math.max(currentGame,...schedule.map(court=>court.game_number))+1;let turn=0;
  while(remaining.length){const court=schedule[turn%schedule.length];const game=nextGame++;let spots=maxPlayers;const deferred:typeof remaining=[];
    const ordered=[...remaining].sort((a,b)=>Number(b.members.some(player=>player.sitout_priority))-Number(a.members.some(player=>player.sitout_priority)));
    for(const block of ordered){const eligible=block.members.every(player=>player.status!=='sitout'||game>(player.sitout_from_game??currentGame));if(eligible&&block.members.length<=spots){for(const player of block.members)result.set(player.id,{game,court:court.court_number});spots-=block.members.length}else deferred.push(block)}
    if(deferred.length===remaining.length){const block=deferred.shift();if(block)for(const player of block.members)result.set(player.id,{game,court:court.court_number})}
    remaining=deferred;turn++;
  }
  return result;
}
function byPosition(a:Player,b:Player){return (a.queue_position??Number.MAX_SAFE_INTEGER)-(b.queue_position??Number.MAX_SAFE_INTEGER)}
function Shell({children}:{children:React.ReactNode}){const [theme,setTheme]=useState<'dark'|'light'>('dark');useEffect(()=>{const saved=localStorage.getItem('opengym-theme');setTheme(saved==='dark'||saved==='light'?saved:(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'));},[]);useEffect(()=>{const cleanIcons=()=>{document.querySelectorAll<HTMLButtonElement>('.back').forEach(button=>{const label=button.textContent?.match(/(Go back|Back to .*)$/)?.[1];const clean=label?`← ${label}`:null;if(clean&&button.textContent!==clean)button.textContent=clean});document.querySelectorAll<HTMLButtonElement>('.pencil').forEach(button=>{if(button.textContent!=='✎')button.textContent='✎'})};cleanIcons();const observer=new MutationObserver(cleanIcons);observer.observe(document.body,{childList:true,subtree:true});return()=>observer.disconnect()},[]);function toggleTheme(){const next=theme==='dark'?'light':'dark';setTheme(next);localStorage.setItem('opengym-theme',next)}const nextTheme=theme==='dark'?'light':'dark';return <div className={`app-shell theme-${theme}`}><button className="theme-switch" aria-label={`Switch to ${nextTheme} mode`} title={`Switch to ${nextTheme} mode`} onClick={toggleTheme}><span className="theme-track" aria-hidden="true"><i className="theme-thumb">{theme==='dark'?'☾':'☀'}</i></span></button>{children}</div>}
function Logo({compact=false}:{compact?:boolean}){return <div className={`logo ${compact?'compact':''}`}><span><img src="/open-gym-app-icon.png" alt=""/></span><div><strong>OpenGym</strong>{!compact&&<small>VOLLEYBALL WAITLIST</small>}</div></div>}
function WaitlistDisclaimer({mode,language,acknowledge}:{mode:Config['mode'];language:AppLanguage;acknowledge:()=>void}){
 const rejoin=mode==='rejoin';
 const title=language==='es'?`Esta es una lista ${rejoin?'de REINGRESO':'REGULAR'}`:language==='zh-CN'?`这是${rejoin?'重新加入':'普通'}等候名单`:`This is a ${mode.toUpperCase()} waitlist`;
 const details=language==='es'?(rejoin?'Cada vez que termines de jugar, DEBES volver a ingresar dentro de cinco minutos para conservar tu lugar.':'No necesitas volver a registrarte. Permanecerás en la fila hasta que salgas o estés fuera del rango permitido del centro.'):language==='zh-CN'?(rejoin?'每次比赛结束后，你必须在五分钟内重新加入，才能保留你的位置。':'你无需重新报名。除非你主动离开或超出场馆允许的范围，否则你会一直保留在队列中。'):(rejoin?'Every time after you play, you MUST rejoin within five minutes to keep your place.':'You do not need to sign up again. You stay in line until you leave or move out of range of the facility.');
 return <div className="onboarding-backdrop"><section className="onboarding-card" role="dialog" aria-modal="true" aria-labelledby="waitlist-mode-title"><span className="onboarding-kicker">BEFORE YOU START</span><h2 id="waitlist-mode-title">{title}</h2><p>{details}</p><button className="hero-button" onClick={acknowledge}>I acknowledge</button></section></div>;
}
const tutorialSteps=[
 {title:'Next Game action button',message:'This button appears only when you are in the current game. Pressing it ends that game, advances the entire queue, and notifies every player—so use it only when the game is truly over.'},
 {title:'Sit Out action button',message:'Sit Out makes you skip one game. After skipping that game, you receive priority for the following game.'},
 {title:'Leave action button',message:'Leave removes only you from the waitlist, so use it when you do not want to play anymore.'},
 {title:'Who is playing now',message:'The players in this section are in the current game. Only they are able to start the next game.'},
 {title:'Waitlist',message:'Your number is your queue position. When you are waiting, your projected game appears beside your name.'},
 {title:'Group Up',message:'Use Group Up beside another player when you want to play together.'},
];
const rejoinTutorialStep={title:'Rejoin after every game',message:'After you play, you will be taken off the waitlist. To keep your saved place, press Rejoin within five minutes.',demo:true};
function getTutorialSteps(mode:Config['mode']){return mode==='rejoin'?[tutorialSteps[0],rejoinTutorialStep,...tutorialSteps.slice(1)]:tutorialSteps}

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
function TutorialCoach({mode,step,next,back,skip}:{mode:Config['mode'];step:number;next:()=>void;back:()=>void;skip:()=>void}){useTutorialInteractionLock();const steps=getTutorialSteps(mode);const item=steps[step];const offset=mode==='rejoin'?1:0;const waitlistStep=4+offset;const groupStep=5+offset;useEffect(()=>{if(item.demo)return;const frame=requestAnimationFrame(()=>{const target=step===waitlistStep?document.querySelector('[data-drop-status="waiting"]'):step===groupStep?document.querySelector('.tutorial-group-target'):document.querySelector('.tutorial-focus');target?.scrollIntoView({behavior:'smooth',block:step>=waitlistStep?'end':'center'})});return()=>cancelAnimationFrame(frame)},[step,item.demo,waitlistStep,groupStep]);return <><div className="tutorial-scrim"/>{item.demo&&<section className="tutorial-rejoin-demo" aria-hidden="true"><Logo compact/><span className="kicker">REJOIN WAITLIST</span><h2>Do you want to rejoin?</h2><p>Your position is saved.</p><div className="return-countdown rejoin-countdown"><strong>4:59</strong><span>left to rejoin</span></div><div className="rejoin-actions"><button className="next tutorial-rejoin-highlight" disabled>Rejoin</button><button className="danger" disabled>Leave</button></div></section>}<section className={`tutorial-coach ${item.demo?'tutorial-coach-rejoin-demo':''} ${step>=waitlistStep?'tutorial-coach-contextual':''} ${step===waitlistStep?'tutorial-coach-waitlist':''} ${step===groupStep?'tutorial-coach-groups':''}`} role="dialog" aria-modal="true" aria-live="polite"><div className="tutorial-progress"><span>QUICK TOUR · {step+1} OF {steps.length}</span><button onClick={skip}>Skip tutorial</button></div><h2>{item.title}</h2><p>{item.message}</p><div className="tutorial-actions">{step>0&&<button className="neutral" onClick={back}>Back</button>}<button className="next" onClick={next}>{step===steps.length-1?'Finish':'Next'}</button></div></section></>}
function createPlayerDragPreview(player:Player,players:Player[],start:number){
 const movingPlayers=player.group_id?players.filter(candidate=>candidate.group_id===player.group_id):[player];
 const preview=document.createElement('div');preview.className='admin-drag-preview';preview.setAttribute('aria-hidden','true');
 for(const movingPlayer of movingPlayers){
  const source=document.querySelector<HTMLElement>(`[data-player-id="${movingPlayer.id}"]`);
  if(source){const row=source.cloneNode(true) as HTMLElement;row.removeAttribute('data-player-id');row.removeAttribute('draggable');row.classList.add('admin-drag-preview-row');row.querySelectorAll<HTMLElement>('button,input').forEach(control=>control.setAttribute('tabindex','-1'));preview.appendChild(row);}
  else{const row=document.createElement('div');row.className='player-row admin-drag-preview-row';const position=document.createElement('span');position.className='position';position.textContent=String(start+players.indexOf(movingPlayer));const name=document.createElement('div');name.className='player-name';const strong=document.createElement('strong');strong.textContent=movingPlayer.display_name;name.appendChild(strong);row.append(position,name);preview.appendChild(row);}
 }
 const sourceRow=document.querySelector<HTMLElement>(`[data-player-id="${player.id}"]`);if(sourceRow)preview.style.width=`${sourceRow.getBoundingClientRect().width}px`;
 return preview;
}
function hideOtherCourtsForDrag(row:HTMLElement){
 const top=row.getBoundingClientRect().top;
 const source=row.closest('.court-section');
 // A player picked up from a court can move only within that court and the
 // shared waitlist. A player picked up from the waitlist can move into any
 // court, so every court must remain visible.
 document.querySelectorAll<HTMLElement>('.court-section').forEach(section=>section.classList.toggle('drag-hidden-court',Boolean(source)&&section!==source));
 // Hiding the other courts changes the document height. Keep the picked-up
 // row under the same finger/cursor instead of letting scroll anchoring jump.
 const delta=row.getBoundingClientRect().top-top;if(Math.abs(delta)>0.5)window.scrollBy({top:delta,left:0,behavior:'instant'});
}
let dragPickupViewport:{playerId:string;top:number}|null=null;
function captureDragPickupViewport(row:HTMLElement){const playerId=row.dataset.playerId;if(playerId)dragPickupViewport={playerId,top:row.getBoundingClientRect().top};}
function restoreDragPickupViewport(playerId:string){if(!dragPickupViewport||dragPickupViewport.playerId!==playerId)return;const anchor=dragPickupViewport;dragPickupViewport=null;requestAnimationFrame(()=>{const row=document.querySelector<HTMLElement>(`[data-player-id="${playerId}"]`);if(!row)return;const delta=row.getBoundingClientRect().top-anchor.top;if(Math.abs(delta)>0.5)window.scrollBy({top:delta,left:0,behavior:'instant'});});}
function clearDragArtifacts(){document.querySelectorAll('.mobile-admin-drag-preview,.admin-drag-preview').forEach(preview=>preview.remove());document.querySelectorAll('.court-section.drag-hidden-court').forEach(section=>section.classList.remove('drag-hidden-court'));document.body.classList.remove('mobile-admin-dragging');}
function captureDropViewport(status:'current'|'waiting',courtNumber:number|null){
 const cards=[...document.querySelectorAll<HTMLElement>(`[data-drop-status="${status}"]`)];
 const card=status==='current'?cards.find(candidate=>Number(candidate.closest<HTMLElement>('.court-section')?.querySelector('h2')?.textContent?.match(/COURT\s+(\d+)/i)?.[1]??1)===(courtNumber??1)):cards.at(-1);
 const anchor=card?.querySelector<HTMLElement>('header')??card;if(!anchor)return()=>{};
 const top=anchor.getBoundingClientRect().top;
 return()=>requestAnimationFrame(()=>requestAnimationFrame(()=>{const next=card.isConnected?(card.querySelector<HTMLElement>('header')??card):null;if(!next)return;const delta=next.getBoundingClientRect().top-top;if(Math.abs(delta)>1)window.scrollBy({top:delta,left:0,behavior:'instant'})}));
}
function setPlayerDragPreview(event:React.DragEvent<HTMLElement>,player:Player,players:Player[],start:number){
 const preview=createPlayerDragPreview(player,players,start);
 document.body.appendChild(preview);event.dataTransfer.setDragImage(preview,24,28);window.setTimeout(()=>preview.remove(),0);
}

function formatCountdown(totalSeconds:number){const minutes=Math.floor(totalSeconds/60);const seconds=totalSeconds%60;return `${minutes}:${String(seconds).padStart(2,'0')}`}
type DropPlacement={status:'current'|'waiting';index:number;marker:string|null;courtNumber:number|null};
function queueDragBounds(){
 const cards=[...document.querySelectorAll<HTMLElement>('[data-drop-status]')];const rows=[...document.querySelectorAll<HTMLElement>('[data-player-id]')];
 if(!cards.length)return null;const cardRects=cards.map(card=>card.getBoundingClientRect());const rowRects=rows.map(row=>row.getBoundingClientRect());
 return{left:Math.min(...cardRects.map(rect=>rect.left)),right:Math.max(...cardRects.map(rect=>rect.right)),top:rowRects.length?Math.min(...rowRects.map(rect=>rect.top)):Math.min(...cardRects.map(rect=>rect.top)),bottom:rowRects.length?Math.max(...rowRects.map(rect=>rect.bottom)):Math.max(...cardRects.map(rect=>rect.bottom))};
}
function queueScrollBounds(){
 const sections=[...document.querySelectorAll<HTMLElement>('.court-section,[data-drop-status="waiting"]')];if(!sections.length)return null;const rects=sections.map(section=>section.getBoundingClientRect());
 return{top:Math.min(...rects.map(rect=>rect.top)),bottom:Math.max(...rects.map(rect=>rect.bottom))};
}
function constrainQueueDragPoint(x:number,y:number){const bounds=queueDragBounds();if(!bounds)return{x,y};return{x:Math.min(bounds.right-2,Math.max(bounds.left+2,x)),y:Math.min(bounds.bottom-2,Math.max(bounds.top+2,y))};}
function positionPlayerDragPreview(preview:HTMLElement,x:number,y:number){
 const bounds=queueDragBounds();if(!bounds)return;const point=constrainQueueDragPoint(x,y);const width=preview.offsetWidth||280;const height=preview.offsetHeight||62;
 const left=Math.min(bounds.right-width,Math.max(bounds.left,point.x-width/2));const top=Math.min(Math.max(bounds.top,bounds.bottom-height),Math.max(bounds.top,point.y-height/2));preview.style.transform=`translate3d(${left}px,${top}px,0)`;
}
function resolveDropPlacement(x:number,y:number,fallback:DropPlacement|null=null):DropPlacement|null{
 const point=constrainQueueDragPoint(x,y);
 const cards=[...document.querySelectorAll<HTMLElement>('[data-drop-status]')].filter(card=>{const rect=card.getBoundingClientRect();return point.x>=rect.left&&point.x<=rect.right&&point.y>=rect.top&&point.y<=rect.bottom});
 const card=cards.at(-1);if(!card)return fallback;const status=card.dataset.dropStatus as 'current'|'waiting';
 const courtNumber=status==='current'?Number(card.closest<HTMLElement>('.court-section')?.querySelector('h2')?.textContent?.match(/COURT\s+(\d+)/i)?.[1]??1):null;
 const placeholder=card.querySelector<HTMLElement>('[data-player-id].dragging');
 if(placeholder&&fallback&&fallback.status===status&&fallback.courtNumber===courtNumber){const rect=placeholder.getBoundingClientRect();if(point.y>=rect.top&&point.y<=rect.bottom)return fallback;}
 const rows=[...card.querySelectorAll<HTMLElement>('[data-player-id]')].filter(row=>!row.classList.contains('dragging'));
 if(!rows.length)return{status,index:0,marker:'empty',courtNumber};
 const blocks:Array<{first:HTMLElement;last:HTMLElement}>=[];
 for(let index=0;index<rows.length;){const first=rows[index];const groupId=first.dataset.groupId;let last=first;index++;if(groupId)while(index<rows.length&&rows[index].dataset.groupId===groupId){last=rows[index];index++;}blocks.push({first,last});}
 // Resolve against the row physically under the pointer. The rendered list is a
 // preview, so data-player-index is intentionally not used here: it includes the
 // moving row and produces an off-by-one position when the RPC persists the drop.
 // Calculate the slot directly from the cursor's vertical position. The row
 // animation may move elements under the cursor, so element hit-testing creates
 // a feedback loop and leaves the placeholder stuck. A fixed row grid makes the
 // highlighted slot follow the pointer predictably while the list previews.
 const header=card.querySelector<HTMLElement>('header');const contentTop=header?.getBoundingClientRect().bottom??card.getBoundingClientRect().top;
 const heights=rows.map(row=>row.getBoundingClientRect().height).filter(height=>height>0);const rowHeight=heights.length?heights.sort((a,b)=>a-b)[Math.floor(heights.length/2)]:62;
 let insertion=Math.max(0,Math.min(Math.round((point.y-contentTop)/rowHeight-.5),rows.length));
 // Never split an existing group: snap a cursor landing inside one to the
 // closest outside edge of that group.
 for(const block of blocks){const firstIndex=rows.indexOf(block.first);const lastIndex=rows.indexOf(block.last);if(insertion>firstIndex&&insertion<=lastIndex){const firstRect=block.first.getBoundingClientRect();const lastRect=block.last.getBoundingClientRect();insertion=point.y<(firstRect.top+lastRect.bottom)/2?firstIndex:lastIndex+1;break;}}
 if(insertion>=rows.length){const last=rows.at(-1)!;return{status,index:rows.length,marker:`after:${last.dataset.playerId}`,courtNumber};}
 return{status,index:insertion,marker:`before:${rows[insertion].dataset.playerId}`,courtNumber};
}

function resolveHighlightedDropPlacement(playerId:string,fallback:DropPlacement|null=null):DropPlacement|null{
 const draggedRow=document.querySelector<HTMLElement>(`[data-player-id="${playerId}"].dragging`);const card=draggedRow?.closest<HTMLElement>('[data-drop-status]');if(!draggedRow||!card)return fallback;
 const status=card.dataset.dropStatus as 'current'|'waiting';const courtNumber=status==='current'?Number(card.closest<HTMLElement>('.court-section')?.querySelector('h2')?.textContent?.match(/COURT\s+(\d+)/i)?.[1]??1):null;
 const rows=[...card.querySelectorAll<HTMLElement>('[data-player-id]')];const firstMoving=rows.findIndex(row=>row.classList.contains('dragging'));if(firstMoving<0)return fallback;
 // The visible highlighted slot is authoritative. The server removes the
 // moving player/group first, so only stationary rows before it count.
 const index=rows.slice(0,firstMoving).filter(row=>!row.classList.contains('dragging')).length;
 const next=rows.slice(firstMoving).find(row=>!row.classList.contains('dragging'));const previous=[...rows.slice(0,firstMoving)].reverse().find(row=>!row.classList.contains('dragging'));
 const marker=next?`before:${next.dataset.playerId}`:previous?`after:${previous.dataset.playerId}`:'empty';return{status,index,marker,courtNumber};
}

function QueueCard({title,subtitle,status,players,start,savedQueuePositions,me,admin=false,operator=false,spotlight=false,groupSpotlight=false,editing,editName,setEditing,setEditName,saveName,requestGroup,leaveGroup,leaveOwnGroup,adminLeaveGroup,permissions,adminSitOut,adminLeave,dragging,dragOver,setDragging,setDragOver,movePlayer,projections,projectedCourts}:{title:string;subtitle:string;status:'current'|'waiting';players:Player[];start:number;savedQueuePositions:Map<string,number|null>;me?:Player|null;admin?:boolean;operator?:boolean;spotlight?:boolean;groupSpotlight?:boolean;editing:string|null;editName:string;setEditing:(v:string|null)=>void;setEditName:(v:string)=>void;saveName:(p:Player)=>void;requestGroup:(p:Player)=>Promise<void>;leaveGroup:(p:Player)=>Promise<void>;leaveOwnGroup:()=>void;adminLeaveGroup:(p:Player)=>Promise<void>;permissions:(p:Player)=>void;adminSitOut:(p:Player)=>void;adminLeave:(p:Player)=>void;dragging:string|null;dragOver:DropPlacement|null;setDragging:(v:string|null)=>void;setDragOver:(v:DropPlacement|null)=>void;movePlayer:(id:string,status:'current'|'waiting',index:number,courtNumber?:number|null)=>Promise<void>;projections?:Map<string,number>;projectedCourts?:Map<string,number>}){
 const draggingPlayer=players.find(player=>player.id===dragging);
 const cardRef=useRef<HTMLElement|null>(null);const previousRowRects=useRef(new Map<string,DOMRect>());
 useLayoutEffect(()=>{const rows=[...(cardRef.current?.querySelectorAll<HTMLElement>('[data-player-id]')??[])];const nextRects=new Map<string,DOMRect>();for(const row of rows){const id=row.dataset.playerId;if(!id)continue;const rect=row.getBoundingClientRect();nextRects.set(id,rect);const previous=previousRowRects.current.get(id);const delta=previous?previous.top-rect.top:0;if(dragging&&Math.abs(delta)>1&&!matchMedia('(prefers-reduced-motion: reduce)').matches){row.getAnimations().forEach(animation=>animation.cancel());row.animate([{transform:`translateY(${delta}px)`},{transform:'translateY(0)'}],{duration:180,easing:'cubic-bezier(.2,.8,.2,1)'});}}previousRowRects.current=nextRects;},[players.map(player=>player.id).join('|'),dragging]);
 useEffect(()=>{if(!groupSpotlight)return;const button=document.querySelector<HTMLElement>('[data-drop-status="waiting"] .group-button');if(!button)return;button.classList.add('tutorial-focus','tutorial-group-target');return()=>button.classList.remove('tutorial-focus','tutorial-group-target')},[groupSpotlight,players.length]);
 useEffect(()=>{if(!projectedCourts)return;const added:HTMLElement[]=[];for(const [playerId,court] of projectedCourts){const row=cardRef.current?.querySelector<HTMLElement>(`[data-player-id="${playerId}"]`);const gameLabel=row?.querySelector<HTMLElement>('.player-name small:not(.sitout-priority-label)');if(!gameLabel||gameLabel.querySelector('.projected-court'))continue;const label=document.createElement('span');label.className='projected-court';label.textContent=` · Court ${court}`;gameLabel.appendChild(label);added.push(label)}return()=>added.forEach(label=>label.remove())},[projectedCourts,players]);
 const mobileDrag=useRef<{timer:number|null;active:boolean;preview:HTMLElement|null;player:Player|null;startX:number;startY:number;lastX:number;lastY:number;frame:number|null}>({timer:null,active:false,preview:null,player:null,startX:0,startY:0,lastX:0,lastY:0,frame:null});
 const dragOverRef=useRef<DropPlacement|null>(dragOver);
 useEffect(()=>{if(dragOver||!mobileDrag.current.active)dragOverRef.current=dragOver},[dragOver]);
 const sameTarget=(a:DropPlacement|null,b:DropPlacement|null)=>Boolean(a&&b&&a.status===b.status&&a.index===b.index&&a.marker===b.marker&&a.courtNumber===b.courtNumber);
 const resetDragTarget=()=>{dragOverRef.current=null;setDragOver(null)};
 const commitDragTarget=(next:DropPlacement|null,_y:number)=>{const current=dragOverRef.current;if((!current&&!next)||sameTarget(current,next))return current;dragOverRef.current=next;setDragOver(next);return next};
 const updateMobileTarget=(x:number,y:number)=>{const point=constrainQueueDragPoint(x,y);commitDragTarget(resolveDropPlacement(point.x,point.y,dragOverRef.current),point.y);};
 const stopAutoScroll=()=>{if(mobileDrag.current.frame!==null){cancelAnimationFrame(mobileDrag.current.frame);mobileDrag.current.frame=null;}};
 useEffect(()=>{if(!operator)return;const prepareDesktopDrag=(event:PointerEvent)=>{if(event.pointerType!=='mouse'||event.button!==0)return;const target=event.target as HTMLElement;if(target.closest('button,input'))return;const row=target.closest<HTMLElement>('[data-player-id]');if(row&&row.dataset.playerStatus===status&&cardRef.current?.contains(row))hideOtherCourtsForDrag(row);};document.addEventListener('pointerdown',prepareDesktopDrag,{capture:true});return()=>document.removeEventListener('pointerdown',prepareDesktopDrag,{capture:true});},[operator,status]);
 useEffect(()=>{if(!operator)return;const trackMouse=(event:MouseEvent)=>{const state=mobileDrag.current;if(!state.active)return;state.lastX=event.clientX;state.lastY=event.clientY;if(state.preview)positionPlayerDragPreview(state.preview,event.clientX,event.clientY);updateMobileTarget(event.clientX,event.clientY);};const finishMouse=(event:MouseEvent)=>{if(mobileDrag.current.active)finishMobileDrag(event.clientX,event.clientY);};document.addEventListener('mousemove',trackMouse);document.addEventListener('mouseup',finishMouse);return()=>{document.removeEventListener('mousemove',trackMouse);document.removeEventListener('mouseup',finishMouse);};},[operator,players]);
 useEffect(()=>{if(!operator)return;const trackDrag=(event:PointerEvent)=>{const state=mobileDrag.current;if(!state.active)return;event.preventDefault();state.lastX=event.clientX;state.lastY=event.clientY;if(state.preview)positionPlayerDragPreview(state.preview,event.clientX,event.clientY);updateMobileTarget(event.clientX,event.clientY);};const finishDrag=(event:PointerEvent)=>{if(mobileDrag.current.active)finishMobileDrag(event.clientX,event.clientY);};const confineNewPreview=new MutationObserver(()=>{const state=mobileDrag.current;if(state.preview)positionPlayerDragPreview(state.preview,state.lastX,state.lastY);});document.addEventListener('pointermove',trackDrag,{passive:false});document.addEventListener('pointerup',finishDrag);document.addEventListener('pointercancel',finishDrag);confineNewPreview.observe(document.body,{childList:true});return()=>{document.removeEventListener('pointermove',trackDrag);document.removeEventListener('pointerup',finishDrag);document.removeEventListener('pointercancel',finishDrag);confineNewPreview.disconnect();};},[operator,players]);
 const startAutoScroll=()=>{if(mobileDrag.current.frame!==null)return;const tick=()=>{if(!mobileDrag.current.active){mobileDrag.current.frame=null;return;}const y=mobileDrag.current.lastY;const edge=Math.min(128,window.innerHeight*.22);const bounds=queueScrollBounds();const direction=y<edge&&Boolean(bounds&&bounds.top<8)?-1:y>window.innerHeight-edge&&Boolean(bounds&&bounds.bottom>window.innerHeight-8)?1:0;if(direction){const strength=Math.max(.3,1-Math.min(y,window.innerHeight-y)/edge);window.scrollBy(0,direction*(7+17*strength));positionPlayerDragPreview(mobileDrag.current.preview!,mobileDrag.current.lastX,y);updateMobileTarget(mobileDrag.current.lastX,y);}mobileDrag.current.frame=requestAnimationFrame(tick)};mobileDrag.current.frame=requestAnimationFrame(tick);};
 useEffect(()=>{if(!operator)return;const beginDesktopDrag=(event:PointerEvent)=>{if(document.body.classList.contains('admin-group-selecting')||event.pointerType!=='mouse'||event.button!==0)return;const target=event.target as HTMLElement;if(target.closest('button,input'))return;const row=target.closest<HTMLElement>('[data-player-id]');if(!row||row.dataset.playerStatus!==status)return;const player=players.find(item=>item.id===row.dataset.playerId);if(!player)return;event.preventDefault();captureDragPickupViewport(row);const state=mobileDrag.current;state.startX=state.lastX=event.clientX;state.startY=state.lastY=event.clientY;state.player=player;state.active=true;setDragging(player.id);const preview=createPlayerDragPreview(player,players,start);preview.classList.add('mobile-admin-drag-preview');document.body.appendChild(preview);state.preview=preview;document.body.classList.add('mobile-admin-dragging');positionPlayerDragPreview(preview,event.clientX,event.clientY);updateMobileTarget(event.clientX,event.clientY);startAutoScroll();};document.addEventListener('pointerdown',beginDesktopDrag,{capture:true});return()=>document.removeEventListener('pointerdown',beginDesktopDrag,{capture:true});},[operator,players,start,status]);
 useEffect(()=>{if(!operator)return;const card=document.querySelector<HTMLElement>(`[data-drop-status="${status}"]`);if(!card)return;const buttons:HTMLButtonElement[]=[];for(const player of players){if(!player.group_id||players.filter(member=>member.group_id===player.group_id).length<2)continue;const row=card.querySelector<HTMLElement>(`[data-player-id="${player.id}"]`);const actions=row?.querySelector('.admin-player-actions');if(!row||!actions)continue;const button=document.createElement('button');button.type='button';button.className='admin-leave-group-button';button.textContent='Leave group';button.setAttribute('aria-label',`Remove ${player.display_name} from group`);button.onclick=()=>void adminLeaveGroup(player);row.insertBefore(button,actions);buttons.push(button);}return()=>buttons.forEach(button=>button.remove());},[operator,adminLeaveGroup,players,status]);
 const finishMobileDrag=(_x:number,_y:number)=>{const state=mobileDrag.current;if(state.timer!==null)window.clearTimeout(state.timer);document.removeEventListener('touchmove',preventNativeTouchScroll);stopAutoScroll();const playerId=state.player?.id??null;const placement=state.active&&playerId?resolveHighlightedDropPlacement(playerId,dragOverRef.current):null;state.preview?.remove();mobileDrag.current={timer:null,active:false,preview:null,player:null,startX:0,startY:0,lastX:0,lastY:0,frame:null};if(playerId&&placement)void movePlayer(playerId,placement.status,placement.index,placement.courtNumber);else{clearDragArtifacts();setDragging(null);resetDragTarget();}};
 return <section ref={cardRef} data-drop-status={status} data-player-count={players.length} className={`queue-card ${dragging?'is-dragging':''} ${spotlight?'tutorial-focus':''}`} onDragOver={e=>{e.preventDefault();setDragOver(resolveDropPlacement(e.clientX,e.clientY,dragOver))}} onDrop={e=>{e.preventDefault();const placement=resolveDropPlacement(e.clientX,e.clientY,dragOver);if(dragging&&placement)void movePlayer(dragging,placement.status,placement.index,placement.courtNumber)}}><header><h2>{title}</h2><span>{subtitle}</span></header><div>{players.length===0?<p className="empty">Players will appear here.</p>:players.map((player,index)=>{const own=player.user_id===me?.user_id;const projection=projections?.get(player.id)??null;const sameGroupBefore=Boolean(player.group_id&&players[index-1]?.group_id===player.group_id);const sameGroupAfter=Boolean(player.group_id&&players[index+1]?.group_id===player.group_id);const hasGroupMember=Boolean(player.group_id&&players.some(other=>other.id!==player.id&&other.group_id===player.group_id));const groupClass=hasGroupMember?(!sameGroupBefore?'grouped group-start':!sameGroupAfter?'grouped group-end':'grouped group-middle'):'';const sameGroup=Boolean(me?.group_id&&player.group_id===me.group_id);const ownGroupStart=Boolean(!operator&&sameGroup&&!sameGroupBefore&&hasGroupMember);return <article data-player-id={player.id} data-player-status={status} data-player-index={index} data-group-id={player.group_id??''} draggable={false} onPointerDown={e=>{if(!operator||e.pointerType==='mouse'||(e.target as HTMLElement).closest('button,input'))return;const row=e.currentTarget;const state=mobileDrag.current;state.startX=state.lastX=e.clientX;state.startY=state.lastY=e.clientY;state.player=player;document.addEventListener('touchmove',preventNativeTouchScroll,{passive:false});state.timer=window.setTimeout(()=>{state.active=true;captureDragPickupViewport(row);setDragging(player.id);row.setPointerCapture(e.pointerId);const preview=createPlayerDragPreview(player,players,start);preview.classList.add('mobile-admin-drag-preview');document.body.appendChild(preview);state.preview=preview;document.body.classList.add('mobile-admin-dragging');navigator.vibrate?.(35);preview.style.transform=`translate3d(${state.lastX+14}px,${state.lastY+14}px,0)`;startAutoScroll();},280)}} onPointerMove={e=>{const state=mobileDrag.current;state.lastX=e.clientX;state.lastY=e.clientY;if(!state.active){if(Math.hypot(e.clientX-state.startX,e.clientY-state.startY)>16&&state.timer!==null){window.clearTimeout(state.timer);state.timer=null;document.removeEventListener('touchmove',preventNativeTouchScroll);}return;}e.preventDefault();if(state.preview)state.preview.style.transform=`translate3d(${e.clientX+14}px,${e.clientY+14}px,0)`;updateMobileTarget(e.clientX,e.clientY)}} onPointerUp={e=>finishMobileDrag(e.clientX,e.clientY)} onPointerCancel={e=>finishMobileDrag(e.clientX,e.clientY)} onDragStart={e=>{setDragging(player.id);e.dataTransfer.effectAllowed='move';setPlayerDragPreview(e,player,players,start)}} onDragEnd={()=>{setDragging(null);setDragOver(null)}} onDragOver={e=>{e.preventDefault();e.stopPropagation();setDragOver(resolveDropPlacement(e.clientX,e.clientY,dragOver))}} onDrop={e=>{e.preventDefault();e.stopPropagation();const placement=resolveDropPlacement(e.clientX,e.clientY,dragOver);if(dragging&&placement)void movePlayer(dragging,placement.status,placement.index,placement.courtNumber)}} className={`player-row ${operator?'admin-row':''} ${own?'own':''} ${ownGroupStart?'own-group-start':''} ${groupClass} ${draggingPlayer?.group_id?(player.group_id===draggingPlayer.group_id?'dragging':''):(dragging===player.id?'dragging':'')}`} key={player.id}>{ownGroupStart&&<span className="your-group-label">Your Group</span>}<span className="position">{dragging?(savedQueuePositions.get(player.id)??start+index):start+index}</span><div className="player-name">{(own||admin)&&<button className="pencil" aria-label="Edit player name" onClick={()=>{setEditing(player.id);setEditName(`${player.first_name} ${player.last_name}`.trim())}}>âœŽ</button>}{editing===player.id?<input className="inline-name" autoFocus value={editName} onChange={e=>setEditName(e.target.value)} onBlur={()=>void saveName(player)} onKeyDown={e=>{if(e.key==='Enter')void saveName(player);if(e.key==='Escape')setEditing(null)}}/>:<><strong>{player.display_name}{player.is_host?' (Host)':''}{player.restricted&&(own||admin)?' (restricted)':''}</strong>{player.sitout_priority&&<small className="sitout-priority-label">(Sit-out priority)</small>}{(own||operator)&&projection&&<small>Projected: Game {projection}</small>}</>}</div>{own&&!admin&&hasGroupMember&&<button className="leave-own-group-button" onClick={leaveOwnGroup}>Leave Group</button>}{own&&<span className="you">You</span>}{!own&&me&&!operator&&(sameGroup?<button className="group-button remove-group-button" onClick={()=>void leaveGroup(player)}>Remove</button>:<button className="group-button" onClick={()=>void requestGroup(player)}>Group Up</button>)}{operator&&<div className="admin-player-actions"><button className="admin-sitout-button" onClick={()=>adminSitOut(player)}>{player.status==='sitout'?'Unsit':'Sit out'}</button><button className="admin-leave-button" onClick={()=>adminLeave(player)}>Remove</button>{admin&&<button className="restrict-button" onClick={()=>permissions(player)}>Permissions</button>}</div>}</article>})}</div></section>
}
function teamLabel(team:KingTeam){return team.members.length?team.members.map(member=>member.display_name).join(' + '):team.name}
function KingTeamCard({team,me,canJoin,busy,joinTeam,start,side,showStreak,operator,admin,adminSitOut,adminLeave,permissions}:{team:KingTeam;me:Player|null;canJoin:boolean;busy:boolean;joinTeam:(team:KingTeam,side:number)=>void;start:number;side:number;showStreak:boolean;operator:boolean;admin:boolean;adminSitOut:(player:Player)=>void;adminLeave:(player:Player)=>void;permissions:(player:Player)=>void}){
 const own=team.id===me?.team_id;const slots=[...team.members,...Array.from({length:Math.max(0,6-team.members.length)},()=>null)];
 return <section className={`king-team-card queue-team-block ${own?'own-king-team':''}`}><div className="team-block-label"><strong>Team {side}</strong>{!operator&&!own&&<button className="king-join-button" disabled={!canJoin||busy} onClick={()=>joinTeam(team,side)}>{team.members.length>=6?'Team full':'Join +'}</button>}{team.status==='current'&&showStreak&&<span>Game streak: {team.consecutive_wins}</span>}</div>{slots.map((member,index)=><article className={`player-row king-player-row ${member?'':'king-empty-row'} ${member?.user_id===me?.user_id?'own':''}`} key={member?.id??`empty-${index}`}><span className="position">{start+index}</span><div className="player-name"><strong>{member?.display_name??'Open spot'}</strong></div>{member&&member.user_id===me?.user_id&&<span className="you">You</span>}{member&&operator&&<div className="admin-player-actions"><button className="admin-sitout-button" onClick={()=>adminSitOut(member)}>Sit out</button><button className="admin-leave-button" onClick={()=>adminLeave(member)}>Remove</button>{admin&&<button className="restrict-button" onClick={()=>permissions(member)}>Permissions</button>}</div>}</article>)}</section>
}
function KingBoard({teams,courts,me,admin,host,busy,nextGame,joinTeam,setCourtRules,adminSitOut,adminLeave,permissions}:{teams:KingTeam[];courts:Court[];me:Player|null;admin:boolean;host:boolean;busy:boolean;nextGame:(court:number)=>void;joinTeam:(team:KingTeam,side:number)=>void;setCourtRules:(court:number,mode:'rotation'|'king',maxWins:number|null)=>Promise<void>;adminSitOut:(player:Player)=>void;adminLeave:(player:Player)=>void;permissions:(player:Player)=>void}){
 const operator=admin||host;const waiting=teams.filter(team=>team.status==='waiting').sort((a,b)=>a.queue_position-b.queue_position);
 return <div className="king-board">{courts.map((court,courtIndex)=>{const active=teams.filter(team=>team.status==='current'&&team.court_number===court.court_number).sort((a,b)=>(a.court_side??1)-(b.court_side??1));const ownCourt=active.some(team=>team.id===me?.team_id);const mode=court.team_mode??'rotation';const maxWins=court.team_max_wins??2;const firstTeam=courtIndex*2+1;return <section className="king-court queue-card" key={court.court_number}><header><div className="king-court-title"><h2>{courts.length>1?`COURT ${court.court_number} - Game ${court.game_number}`:'CURRENT GAME - Team 1 vs Team 2'}</h2><div className="court-team-rule">{operator?<><select aria-label={`Court ${court.court_number} format`} value={mode} onChange={event=>void setCourtRules(court.court_number,event.target.value as 'rotation'|'king',maxWins)}><option value="rotation">2 on, 2 off</option><option value="king">King of the Court</option></select>{mode==='king'&&<><span>with</span><select aria-label={`Court ${court.court_number} consecutive games`} value={court.team_max_wins??'unlimited'} onChange={event=>void setCourtRules(court.court_number,'king',event.target.value==='unlimited'?null:Number(event.target.value))}><option value="2">2</option><option value="3">3</option><option value="unlimited">Unlimited</option></select><span>consecutive games MAX</span></>}</>:<span>{mode==='king'?`KING OF THE COURT (${court.team_max_wins==null?'UNLIMITED':court.team_max_wins} CONSECUTIVE GAMES MAX)`:'2 ON, 2 OFF'}</span>}</div></div><span>{active.reduce((total,team)=>total+team.members.length,0)} playing</span></header>{courts.length>1&&(operator||ownCourt)&&<button className="court-next-button" disabled={busy||active.length!==2||Boolean(me?.restricted)} onClick={()=>nextGame(court.court_number)}>Next game (Court {court.court_number})</button>}<div className="king-current-teams">{active.map((team,index)=><KingTeamCard key={team.id} team={team} me={me} canJoin={!operator&&team.id!==me?.team_id&&team.members.length<6} busy={busy} joinTeam={joinTeam} start={index*6+1} side={firstTeam+index} showStreak={mode==='king'} operator={operator} admin={admin} adminSitOut={adminSitOut} adminLeave={adminLeave} permissions={permissions}/>)}{active.length<2&&Array.from({length:2-active.length},(_,index)=><section className="king-team-card queue-team-block empty-team-block" key={`empty-team-${index}`}><div className="team-block-label"><strong>Team {firstTeam+active.length+index}</strong></div>{Array.from({length:6},(__,slot)=><article className="player-row king-player-row king-empty-row" key={slot}><span className="position">{(active.length+index)*6+slot+1}</span><div className="player-name"><strong>Open spot</strong></div></article>)}</section>)}</div></section>})}<section className="king-waitlist queue-card"><header><h2>Waitlist</h2><span>{waiting.length?`${waiting.length} team${waiting.length===1?'':'s'} waiting`:'No one waiting'}</span></header><div className="king-waiting-list">{waiting.length?waiting.map((team,index)=><KingTeamCard key={team.id} team={team} me={me} canJoin={!operator&&team.id!==me?.team_id&&team.members.length<6} busy={busy} joinTeam={joinTeam} start={13+index*6} side={courts.length*2+index+1} showStreak={false} operator={operator} admin={admin} adminSitOut={adminSitOut} adminLeave={adminLeave} permissions={permissions}/>):<section className="king-team-card queue-team-block empty-team-block"><div className="team-block-label"><strong>Team {courts.length*2+1}</strong></div>{Array.from({length:6},(_,slot)=><article className="player-row king-player-row king-empty-row" key={slot}><span className="position">{13+slot}</span><div className="player-name"><strong>Open spot</strong></div></article>)}</section>}</div></section></div>
}
function Modal({notice,close,busy}:{notice:Exclude<Notice,null>;close:()=>void;busy:boolean}){const dismiss=async()=>{close();await notice.cancelAction?.();notice.onClose?.()};const emphasized=notice.message.match(/^(.*?) \*\*(.+)\*\*$/);return <div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget&&!notice.blocking&&!notice.onClose)void dismiss()}}><section className="modal" role="dialog" aria-modal="true"><span className="modal-mark">OG</span><h2>{notice.title}</h2>{emphasized?<p>{emphasized[1]}<strong className="modal-reminder">**{emphasized[2]}**</strong></p>:<p>{notice.message}</p>}<div className="modal-actions">{notice.action&&<button className={notice.actionTone==='success'?'next':'danger'} disabled={busy} onClick={async()=>{close();await notice.action?.();notice.onClose?.()}}>{notice.confirm}</button>}<button className={notice.cancelTone==='danger'?'danger':notice.cancelTone==='success'?'next':'neutral'} disabled={busy} onClick={()=>void dismiss()}>{notice.cancelLabel??(notice.action?'Cancel':'OK')}</button></div></section></div>}

