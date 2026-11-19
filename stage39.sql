-- STAGE 39: map order and veto order
-- map_number: the order a map was played in its series (1, 2, 3...), read from the official page or siege.gg.
-- steps: the map veto in the order it happened, like [{"type":"ban","team":"Cloud9","map":"Bank"}, ...].
alter table public.scout_matches add column if not exists map_number integer;
alter table public.scout_vetoes add column if not exists steps jsonb not null default '[]'::jsonb;
notify pgrst, 'reload schema';
