-- Stage 50: the map saved as "Unknown (409325881472)" is Villa.
-- Renames it to Villa everywhere it is stored (games, rounds, scrims, strats, site names, replay maps...).
-- Where Villa already has settings, the two are merged (Villa's own entries win if both have the same one).
-- Safe to run more than once.
do $$
declare
  old text := 'Unknown (409325881472)';
  r record;
  n bigint;
begin
  -- plain text columns
  for r in select c.table_name, c.column_name from information_schema.columns c
           join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
           where c.table_schema='public' and c.is_generated='NEVER' and c.data_type in ('text','character varying') loop
    execute format('update public.%I set %I = ''Villa'' where btrim(%I) = %L', r.table_name, r.column_name, r.column_name, old);
    get diagnostics n = row_count;
    if n > 0 then raise notice '%.%: % rows', r.table_name, r.column_name, n; end if;
  end loop;

  -- text lists (for example a scrim's maps)
  for r in select c.table_name, c.column_name from information_schema.columns c
           join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
           where c.table_schema='public' and c.is_generated='NEVER' and c.data_type='ARRAY' and c.udt_name='_text' loop
    execute format('update public.%I set %I = (select coalesce(array_agg(distinct_v order by first_i), ''{}'') from (select v as distinct_v, min(i) as first_i from unnest(array_replace(%I, %L, ''Villa'')) with ordinality u(v,i) group by v) s) where %L = any(%I)',
                   r.table_name, r.column_name, r.column_name, old, old, r.column_name);
    get diagnostics n = row_count;
    if n > 0 then raise notice '%.%: % rows', r.table_name, r.column_name, n; end if;
  end loop;

  -- json settings: the map as a key (site names, replay maps, map photos...) is merged into Villa,
  -- then the map as a value anywhere inside is renamed
  for r in select c.table_name, c.column_name from information_schema.columns c
           join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
           where c.table_schema='public' and c.is_generated='NEVER' and c.data_type='jsonb' loop
    execute format($q$
      update public.%1$I set %2$I = (
        case
          when jsonb_typeof(%2$I->%3$L)='array' and jsonb_typeof(%2$I->'Villa')='array'
            then (%2$I - %3$L) || jsonb_build_object('Villa', (%2$I->%3$L) || (%2$I->'Villa'))
          when jsonb_typeof(%2$I->%3$L)='object' and jsonb_typeof(%2$I->'Villa')='object'
            then (%2$I - %3$L) || jsonb_build_object('Villa', (%2$I->%3$L) || (%2$I->'Villa'))
          when %2$I ? 'Villa' then %2$I - %3$L
          else (%2$I - %3$L) || jsonb_build_object('Villa', %2$I->%3$L)
        end)
      where jsonb_typeof(%2$I)='object' and %2$I ? %3$L$q$, r.table_name, r.column_name, old);
    get diagnostics n = row_count;
    if n > 0 then raise notice '%.% keys: % rows', r.table_name, r.column_name, n; end if;
    execute format('update public.%1$I set %2$I = replace(%2$I::text, %3$L, ''"Villa"'')::jsonb where %2$I::text like %4$L',
                   r.table_name, r.column_name, '"' || old || '"', '%' || old || '%');
    get diagnostics n = row_count;
    if n > 0 then raise notice '%.% values: % rows', r.table_name, r.column_name, n; end if;
  end loop;
end $$;
