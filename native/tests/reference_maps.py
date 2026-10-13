"""Compare every detector output to a compact, independently frozen reference."""
import numpy as np

SCALE = 65535
ENCODING_ERROR = 0.5 / SCALE
ATOL = 1e-3
RTOL = 1e-4


def compare_detector(actual, encoded):
    assert actual.dtype == np.float32 and encoded.dtype == np.uint16
    assert actual.ndim == 1 and actual.shape == encoded.shape and actual.size > 0
    assert np.isfinite(actual).all() and (actual >= 0).all() and (actual <= 1).all()
    expected = encoded.astype(np.float64) / SCALE
    # This rounding applies ONLY to stored test expectations, never inference.
    # Allow the established numerical tolerance plus the bounded encoding error.
    np.testing.assert_allclose(actual, expected, atol=ATOL + ENCODING_ERROR, rtol=RTOL)
    return float(np.max(np.abs(actual.astype(np.float64) - expected)))
