#!/usr/bin/env python3
"""Isolated Xray runtime refusal test; never edits the live Xray config."""
import json
import os
import tempfile
from pathlib import Path

from vpnctl.drivers.xray import XrayDriver

with tempfile.TemporaryDirectory(prefix='vpn-xray-rollback-', dir='/run/vpn') as directory:
    config_path = Path(directory) / 'config.json'
    config = {
        'inbounds': [{
            'tag': 'codex-rollback-vmess', 'listen': '127.0.0.1', 'port': 10001,
            'protocol': 'vmess', 'settings': {'clients': []},
        }],
        'outbounds': [],
    }
    config_path.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    before = config_path.read_bytes()
    driver = XrayDriver(config_path=str(config_path), api_server='127.0.0.1:1')
    try:
        driver.create('vmess', 'codexrollback', 1893456000)
    except Exception as exc:
        print(f'Runtime refusal observed: {type(exc).__name__}.')
    else:
        raise AssertionError('Expected the isolated unavailable Xray API endpoint to reject account creation')
    after = config_path.read_bytes()
    assert after == before, 'Xray config was not restored byte-for-byte after runtime failure'
    restored = json.loads(after)
    assert restored['inbounds'][0]['settings']['clients'] == []
    print('Xray rollback passed: isolated config restored byte-for-byte; no account remained.')
