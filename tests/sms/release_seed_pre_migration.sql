-- LOCAL ONLY. Rows inserted BEFORE the Return/Pickup migrations, mirroring
-- the production mix of passengers in custody read on 2026-10-09 (ids 8xxx)
-- plus delivered/archived history that must stay byte-identical.
insert into public.passengers (id, name, phone, ticket, status, loc, not_returning_with_makers_air, delivery_at_customs, welcome_back_sent_at, customs_welcome_sent_at) values
  (8001, 'MK PLAIN',      '3055558001', '1009-1',   'PENDING', 'HANGAR 18', false, false, null, null),
  (8002, 'MK NODATE',     '3055558002', '1009-2',   'NO DATE', 'HANGAR 19', false, false, null, null),
  (8003, 'MK CUSTOMS',    '3055558003', '1009-3',   'PENDING', 'HANGAR 16', false, true,  null, null),
  (8004, 'AS PLAIN',      '3055558004', 'A-1009-1', 'PENDING', 'HANGAR 19', false, false, null, null),
  (8005, 'AS CUSTOMSFLAG','3055558005', 'A-1009-2', 'PENDING', 'HANGAR 19', false, true,  null, null),
  (8006, 'MK OTHERBOAT',  '3055558006', '1009-6',   'PENDING', 'HANGAR 7',  true,  false, null, null),
  (8007, 'MK WB SENT',    '3055558007', '1009-7',   'PENDING', 'HANGAR 19', false, false, now() - interval '1 hour', null),
  (8101, 'DEL ONE',       '3055558101', '0901-1',   'DELIVERED', 'HANGAR 19', true,  true,  now() - interval '9 days', null),
  (8102, 'DEL TWO',       '3055558102', 'A-0901-2', 'DELIVERED', 'HANGAR 18', false, true,  null, now() - interval '8 days'),
  (8103, 'ARCH ONE',      '3055558103', '0801-3',   'ARCHIVED',  'HANGAR 16', false, false, null, null);
create table public._release_hist_fp as
  select id, md5(to_jsonb(p)::text) as fp from public.passengers p where status in ('DELIVERED', 'ARCHIVED');
