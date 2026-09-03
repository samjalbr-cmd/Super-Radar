#!/usr/bin/env node
/**
 * Read each office's Area Forecast Discussion and have Claude draw the areas it
 * describes, then write them to data/afd-areas.json for the map to load.
 *
 * Runs in CI, never in the browser: the site is static, so an API key must
 * never reach a visitor. See .github/workflows/afd-areas.yml.
 *
 * Cost control is the product id — an AFD is reissued only a few times a day,
 * so any office whose latest product we have already read is skipped.
 */
import Anthropic from '@anthropic-ai/sdk';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const OUT = 'data/afd-areas.json';
const OFFICES = 'data/offices.json';
const UA = 'super-radar (github.com/samjalbr-cmd/Super-Radar)';
const MODEL = process.env.AFD_MODEL || 'claude-opus-5';
const DRY = process.argv.includes('--dry-run');
const ONLY = (process.argv.find(a => a.startsWith('--only=')) || '').split('=')[1];

const CWA_URL = 'https://mapservices.weather.noaa.gov/static/rest/services/' +
                'nws_reference_maps/nws_reference_map/FeatureServer/1/query';

const HAZARDS = ['tornado', 'hail', 'damaging wind', 'flash flooding', 'severe storms',
                 'heavy snow', 'ice', 'extreme cold', 'heat', 'dense fog',
                 'fire weather', 'high wind', 'marine', 'other'];

// One object per area the discussion actually describes. Everything is required
// so the model can't quietly omit the parts we rely on.
const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['areas', 'headline'],
  properties: {
    headline: { type: 'string', description: 'The single most important thing this discussion says, under 70 characters.' },
    areas: {
      type: 'array',
      maxItems: 4,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['hazard', 'label', 'confidence', 'start', 'end', 'polygon', 'quote'],
        properties: {
          hazard: { type: 'string', enum: HAZARDS },
          label: { type: 'string', description: 'Under 40 characters, e.g. "Large hail, damaging winds".' },
          confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
          start: { type: 'string', description: 'ISO 8601 UTC, e.g. 2026-09-02T02:00:00Z' },
          end:   { type: 'string', description: 'ISO 8601 UTC' },
          polygon: {
            type: 'array', minItems: 3, maxItems: 14,
            description: '[latitude, longitude] pairs, in order, forming a closed area.',
            items: { type: 'array', minItems: 2, maxItems: 2, items: { type: 'number' } },
          },
          quote: { type: 'string', description: 'The sentence from the discussion this area comes from, verbatim.' },
        },
      },
    },
  },
};

const SYSTEM = `You read National Weather Service Area Forecast Discussions and mark on a map the areas they describe.

You will be given one discussion, the issuing office, the time it was issued, and the office's boundary as a polygon.

Draw an area only where the text describes a hazard affecting a specific part of the region. Forecasters name places constantly — "southwest Lower Michigan", "along and south of I-94", "the Lakeshore counties", "east of a line from Muskegon to Lansing", airport identifiers like AZO or LAN. Turn those descriptions into polygons.

Rules:
- Only draw what the text supports. A discussion describing quiet weather gets zero areas. Do not invent a threat to have something to draw.
- Every polygon must lie within the office boundary you are given, or overlap it substantially. That boundary is the ground truth for where this office forecasts.
- Resolve relative times ("tonight", "Wednesday afternoon", "after midnight") against the issuance time you are given, and express them in UTC. Remember the issuance time is local to the office.
- If the text describes one hazard over the whole area, one polygon covering the office is correct.
- Prefer fewer, larger areas over many small ones.
- quote must be copied verbatim from the discussion. Do not paraphrase it.
- confidence reflects how specific the text is about that area, not how severe the weather is. "greatest threat across southwest Lower Michigan" is high; "somewhere in the region" is low.`;

const j = async (url) => {
  const r = await fetch(url, { headers: { 'User-Agent': UA } });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json();
};

function vertexCount(feat) {
  let n = 0;
  (function walk(c) { if (!c?.length) return; typeof c[0][0] === 'number' ? n += c.length : c.forEach(walk); })(feat.geometry.coordinates);
  return n;
}
async function cwa(wfo) {
  const q = (off) => `${CWA_URL}?where=cwa%3D%27${wfo}%27&outFields=cwa,citystate&returnGeometry=true&outSR=4326&maxAllowableOffset=${off}&f=geojson`;
  let d = await j(q(0.02));
  let f = d.features?.[0];
  if (f && vertexCount(f) > 400) f = (await j(q(0.3))).features?.[0] || f;   // Alaska
  return f || null;
}
function bbox(feat) {
  let s = 90, n = -90, w = 180, e = -180;
  (function walk(c) {
    if (!c?.length) return;
    if (typeof c[0][0] === 'number') for (const [x, y] of c) { s = Math.min(s, y); n = Math.max(n, y); w = Math.min(w, x); e = Math.max(e, x); }
    else c.forEach(walk);
  })(feat.geometry.coordinates);
  return { s, n, w, e };
}

// The model writes the coordinates, so nothing it returns is trusted until it
// has been checked against the office's real boundary.
function validate(area, box, wfo) {
  const bad = (why) => { console.log(`    rejected (${why}): ${area.label}`); return null; };
  if (!Array.isArray(area.polygon) || area.polygon.length < 3) return bad('too few vertices');
  const pts = [];
  for (const p of area.polygon) {
    const [lat, lon] = p;
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return bad('non-numeric vertex');
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return bad('vertex off the earth');
    pts.push([+lat.toFixed(4), +lon.toFixed(4)]);
  }
  // Centroid must sit inside the office's box, and the shape must not sprawl far
  // beyond it — both catch a plausible-looking polygon drawn in the wrong state.
  const cLat = pts.reduce((a, p) => a + p[0], 0) / pts.length;
  const cLon = pts.reduce((a, p) => a + p[1], 0) / pts.length;
  const padLat = (box.n - box.s) * 0.35 + 0.4, padLon = (box.e - box.w) * 0.35 + 0.4;
  if (cLat < box.s - padLat || cLat > box.n + padLat || cLon < box.w - padLon || cLon > box.e + padLon)
    return bad(`centroid ${cLat.toFixed(1)},${cLon.toFixed(1)} outside ${wfo}`);
  const span = Math.max(...pts.map(p => p[0])) - Math.min(...pts.map(p => p[0]));
  if (span > (box.n - box.s) * 3 + 2) return bad('polygon far larger than the office');
  const t0 = Date.parse(area.start), t1 = Date.parse(area.end);
  if (!t0 || !t1 || t1 <= t0) return bad('unusable time window');
  return { hazard: area.hazard, label: String(area.label).slice(0, 60), confidence: area.confidence,
           start: new Date(t0).toISOString(), end: new Date(t1).toISOString(),
           quote: String(area.quote).slice(0, 300), polygon: pts };
}

async function main() {
  const offices = JSON.parse(readFileSync(OFFICES, 'utf8'));
  let out = { generated: null, offices: {} };
  try { out = JSON.parse(readFileSync(OUT, 'utf8')); } catch {}
  out.offices ||= {};
  const before = JSON.stringify(out.offices);

  const client = new Anthropic();
  console.log(`model: ${MODEL}`);
  const list = ONLY ? ONLY.split(',') : offices;
  let calls = 0, drawn = 0;

  for (const wfo of list) {
    try {
      const idx = await j(`https://api.weather.gov/products/types/AFD/locations/${wfo}`);
      const latest = idx['@graph']?.[0];
      if (!latest) { console.log(`${wfo}: no AFD`); continue; }
      if (out.offices[wfo]?.product === latest.id && !ONLY) { console.log(`${wfo}: unchanged`); continue; }

      const prod = await j(`https://api.weather.gov/products/${latest.id}`);
      const feat = await cwa(wfo);
      if (!feat) { console.log(`${wfo}: no boundary`); continue; }
      const box = bbox(feat);

      const prompt = [
        `Office: ${wfo} (${feat.properties.citystate})`,
        `Issued: ${latest.issuanceTime}`,
        `Office boundary (GeoJSON, [longitude, latitude]):`,
        JSON.stringify(feat.geometry),
        ``, `Discussion:`, prod.productText,
      ].join('\n');

      if (DRY) { console.log(`${wfo}: would send ${prompt.length} chars`); continue; }

      const res = await client.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        system: SYSTEM,
        thinking: { type: 'adaptive' },
        output_config: { format: { type: 'json_schema', schema: SCHEMA } },
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        messages: [{ role: 'user', content: prompt }],
      });
      calls++;
      if (res.stop_reason === 'refusal') { console.log(`${wfo}: refused (${res.stop_details?.category})`); continue; }

      const text = res.content.find(b => b.type === 'text')?.text;
      const parsed = JSON.parse(text);
      const areas = (parsed.areas || []).map(a => validate(a, box, wfo)).filter(Boolean);
      drawn += areas.length;

      out.offices[wfo] = {
        product: latest.id,
        issued: latest.issuanceTime,
        office: feat.properties.citystate,
        headline: String(parsed.headline || '').slice(0, 90),
        areas,
      };
      const u = res.usage;
      console.log(`${wfo}: ${areas.length} area(s)  [in ${u.input_tokens} / out ${u.output_tokens}]  ${parsed.headline}`);
    } catch (e) {
      const msg = e.message || String(e);
      if (/credit balance|authentication|invalid x-api-key|permission|401|403/i.test(msg)) {
        console.error(`\nFATAL — this affects every office, stopping.\n${msg}\n`);
        if (/credit balance/i.test(msg))
          console.error('Add API credit at console.anthropic.com -> Plans & Billing.\n' +
                        'A Claude subscription is billed separately and does not fund the API.');
        process.exit(1);
      }
      console.log(`${wfo}: FAILED — ${msg}`);
    }
  }

  if (DRY) return;
  const body = JSON.stringify(out.offices);
  if (body === before) {
    console.log(`\n${calls} model call(s), nothing changed — leaving ${OUT} alone`);
    return;
  }
  out.generated = new Date().toISOString();
  mkdirSync('data', { recursive: true });
  writeFileSync(OUT, JSON.stringify(out, null, 1) + '\n');
  console.log(`\n${calls} model call(s), ${drawn} area(s) drawn -> ${OUT}`);
}

main().catch(e => { console.error(e); process.exit(1); });
