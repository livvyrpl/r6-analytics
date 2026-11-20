-- Stage 48: site names for each map (a default name per bomb site, plus the other names that mean the same site)
-- Shape: { "Bank": [ { "name": "2F Executive Lounge / CEO Office", "also": ["...", "..."] }, ... ], ... }
alter table public.site_settings add column if not exists site_names jsonb not null default '{}';
