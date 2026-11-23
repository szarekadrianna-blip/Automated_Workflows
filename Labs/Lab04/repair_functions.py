"""Three plausible implementations to investigate and repair. No syntax puzzles."""
import numpy as np

SPEC_VERSION = 1


def _plain(value):
    """Convert to canonical plain-JSON types and normalize equivalent numbers."""
    if isinstance(value, dict):
        return {str(k): _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    if isinstance(value, np.ndarray):
        return _plain(value.tolist())
    if isinstance(value, np.generic):
        return _plain(value.item())
    if isinstance(value, bool) or value is None or isinstance(value, (str, int)):
        return value
    if isinstance(value, float):
        if not np.isfinite(value):
            raise ValueError('NaN/Infinity cannot be part of a request spec')
        # 1 and 1.0 (and -0.0 / 0.0) are the same setting.
        return int(value) if value.is_integer() else value
    raise TypeError(f'Cannot canonicalize {type(value).__name__} in request spec')


def make_request_spec(science, inputs, environment, runtime):
    """Return (normalized_spec, fingerprint).

    Equivalence policy: the policy named in `environment['policy']`
    (exact_environment_v1 = any change to code, Python, relevant library
    versions or platform is a different request). Identity = scientific
    settings (including calibration values) + named inputs (exact artifact
    identity, checksum, lineage, raster interpretation) + recorded environment.
    `runtime` (output/log paths) is deliberately excluded.
    """
    import processing_store as store  # same canonical digest the checker uses
    spec = {
        'spec_version': SPEC_VERSION,
        'equivalence_policy': environment['policy'],
        'stage': science['stage'],
        'settings': science,
        # Sorted by role name: identity must not depend on dict/file order,
        # while the role itself stays part of identity (red/nir swapped differs).
        'inputs': [
            {
                'role': role,
                'artifact_id': inputs[role]['artifact_id'],
                'sha256': inputs[role]['sha256'],
                'size_bytes': inputs[role].get('size_bytes'),
                'lineage': inputs[role]['lineage'],
                'raster': inputs[role]['raster'],
            }
            for role in sorted(inputs)
        ],
        'environment': environment,
    }
    spec = _plain(spec)  # normalized, JSON-safe copy
    return spec, store.digest(spec)


def _lineage_value(inp, key):
    """Look in the lineage record first, then at the top level of the input."""
    lineage = inp.get('lineage')
    if isinstance(lineage, dict) and key in lineage:
        return lineage[key]
    return inp.get(key)


def _same_numbers(a, b):
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    return a.shape == b.shape and bool(np.allclose(a, b, rtol=1e-9, atol=0.0))


def _usable_number(value):
    return (isinstance(value, (int, float, np.integer, np.floating))
            and not isinstance(value, bool) and bool(np.isfinite(value)))


def validate_pair(red, nir):
    """Raise ValueError if metadata cannot justify a red/NIR calculation."""
    # Roles must really be red and nir (also rejects swapped arguments).
    for inp, expected in ((red, 'red'), (nir, 'nir')):
        found = _lineage_value(inp, 'asset_key')
        if found != expected:
            raise ValueError(f'Expected asset_key {expected!r}, found {found!r}')
    # Same grid is not enough: both bands must come from the same scene/AOI.
    for key in ('collection', 'item_id', 'aoi_key'):
        rv, nv = _lineage_value(red, key), _lineage_value(nir, key)
        if key == 'item_id' and (rv is None or nv is None):
            raise ValueError('Missing item_id in lineage')
        if rv != nv:
            raise ValueError(f'Input {key} differs: {rv!r} vs {nv!r}')
    r, n = red.get('raster'), nir.get('raster')
    if not isinstance(r, dict) or not isinstance(n, dict):
        raise ValueError('Missing raster metadata')
    # Calibration must be usable for each band (scale may differ per band).
    for label, meta in (('red', r), ('nir', n)):
        if not _usable_number(meta.get('scale')) or meta['scale'] == 0:
            raise ValueError(f'Missing or unusable scale for {label}')
        if not _usable_number(meta.get('offset')):
            raise ValueError(f'Missing or unusable offset for {label}')
    # Same pixel count is not enough: pixels must cover the same ground.
    for key in ('shape', 'crs', 'transform'):
        if r.get(key) is None or n.get(key) is None:
            raise ValueError(f'Missing {key} in raster metadata')
    if list(r['shape']) != list(n['shape']):
        raise ValueError('Input shapes differ')
    if r['crs'] != n['crs']:
        raise ValueError('Input CRS differ')
    if not _same_numbers(r['transform'], n['transform']):
        raise ValueError('Input transforms (grid origin/resolution) differ')
    if r.get('bounds') is not None and n.get('bounds') is not None \
            and not _same_numbers(r['bounds'], n['bounds']):
        raise ValueError('Input bounds differ')


def _to_physical(dn, meta):
    """DN -> float64 physical values, with nodata/non-finite set to NaN."""
    arr = np.asarray(dn).astype('float64')  # never subtract in uint16
    nodata = meta.get('nodata')
    invalid = ~np.isfinite(arr)
    if nodata is not None:
        invalid |= (arr == float(nodata))
    out = arr * float(meta.get('scale', 1.0)) + float(meta.get('offset', 0.0))
    out[invalid] = np.nan
    return out


def calculate_ndvi(red, nir, red_meta, nir_meta, epsilon):
    """Return float32 NDVI; invalid pixels must be NaN. Inputs are stored DN."""
    if np.shape(red) != np.shape(nir):
        raise ValueError('Input shapes differ')
    # The offset does NOT cancel in a ratio (only a shared pure scale does),
    # and each band may have its own scale/offset, so convert each band first.
    r = _to_physical(red, red_meta)
    n = _to_physical(nir, nir_meta)
    denom = n + r
    valid = np.isfinite(denom) & (np.abs(denom) > epsilon)
    out = np.full(denom.shape, np.nan, dtype='float64')
    np.divide(n - r, denom, out=out, where=valid)
    return (out + 0.0).astype('float32')  # + 0.0 turns -0.0 into 0.0