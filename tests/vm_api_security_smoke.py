#!/usr/bin/env python3
"""Live API input and authentication checks; uses only invalid usernames."""
import json
import secrets
import urllib.error
import urllib.request

settings = {}
with open('/etc/vpn/api.env', encoding='utf-8') as stream:
    for line in stream:
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.rstrip().split('=', 1)
            settings[key] = value
api_key = settings['API_KEY']
base = 'http://127.0.0.1:8088'

def post(username, key=api_key):
    payload = json.dumps({'service': 'ssh', 'username': username, 'days': 1}).encode()
    req = urllib.request.Request(base + '/v1/accounts', data=payload,
        headers={'X-API-Key': key, 'Content-Type': 'application/json'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=10) as response: return response.status
    except urllib.error.HTTPError as error: return error.code

for headers in ({}, {'X-API-Key': 'intentionally-wrong'}):
    req = urllib.request.Request(base + '/v1/status', headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5): raise AssertionError('unauthenticated status request unexpectedly succeeded')
    except urllib.error.HTTPError as error:
        assert error.code == 401

sentinel = '/tmp/vpn-pwn-' + secrets.token_hex(8)
assert not __import__('os').path.exists(sentinel)
for username in ('a;touch ' + sentinel, '$(id)', 'bad username', 'un?c?de'):
    assert post(username) == 422, 'invalid username was not rejected with HTTP 422'
assert not __import__('os').path.exists(sentinel), 'invalid username caused a sentinel file to be created'
print('Live API security smoke passed: missing/wrong key => 401; shell metacharacters, spaces, and Unicode => 422; no command ran.')
