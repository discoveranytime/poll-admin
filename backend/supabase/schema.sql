-- ============================================================
-- Poll system — Supabase schema
-- Run in the Supabase SQL editor (or via migration).
-- Requires: pgcrypto (gen_random_uuid, digest).
-- ============================================================

create extension if not exists pgcrypto;

-- ---------------- helpers ----------------
create or replace function public.is_admin()
returns boolean language sql stable security definer as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.poll_is_votable(p public.polls)
returns boolean language sql stable as $$
  select p.status = 'open'
      or (p.status = 'scheduled'
          and (p.scheduled_opens_at is null or now() >= p.scheduled_opens_at)
          and (p.scheduled_closes_at is null or now() <= p.scheduled_closes_at));
$$;

-- ---------------- tables ----------------
create table public.polls (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null check (slug ~ '^[a-z0-9-]+$'),
  title text not null,
  description text default '',
  topic text default '',
  category text default '',
  status text not null default 'draft' check (status in ('draft','scheduled','open','closed')),
  scheduled_opens_at timestamptz,
  scheduled_closes_at timestamptz,
  hide_results_until_close boolean not null default false,
  require_captcha boolean not null default false,
  disclaimer text default '',
  theme jsonb not null default '{}',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id) on delete cascade,
  label text not null,
  emoji text default '',
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index on public.poll_options (poll_id, position);

create table public.votes (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id) on delete cascade,
  option_id uuid not null references public.poll_options(id) on delete cascade,
  fingerprint_hash text not null,
  ip_hash text not null,
  country_code text,                       -- only when GeoIP available & enabled
  status text not null default 'valid' check (status in ('valid','flagged','invalid')),
  flag_reason text,
  turnstile_ok boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.votes (poll_id, created_at);
create index on public.votes (poll_id, fingerprint_hash);
create index on public.votes (ip_hash, created_at);

create table public.poll_views (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id) on delete cascade,
  fingerprint_hash text,
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index on public.poll_views (poll_id, created_at);
create index on public.poll_views (poll_id, fingerprint_hash, created_at);

create table public.bans (
  id uuid primary key default gen_random_uuid(),
  fingerprint_hash text,
  ip_hash text,
  reason text default '',
  expires_at timestamptz,                   -- null = permanent
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (fingerprint_hash is not null or ip_hash is not null)
);

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor uuid references auth.users(id),
  action text not null,
  target_type text,
  target_id text,
  details jsonb,
  created_at timestamptz not null default now()
);
create index on public.audit_log (created_at desc);

create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'admin',
  created_at timestamptz not null default now()
);

create table public.settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.settings (key, value) values
  ('data_retention_days', '365'),
  ('captcha_required_default', 'false')
on conflict (key) do nothing;

-- ---------------- updated_at ----------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger polls_touch before update on public.polls
  for each row execute function public.touch_updated_at();

-- ---------------- audit trigger ----------------
create or replace function public.audit_changes()
returns trigger language plpgsql security definer as $$
declare detail jsonb;
begin
  detail = jsonb_build_object('table', TG_TABLE_NAME, 'op', TG_OP);
  insert into public.audit_log (actor, action, target_type, target_id, details)
  values (auth.uid(), TG_TABLE_NAME || '.' || lower(TG_OP),
          TG_TABLE_NAME, coalesce((to_jsonb(new)->>'id'), (to_jsonb(old)->>'id')), detail);
  return coalesce(new, old);
end $$;

create trigger polls_audit   after insert or update or delete on public.polls
  for each row execute function public.audit_changes();
create trigger options_audit after insert or update or delete on public.poll_options
  for each row execute function public.audit_changes();
create trigger bans_audit    after insert or delete on public.bans
  for each row execute function public.audit_changes();
create trigger settings_audit after update on public.settings
  for each row execute function public.audit_changes();

-- vote status changes are audited explicitly by admins; add trigger too
create trigger votes_audit after update of status on public.votes
  for each row execute function public.audit_changes();

-- ---------------- public results RPC ----------------
create or replace function public.get_public_results(p_poll_id uuid)
returns jsonb language plpgsql stable security definer as $$
declare
  p public.polls%rowtype;
  hidden boolean;
  total int;
  opts jsonb;
begin
  select * into p from public.polls where id = p_poll_id;
  if not found then
    return jsonb_build_object('hidden', true, 'total', 0, 'options', '[]'::jsonb);
  end if;
  hidden := p.hide_results_until_close
            and (p.status = 'open' or (p.status = 'scheduled' and public.poll_is_votable(p)));
  select count(*) into total from public.votes
    where poll_id = p_poll_id and status = 'valid';
  if hidden then
    return jsonb_build_object('hidden', true, 'total', total, 'options', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(o order by o.position), '[]'::jsonb) into opts
  from (
    select po.id as option_id, po.label, po.emoji,
           count(v.id)::int as votes,
           round(count(v.id)::numeric / nullif((select count(*) from public.votes
             where poll_id = p_poll_id and status='valid'),0) * 100, 1) as pct
    from public.poll_options po
    left join public.votes v on v.option_id = po.id and v.status = 'valid'
    where po.poll_id = p_poll_id
    group by po.id, po.label, po.emoji, po.position
  ) o;
  return jsonb_build_object('hidden', false, 'total', total, 'options', opts);
end $$;

-- ---------------- admin overview RPC ----------------
create or replace function public.admin_poll_overview(p_poll_id uuid)
returns jsonb language plpgsql stable security definer as $$
declare out jsonb;
begin
  if not public.is_admin() then
    raise exception 'forbidden';
  end if;
  with v as (
    select * from public.votes where poll_id = p_poll_id
  )
  select jsonb_build_object(
    'views',      (select count(*) from public.poll_views where poll_id = p_poll_id),
    'votes',      (select count(*) from v),
    'valid_votes',(select count(*) from v where status='valid'),
    'flagged',    (select count(*) from v where status='flagged'),
    'invalid',    (select count(*) from v where status='invalid'),
    'conversion', round(
        (select count(*) from v where status='valid')::numeric
        / nullif((select count(*) from public.poll_views where poll_id = p_poll_id),0) * 100, 1),
    'options', (
      select coalesce(jsonb_agg(o order by o.position), '[]'::jsonb) from (
        select po.id as option_id, po.label, po.emoji, po.position,
               count(vv.id)::int as votes,
               round(count(vv.id)::numeric / nullif((select count(*) from v where status='valid'),0) * 100, 1) as pct
        from public.poll_options po
        left join v vv on vv.option_id = po.id and vv.status='valid'
        where po.poll_id = p_poll_id
        group by po.id, po.label, po.emoji, po.position
      ) o
    ),
    'votes_by_day', (
      select coalesce(jsonb_agg(d order by d.day), '[]'::jsonb) from (
        select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as day,
               count(*)::int as votes
        from v where status='valid' group by 1
      ) d
    ),
    'votes_by_hour', (
      select coalesce(jsonb_agg(hh order by hh.hour), '[]'::jsonb) from (
        select extract(hour from created_at)::int as hour, count(*)::int as votes
        from v where status='valid' group by 1
      ) hh
    ),
    'top_countries', (
      select coalesce(jsonb_agg(c order by c.votes desc), '[]'::jsonb) from (
        select country_code, count(*)::int as votes
        from v where status='valid' and country_code is not null
        group by 1 order by 2 desc limit 10
      ) c
    ),
    'new_vs_returning', (
      select jsonb_build_object(
        'new', (select count(*) from
                 (select distinct fingerprint_hash from v where status='valid') f
                 where not exists (
                   select 1 from public.votes ov
                   where ov.fingerprint_hash = f.fingerprint_hash
                     and ov.poll_id <> p_poll_id)),
        'returning', (select count(*) from
                 (select distinct fingerprint_hash from v where status='valid') f
                 where exists (
                   select 1 from public.votes ov
                   where ov.fingerprint_hash = f.fingerprint_hash
                     and ov.poll_id <> p_poll_id))
      )
    ),
    'bans', (select count(*) from public.bans
             where expires_at is null or expires_at > now())
  ) into out;
  return out;
end $$;

-- ---------------- RLS ----------------
alter table public.polls         enable row level security;
alter table public.poll_options   enable row level security;
alter table public.votes          enable row level security;
alter table public.poll_views     enable row level security;
alter table public.bans           enable row level security;
alter table public.audit_log      enable row level security;
alter table public.admins         enable row level security;
alter table public.settings       enable row level security;

-- public: read votable polls + their options
create policy polls_public_read on public.polls
  for select using (public.poll_is_votable(polls));
create policy options_public_read on public.poll_options
  for select using (
    exists (select 1 from public.polls p
            where p.id = poll_options.poll_id and public.poll_is_votable(p)));

-- admins: everything
create policy polls_admin_all on public.polls
  for all using (public.is_admin()) with check (public.is_admin());
create policy options_admin_all on public.poll_options
  for all using (public.is_admin()) with check (public.is_admin());
create policy votes_admin_all on public.votes
  for all using (public.is_admin()) with check (public.is_admin());
create policy views_admin_read on public.poll_views
  for select using (public.is_admin());
create policy views_admin_delete on public.poll_views
  for delete using (public.is_admin());
create policy bans_admin_all on public.bans
  for all using (public.is_admin()) with check (public.is_admin());
create policy audit_admin_read on public.audit_log
  for select using (public.is_admin());
create policy admins_admin_read on public.admins
  for select using (public.is_admin());
create policy settings_admin_all on public.settings
  for all using (public.is_admin()) with check (public.is_admin());

-- RPCs: locked down inside the function bodies
grant execute on function public.get_public_results(uuid) to anon, authenticated;
grant execute on function public.admin_poll_overview(uuid) to authenticated;

-- ---------------- seed: Retatrutide poll ----------------
-- (run after creating your first admin user; created_by left null)
insert into public.polls (slug, title, description, topic, category, status, disclaimer, theme)
values (
  'retatrutide-interests',
  'What Interests You Most About Retatrutide?',
  'Retatrutide is generating a lot of interest. What are you most curious about?',
  'Retatrutide',
  'Weight Loss / Metabolic Health',
  'open',
  'This poll is for community discussion only. Answers reflect what participants are curious about — not medical advice, and poll results are not scientific evidence. Retatrutide is investigational and not FDA-approved.',
  '{"accent":"#7cc7ff","accent2":"#5eead4","accent3":"#fb923c","bg":"#06070d","card":"#0d1020","ink":"#edf0f9","muted":"#a9b1c9"}'
) on conflict (slug) do nothing;

insert into public.poll_options (poll_id, label, emoji, position)
select id, x.label, x.emoji, x.pos
from public.polls p,
lateral (values
  ('How much weight can Retatrutide actually help me lose?', '🔥', 1),
  ('How strongly does it reduce appetite and cravings?', '🧠', 2),
  ('How does it affect muscle vs. fat loss?', '💪', 3),
  ('What other metabolic/health effects might it have?', '🧬', 4),
  ('What side effects and long-term risks are associated with it?', '⚠️', 5),
  ('How do different doses compare?', '💉', 6),
  ('What happens after stopping Retatrutide?', '🔄', 7),
  ('How much does Retatrutide realistically cost?', '💰', 8)
) as x(label, emoji, pos)
where p.slug = 'retatrutide-interests'
  and not exists (select 1 from public.poll_options po where po.poll_id = p.id);
