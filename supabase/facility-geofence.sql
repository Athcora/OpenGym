-- Facility geofence. Coordinates are used only for an on-site distance check;
-- individual player locations are never stored.
alter table public.waitlist_config
  add column if not exists facility_latitude double precision,
  add column if not exists facility_longitude double precision,
  add column if not exists geofence_radius_m integer not null default 150,
  add column if not exists geofence_enabled boolean not null default false;

create or replace function public.admin_set_facility_location(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_m integer default 150
)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'Invalid facility location.';
  end if;
  if p_radius_m not between 50 and 1000 then raise exception 'Radius must be between 50 and 1000 meters.'; end if;
  update public.waitlist_config set
    facility_latitude=p_latitude,
    facility_longitude=p_longitude,
    geofence_radius_m=p_radius_m,
    geofence_enabled=true,
    updated_at=now()
  where id;
  return jsonb_build_object('message','Facility location saved.','radius_m',p_radius_m);
end;
$$;

create or replace function public.verify_facility_location(
  p_latitude double precision,
  p_longitude double precision
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.waitlist_config; distance_m double precision;
begin
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'Invalid device location.';
  end if;
  select * into c from public.waitlist_config where id;
  if not c.geofence_enabled or c.facility_latitude is null or c.facility_longitude is null then
    return jsonb_build_object('configured',false,'inside',true,'distance_m',0,'radius_m',c.geofence_radius_m);
  end if;
  distance_m:=6371000*acos(least(1,greatest(-1,
    sin(radians(c.facility_latitude))*sin(radians(p_latitude))+
    cos(radians(c.facility_latitude))*cos(radians(p_latitude))*cos(radians(p_longitude-c.facility_longitude))
  )));
  return jsonb_build_object(
    'configured',true,
    'inside',distance_m<=c.geofence_radius_m,
    'distance_m',round(distance_m::numeric,1),
    'radius_m',c.geofence_radius_m
  );
end;
$$;

grant execute on function public.admin_set_facility_location(double precision,double precision,integer) to authenticated;
grant execute on function public.verify_facility_location(double precision,double precision) to authenticated;
