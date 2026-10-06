import base64
import json
import unittest

from api.main import _xray_connection


class XrayLinkTests(unittest.TestCase):
    def test_vmess_link_contains_tls_websocket_profile(self):
        link = _xray_connection(
            "vmess",
            "vm1.brutalx.my.id",
            {"uuid": "00000000-0000-4000-8000-000000000000", "username": "testuser"},
            {"vmess": {"ws_tls": True}},
        )["links"]["ws_tls"]
        profile = json.loads(base64.b64decode(link.removeprefix("vmess://")))

        self.assertEqual(profile["add"], "vm1.brutalx.my.id")
        self.assertEqual(profile["port"], "443")
        self.assertEqual(profile["id"], "00000000-0000-4000-8000-000000000000")
        self.assertEqual(profile["net"], "ws")
        self.assertEqual(profile["path"], "/vmess")
        self.assertEqual(profile["tls"], "tls")


if __name__ == "__main__":
    unittest.main()
