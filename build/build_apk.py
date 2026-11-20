#!/usr/bin/env python3
"""Rebuild the Morning Missions Android app around a new planner HTML file.

The native shell (WebView, file save, print, back button) comes from build/wrapper.apk.
This script swaps in the new assets/index.html, optionally bumps the version,
keeps stored entries 4-byte aligned, and signs with APK Signature Scheme v2.

  python3 build/build_apk.py --key signing/key.pem --cert signing/cert.pem
  python3 build/build_apk.py --new-key signing/   # first time: make a signing key

Keep the key files private and reuse them for every update. Android only installs
an update over the app when it is signed with the same key.
"""
import argparse, datetime, hashlib, io, os, struct, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import axml  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V2_BLOCK_ID = 0x7109871A
RSA_PKCS1_SHA256 = 0x0103
CHUNK = 1024 * 1024


def u32(n): return struct.pack('<I', n)
def u64(n): return struct.pack('<Q', n)
def lp(b): return u32(len(b)) + b


def make_key(folder):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    os.makedirs(folder, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Morning Missions')])
    now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=365 * 40))
            .sign(key, hashes.SHA256()))
    kp, cp = os.path.join(folder, 'key.pem'), os.path.join(folder, 'cert.pem')
    with open(kp, 'wb') as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    os.chmod(kp, 0o600)
    with open(cp, 'wb') as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    return kp, cp


def patch_manifest(data, code, name):
    d = bytearray(data)
    for el, attr, vtype, vdata, off, raw in axml.attributes(bytes(d)):
        if el == 'manifest' and attr == 'versionCode' and code is not None:
            struct.pack_into('<I', d, off, code)
    if name is not None:
        cur = next(raw for el, attr, _t, _v, _o, raw in axml.attributes(bytes(d)) if el == 'manifest' and attr == 'versionName')
        for s, pos, n, enc in axml.strings(bytes(d)):
            if s == cur:
                if len(name) != n or not name.isascii():
                    raise SystemExit('versionName must be ASCII and keep the original length (%d characters)' % n)
                new = name.encode('utf8' if enc == 'utf8' else 'utf-16le')
                d[pos:pos + len(new)] = new
                break
    return bytes(d)


def build_zip(base, html, code, name):
    src = zipfile.ZipFile(base)
    out = io.BytesIO()
    dst = zipfile.ZipFile(out, 'w')
    for info in src.infolist():
        fn = info.filename
        if fn.startswith('META-INF/') and fn.rsplit('.', 1)[-1].upper() in ('SF', 'RSA', 'DSA', 'EC', 'MF'):
            continue  # old v1 signature files
        data = src.read(fn)
        if fn == 'assets/index.html':
            data = html
        elif fn == 'AndroidManifest.xml' and (code is not None or name is not None):
            data = patch_manifest(data, code, name)
        zi = zipfile.ZipInfo(fn, date_time=(1981, 1, 1, 1, 1, 2))
        zi.compress_type = info.compress_type
        zi.external_attr = info.external_attr
        zi.create_system = 0
        if zi.compress_type == zipfile.ZIP_STORED:
            # Align stored data to 4 bytes with a zipalign-style extra field (0xD935).
            start = out.tell() + 30 + len(fn.encode())
            pad = (-(start + 6)) % 4
            zi.extra = struct.pack('<HHH', 0xD935, 2 + pad, 4) + b'\0' * pad
        dst.writestr(zi, data)
    dst.close()
    return out.getvalue()


def chunk_digest(sections):
    chunks = []
    for s in sections:
        for i in range(0, len(s), CHUNK):
            c = s[i:i + CHUNK]
            chunks.append(hashlib.sha256(b'\xa5' + u32(len(c)) + c).digest())
    return hashlib.sha256(b'\x5a' + u32(len(chunks)) + b''.join(chunks)).digest()


def sign_v2(apk, key_pem, cert_pem):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    key = serialization.load_pem_private_key(key_pem, password=None)
    cert = x509.load_pem_x509_certificate(cert_pem)
    cert_der = cert.public_bytes(serialization.Encoding.DER)
    pub_der = cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    eocd = apk.rfind(b'PK\x05\x06')
    if eocd < 0 or len(apk) - eocd != 22:
        raise SystemExit('Unexpected zip layout')
    cd_size, cd_off = struct.unpack_from('<II', apk, eocd + 12)
    entries, cd, end = apk[:cd_off], apk[cd_off:eocd], apk[eocd:]
    digest = chunk_digest([entries, cd, end])
    signed = lp(lp(u32(RSA_PKCS1_SHA256) + lp(digest))) + lp(lp(cert_der)) + lp(b'')
    sig = key.sign(signed, padding.PKCS1v15(), hashes.SHA256())
    signer = lp(signed) + lp(lp(u32(RSA_PKCS1_SHA256) + lp(sig))) + lp(pub_der)
    value = lp(lp(signer))
    pair = u64(4 + len(value)) + u32(V2_BLOCK_ID) + value
    size = len(pair) + 8 + 16
    block = u64(size) + pair + u64(size) + b'APK Sig Block 42'
    end = bytearray(end)
    struct.pack_into('<I', end, 16, cd_off + len(block))
    return entries + block + cd + bytes(end)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', default=os.path.join(ROOT, 'build', 'wrapper.apk'))
    ap.add_argument('--html', default=os.path.join(ROOT, 'Morning_Missions_Tracker.html'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'Morning_Missions_Android.apk'))
    ap.add_argument('--key'); ap.add_argument('--cert')
    ap.add_argument('--new-key', metavar='FOLDER', help='create key.pem and cert.pem in FOLDER, then build')
    ap.add_argument('--version-code', type=int, default=2)
    ap.add_argument('--version-name', default='2.0.0')
    a = ap.parse_args()
    if a.new_key:
        a.key, a.cert = make_key(a.new_key)
        print('New signing key:', a.key, a.cert)
    if not (a.key and a.cert):
        ap.error('pass --key and --cert, or --new-key FOLDER')
    with open(a.html, 'rb') as f:
        html = f.read()
    unsigned = build_zip(a.base, html, a.version_code, a.version_name)
    with open(a.key, 'rb') as k, open(a.cert, 'rb') as c:
        apk = sign_v2(unsigned, k.read(), c.read())
    with open(a.out, 'wb') as f:
        f.write(apk)
    print('Wrote %s (%d bytes, sha256 %s)' % (a.out, len(apk), hashlib.sha256(apk).hexdigest()))


if __name__ == '__main__':
    main()
