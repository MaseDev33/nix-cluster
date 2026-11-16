import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).with_name("discover-nas.py")
SPEC = importlib.util.spec_from_file_location("discover_nas", SCRIPT)
nas = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nas)


class NasDiscoveryTests(unittest.TestCase):
    def test_selects_unique_large_btrfs_filesystem(self):
        document = {
            "blockdevices": [
                {"path": "/dev/sda1", "size": 16000000000, "fstype": "ext4", "uuid": "boot"},
                {"path": "/dev/sdb1", "size": 4000000000000, "fstype": "btrfs", "uuid": "nas"},
            ]
        }
        self.assertEqual(nas.discover(document, 3500000000000), "nas")

    def test_refuses_multiple_large_btrfs_candidates(self):
        document = {
            "blockdevices": [
                {"path": "/dev/sdb1", "size": 4000000000000, "fstype": "btrfs", "uuid": "nas-a"},
                {"path": "/dev/sdc1", "size": 4000000000000, "fstype": "btrfs", "uuid": "nas-b"},
            ]
        }
        with self.assertRaises(ValueError):
            nas.discover(document, 3500000000000)

    def test_refuses_small_btrfs_filesystem(self):
        document = {
            "blockdevices": [
                {"path": "/dev/sda1", "size": 16000000000, "fstype": "btrfs", "uuid": "boot"}
            ]
        }
        with self.assertRaises(ValueError):
            nas.discover(document, 3500000000000)


if __name__ == "__main__":
    unittest.main()
