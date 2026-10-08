// Builds the MapLibre style for the app from the official @protomaps/basemaps package:
// "light" flavour, English labels, reading the vector source named "protomaps".
const b = require('@protomaps/basemaps');
const layers = b.layers('protomaps', b.namedFlavor('light'), { lang: 'en' });
const style = {
  version: 8,
  name: 'Smart Step GPS - Protomaps Light (English)',
  sources: { protomaps: { type: 'vector', attribution: '© OpenStreetMap' } },
  layers,
};
require('fs').writeFileSync('protomaps_light_en.json', JSON.stringify(style));
console.log('layers:', layers.length, 'types:', [...new Set(layers.map(l => l.type))].join(','));
const tf = layers.filter(l => l.layout && l.layout['text-field']);
console.log('label layers:', tf.length);
console.log('sample text-field:', JSON.stringify(tf.find(l => l.id.includes('places'))?.layout['text-field'] || tf[0].layout['text-field']).slice(0, 400));
