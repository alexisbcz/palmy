package main

// Web Mercator (EPSG:3857) and the slippy-map tile scheme.
//
// Everything in this file is pure arithmetic with published reference values,
// which is why it is the first thing the self-test checks. Two coordinate
// spaces matter:
//
//   lon/lat    degrees, WGS84, what a GeoJSON file holds
//   world      normalised Mercator, [0,1] x [0,1], origin at the top left
//              (lon -180 .. +180 maps to x 0 .. 1, lat +85.0511 .. -85.0511
//              maps to y 0 .. 1)
//
// The world square is the zoom-0 tile. At zoom z there are 2^z tiles per axis,
// so a tile coordinate is simply `world * 2^z`, and a screen position is
// `world * TILE_SIZE * 2^z` minus the viewport origin. Keeping the model in
// normalised world units rather than in pixels means the stored geometry never
// has to be rebuilt when the zoom changes.

import "core:math"

// The Mercator projection sends the poles to infinity, so the tile scheme
// stops at the latitude whose projected y is exactly one world square from the
// equator: atan(sinh(pi)) in degrees.
//
//	lat = 180/pi * atan(sinh(pi)) = 85.0511287798066...
MAX_LAT :: 85.05112877980659

// The side of one tile in pixels. 256 is the value every published
// resolution table is quoted against.
TILE_SIZE :: 256.0

// The equatorial circumference of the WGS84 ellipsoid used by EPSG:3857,
// 2*pi*6378137. Ground resolution at the equator and zoom 0 is this over 256,
// which is the familiar 156543.03392804097 m/px.
EARTH_CIRCUMFERENCE :: 40075016.685578488
EARTH_RADIUS :: 6378137.0

// World_Pt is a point in normalised Mercator space.
World_Pt :: [2]f64

// lonlat_to_world projects degrees to the normalised Mercator square. The
// latitude is clamped to the Mercator limit rather than returning an infinity.
lonlat_to_world :: proc(lon, lat: f64) -> World_Pt {
	x := (lon + 180) / 360
	l := clamp(lat, -MAX_LAT, MAX_LAT)
	s := math.sin(l * math.PI / 180)
	y := 0.5 - math.ln((1 + s) / (1 - s)) / (4 * math.PI)
	return {x, y}
}

// world_to_lonlat is the exact inverse of lonlat_to_world inside the limit.
world_to_lonlat :: proc(w: World_Pt) -> (lon, lat: f64) {
	lon = w.x * 360 - 180
	n := math.PI * (1 - 2 * w.y)
	lat = math.atan(math.sinh(n)) * 180 / math.PI
	return
}

// lonlat_to_tile gives the fractional tile coordinate at a zoom level. The
// integer tile containing the point is the floor of each component, which is
// what the OSM slippy-map scheme specifies.
lonlat_to_tile :: proc(lon, lat: f64, z: int) -> (tx, ty: f64) {
	w := lonlat_to_world(lon, lat)
	n := f64(tiles_per_axis(z))
	return w.x * n, w.y * n
}

// tile_to_lonlat returns the north-west corner of a tile.
tile_to_lonlat :: proc(tx, ty: f64, z: int) -> (lon, lat: f64) {
	n := f64(tiles_per_axis(z))
	return world_to_lonlat({tx / n, ty / n})
}

// tiles_per_axis is 2^z. Guarded so a silly zoom cannot shift by 64.
tiles_per_axis :: proc(z: int) -> i64 {
	zz := clamp(z, 0, 30)
	return i64(1) << uint(zz)
}

// world_scale is how many pixels one unit of world space spans at this zoom.
// Continuous: the zoom is an f64 and nothing rounds it to a level.
world_scale :: proc(zoom: f64) -> f64 {
	return TILE_SIZE * math.pow(2, zoom)
}

// ground_resolution is metres per pixel at a latitude and zoom. At lat 0,
// zoom 0 it is 156543.03392804097, the published figure for a 256px tile.
ground_resolution :: proc(lat, zoom: f64) -> f64 {
	l := clamp(lat, -MAX_LAT, MAX_LAT)
	return math.cos(l * math.PI / 180) * EARTH_CIRCUMFERENCE / world_scale(zoom)
}

// ---------------------------------------------------------------------------
// The viewport
// ---------------------------------------------------------------------------

// View is the camera: a world-space centre, a continuous zoom, and the size of
// the panel it is drawn into. Screen coordinates are relative to the panel's
// own top left, so the panel's position on screen is added by the caller.
View :: struct {
	center: World_Pt,
	zoom:   f64,
	w, h:   f64,
}

view_scale :: proc(v: View) -> f64 {
	return world_scale(v.zoom)
}

// world_to_screen maps a world point into the panel.
world_to_screen :: proc(v: View, p: World_Pt) -> [2]f64 {
	s := view_scale(v)
	return {(p.x - v.center.x) * s + v.w / 2, (p.y - v.center.y) * s + v.h / 2}
}

// screen_to_world is its inverse, which is how the cursor read-out and
// click-to-place work.
screen_to_world :: proc(v: View, sx, sy: f64) -> World_Pt {
	s := view_scale(v)
	return {(sx - v.w / 2) / s + v.center.x, (sy - v.h / 2) / s + v.center.y}
}

// view_bounds is the world-space rectangle the panel shows, grown by a margin
// in pixels so that a feature whose stroke reaches into the viewport is not
// culled by its centre line being outside it.
view_bounds :: proc(v: View, margin_px: f64 = 64) -> (min, max: World_Pt) {
	s := view_scale(v)
	hw := (v.w / 2 + margin_px) / s
	hh := (v.h / 2 + margin_px) / s
	return {v.center.x - hw, v.center.y - hh}, {v.center.x + hw, v.center.y + hh}
}

// view_zoom_at changes the zoom while keeping the world point under a given
// screen position fixed, which is what a wheel zoom has to do.
view_zoom_at :: proc(v: ^View, dz: f64, sx, sy: f64, lo := 1.0, hi := 21.0) {
	before := screen_to_world(v^, sx, sy)
	v.zoom = clamp(v.zoom + dz, lo, hi)
	after := screen_to_world(v^, sx, sy)
	v.center += before - after
	view_clamp(v)
}

// view_clamp keeps the centre inside the world square. Mercator has no
// meaningful data past the limit, and letting the centre leave the square puts
// the whole map off screen with no way back.
view_clamp :: proc(v: ^View) {
	v.center.x = clamp(v.center.x, 0, 1)
	v.center.y = clamp(v.center.y, 0, 1)
}

// view_fit centres a world-space bounding box with padding, choosing the
// largest zoom at which it still fits.
// A bounding box built from a south-west and a north-east corner in lon/lat
// has its y components the other way round in Mercator space, because world y
// grows southwards. So the extent is taken as an absolute difference rather
// than trusting the order of the two points.
view_fit :: proc(v: ^View, min, max: World_Pt, pad_px: f64 = 48) {
	v.center = (min + max) / 2
	dw := abs(max.x - min.x)
	dh := abs(max.y - min.y)
	aw := math.max(v.w - 2 * pad_px, 32.0)
	ah := math.max(v.h - 2 * pad_px, 32.0)
	z := 21.0
	if dw > 0 {
		z = math.min(z, math.log2(aw / (dw * TILE_SIZE)))
	}
	if dh > 0 {
		z = math.min(z, math.log2(ah / (dh * TILE_SIZE)))
	}
	v.zoom = clamp(z, 1, 21)
	view_clamp(v)
}

// ---------------------------------------------------------------------------
// Distance
// ---------------------------------------------------------------------------

// haversine is the great-circle distance in metres on a sphere of the WGS84
// equatorial radius. Routing costs are quoted in metres, and over a city the
// difference between this and a proper geodesic is centimetres.
haversine :: proc(lon1, lat1, lon2, lat2: f64) -> f64 {
	r1 := lat1 * math.PI / 180
	r2 := lat2 * math.PI / 180
	dlat := r2 - r1
	dlon := (lon2 - lon1) * math.PI / 180
	a := math.sin(dlat / 2) * math.sin(dlat / 2) +
		math.cos(r1) * math.cos(r2) * math.sin(dlon / 2) * math.sin(dlon / 2)
	return 2 * EARTH_RADIUS * math.atan2(math.sqrt(a), math.sqrt(math.max(0, 1 - a)))
}

// world_distance is haversine between two world points.
world_distance :: proc(a, b: World_Pt) -> f64 {
	lon1, lat1 := world_to_lonlat(a)
	lon2, lat2 := world_to_lonlat(b)
	return haversine(lon1, lat1, lon2, lat2)
}

// bearing is the initial compass bearing from a to b, 0 = north, clockwise.
// Turn instructions are the difference between two of these.
bearing :: proc(lon1, lat1, lon2, lat2: f64) -> f64 {
	r1 := lat1 * math.PI / 180
	r2 := lat2 * math.PI / 180
	dl := (lon2 - lon1) * math.PI / 180
	y := math.sin(dl) * math.cos(r2)
	x := math.cos(r1) * math.sin(r2) - math.sin(r1) * math.cos(r2) * math.cos(dl)
	d := math.atan2(y, x) * 180 / math.PI
	if d < 0 {
		d += 360
	}
	return d
}

world_bearing :: proc(a, b: World_Pt) -> f64 {
	lon1, lat1 := world_to_lonlat(a)
	lon2, lat2 := world_to_lonlat(b)
	return bearing(lon1, lat1, lon2, lat2)
}

// angle_delta normalises a bearing change into (-180, 180]: negative is a left
// turn, positive a right turn.
angle_delta :: proc(from, to: f64) -> f64 {
	d := to - from
	for d <= -180 {
		d += 360
	}
	for d > 180 {
		d -= 360
	}
	return d
}
