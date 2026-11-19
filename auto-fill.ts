// Supabase Edge Function: auto-fill
// The database calls this on its own every 5 minutes (see stage43.sql), so nobody has to open the site:
//  - { owner, r6, gg }: one series. Its games get their empty op bans, map order, scoreboard, map veto and match details
//    from its official and siege.gg pages.
//  - { owner, find: { date, team, opponent } }: a game with no ID. Its official match is looked up on the official calendar
//    by date and teams, and when there is exactly one, the series gets its ID and is filled.
//  - { scores: true }: games whose saved rounds are complete get the score and result those rounds add up to.
// One series per request keeps each run small (Supabase limits a run's processing time) and means no function calls another
// (Supabase limits that too). It only fills empty things and never overwrites what someone typed. It uses the service role key
// Supabase gives every Edge Function on its own (SUPABASE_SERVICE_ROLE_KEY); no key is written here.
import { createClient } from 'npm:@supabase/supabase-js@2';

const URL = Deno.env.get('SUPABASE_URL')!;
const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db = createClient(URL, KEY, { auth: { persistSession: false } });
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
// ---- the page reader, the same as in match-bans.ts. When match-bans.ts changes, copy its reader part here too.
const UA = { 'User-Agent': 'Mozilla/5.0 (compatible; LivAnalytics/1.0)' };

type Step = { type: 'ban' | 'pick' | 'decider'; team: string | null; map: string };
type Side = { name: string; atk: string[]; def: string[]; players?: Record<string, unknown>[]; won_atk?: number | null; won_def?: number | null; won_ot_atk?: number | null; won_ot_def?: number | null; start?: string; ot_start?: string; split?: number | null; score?: number | null };
type Game = { map: string; teams: Side[] };
type Info = { league: string; phase: string; vod: string; replay: string };
type Series = { teams: string[]; format: string; veto: Step[]; games: Game[]; info: Info };
const key = (s: string) => s.toLowerCase().replace(/[^a-z]/g, '');

async function official(id: string): Promise<Series> {
  const r = await fetch('https://www.ubisoft.com/en-us/esports/rainbow-six/siege/match/' + id, { headers: UA });
  if (r.status === 404) throw new Error('The official page for match ' + id + ' does not exist.');
  if (!r.ok) throw new Error('The official site answered ' + r.status + '.');
  const m = (await r.text()).match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('The official page did not have match data.');
  const data = JSON.parse(m[1])?.props?.pageProps?.pageData || {};
  const match = data.match || {};
  const names = new Map<number, string>();
  const look = (o: unknown) => { if (o && typeof o === 'object') { const x = o as Record<string, unknown>; if (typeof x.id === 'number' && typeof x.name === 'string' && ('logoUrl' in x || 'guid' in x)) names.set(x.id, x.name); Object.values(x).forEach(look); } };
  look(data);
  const byRound = (l: any[]) => [...l].sort((a, b) => (a.roundIndex ?? 0) - (b.roundIndex ?? 0));
  const games: Game[] = [...(match.games || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0)).map((g: any) => ({
    map: g?.map?.name || '',
    teams: (g.teams || []).map((t: any) => {
      const bans = byRound(t.operatorBans || []);
      const rs = [...(g.rounds || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0)), reg = rs.filter((x: any) => !x.isOvertime), ot = rs.filter((x: any) => x.isOvertime);
      const won = (l: any[], side: string) => l.filter((x: any) => x.winnerId === t.id && x[side] === t.id).length;
      const sideOf = (x: any) => !x ? '' : x.attackerId === t.id ? 'attack' : x.defenderId === t.id ? 'defense' : '';
      const sides = rs.length ? { won_atk: won(reg, 'attackerId'), won_def: won(reg, 'defenderId'), won_ot_atk: won(ot, 'attackerId'), won_ot_def: won(ot, 'defenderId'), start: sideOf(rs[0]), ot_start: sideOf(ot[0]), split: rs.length >= 6 ? rs.slice(0, 6).filter((x: any) => x.winnerId === t.id).length : null } : {};
      const c = (s: any, k: string) => (s?.[k] && typeof s[k] === 'object' ? s[k].count : null) ?? null;
      const players = [...(t.players || [])].sort((x: any, y: any) => (x.positionIndex ?? 0) - (y.positionIndex ?? 0)).map((p: any) => ({
        name: p.name || '', kills: c(p.stats, 'kills'), deaths: c(p.stats, 'deaths'), headshots: c(p.stats, 'headshots'),
        opening_kills: c(p.stats, 'openingKills'), opening_deaths: c(p.stats, 'openingDeaths'),
        kost: typeof p.stats?.kost === 'number' ? Math.round(p.stats.kost * 100) : null, plants: c(p.stats, 'diffuserPlanted'), clutches: c(p.stats, 'clutch'),
      })).filter((p: any) => p.name);
      return { name: names.get(t.id) || '', atk: bans.filter((b) => b.isAttacker).map((b) => b.name).filter(Boolean), def: bans.filter((b) => b.isAttacker === false).map((b) => b.name).filter(Boolean), players, score: t.score ?? null, ...sides };
    }),
  }));
  const kinds: Record<number, Step['type']> = { 1: 'pick', 2: 'ban', 3: 'decider' };
  const veto: Step[] = [...(match.mapSelections || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0))
    .filter((s: any) => kinds[s.selectionType] && s.mapName)
    .map((s: any) => ({ type: kinds[s.selectionType], team: s.choosingTeam || null, map: s.mapName }));
  const n = match.matchFormatNumberOfGames;
  // league: the championship and the event, without saying a word twice (BLAST R6 Major + Osaka Major = BLAST R6 Major Osaka)
  const ch = String(data.championship?.name || ''), co = String(data.competition?.name || ''), seen = new Set(ch.toLowerCase().split(/\s+/));
  const league = [ch, co.split(/\s+/).filter((w) => !seen.has(w.toLowerCase())).join(' ')].filter(Boolean).join(' ').trim();
  const info = { league, phase: String(data.phase?.name || ''), vod: String(match.youtubeLink || ''), replay: String(match.replayLink || '') };
  return { teams: (match.teams || []).map((t: any) => names.get(t.id) || ''), format: n ? 'Bo' + n : '', veto, games, info };
}

async function siegegg(id: string): Promise<Series> {
  const r = await fetch('https://siege.gg/matches/' + id, { headers: UA });
  if (r.status === 404) throw new Error('siege.gg has no match ' + id + '.');
  if (!r.ok) throw new Error('siege.gg answered ' + r.status + '.');
  const m = (await r.text()).match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('The siege.gg page did not have match data.');
  const a: any[] = JSON.parse(m[1]);
  const wrap = new Set(['Reactive', 'ShallowReactive', 'Ref', 'ShallowRef', 'EmptyRef']);
  const res = (i: any, d = 0): any => {
    if (typeof i !== 'number' || d > 12) return i;
    const v = a[i];
    if (Array.isArray(v)) { if (typeof v[0] === 'string' && wrap.has(v[0])) return res(v[1], d + 1); return v.map((x) => res(x, d + 1)); }
    if (v && typeof v === 'object') { const o: any = {}; for (const k in v) o[k] = res(v[k], d + 1); return o; }
    return v;
  };
  const at = a.findIndex((x) => x && typeof x === 'object' && !Array.isArray(x) && 'rosters' in x && 'games' in x && String(res(x.id)) === id);
  if (at < 0) throw new Error('The siege.gg page did not have this match.');
  const match = res(at);
  const names = new Map<number, string>();
  (match.rosters || []).forEach((t: any) => names.set(t.id, t.name));
  const kinds: Record<string, Step['type']> = { BAN: 'ban', PICK: 'pick', DECIDER: 'decider' };
  const vi = a.findIndex((x) => x && typeof x === 'object' && !Array.isArray(x) && 'vetos' in x);
  const veto: Step[] = (vi >= 0 ? res(a[vi].vetos) || [] : [])
    .filter((s: any) => kinds[s.type] && s.map?.name)
    .map((s: any) => ({ type: kinds[s.type], team: s.roster_id != null ? names.get(s.roster_id) || null : null, map: s.map.name }));
  const games: Game[] = (match.games || []).map((g: any) => {
    const bans = [...(g.operator_bans || [])].sort((x: any, y: any) => (x.ban_round ?? 0) - (y.ban_round ?? 0));
    return {
      map: g.map?.name || '',
      teams: [...names.entries()].map(([rid, name]) => {
        const mine = bans.filter((b: any) => b.stats_roster_id === rid && b.operator?.name);
        const rw = g.round_wins_by_roster?.[rid] || g.round_wins_by_roster?.[String(rid)];
        return { name, atk: mine.filter((b: any) => /att/i.test(b.operator.side)).map((b: any) => b.operator.name), def: mine.filter((b: any) => /def/i.test(b.operator.side)).map((b: any) => b.operator.name), won_atk: rw?.atk ?? null, won_def: rw?.def ?? null, score: g.win_roster_id === rid ? g.win_score ?? null : g.loss_roster_id === rid ? g.loss_score ?? null : null };
      }),
    };
  });
  const picks = veto.filter((s) => s.type !== 'ban').length;
  return { teams: [...names.values()], format: picks ? 'Bo' + picks : '', veto, games, info: { league: String(match.competition_full_name || match.competition_name || ''), phase: '', vod: '', replay: '' } };
}

// FINDING THE OFFICIAL MATCH of a game with no ID: the official calendar lists every match of a month with its date and teams.
// The same two teams on the same day (or one day either side, when there is nothing on the day) and only one such match.
const nameCore = (s: string) => String(s || '').toLowerCase().replace(/\b(e-?sports?|gaming|team|club|clan|gg)\b/g, '').replace(/[^a-z0-9]/g, '');
const months = new Map<string, any[]>();
async function calendar(ym: string) {
  if (months.has(ym)) return months.get(ym)!;
  const r = await fetch('https://www.ubisoft.com/en-us/esports/rainbow-six/siege/calendar/' + ym, { headers: UA });
  if (!r.ok) throw new Error('The official calendar answered ' + r.status + '.');
  const m = (await r.text()).match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  const list = m ? (JSON.parse(m[1])?.props?.pageProps?.pageData?.matches || []).map((x: any) => ({ id: String(x.id), date: new Date((x.timestamp || 0) * 1000).toISOString().slice(0, 10), t1: x.team1?.name || '', t2: x.team2?.name || '' })) : [];
  months.set(ym, list);
  return list;
}
async function findOfficial(date: string, a: string[], b: string[]) {
  const d0 = Date.parse(String(date).slice(0, 10) + 'T00:00:00Z');
  if (!d0) throw new Error('No date to look for.');
  const yms = [...new Set([-864e5, 0, 864e5].map((x) => new Date(d0 + x).toISOString().slice(0, 7)))];
  const all = (await Promise.all(yms.map(calendar))).flat();
  const A = a.map(nameCore).filter(Boolean), B = b.map(nameCore).filter(Boolean);
  const is = (n: string, l: string[]) => { const c = nameCore(n); return !!c && l.some((x) => x === c || (x.length >= 3 && c.length >= 3 && (x.includes(c) || c.includes(x)))); };
  const near = all.filter((m) => ((is(m.t1, A) && is(m.t2, B)) || (is(m.t1, B) && is(m.t2, A))) && Math.abs(Date.parse(m.date + 'T00:00:00Z') - d0) <= 864e5);
  const exact = near.filter((m) => m.date === String(date).slice(0, 10));
  const pick = exact.length === 1 ? exact[0] : !exact.length && near.length === 1 ? near[0] : null;
  return { id: pick?.id || null, match: pick, choices: near.length };
}

// both pages: the official one first, siege.gg for what it lacks
async function readBoth(r6: string, gg: string) {
  const notes: string[] = [];
  let a: Series | null = null, b: Series | null = null;
  if (/^\d+$/.test(r6)) { try { a = await official(r6); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
  const lacks = (s: Series | null) => !s || !s.veto.length || !s.games.length || s.games.some((g) => g.teams.every((t) => !t.atk.length && !t.def.length));
  if (/^\d+$/.test(gg) && lacks(a)) { try { b = await siegegg(gg); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
  if (!a && !b) throw new Error(notes.join(' ') || 'Nothing could be read.');
  const main = (a || b)!, alt = a ? b : null;
  // the official page first; siege.gg fills a missing veto, or a map without bans
  const games = main.games.length ? main.games.map((g) => {
    if (g.teams.some((t) => t.atk.length || t.def.length) || !alt) return g;
    const o = alt.games.find((x) => key(x.map) === key(g.map));
    return o ? { ...g, teams: o.teams } : g;
  }) : alt?.games || [];
  return ({
    source: [a && 'Official', b && 'siege.gg'].filter(Boolean).join(' + '),
    teams: main.teams.length ? main.teams : alt?.teams || [],
    format: main.format || alt?.format || '',
    veto: main.veto.length ? main.veto : alt?.veto || [],
    games,
    info: { league: main.info.league || alt?.info.league || '', phase: main.info.phase || alt?.info.phase || '', vod: main.info.vod || alt?.info.vod || '', replay: main.info.replay || alt?.info.replay || '' },
    notes,
  });
}

// ---- end of the page reader

// a game with no ID: look for its official match by date and teams; when one is found, every map of that series gets the ID and is filled
async function findSeries(owner: string, date: string, team: string, opponent: string, log: string[]) {
  const t = await db.from('scout_teams').select('id,name,short_name,aliases').eq('owner_team_id', owner);
  const teams = t.data || [], same = namer(teams);
  const names = (n: string) => { const st = teams.find((x: any) => same(x.name, n)); return [n, ...(st ? [st.name, st.short_name, ...(st.aliases || [])] : [])].filter(Boolean); };
  const f = await findOfficial(date, names(team), names(opponent));
  const lo = new Date(day(date) - 864e5).toISOString().slice(0, 10), hi = new Date(day(date) + 864e5).toISOString().slice(0, 10);
  const q = await db.from('scout_matches').select('id,team,opponent,match_date,r6esports_id,siegegg_id').eq('owner_team_id', owner).gte('match_date', lo).lte('match_date', hi);
  const rows = (q.data || []).filter((x: any) => !x.r6esports_id && !x.siegegg_id && x.match_date === date && ((same(x.team, team) && same(x.opponent, opponent)) || (same(x.team, opponent) && same(x.opponent, team))));
  await db.from('scout_matches').update({ src_find_at: new Date().toISOString() }).in('id', rows.map((x: any) => x.id));
  if (!f.id) { log.push(team + ' vs ' + opponent + ' ' + date + ': ' + (f.choices ? f.choices + ' possible official matches, so none was picked' : 'not on the official calendar')); return; }
  if (rows.length) await db.from('scout_matches').update({ r6esports_id: f.id }).in('id', rows.map((x: any) => x.id));
  log.push(team + ' vs ' + opponent + ' ' + date + ': official match ' + f.id);
  await fillSeries(owner, f.id, '', log);
}

async function fillSeries(owner: string, r6: string, gg: string, log: string[]) {
  const all = await db.from('scout_matches').select('*').eq('owner_team_id', owner).eq(r6 ? 'r6esports_id' : 'siegegg_id', r6 || gg);
  if (all.error || !all.data.length) { log.push('No games for this series'); return; }
  const rows = all.data, k = r6 ? 'official ' + r6 : 'siege.gg ' + gg;
  const t = await db.from('scout_teams').select('id,name,short_name,aliases').eq('owner_team_id', owner);
  const same = namer(t.data || []);
  let d: any;
  try { d = await readBoth(r6 || rows[0].r6esports_id || '', gg || rows[0].siegegg_id || ''); }
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

Deno.serve(async (req) => {
  const log: string[] = [];
  const body = await req.json().catch(() => ({}));
  try {
    if (body.scores) await fixScores(log);
    else if (body.owner && body.find) await findSeries(String(body.owner), String(body.find.date || ''), String(body.find.team || ''), String(body.find.opponent || ''), log);
    else if (body.owner && (/^\d+$/.test(String(body.r6 || '')) || /^\d+$/.test(String(body.gg || '')))) await fillSeries(String(body.owner), String(body.r6 || ''), String(body.gg || ''), log);
    else log.push('Nothing to do: send { owner, r6, gg } for a series or { scores: true }.');
  } catch (e) { log.push(e instanceof Error ? e.message : String(e)); }
  return new Response(JSON.stringify({ ok: true, log }), { headers: { 'Content-Type': 'application/json' } });
});
