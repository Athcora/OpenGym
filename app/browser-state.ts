import { useCallback, useState, useSyncExternalStore } from 'react';

// Browser storage is external state. The server snapshot deliberately stays at
// the default so hydration cannot overwrite a saved preference with that default.
export function useBrowserPreference<T extends string>(key:string,allowed:readonly T[],fallback:T,browserFallback?:()=>T){
  const subscribe=useCallback((notify:()=>void)=>{
    const changed=(event:Event)=>{
      if(!(event instanceof StorageEvent)||event.key===key||event.key===null)notify();
    };
    window.addEventListener('storage',changed);
    window.addEventListener('opengym-preference-change',changed);
    return()=>{window.removeEventListener('storage',changed);window.removeEventListener('opengym-preference-change',changed)};
  },[key]);
  const snapshot=useCallback(()=>{
    const saved=localStorage.getItem(key);
    return allowed.includes(saved as T)?saved as T:browserFallback?.()??fallback;
  },[key,allowed,fallback,browserFallback]);
  const value=useSyncExternalStore(subscribe,snapshot,()=>fallback);
  const setValue=useCallback((next:T)=>{
    localStorage.setItem(key,next);
    window.dispatchEvent(new Event('opengym-preference-change'));
  },[key]);
  return [value,setValue] as const;
}

function createClock(){
  let now=Date.now();
  return {
    snapshot:()=>now,
    subscribe(notify:()=>void){
      const tick=()=>{now=Date.now();notify()};
      tick();
      const timer=window.setInterval(tick,1000);
      return()=>window.clearInterval(timer);
    },
  };
}

export function useBrowserClock(active:boolean){
  const [clock]=useState(createClock);
  const subscribe=useCallback((notify:()=>void)=>{
    if(!active)return()=>{};
    return clock.subscribe(notify);
  },[active,clock]);
  return useSyncExternalStore(subscribe,clock.snapshot,clock.snapshot);
}
