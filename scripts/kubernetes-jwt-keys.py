#!/usr/bin/env python3
"""Export Kubernetes RSA signing keys for offline Vault JWT validation."""
import base64, json, subprocess
def der(tag, value):
    n = len(value)
    length = bytes([n]) if n < 128 else bytes([128 + (n.bit_length()+7)//8]) + n.to_bytes((n.bit_length()+7)//8, 'big')
    return bytes([tag]) + length + value
def integer(value):
    raw = base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
    return der(2, b'\x00' + raw if raw[0] & 128 else raw)
keys = json.loads(subprocess.check_output(['kubectl', 'get', '--raw=/openid/v1/jwks']))['keys']
result = []
for key in keys:
    if key['kty'] != 'RSA':
        raise SystemExit('Unsupported Kubernetes signing key type: ' + key['kty'])
    rsa = der(48, integer(key['n']) + integer(key['e']))
    spki = der(48, bytes.fromhex('300d06092a864886f70d0101010500') + der(3, b'\x00' + rsa))
    text = base64.b64encode(spki).decode()
    result.append('-----BEGIN PUBLIC KEY-----\n' + '\n'.join(text[i:i+64] for i in range(0,len(text),64)) + '\n-----END PUBLIC KEY-----\n')
print(json.dumps(result))
