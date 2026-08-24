-- Tip status tracking (replaces the retired Passenger Rating workflow).
-- Additive only: one new nullable boolean column on the existing
-- `passengers` table. Does NOT touch, rename, or clear `customer_rating` —
-- that column and its historical GREAT/NORMAL/DIFFICULT values are left
-- exactly as they are. Safe to run more than once.

alter table public.passengers add column if not exists tip_received boolean;

-- Expected values going forward:
--   true  = passenger left a tip
--   false = passenger did not leave a tip
--   null  = tip status has not been recorded (default for all existing rows)
