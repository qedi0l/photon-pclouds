/*
--------------------------------------------------------------------------------

  Pollution clouds integration

  Renders localized volumetric pollution clouds supplied by the Pollution clouds
  mod through an Iris SSBO (bufferObject.0, binding 0).

  The mod uploads one ellipsoid per connected polluted region:
    - world-space center
    - per-axis half-extents
    - an RGBA color (A = density multiplier)

  Each ellipsoid is raymarched with a Beer-Lambert attenuation and composited
  front-to-back.

--------------------------------------------------------------------------------
*/

#if !defined INCLUDE_POLLUTION_FOG
#define INCLUDE_POLLUTION_FOG

#ifdef POLLUTION_FOG

// SSBO for reading pollution cloud world positions, sizes, and colors.
// Must match the std430 layout written by PCloudsMod's PollutionSsboWriter:
//   int   positionCount   -> offset 0,     padded to 16
//   vec3  positions[1024] -> offset 16,    16 bytes each
//   vec3  sizes[1024]     -> offset 16400, 16 bytes each
//   vec4  colors[1024]    -> offset 32784, 16 bytes each
layout(std430, binding = 0) buffer pollutionClouds {
    int positionCount;
    vec3 positions[1024];
    vec3 sizes[1024];   // per-cloud half-extents (sizeX, sizeY, sizeZ)
    vec4 colors[1024];  // per-cloud RGBA color (A = density multiplier)
};

// Tuning
#define POLLUTION_FOG_SAMPLES 5
#define POLLUTION_FOG_MAX_CLOUDS 512

// Minimum brightness at night so fog is still visible
#define POLLUTION_FOG_NIGHT_BRIGHTNESS 0.3

// Daylight factor based on world time.
// Sunrise at tick 23215, sunset at tick 12785 (sun/moon equidistant at horizon).
// Day length: 13570 ticks, Night length: 10430 ticks.
float pollution_get_daylight_factor() {
    float time = mod(worldTime, 24000.0);
    // Shift so that t=0 is sunrise
    float t = mod(time - 23215.0, 24000.0);
    float dayLength = 13570.0;

    float daylight;
    if (t < dayLength) {
        // Daytime: smooth sine curve (0 at sunrise/sunset, 1 at midday)
        daylight = sin(t / dayLength * pi) * 1.5;
    } else {
        // Nighttime
        daylight = 0.0;
    }

    return POLLUTION_FOG_NIGHT_BRIGHTNESS + 0.85 * daylight;
}

// 3D noise from the 2D noisetex (Eclipse-Shader technique).
float pollution_density_at_pos(vec3 pos) {
    pos /= 18.0;
    pos.xz *= 0.5;

    vec3 p = floor(pos);
    vec3 f = fract(pos);

    // Smoothstep interpolation
    f = f * f * (3.0 - 2.0 * f);

    // Encode Y into texture UV offset for pseudo-3D noise
    vec2 uv = p.xz + f.xz + p.y * vec2(0.0, 193.0);
    vec2 coord = uv / 512.0;
    vec2 xy = texture(noisetex, coord).yx;

    return mix(xy.r, xy.g, f.y);
}

// Cloud volume density function (simplified from Eclipse-Shader).
float pollution_cloud_vol(vec3 pos, vec3 fogColor) {
    vec3 samplePos = pos;

    // Wind effect based on height
    float Wind = pow(pos.y / 305.0, 1.3) - frameTimeCounter;

    float colorCoeff = (fogColor.r + fogColor.g + fogColor.b) * 1500.0;

    // Plume noise
    float Plumes = texture(noisetex, (vec2(samplePos.z, samplePos.x * 1.2) - Wind) / colorCoeff).b;
    float floorPlumes = clamp(0.5 - exp(Plumes * -6.0), 0.0, 1.0);
    Plumes *= Plumes * floorPlumes * 4.0;

    return Plumes;
}

// Ray-ellipsoid intersection test.
// Ellipsoid defined by center and half-extents (sizeX, sizeY, sizeZ).
// Returns true if the ray intersects the ellipsoid, sets tNear and tFar.
bool pollution_ray_ellipsoid_intersect(
    vec3 rayOrigin,
    vec3 rayDir,
    vec3 ellipsoidCenter,
    vec3 halfExtents,
    out float tNear,
    out float tFar
) {

    // Transform to unit-sphere space: divide by half-extents
    vec3 invExtents = rcp(halfExtents);
    vec3 oc = (rayOrigin - ellipsoidCenter) * invExtents;
    vec3 rd = rayDir * invExtents;

    float a = dot(rd, rd);
    float b = 2.0 * dot(oc, rd);
    float c = dot(oc, oc) - 1.0;
    float discriminant = b * b - 4.0 * a * c;

    if (discriminant < 0.0) {
        return false;
    }

    float sqrtDisc = sqrt(discriminant);
    tNear = (-b - sqrtDisc) * rcp(2.0 * a);
    tFar = (-b + sqrtDisc) * rcp(2.0 * a);

    // Ensure intersections are in front of the camera
    if (tNear < 0.0) tNear = 0.0;
    if (tFar < 0.0) return false;

    return true;
}

// Render volumetric fog for a single pollution cloud (ellipsoid).
// All positions are in player (camera-relative) space.
// sceneDist: view-space distance to the opaque surface at this pixel
// (far plane for sky). The fog is clamped to not render behind terrain.
vec4 pollution_render_fog_ellipsoid(
    vec3 rayOrigin,
    vec3 rayDir,
    vec3 ellipsoidCenter,
    vec3 halfExtents,
    vec4 cloudColor,
    float dither,
    float sceneDist
) {
    float tNear, tFar;
    if (!pollution_ray_ellipsoid_intersect(rayOrigin, rayDir, ellipsoidCenter, halfExtents, tNear, tFar)) {
        return vec4(0.0, 0.0, 0.0, 1.0); // No intersection, fully transparent
    }

    // Occlusion: fog must not render behind the opaque surface
    tFar = min(tFar, sceneDist);
    if (tNear >= tFar) {
        return vec4(0.0, 0.0, 0.0, 1.0); // Terrain is in front of (or at) the fog
    }

    // Raymarch through the ellipsoid
    vec3 color = cloudColor.rgb;
    float absorbance = 1.0;
    float segmentLength = tFar - tNear;

    // Per-cloud color from SSBO (RGBA)
    vec3 fogColor = cloudColor.rgb;
    float densityMultiplier = cloudColor.a;

    for (int i = 0; i < POLLUTION_FOG_SAMPLES; i++) {
        // Uniform sampling through the ellipsoid segment
        float t = tNear + (float(i) + dither) / float(POLLUTION_FOG_SAMPLES) * segmentLength;
        float dt = segmentLength / float(POLLUTION_FOG_SAMPLES);

        // Current sample position (player space)
        vec3 samplePos = rayOrigin + t * rayDir;

        // Normalized distance from ellipsoid center (in unit-sphere space)
        vec3 normalizedOffset = (samplePos - ellipsoidCenter) * rcp(halfExtents);
        float normalizedDist = length(normalizedOffset);

        // Density falls off towards the edges of the ellipsoid
        float edgeFalloff = 1.0 - normalizedDist * normalizedDist;
        edgeFalloff = max(edgeFalloff, 0.0) * 1.5;

        // Convert to world-space for noise sampling
        vec3 worldSamplePos = samplePos + cameraPosition;

        // Get fog density at this position
        float densityVol = pollution_cloud_vol(worldSamplePos, fogColor);
        densityVol = smoothstep(0.0001, 1.0, densityVol) * densityVol;

        // Apply edge falloff and per-cloud density multiplier
        densityVol *= edgeFalloff * 0.09 * densityMultiplier;

        // Beer-Lambert attenuation
        float plumeDensity = densityVol * 0.5;
        float plumeVolumeCoeff = exp(-plumeDensity * dt);

        // Lighting (simplified)
        vec3 lighting = fogColor * 0.3 * exp(-10.0 * densityVol);

        // Accumulate color
        color += (lighting - lighting * plumeVolumeCoeff) * absorbance;
        absorbance *= plumeVolumeCoeff;

        // Early exit if fully opaque
        if (absorbance < 0.01) break;
    }

    return vec4(color, absorbance);
}

// Main volumetric fog function.
// Renders fog as volumetric ellipsoids around each pollution cloud position.
// sceneDist: view-space distance to the opaque surface at this pixel
//            (far plane for sky).
vec4 pollution_get_volumetric_fog(
    vec3 viewPosition,
    float dither,
    float sceneDist
) {
    // Limit iterations to avoid performance issues
    int maxIter = min(positionCount, POLLUTION_FOG_MAX_CLOUDS);

    if (maxIter == 0){
        return vec4(0.0);
    }
    
    // Convert ray from view space to player space for correct intersection.
    // Ray origin in view space is (0,0,0), which maps to the camera position
    // in player space.
    vec3 rayOriginPlayer = gbufferModelViewInverse[3].xyz;
    vec3 rayDirPlayer = mat3(gbufferModelViewInverse) * normalize(viewPosition);

    // Accumulate fog from all pollution cloud ellipsoids
    vec3 totalColor = vec3(0.0);
    float totalAbsorbance = 1.0;

    for (int i = 0; i < maxIter; i++) {
        // Per-cloud half-extents from SSBO
        vec3 halfExtents = sizes[i];

        // Skip zero-size / origin clouds
        if (positions[i] == vec3(0.0) || halfExtents.x <= 0.0 || halfExtents.y <= 0.0 || halfExtents.z <= 0.0) {
            continue;
        }

        // Ellipsoid center in player space (positions[i] is world space)
        vec3 playerEllipsoidCenter = positions[i] - cameraPosition;

        // Render fog for this ellipsoid (all in player space)
        vec4 ellipsoidFog = pollution_render_fog_ellipsoid(
            rayOriginPlayer,
            rayDirPlayer,
            playerEllipsoidCenter,
            halfExtents,
            colors[i],
            dither,
            sceneDist
        );

        // Composite this ellipsoid's fog with the accumulated fog (front-to-back)
        float alpha = 1.0 - ellipsoidFog.a;
        totalColor = totalColor * ellipsoidFog.a + ellipsoidFog.rgb * alpha;
        totalAbsorbance *= ellipsoidFog.a;

        // Early exit if fully opaque
        if (totalAbsorbance < 0.01) break;
    }

    // Apply daylight tint: fog is dimmer at night, brighter during the day
    float daylight = pollution_get_daylight_factor();
    totalColor *= daylight;

    return vec4(totalColor, totalAbsorbance);
}

#endif // POLLUTION_FOG

#endif // INCLUDE_POLLUTION_FOG
