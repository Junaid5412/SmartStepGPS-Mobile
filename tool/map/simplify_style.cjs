// Turns the official Protomaps "light / English" style into one the Flutter renderer can draw:
//  - every name label becomes plain English: name:en, falling back to the local name
//    (the official style prints English + Arabic on two lines with format/is-supported-script);
//  - a font chosen by an expression becomes a plain font name (the renderer does not evaluate it);
//  - icon images are removed (they need a sprite sheet the app does not ship).
// Reads protomaps_light_en.json (from gen_style.cjs), writes protomaps_light_en_flutter.json.
const st = require('./protomaps_light_en.json');
const EN = ['coalesce', ['get', 'name:en'], ['get', 'name']];
const usesNameLogic = v => JSON.stringify(v).match(/"format"|is-supported-script|"name:en"|"pgf:name"/);
const isPlainFontList = v => Array.isArray(v) && v.every(x => typeof x === 'string') && v[0] !== 'case';

for (const l of st.layers) {
  const lay = l.layout || {};
  if (lay['text-field'] && usesNameLogic(lay['text-field'])) lay['text-field'] = EN;
  if (lay['text-font'] && !isPlainFontList(lay['text-font'])) lay['text-font'] = ['Noto Sans Medium'];
  for (const k of Object.keys(lay)) if (k.startsWith('icon-')) delete lay[k];
}
// A symbol layer left with neither text nor icon would draw nothing; drop it.
st.layers = st.layers.filter(l => l.type !== 'symbol' || (l.layout && l.layout['text-field']));
require('fs').writeFileSync('protomaps_light_en_flutter.json', JSON.stringify(st));

const fonts = new Set(st.layers.map(l => l.layout && l.layout['text-font']).filter(Boolean).map(f => JSON.stringify(f)));
console.log('layers:', st.layers.length, '| fonts:', [...fonts].join(' '));
