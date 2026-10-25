-- SCC Intake Portal: initial schema
-- Draft from the Google Form screenshot. Review before running.

-- ---------- enums ----------
create type app_role as enum ('applicant', 'coordinator', 'board');

create type membership_type as enum (
  'individual_coop',          -- $500 refundable one-time
  'individual_casual',        -- $10/month, non-refundable
  'family_coop',              -- $750 refundable, incl. additional family member
  'additional_family',        -- $250 refundable
  'corporate',                -- $750 refundable
  'additional_corporate_driver'
);

create type fee_method as enum ('etransfer_paypal', 'cheque', 'other');
create type onboarding_stage as enum
  ('applied', 'approved', 'paperwork', 'deposit', 'orientation', 'in_engage');
create type doc_kind as enum ('licence', 'abstract', 'other');

-- ---------- roles ----------
create table profiles (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  role       app_role not null default 'applicant',
  created_at timestamptz not null default now()
);

create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (user_id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

create function user_role() returns app_role
language sql stable security definer set search_path = public as $$
  select role from profiles where user_id = auth.uid()
$$;

create function is_coordinator() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(user_role() = 'coordinator', false)
$$;

create function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(user_role() in ('coordinator', 'board'), false)
$$;

alter table profiles enable row level security;
-- No insert/update policies: roles are changed only via SQL or the service key.
create policy "read own profile or coordinator"
  on profiles for select to authenticated
  using (user_id = auth.uid() or is_coordinator());

-- ---------- applicants (data the applicant supplies) ----------
create table applicants (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null unique references auth.users (id) on delete cascade,
  created_at       timestamptz not null default now(),

  first_name       text not null,
  last_name        text not null,
  email            text not null,
  membership_type  membership_type not null,
  linked_account   text,            -- family/corporation name + member number, if additional member/driver
  fee_method       fee_method not null,
  fee_method_other text,

  phone_home       text not null,
  phone_cell       text,
  phone_work       text,
  street_address   text not null,
  city             text not null,
  postal_code      text not null,

  heard_about       text,           -- optional
  heard_about_other text,
  coop_referral     text,           -- optional

  ec_first_name    text not null,   -- emergency contact
  ec_last_name     text not null,
  ec_relationship  text not null,
  ec_phone         text not null
);

-- Defined after applicants: a sql-language function body is validated when created.
create function owns_applicant(aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from applicants where id = aid and user_id = auth.uid())
$$;

alter table applicants enable row level security;

-- OPEN: board currently reads all applicant contact details. Confirm this is intended.
create policy "applicant reads own, staff reads all"
  on applicants for select to authenticated
  using (user_id = auth.uid() or is_staff());
create policy "applicant creates own"
  on applicants for insert to authenticated
  with check (user_id = auth.uid());
-- OPEN: applicants can still edit their row (e.g. membership_type) after approval.
create policy "applicant updates own"
  on applicants for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "coordinator updates all"
  on applicants for update to authenticated
  using (is_coordinator()) with check (is_coordinator());

-- ---------- onboarding (coordinator-controlled progress; applicant read-only) ----------
create table onboarding (
  applicant_id            uuid primary key references applicants (id) on delete cascade,
  stage                   onboarding_stage not null default 'applied',
  approved_at             timestamptz,
  fee_received_at         timestamptz,
  abstract_received_at    timestamptz,
  attestation_received_at timestamptz,   -- OPEN: define what "attestation" means in the real process
  licence_verified_at     timestamptz,
  licence_verified_by     uuid references auth.users (id),
  abstract_verified_at    timestamptz,
  abstract_verified_by    uuid references auth.users (id),
  orientation_done_at     timestamptz,
  fob_mailed_at           timestamptz,
  insurer_notified_at     timestamptz,
  in_engage_at            timestamptz
);

create function create_onboarding() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into onboarding (applicant_id) values (new.id);
  return new;
end $$;

create trigger applicant_created
  after insert on applicants
  for each row execute function create_onboarding();

alter table onboarding enable row level security;
create policy "owner or staff reads"
  on onboarding for select to authenticated
  using (owns_applicant(applicant_id) or is_staff());
create policy "coordinator updates"
  on onboarding for update to authenticated
  using (is_coordinator()) with check (is_coordinator());

-- ---------- sensitive identity fields (coordinator only; board has no access) ----------
-- OPEN: CLAUDE.md says not to store licence numbers. Confirm with Ed/board before keeping these.
-- OPEN: after the scrub trigger runs, the owner insert policy lets the row be re-created.
create table applicant_sensitive (
  applicant_id   uuid primary key references applicants (id) on delete cascade,
  date_of_birth  date not null,
  licence_number text not null,
  licence_expiry date not null
);

alter table applicant_sensitive enable row level security;
create policy "owner reads own"
  on applicant_sensitive for select to authenticated
  using (owns_applicant(applicant_id) or is_coordinator());
create policy "owner inserts own"
  on applicant_sensitive for insert to authenticated
  with check (owns_applicant(applicant_id));
create policy "owner updates own"
  on applicant_sensitive for update to authenticated
  using (owns_applicant(applicant_id)) with check (owns_applicant(applicant_id));

-- ---------- acknowledgements (insert-only record of each checkbox) ----------
-- section: 'rights' (11 items), 'driver_attestation' (6), 'declaration' (2)
-- wording_version points at the exact wording stored in the repo.
create table acknowledgements (
  id              uuid primary key default gen_random_uuid(),
  applicant_id    uuid not null references applicants (id) on delete cascade,
  section         text not null check (section in ('rights', 'driver_attestation', 'declaration')),
  item_key        text not null,
  wording_version text not null,
  accepted_at     timestamptz not null default now(),
  unique (applicant_id, item_key, wording_version)
);

-- The client can't backdate or forge the timestamp.
create function stamp_acknowledgement() returns trigger
language plpgsql set search_path = public as $$
begin
  new.accepted_at := now();
  return new;
end $$;

create trigger acknowledgement_stamp
  before insert on acknowledgements
  for each row execute function stamp_acknowledgement();

alter table acknowledgements enable row level security;
create policy "owner or staff reads"
  on acknowledgements for select to authenticated
  using (owns_applicant(applicant_id) or is_staff());
create policy "owner inserts own"
  on acknowledgements for insert to authenticated
  with check (owns_applicant(applicant_id));
-- No update/delete policies: the record is immutable from the client.

-- ---------- coordinator-only notes ----------
create table applicant_notes (
  id           uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references applicants (id) on delete cascade,
  body         text not null,
  created_by   uuid references auth.users (id) default auth.uid(),
  created_at   timestamptz not null default now()
);

alter table applicant_notes enable row level security;
create policy "coordinator only"
  on applicant_notes for all to authenticated
  using (is_coordinator()) with check (is_coordinator());

-- ---------- uploaded documents (metadata only; files live in Storage) ----------
create table documents (
  id           uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references applicants (id) on delete cascade,
  kind         doc_kind not null,
  storage_path text not null unique,    -- '<auth user id>/<filename>'
  uploaded_at  timestamptz not null default now(),
  verified_at  timestamptz,
  verified_by  uuid references auth.users (id),
  deleted_at   timestamptz              -- set when the file is removed from Storage
);

alter table documents enable row level security;
create policy "owner reads own, coordinator reads all"
  on documents for select to authenticated
  using (owns_applicant(applicant_id) or is_coordinator());
-- The applicant can't pre-verify a document or point it at someone else's folder.
create policy "owner registers own upload"
  on documents for insert to authenticated
  with check (
    owns_applicant(applicant_id)
    and verified_at is null
    and verified_by is null
    and deleted_at is null
    and storage_path like auth.uid()::text || '/%'
  );
create policy "coordinator updates"
  on documents for update to authenticated
  using (is_coordinator()) with check (is_coordinator());

-- ---------- storage bucket (private) ----------
insert into storage.buckets (id, name, public)
values ('applicant-docs', 'applicant-docs', false)
on conflict (id) do nothing;

create policy "applicant uploads to own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'applicant-docs'
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "applicant reads own folder, coordinator reads all"
  on storage.objects for select to authenticated
  using (bucket_id = 'applicant-docs'
         and ((storage.foldername(name))[1] = auth.uid()::text or is_coordinator()));
create policy "coordinator deletes"
  on storage.objects for delete to authenticated
  using (bucket_id = 'applicant-docs' and is_coordinator());

-- ---------- app settings (retention flags etc.) ----------
create table app_settings (
  key   text primary key,
  value jsonb not null
);

insert into app_settings (key, value) values
  ('discard_licences', 'true'),
  ('licence_retention_days', '30'),
  ('scrub_sensitive_on_engage', 'true');

alter table app_settings enable row level security;
create policy "staff reads" on app_settings for select to authenticated using (is_staff());
create policy "coordinator writes" on app_settings for update to authenticated
  using (is_coordinator()) with check (is_coordinator());

-- When someone is entered in Engage, optionally delete their DOB / licence number.
create function scrub_sensitive() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.in_engage_at is not null and old.in_engage_at is null
     and coalesce((select (value #>> '{}')::boolean
                   from app_settings where key = 'scrub_sensitive_on_engage'), true) then
    delete from applicant_sensitive where applicant_id = new.applicant_id;
  end if;
  return new;
end $$;

create trigger onboarding_scrub
  after update on onboarding
  for each row execute function scrub_sensitive();

-- ---------- coordinator task view ----------
-- security_invoker makes the view respect the caller's RLS.
create view coordinator_tasks with (security_invoker = true) as
select
  a.id as applicant_id,
  a.first_name || ' ' || a.last_name as name,
  a.membership_type,
  o.stage,
  case when o.fee_received_at is null
         or o.abstract_received_at is null
         or o.attestation_received_at is null
       then 'applicant' else 'coordinator' end as waiting_on,
  array_remove(array[
    case when o.fee_received_at          is null then 'membership fee' end,
    case when o.abstract_received_at     is null then 'abstract' end,
    case when o.attestation_received_at  is null then 'attestation' end,
    case when o.licence_verified_at      is null then 'licence check' end,
    case when o.orientation_done_at      is null then 'orientation' end,
    case when o.fob_mailed_at            is null then 'fob to mail' end,
    case when o.insurer_notified_at      is null then 'insurer notice' end,
    case when o.in_engage_at             is null then 'enter in Engage' end
  ], null) as outstanding,
  a.created_at as applied_at
from applicants a
join onboarding o on o.applicant_id = a.id
where o.stage <> 'in_engage';

-- ---------- function and view privileges ----------
-- Supabase grants new functions to anon by default; only signed-in users need the helpers.
revoke execute on function
  user_role(), is_coordinator(), is_staff(), owns_applicant(uuid),
  handle_new_user(), create_onboarding(), scrub_sensitive(), stamp_acknowledgement()
  from public, anon, authenticated;
grant execute on function
  user_role(), is_coordinator(), is_staff(), owns_applicant(uuid)
  to authenticated;

revoke all on coordinator_tasks from anon;
