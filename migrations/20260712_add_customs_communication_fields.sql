-- Customs communication tracking (Welcome Back / Gratuity SMS state).
-- Additive only: five nullable/defaulted columns on the existing
-- `passengers` table. Each check-in is already its own row, so these
-- flags are naturally scoped to a single trip — no new table needed.
-- Safe to run more than once; never overwrites existing passenger data.

alter table public.passengers add column if not exists customs_welcome_sent boolean not null default false;
alter table public.passengers add column if not exists customs_welcome_sent_at timestamptz;
alter table public.passengers add column if not exists customs_gratuity_sent boolean not null default false;
alter table public.passengers add column if not exists customs_gratuity_sent_at timestamptz;
alter table public.passengers add column if not exists customs_gratuity_dismissed boolean not null default false;
