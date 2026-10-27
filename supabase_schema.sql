-- SeasonLong v1.4 Shared Cloud schema for Supabase
-- Run this entire file in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.private_leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  invite_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.league_members (
  league_id uuid not null references public.private_leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  team_index int not null check (team_index between 0 and 3),
  team_name text not null check (char_length(team_name) between 1 and 50),
  joined_at timestamptz not null default now(),
  primary key (league_id,user_id),
  unique (league_id,team_index)
);
create table if not exists public.league_snapshots (
  league_id uuid primary key references public.private_leagues(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now()
);

create or replace function public.create_private_league(p_name text, p_team_name text)
returns table(league_id uuid, invite_code text)
language plpgsql security definer set search_path=public,auth as $$
declare v_id uuid; v_code text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 v_code := upper(substr(encode(gen_random_bytes(8),'hex'),1,8));
 insert into public.private_leagues(name,invite_code,owner_id) values (left(coalesce(nullif(trim(p_name),''),'SeasonLong League'),80),v_code,auth.uid()) returning id into v_id;
 insert into public.league_members(league_id,user_id,team_index,team_name) values(v_id,auth.uid(),0,left(coalesce(nullif(trim(p_team_name),''),'Team 1'),50));
 insert into public.league_snapshots(league_id,state,updated_by) values(v_id,jsonb_build_object('leagueName',left(coalesce(nullif(trim(p_name),''),'SeasonLong League'),80),'seasonPhase','setup','myTeamId',0,'teams',jsonb_build_array(jsonb_build_object('name',left(coalesce(nullif(trim(p_team_name),''),'Team 1'),50),'picks','[]'::jsonb,'faIds','[]'::jsonb),jsonb_build_object('name','Team 2','picks','[]'::jsonb,'faIds','[]'::jsonb),jsonb_build_object('name','Team 3','picks','[]'::jsonb,'faIds','[]'::jsonb),jsonb_build_object('name','Team 4','picks','[]'::jsonb,'faIds','[]'::jsonb)),'pickLog','[]'::jsonb,'statsRows','[]'::jsonb,'weeklyResults','[]'::jsonb,'transactions','[]'::jsonb,'myRosterIds','[]'::jsonb),auth.uid());
 return query select v_id,v_code;
end; $$;

create or replace function public.join_private_league(p_code text, p_team_name text)
returns table(league_id uuid, team_index int)
language plpgsql security definer set search_path=public,auth as $$
declare v_id uuid; v_slot int; v_name text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select l.id into v_id from public.private_leagues l where l.invite_code=upper(trim(p_code));
 if v_id is null then raise exception 'Invalid invite code'; end if;
 if exists(select 1 from public.league_members m where m.league_id=v_id and m.user_id=auth.uid()) then
   select m.team_index into v_slot from public.league_members m where m.league_id=v_id and m.user_id=auth.uid();
   return query select v_id,v_slot; return;
 end if;
 select gs.slot into v_slot from generate_series(0,3) as gs(slot) where not exists(select 1 from public.league_members m where m.league_id=v_id and m.team_index=gs.slot) order by gs.slot limit 1;
 if v_slot is null then raise exception 'League is full'; end if;
 v_name:=left(coalesce(nullif(trim(p_team_name),''),'Team '||(v_slot+1)),50);
 insert into public.league_members(league_id,user_id,team_index,team_name) values(v_id,auth.uid(),v_slot,v_name);
 return query select v_id,v_slot;
end; $$;

alter table public.private_leagues enable row level security;
alter table public.league_members enable row level security;
alter table public.league_snapshots enable row level security;

create or replace function public.is_league_member(p_league_id uuid)
returns boolean language sql stable security definer set search_path=public,auth as $$
  select exists(select 1 from public.league_members m where m.league_id=p_league_id and m.user_id=auth.uid());
$$;
revoke all on function public.is_league_member(uuid) from public, anon;
grant execute on function public.is_league_member(uuid) to authenticated;

drop policy if exists "members read league" on public.private_leagues;
create policy "members read league" on public.private_leagues for select to authenticated using (public.is_league_member(id));
drop policy if exists "members read members" on public.league_members;
create policy "members read members" on public.league_members for select to authenticated using (public.is_league_member(league_id));
drop policy if exists "members read snapshot" on public.league_snapshots;
create policy "members read snapshot" on public.league_snapshots for select to authenticated using (public.is_league_member(league_id));
drop policy if exists "members update snapshot" on public.league_snapshots;
create policy "members update snapshot" on public.league_snapshots for update to authenticated using (public.is_league_member(league_id)) with check (public.is_league_member(league_id) and updated_by=auth.uid());
drop policy if exists "members insert snapshot" on public.league_snapshots;
create policy "members insert snapshot" on public.league_snapshots for insert to authenticated with check (public.is_league_member(league_id) and updated_by=auth.uid());

grant select on public.private_leagues, public.league_members, public.league_snapshots to authenticated;
grant insert,update on public.league_snapshots to authenticated;
grant execute on function public.create_private_league(text,text) to authenticated;
grant execute on function public.join_private_league(text,text) to authenticated;
-- Enable Realtime for shared snapshot updates.
do $$ begin alter publication supabase_realtime add table public.league_snapshots; exception when duplicate_object then null; when undefined_object then null; end $$;

revoke all on function public.create_private_league(text,text) from public, anon;
revoke all on function public.join_private_league(text,text) from public, anon;
