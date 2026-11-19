// Supabase Edge Function: auto-fill
// Runs on its own every 5 minutes (see stage42.sql), so nobody has to open the site for these to happen:
//  1. games with an official or siege.gg match ID get their empty op bans, map order, scoreboard, map veto and match details
//     from those pages;
//  2. games whose saved rounds are complete get the score and result those rounds add up to.
// It only fills empty things and never overwrites what someone typed. It uses the service role key that Supabase
// gives every Edge Function on its own (SUPABASE_SERVICE_ROLE_KEY); no key is written here.
import { createClient } from 'npm:@supabase/supabase-js@2';

const URL = Deno.env.get('SUPABASE_URL')!;
const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db = createClient(URL, KEY, { auth: { persistSession: false } });
// each run reads 2 series at a time and keeps going for about 2 minutes (Supabase stops a function at 150 seconds)
const AT_ONCE = 2, TIME_BUDGET = 115000;
// Supabase hands back at most 1,000 rows at a time, so long lists are read page by page
async function every(make: () => any, max = 50000) {
  const out: any[] = [];
  for (let from = 0; from < max; from += 1000) {
    const r = await make().range(from, from + 999);
    if (r.error) return { data: null, error: r.error };
    out.push(...r.data);
    if (r.data.length < 1000) break;
  }
  return { data: out, error: null };
}

const sq = (s: unknown) => String(s ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
const core = (s: unknown) => String(s ?? '').toLowerCase().replace(/\b(e-?sports?|gaming|team|club|clan|gg)\b/g, '').replace(/[^a-z0-9]/g, '');
const mapKey = (s: unknown) => String(s ?? '').toLowerCase().replace(/dostoyevsky|labs/g, '').replace(/[^a-z]/g, '');
const idSlug = (v: unknown) => String(v ?? '').toUpperCase().replace(/[^A-Z0-9]+/g, '');
const matchId = (r: any) => [String(r.match_date).replace(/-/g, ''), ...[idSlug(r.team), idSlug(r.opponent)].sort(), idSlug(r.map), idSlug(r.phase)].filter(Boolean).join('-');
const parseScore = (t: unknown) => { const m = /^\s*(\d+)\s*[-–:]\s*(\d+)\s*$/.exec(String(t ?? '')); return m ? { a: +m[1], b: +m[2] } : null; };
const gameDone = (a: number, b: number) => (a >= 7 || b >= 7) && (Math.abs(a - b) >= 2 || a >= 8 || b >= 8);
const res = (v: unknown) => { const k = String(v ?? '').toLowerCase(); return k === 'w' || k === 'win' ? 'W' : k === 'l' || k === 'loss' ? 'L' : ''; };
const day = (s: string) => Date.parse(String(s).slice(0, 10) + 'T00:00:00Z') || 0;

// team names: the same when equal, one inside the other, or two names of one scouted team
function namer(teams: any[]) {
  const key = new Map<string, string>();
  teams.forEach((t) => [t.name, t.short_name, ...(t.aliases || [])].filter(Boolean).forEach((n: string) => { key.set(sq(n), t.id); key.set(core(n), t.id); }));
  return (a: unknown, b: unknown) => {
    const x = sq(a), y = sq(b), cx = core(a), cy = core(b);
    if (!x || !y) return false;
    if (x === y || (cx && cx === cy)) return true;
    if (cx.length >= 3 && cy.length >= 3 && (cx.includes(cy) || cy.includes(cx))) return true;
    const kx = key.get(x) || key.get(cx), ky = key.get(y) || key.get(cy);
    return !!kx && kx === ky;
  };
}

// starting side, overtime side, score after 6 rounds, rounds won per side and the score, for empty boxes only
function facts(x: any, t1: any, t2: any) {
  const up: Record<string, unknown> = {}, S = (v: string) => v === 'attack' ? 'Attack' : v === 'defense' ? 'Defense' : '';
  if (!String(x.start_side || '').trim() && S(t1.start)) up.start_side = S(t1.start);
  if (!String(x.ot_start || '').trim() && S(t1.ot_start)) up.ot_start = S(t1.ot_start);
  if (!String(x.split_score || '').trim() && t1.split != null && t2.split != null && t1.split + t2.split === 6) up.split_score = t1.split + '-' + t2.split;
  if (!parseScore(x.round_score) && t1.score != null && t2.score != null) { up.round_score = t1.score + '-' + t2.score; up.total_rounds = t1.score + t2.score; up.result = t1.score > t2.score ? 'W' : t1.score < t2.score ? 'L' : 'D'; }
  const sc = parseScore((up.round_score as string) || x.round_score);
  if (['t1_atk', 't1_def', 't2_atk', 't2_def'].every((k) => x[k] == null) && [t1.won_atk, t1.won_def, t2.won_atk, t2.won_def].every((v) => v != null)) {
    const v = { t1_atk: t1.won_atk, t1_def: t1.won_def, t1_ot_atk: t1.won_ot_atk || 0, t1_ot_def: t1.won_ot_def || 0, t2_atk: t2.won_atk, t2_def: t2.won_def, t2_ot_atk: t2.won_ot_atk || 0, t2_ot_def: t2.won_ot_def || 0 };
    if (!sc || (v.t1_atk + v.t1_def + v.t1_ot_atk + v.t1_ot_def === sc.a && v.t2_atk + v.t2_def + v.t2_ot_atk + v.t2_ot_def === sc.b)) Object.assign(up, v);
  }
  return up;
}
// pages are read by the match-bans function: each read there gets its own processing time, which this job would run out of.
// Supabase also limits how fast one function calls another, so this job reads 2 at a time and stops for the run when told to slow down.
let slowDown = false;
async function readSeries(r6: string, gg: string) {
  const r = await fetch(URL + '/functions/v1/match-bans', { method: 'POST', headers: { Authorization: 'Bearer ' + KEY, apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ r6, gg }) });
  const j = await r.json().catch(() => ({}));
  const msg = String(j.error || j.msg || j.message || '');
  if (r.status === 429 || /rate limit/i.test(msg)) { slowDown = true; throw new Error('Supabase asked to slow down; tried again next run'); }
  if (!r.ok || j.error) throw new Error(msg || 'match-bans answered ' + r.status);
  return j;
}

async function fillSources(log: string[]) {
  const since = new Date(Date.now() - 864e5).toISOString(), week = new Date(Date.now() - 7 * 864e5).toISOString(), recent = new Date(Date.now() - 45 * 864e5).toISOString().slice(0, 10);
  // games with an id not checked lately: every day for the last 45 days of games, every week for older ones
  const q = await db.from('scout_matches').select('*').or('r6esports_id.neq.,siegegg_id.neq.')
    .or(`src_checked_at.is.null,and(src_checked_at.lt.${since},match_date.gte.${recent}),src_checked_at.lt.${week}`)
    .order('match_date', { ascending: false }).limit(1000);
  if (q.error) { log.push('Could not list games: ' + q.error.message); return; }
  const groups = new Map<string, any[]>();
  for (const r of q.data) { const k = r.owner_team_id + '|' + (r.r6esports_id ? 'o' + r.r6esports_id : 'g' + r.siegegg_id); (groups.get(k) || groups.set(k, []).get(k)!).push(r); }
  const teamsByOwner = new Map<string, any[]>();
  let done = 0;
  const start = Date.now(), list = [...groups];
  const one = async ([k, part]: [string, any[]]) => {
    const owner = part[0].owner_team_id;
    // every map of the series, also the ones checked lately
    const all = await db.from('scout_matches').select('*').eq('owner_team_id', owner).eq(part[0].r6esports_id ? 'r6esports_id' : 'siegegg_id', part[0].r6esports_id || part[0].siegegg_id);
    const rows = all.error ? part : all.data;
    if (!teamsByOwner.has(owner)) { const t = await db.from('scout_teams').select('id,name,short_name,aliases').eq('owner_team_id', owner); teamsByOwner.set(owner, t.data || []); }
    const same = namer(teamsByOwner.get(owner)!);
    let d: any;
    try { d = await readSeries(rows[0].r6esports_id || '', rows[0].siegegg_id || ''); }
    catch (e) { const m = e instanceof Error ? e.message : String(e); log.push(k + ': ' + m); if (/does not exist|has no match|did not have this match/i.test(m)) await db.from('scout_matches').update({ src_checked_at: new Date().toISOString() }).in('id', rows.map((x: any) => x.id)); return; }
    const games: any[] = d.games || [];
    const sbHave = await db.from('scout_scoreboard').select('scout_match_id').in('scout_match_id', rows.map((x: any) => x.id));
    const hasSb = new Set((sbHave.data || []).map((x: any) => x.scout_match_id));
    for (const x of rows) {
      const gi = games.findIndex((g) => mapKey(g.map) === mapKey(x.map)), g = games[gi], up: Record<string, unknown> = { src_checked_at: new Date().toISOString() };
      if (g && (g.teams || []).length >= 2) {
        const [a, b] = g.teams, s1 = same(a.name, x.team) || same(b.name, x.opponent), s2 = same(b.name, x.team) || same(a.name, x.opponent);
        if (s1 !== s2) {
          const t1 = s1 ? a : b, t2 = s1 ? b : a, set = (c: string, l: string[]) => { if ((l || []).length && !String(x[c] || '').trim()) up[c] = l.join(', '); };
          set('our_atk_ban', t1.atk); set('our_def_ban', t1.def); set('opp_atk_ban', t2.atk); set('opp_def_ban', t2.def);
          if (!hasSb.has(x.id) && !x.replay_match_id && !x.board_none) {
            const ins: any[] = [];
            [[t1, 1], [t2, 2]].forEach(([tm, side]: any) => (tm.players || []).slice(0, 6).forEach((p: any, i: number) => ins.push({ owner_team_id: owner, scout_match_id: x.id, side, slot: i + 1, player: p.name || '', kills: p.kills ?? null, deaths: p.deaths ?? null, headshots: p.headshots ?? null, opening_kills: p.opening_kills ?? null, opening_deaths: p.opening_deaths ?? null, kost: p.kost ?? null, plants: p.plants ?? null, clutches: p.clutches ?? null, source: 'official' })));
            if (ins.length) { const s = await db.from('scout_scoreboard').insert(ins); if (!s.error) log.push(x.map + ': scoreboard'); }
          }
        }
      }
      if (gi >= 0 && x.map_number !== gi + 1) up.map_number = gi + 1;
      // everything else the page knows about this map, only where it is empty
      if (g && (g.teams || []).length >= 2) {
        const [a, b] = g.teams, s1 = same(a.name, x.team) || same(b.name, x.opponent), s2 = same(b.name, x.team) || same(a.name, x.opponent);
        if (s1 !== s2) Object.assign(up, facts(x, s1 ? a : b, s1 ? b : a));
      }
      const info = d.info || {};
      if (!String(x.league || '').trim() && info.league) up.league = info.league;
      if (!String(x.vod_link || '').trim() && /^https?:\/\//.test(info.vod || '')) up.vod_link = info.vod;
      if (!String(x.replay_link || '').trim() && /^https:\/\//.test(info.replay || '')) up.replay_link = info.replay;
      const pk = (d.veto || []).find((s: any) => s.type !== 'ban' && mapKey(s.map) === mapKey(x.map));
      if (pk && !String(x.picked_by || '').trim()) { const who = pk.type === 'decider' ? 'Decider' : same(pk.team, x.team) ? x.team : same(pk.team, x.opponent) ? x.opponent : ''; if (who) up.picked_by = who; }
      // the phase is part of how a game's rounds are found, so it is only filled on a game with no rounds
      if (!String(x.phase || '').trim() && info.phase && !x.replay_match_id) {
        const rr = await db.from('scout_rounds').select('id').eq('owner_team_id', owner).eq('match_id', matchId(x)).limit(1);
        if (!rr.error && !rr.data.length) await db.from('scout_matches').update({ phase: info.phase }).eq('id', x.id);
      }
      await db.from('scout_matches').update(up).eq('id', x.id);
    }
    // the map veto: a new one, or the order added to one already saved
    const veto: any[] = d.veto || [], r = rows[0];
    if (veto.length) {
      const steps = veto.map((s) => ({ type: s.type, team: s.team || null, map: s.map }));
      const vs = await db.from('scout_vetoes').select('*').eq('owner_team_id', owner)
        .gte('veto_date', new Date(day(r.match_date) - 864e5).toISOString().slice(0, 10)).lte('veto_date', new Date(day(r.match_date) + 864e5).toISOString().slice(0, 10));
      const old = (vs.data || []).find((v: any) => (same(v.team, r.team) && same(v.opponent, r.opponent)) || (same(v.team, r.opponent) && same(v.opponent, r.team)));
      if (old) { if (!(old.steps || []).length) await db.from('scout_vetoes').update({ steps, ...(old.format ? {} : { format: d.format || '' }) }).eq('id', old.id); }
      else if (steps.some((s) => s.team && (same(s.team, r.team) || same(s.team, r.opponent)))) {
        const of = (w: string, t: unknown) => steps.filter((s) => s.type === w && (t === null || same(s.team, t))).map((s) => s.map);
        const b1 = of('ban', r.team), b2 = of('ban', r.opponent), p1 = of('pick', r.team), p2 = of('pick', r.opponent), dc = of('decider', null)[0] || '';
        const ins = await db.from('scout_vetoes').insert({ owner_team_id: owner, veto_date: r.match_date, team: r.team, opponent: r.opponent, league: r.league || '', phase: r.phase || '', t1_ban_1: b1[0] || '', t1_ban_2: b1[1] || '', t1_ban_3: b1[2] || '', t1_ban_4: b1[3] || '', t2_ban_1: b2[0] || '', t2_ban_2: b2[1] || '', t2_ban_3: b2[2] || '', t2_ban_4: b2[3] || '', t1_pick: p1[0] || '', t2_pick: p2[0] || '', t1_pick_2: p1[1] || '', t2_pick_2: p2[1] || '', decider: dc, format: d.format || '', source: d.source || 'Official', steps });
        if (!ins.error) log.push(r.team + ' vs ' + r.opponent + ': map veto');
      }
    }
  };
  slowDown = false;
  const worker = async () => { while (list.length && !slowDown && Date.now() - start < TIME_BUDGET) { const g = list.shift()!; done++; try { await one(g); } catch (e) { log.push(g[0] + ': ' + (e instanceof Error ? e.message : String(e))); } } };
  await Promise.all(Array.from({ length: AT_ONCE }, worker));
  log.push('Series read: ' + done + (list.length ? ', ' + list.length + ' left for the next run' : '') + (slowDown ? ' (Supabase asked to slow down)' : ''));
}

// a game whose saved rounds go from 1 to the last with a winner each, and make a finished game, gets that score
async function fixScores(log: string[]) {
  const since = new Date(Date.now() - 2 * 864e5).toISOString();
  const [nr, ng] = await Promise.all([
    db.from('scout_rounds').select('owner_team_id,match_id').gte('created_at', since).limit(2000),
    db.from('scout_matches').select('owner_team_id,id').gte('created_at', since).limit(2000),
  ]);
  const owners = new Set<string>([...(nr.data || []), ...(ng.data || [])].map((x: any) => x.owner_team_id));
  let n = 0;
  for (const owner of owners) {
    const [gm, rr, tt] = await Promise.all([
      every(() => db.from('scout_matches').select('id,team,opponent,map,match_date,phase,round_score,result').eq('owner_team_id', owner).order('id')),
      every(() => db.from('scout_rounds').select('match_id,round_number,team,result').eq('owner_team_id', owner).order('id')),
      db.from('scout_teams').select('id,name,short_name,aliases').eq('owner_team_id', owner),
    ]);
    if (gm.error || rr.error) continue;
    const same = namer(tt.data || []), by = new Map<string, any[]>();
    rr.data.forEach((x: any) => { const k = String(x.match_id).toLowerCase(); (by.get(k) || by.set(k, []).get(k)!).push(x); });
    for (const g of gm.data) {
      const l = by.get(matchId(g).toLowerCase()); if (!l?.length) continue;
      const seen = new Map<number, string>();
      for (const x of l) { if (!x.round_number || seen.has(x.round_number)) continue; let v = res(x.result); if (!same(x.team, g.team) && same(x.team, g.opponent)) v = v === 'W' ? 'L' : v === 'L' ? 'W' : v; seen.set(x.round_number, v); }
      const top = Math.max(0, ...seen.keys()); if (!top || seen.size !== top || [...seen.values()].some((v) => !v)) continue;
      const w = [...seen.values()].filter((v) => v === 'W').length, lo = top - w; if (!gameDone(w, lo)) continue;
      const sc = w + '-' + lo, rs = w > lo ? 'W' : 'L', p = parseScore(g.round_score);
      if (p && p.a === w && p.b === lo && res(g.result) === rs) continue;
      const u = await db.from('scout_matches').update({ round_score: sc, result: rs, total_rounds: w + lo }).eq('id', g.id);
      if (!u.error) n++;
    }
  }
  log.push('Scores put right from rounds: ' + n);
}

Deno.serve(async () => {
  const log: string[] = [], began = Date.now();
  try { await fillSources(log); } catch (e) { log.push('Sources: ' + (e instanceof Error ? e.message : String(e))); }
  if (Date.now() - began > 125000) { log.push('Scores: checked on the next run'); return new Response(JSON.stringify({ ok: true, log }), { headers: { 'Content-Type': 'application/json' } }); }
  try { await fixScores(log); } catch (e) { log.push('Scores: ' + (e instanceof Error ? e.message : String(e))); }
  return new Response(JSON.stringify({ ok: true, log }), { headers: { 'Content-Type': 'application/json' } });
});
