"""Safety checks for the compact full-map reference comparator."""
import unittest
import numpy as np
from reference_maps import ATOL, ENCODING_ERROR, compare_detector


class ReferenceTests(unittest.TestCase):
    def test_exact_and_rounding(self):
        # Exercise all representable bins, including endpoints.
        actual = np.linspace(0, 1, 65536, dtype=np.float32)
        encoded = np.arange(65536, dtype=np.uint16)
        self.assertLessEqual(compare_detector(actual, encoded), ENCODING_ERROR)

    def test_tolerance_and_rejection(self):
        encoded = np.array([0, 32768, 65535], dtype=np.uint16)
        within = encoded.astype(np.float32) / 65535
        within[0] += ATOL * 0.99
        compare_detector(within, encoded)
        outside = within.copy()
        outside[0] = ATOL + ENCODING_ERROR + 1e-5
        with self.assertRaises(AssertionError):
            compare_detector(outside, encoded)
        # Every element matters, not only a sampled subset.
        actual = np.zeros(10000, dtype=np.float32)
        actual[4321] = 0.1
        with self.assertRaises(AssertionError):
            compare_detector(actual, np.zeros(10000, dtype=np.uint16))

    def test_bad_inputs(self):
        encoded = np.zeros(1, dtype=np.uint16)
        for actual in (np.array([np.nan], dtype=np.float32),
                       np.array([-0.1], dtype=np.float32),
                       np.array([1.1], dtype=np.float32),
                       np.zeros(1, dtype=np.float64),
                       np.zeros((1, 1), dtype=np.float32),
                       np.zeros(2, dtype=np.float32)):
            with self.subTest(actual=actual):
                with self.assertRaises(AssertionError):
                    compare_detector(actual, encoded)
        with self.assertRaises(AssertionError):
            compare_detector(np.zeros(1, dtype=np.float32), np.zeros(1, dtype=np.float32))
        with self.assertRaises(AssertionError):
            compare_detector(np.zeros(0, dtype=np.float32), np.zeros(0, dtype=np.uint16))


if __name__ == '__main__':
    unittest.main()
