// Great Lakes water temperature, for the map.
//
// NDBC publishes every station's latest observation in one file, which is the
// cheapest possible way to get this — 107 KB for the whole country, of which we
// keep the Great Lakes. It sends no CORS header, so the browser cannot read it
// directly; this runs in CI and commits the result, the same arrangement the
// forecast discussion areas use.
//
// CO-OPS is CORS-open and was the obvious alternative, but its Great Lakes
// coverage is harbours and connecting channels — twenty stations, almost none on
// open Lake Michigan, which is the water that matters here.

import { writeFileSync, mkdirSync } from 'node:fs';

const SRC = 'https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt';
const OUT = 'data/lake-temps.json';

// Generous enough for all five lakes plus the connecting waters.
const BOX = { s: 40.5, n: 49.5, w: -93.5, e: -75.5 };

// Columns in latest_obs.txt, which is fixed-order whitespace-separated.
const STN = 0, LAT = 1, LON = 2, YR = 3, MO = 4, DY = 5, HH = 6, MI = 7;
const ATMP = 17, WTMP = 18;

const num = (v) => {
  if (v == null || v === 'MM') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

const res = await fetch(SRC, { headers: { 'User-Agent': 'nightwatch-lake-temps' } });
if (!res.ok) {
  console.error(`NDBC returned ${res.status}; leaving ${OUT} alone`);
  process.exit(1);
}
const text = await res.text();

const stations = [];
for (const line of text.split('\n')) {
  if (!line || line.startsWith('#')) continue;
  const f = line.trim().split(/\s+/);
  if (f.length <= WTMP) continue;
  const lat = num(f[LAT]), lon = num(f[LON]), water = num(f[WTMP]);
  if (lat == null || lon == null || water == null) continue;
  if (lat < BOX.s || lat > BOX.n || lon < BOX.w || lon > BOX.e) continue;
  // A lake is not going to be at 40C, and a stuck sensor often reads an extreme.
  if (water < -2 || water > 35) continue;
  const valid = `${f[YR]}-${f[MO]}-${f[DY]}T${f[HH]}:${f[MI]}:00Z`;
  stations.push({
    id: f[STN],
    lat: +lat.toFixed(4),
    lon: +lon.toFixed(4),
    waterF: +(water * 9 / 5 + 32).toFixed(1),
    airF: num(f[ATMP]) == null ? null : +(num(f[ATMP]) * 9 / 5 + 32).toFixed(1),
    valid,
  });
}

/* The last 24 hours for each buoy, for the graph a tap opens on the map.

   latest_obs.txt is one file for the whole country but carries only the newest
   observation, so history means one request per station. Fifty-odd of those is
   nothing in CI and impossible in the browser, which is the same reason this
   script exists at all: NDBC sends no CORS header.

   Sampled to the hour. The feed reports every ten minutes, and 144 points to
   draw a line 228 pixels wide is 120 points nobody can see. */
const HIST_HOURS = 24;
const WTMP_COL = 14;                       // after the five date fields

async function history(id) {
  try {
    const r = await fetch(`https://www.ndbc.noaa.gov/data/realtime2/${id}.txt`,
                          { headers: { 'User-Agent': 'nightwatch-lake-temps' } });
    if (!r.ok) return [];
    const cut = Date.now() - HIST_HOURS * 3600e3;
    const seen = new Set();
    const out = [];
    for (const line of (await r.text()).split('\n')) {
      if (!line || line.startsWith('#')) continue;
      const f = line.trim().split(/\s+/);
      if (f.length <= WTMP_COL) continue;
      const w = num(f[WTMP_COL]);
      if (w == null || w < -2 || w > 35) continue;
      const t = Date.parse(`${f[0]}-${f[1]}-${f[2]}T${f[3]}:${f[4]}:00Z`);
      if (!Number.isFinite(t) || t < cut) continue;
      const hour = Math.floor(t / 3600e3);
      if (seen.has(hour)) continue;        // rows are newest first; keep the first per hour
      seen.add(hour);
      out.push({ t: new Date(t).toISOString(), w: +(w * 9 / 5 + 32).toFixed(1) });
    }
    return out.reverse();                  // oldest first, the way it is drawn
  } catch { return []; }
}

// A few at a time. Fifty-three parallel requests at one host is rude and gets
// throttled; serial would take a minute.
for (let i = 0; i < stations.length; i += 6) {
  const slice = stations.slice(i, i + 6);
  const got = await Promise.all(slice.map(s => history(s.id)));
  slice.forEach((s, k) => { if (got[k].length >= 2) s.hist = got[k]; });
}

if (!stations.length) {
  console.error(`parsed no Great Lakes stations; leaving ${OUT} alone`);
  process.exit(1);
}

stations.sort((a, b) => a.id.localeCompare(b.id));
mkdirSync('data', { recursive: true });
writeFileSync(OUT, JSON.stringify({ generated: new Date().toISOString(), stations }, null, 0) + '\n');

const temps = stations.map(s => s.waterF);
console.log(`${stations.length} stations -> ${OUT}`);
console.log(`  water ${Math.min(...temps).toFixed(0)}F .. ${Math.max(...temps).toFixed(0)}F`);
const withHist = stations.filter(s => s.hist).length;
console.log(`  history for ${withHist}/${stations.length}, ${(JSON.stringify(stations).length / 1024).toFixed(0)} KB`);
