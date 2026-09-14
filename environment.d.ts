interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  readonly VITE_VAPID_PUBLIC_KEY?: string;
}

interface ImportMeta { readonly env: ImportMetaEnv }

interface Fetcher { fetch(input:RequestInfo|URL,init?:RequestInit):Promise<Response> }
interface D1Database {}

declare module 'cloudflare:workers' {
  export const env: { DB?: D1Database };
  export class DurableObject<Env=unknown> {
    protected env:Env;
    constructor(state:unknown,env:Env);
  }
}
