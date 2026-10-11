<?php
// Builds a Google-Maps-like style from the Protomaps light style. Only colours / widths / label sizes /
// POI thresholds change; every expression form used is one the original style already uses.
$src = 'assets/map/protomaps_light_en.json';
$dst = 'assets/map/protomaps_google_en.json';
$j = json_decode(file_get_contents($src), true);

$LAND = '#f2efe9'; $WATER = '#a8d4f5'; $PARK = '#c9e7bd'; $BUILD = '#ebe6dc';
$ROADTXT = '#5f6368'; $PLACETXT = '#3c4043';

// multiply the output values of a line-width / gap interpolate by $k
function scale_w($e, $k) {
    if (!is_array($e) || ($e[0] ?? '') !== 'interpolate') return is_numeric($e) ? $e * $k : $e;
    for ($i = 3; $i < count($e); $i += 2) $e[$i + 1] = round($e[$i + 1] * $k, 3);
    return $e;
}

$ids = [];
foreach ($j['layers'] as $i => &$l) {
    $id = $l['id'];
    $p = &$l['paint'];
    $ly = &$l['layout'];
    switch (true) {
        case $id === 'background': $p['background-color'] = $LAND; break;
        case $id === 'earth': $p['fill-color'] = $LAND; break;
        case $id === 'landuse_park':
            $p['fill-color'] = ['case',
                ['in', ['get', 'kind'], ['literal', ['national_park', 'park', 'cemetery', 'protected_area', 'nature_reserve', 'forest', 'golf_course']]], $PARK,
                ['==', ['get', 'kind'], 'wood'], '#b9dfa8',
                ['in', ['get', 'kind'], ['literal', ['scrub', 'grassland', 'grass']]], '#d3e8c6',
                ['==', ['get', 'kind'], 'glacier'], '#e7e7e7',
                ['==', ['get', 'kind'], 'sand'], '#eee6cf',
                ['in', ['get', 'kind'], ['literal', ['military', 'naval_base', 'airfield']]], '#e3e3dc',
                $LAND];
            break;
        case $id === 'landuse_urban_green': $p['fill-color'] = '#c9e7bd'; break;
        case $id === 'landuse_hospital': $p['fill-color'] = '#f8dcdc'; break;
        case $id === 'landuse_industrial': $p['fill-color'] = '#e8e6e1'; break;
        case $id === 'landuse_school': $p['fill-color'] = '#efe6d2'; break;
        case $id === 'landuse_beach': $p['fill-color'] = '#f3e8c6'; break;
        case $id === 'landuse_zoo': $p['fill-color'] = '#d3e8c6'; break;
        case $id === 'landuse_aerodrome': $p['fill-color'] = '#e6e8ea'; break;
        case $id === 'landuse_pedestrian': $p['fill-color'] = '#f7f5f0'; break;
        case $id === 'landuse_pier': $p['fill-color'] = '#e8e4da'; break;
        case $id === 'water': $p['fill-color'] = $WATER; break;
        case $id === 'water_stream': case $id === 'water_river': $p['line-color'] = $WATER; break;
        case $id === 'buildings':
            $p['fill-color'] = $BUILD;
            $p['fill-opacity'] = ['interpolate', ['linear'], ['zoom'], 13.5, 0, 15, 1];
            break;
        case $id === 'roads_runway': case $id === 'roads_taxiway': $p['line-color'] = '#d9dce0'; break;
        case $id === 'landuse_runway': $p['fill-color'] = '#d9dce0'; break;
        case $id === 'roads_pier': $p['line-color'] = '#e8e4da'; break;
        case $id === 'roads_rail': $p['line-color'] = '#9aa0a6'; $p['line-opacity'] = 0.6; break;
        case $id === 'boundaries_country' || $id === 'boundaries': $p['line-color'] = '#b8bcc4'; break;
    }

    // ---- roads
    $isRoad = ($l['source-layer'] ?? '') === 'roads' && $l['type'] === 'line';
    if ($isRoad && strpos($id, 'roads_runway') === false && strpos($id, 'roads_taxiway') === false && $id !== 'roads_rail' && $id !== 'roads_pier') {
        $casing = strpos($id, 'casing') !== false;
        $hw = strpos($id, 'highway') !== false;
        $maj = strpos($id, 'major') !== false;
        $link = strpos($id, '_link') !== false;
        $tun = strpos($id, 'tunnels') !== false;
        $svc = strpos($id, 'service') !== false;
        $oth = strpos($id, '_other') !== false;
        if ($casing) {
            $p['line-color'] = $hw ? '#e0a53a' : ($maj ? '#c7cbd1' : ($link ? '#d4a845' : '#d6d9de'));
            if (isset($p['line-gap-width'])) $p['line-gap-width'] = scale_w($p['line-gap-width'], 1.25);
        } else {
            if ($hw || $link) $p['line-color'] = '#fdd77c';
            elseif ($maj) $p['line-color'] = '#ffffff';
            elseif ($svc || $oth) $p['line-color'] = '#ffffff';
            else $p['line-color'] = '#ffffff';
            if (isset($p['line-width'])) $p['line-width'] = scale_w($p['line-width'], 1.25);
            if ($tun) $p['line-opacity'] = 0.55;
        }
        // minor roads: give the (formerly casing-less) fills a visible edge from zoom 12 by keeping the casings.
    }

    // ---- labels
    if ($l['type'] === 'symbol') {
        $isLine = ($ly['symbol-placement'] ?? '') === 'line';
        if (in_array($id, ['roads_labels_minor', 'roads_labels_major'])) {
            $p['text-color'] = $ROADTXT; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 2;
            $ly['text-size'] = ['interpolate', ['linear'], ['zoom'], 12, 10, 15, 11.5, 18, 14];
            $ly['text-font'] = ['Noto Sans Medium'];
        }
        if ($id === 'roads_labels_minor') $l['minzoom'] = 14.5;
        if ($id === 'roads_shields') $p['text-color'] = $ROADTXT;
        if (in_array($id, ['water_label_ocean', 'water_label_lakes', 'water_waterway_label'])) {
            $p['text-color'] = '#4a86b8'; $p['text-halo-color'] = $WATER; $p['text-halo-width'] = 1.5;
        }
        if ($id === 'water_label_ocean') $ly['text-size'] = ['interpolate', ['linear'], ['zoom'], 3, 11, 10, 14];
        if ($id === 'earth_label_islands') { $p['text-color'] = '#70757a'; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 1.5; }
        if ($id === 'address_label') { $p['text-color'] = '#80868b'; $l['minzoom'] = 17; }
        if ($id === 'places_subplace') {
            $p['text-color'] = '#70757a'; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 2;
            unset($ly['text-transform']);
            $ly['text-font'] = ['Noto Sans Medium'];
            $ly['text-size'] = ['interpolate', ['linear'], ['zoom'], 11, 10, 14, 14, 18, 22];
            $ly['text-letter-spacing'] = 0.04;
        }
        if ($id === 'places_locality') { $p['text-color'] = $PLACETXT; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 2; $ly['text-font'] = ['Noto Sans Medium']; }
        if ($id === 'places_region') { $p['text-color'] = '#80868b'; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 2; unset($ly['text-transform']); }
        if ($id === 'places_country') { $p['text-color'] = '#70757a'; $p['text-halo-color'] = '#ffffff'; $p['text-halo-width'] = 2; }

        if ($id === 'pois') {
            $kinds = ['beach', 'forest', 'marina', 'park', 'peak', 'zoo', 'garden', 'bench', 'aerodrome', 'station', 'bus_stop', 'ferry_terminal', 'stadium', 'university', 'library', 'school', 'animal', 'toilets', 'drinking_water', 'post_office', 'building', 'townhall', 'restaurant', 'fast_food', 'cafe', 'bar', 'supermarket', 'convenience', 'books', 'beauty', 'electronics', 'clothes', 'attraction', 'museum', 'theatre', 'artwork',
                'hospital', 'clinic', 'pharmacy', 'dentist', 'doctors', 'hotel', 'mall', 'department_store', 'bank', 'atm', 'place_of_worship', 'fuel', 'kindergarten', 'college', 'cinema', 'swimming_pool', 'pitch', 'sports_centre', 'police', 'fire_station', 'bakery', 'jewelry', 'mobile_phone', 'car_repair', 'marketplace'];
            $mk = function ($list) { return ['in', ['get', 'kind'], ['literal', $list]]; };
            $p['text-color'] = ['case',
                $mk(['beach', 'forest', 'marina', 'park', 'peak', 'zoo', 'garden', 'bench', 'pitch', 'swimming_pool', 'sports_centre']), '#188038',
                $mk(['aerodrome', 'station', 'bus_stop', 'ferry_terminal', 'fuel']), '#1a73e8',
                $mk(['hospital', 'clinic', 'pharmacy', 'dentist', 'doctors', 'police', 'fire_station']), '#c5221f',
                $mk(['hotel']), '#a142f4',
                $mk(['supermarket', 'convenience', 'books', 'beauty', 'electronics', 'clothes', 'mall', 'department_store', 'bank', 'atm', 'jewelry', 'mobile_phone', 'marketplace']), '#1967d2',
                $mk(['restaurant', 'fast_food', 'cafe', 'bar', 'bakery']), '#e8710a',
                $mk(['attraction', 'museum', 'theatre', 'artwork', 'cinema']), '#d01884',
                $mk(['stadium', 'university', 'library', 'school', 'college', 'kindergarten', 'animal', 'toilets', 'drinking_water', 'post_office', 'building', 'townhall', 'place_of_worship', 'car_repair']), '#5f6368',
                '#5f6368'];
            $p['text-halo-color'] = '#ffffff';
            $p['text-halo-width'] = 2;
            $ly['text-font'] = ['Noto Sans Medium'];
            $ly['text-size'] = ['interpolate', ['linear'], ['zoom'], 14, 10, 17, 11.5, 19, 15];
            $ly['text-padding'] = 3;
            $ly['text-max-width'] = 7;
            $l['filter'] = ['all', $mk($kinds), ['>=', ['zoom'], ['+', ['get', 'min_zoom'], -2]]];
        }
    }
    unset($p, $ly);
}
unset($l); foreach ($j["layers"] as &$l2) { foreach (["paint","layout"] as $k) if (array_key_exists($k,$l2) && ($l2[$k]===null || $l2[$k]===[])) unset($l2[$k]); } unset($l2);
$j['name'] = 'Smart Step GPS - Google-style (English)';
file_put_contents($dst, json_encode($j, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");
echo "written ", filesize($dst), " bytes\n";
