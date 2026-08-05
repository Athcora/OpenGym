-- Enforces safe, unique player names when a guest or admin edits a name.
create or replace function public.is_inappropriate_player_name(p_name text)
returns boolean language plpgsql immutable as $$
declare
  normalized text;
  token text;
  blocked text[] := array[
    'fuck','fuk','fck','shit','bitch','cunt','dick','pussy','asshole','whore','slut',
    'nigger','nigga','niger','faggot','fag','retard','kike','chink','spic','wetback',
    'porn','rape','rapist','nazi','hitler'
  ];
begin
  normalized := lower(coalesce(p_name,''));
  normalized := translate(normalized,'013457@$!','oieasgasii');
  normalized := regexp_replace(normalized,'[^a-z]+',' ','g');
  foreach token in array blocked loop
    if (' '||normalized||' ') like '% '||token||' %'
       or replace(normalized,' ','') like '%'||token||'%' then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

create or replace function public.rename_waitlist_player(
  p_player_id uuid,
  p_first_name text,
  p_last_name text default ''
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players;
  clean_first text := initcap(public.clean_player_name(p_first_name));
  clean_last text := initcap(public.clean_player_name(p_last_name));
  shown_name text;
  same_first boolean;
begin
  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null then raise exception 'This player could not be found.'; end if;
  if player.user_id is distinct from auth.uid() and not public.is_waitlist_admin() then
    raise exception 'You can only edit your own name.';
  end if;
  if clean_first='' then raise exception 'Enter a first name using letters.'; end if;
  if public.is_inappropriate_player_name(clean_first||' '||clean_last) then
    raise exception 'This name is not allowed. Choose a different name.';
  end if;

  select exists(
    select 1 from public.waitlist_players p
    where p.id<>player.id and p.status<>'left' and lower(p.first_name)=lower(clean_first)
  ) into same_first;

  if same_first and clean_last='' then
    raise exception 'That first name is already being used. Add a last initial or last name.';
  end if;

  shown_name := clean_first||case when clean_last='' then '' else ' '||left(clean_last,1) end;
  if exists(
    select 1 from public.waitlist_players p
    where p.id<>player.id and p.status<>'left' and lower(p.display_name)=lower(shown_name)
  ) then
    if length(clean_last)>1 then
      shown_name := clean_first||' '||clean_last;
    else
      raise exception 'That name is already being used. Add a full last name.';
    end if;
  end if;

  if exists(
    select 1 from public.waitlist_players p
    where p.id<>player.id and p.status<>'left' and lower(p.display_name)=lower(shown_name)
  ) then
    raise exception 'That name is already being used. Choose a different last name.';
  end if;

  update public.waitlist_players
    set first_name=clean_first,last_name=clean_last,display_name=shown_name,updated_at=now()
    where id=player.id;
  return jsonb_build_object('message','Your name was updated.');
end;
$$;

grant execute on function public.rename_waitlist_player(uuid,text,text) to authenticated;
