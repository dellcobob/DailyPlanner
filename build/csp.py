#!/usr/bin/env python3
"""Keep the planner's Content-Security-Policy in sync with its inline scripts.

The page only allows the exact inline scripts it ships with (by SHA-256 hash), and
blocks every network request. Run this after editing the HTML:

  python3 build/csp.py            # update the policy in Daily_Missions.html
  python3 build/csp.py --check    # exit 1 if the policy is out of date
"""
import base64, hashlib, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, 'Daily_Missions.html')
SCRIPTS = ('theme-boot', 'app')
META = re.compile(r'<meta http-equiv="Content-Security-Policy" content="[^"]*">')


def policy(html):
    hashes = []
    for sid in SCRIPTS:
        m = re.search(r'<script id="%s">(.*?)</script>' % re.escape(sid), html, re.S)
        if not m:
            raise SystemExit('script #%s not found' % sid)
        hashes.append("'sha256-%s'" % base64.b64encode(hashlib.sha256(m.group(1).encode('utf-8')).digest()).decode())
    # Every other inline script must be a non-executing data block.
    outside = re.sub(r'(<script\b[^>]*>).*?</script>', r'\1</script>', html, flags=re.S)
    for tag in re.findall(r'<script\b[^>]*>', outside):
        if not (re.search(r'id="(%s)"' % '|'.join(SCRIPTS), tag) or 'type="application/json"' in tag):
            raise SystemExit('unexpected script tag: ' + tag)
    return ("default-src 'none'; script-src %s; style-src 'unsafe-inline'; img-src data: blob:; "
            "base-uri 'none'; form-action 'none'; object-src 'none'; connect-src 'none'; "
            "worker-src 'none'; manifest-src 'none'" % ' '.join(hashes))


def current(html):
    m = META.search(html)
    return m.group(0) if m else None


def expected(html):
    return '<meta http-equiv="Content-Security-Policy" content="%s">' % policy(html)


def main():
    with open(HTML, encoding='utf-8') as f:
        html = f.read()
    want, have = expected(html), current(html)
    if have is None:
        raise SystemExit('policy meta tag not found')
    if '--check' in sys.argv:
        if want != have:
            raise SystemExit('Content-Security-Policy is out of date. Run: python3 build/csp.py')
        print('Content-Security-Policy is up to date.')
        return
    if want != have:
        with open(HTML, 'w', encoding='utf-8') as f:
            f.write(html.replace(have, want))
        print('Updated Content-Security-Policy.')
    else:
        print('Content-Security-Policy already up to date.')


if __name__ == '__main__':
    main()
