"""Minimal reader/patcher for Android binary XML (AndroidManifest.xml)."""
import struct

def _strings(d):
    t, hs, size = struct.unpack_from('<HHI', d, 8)
    cnt, _, flags, sstart, _ = struct.unpack_from('<IIIII', d, 16)
    utf8 = flags & 0x100
    offs = struct.unpack_from('<%dI' % cnt, d, 8 + hs)
    out = []
    for o in offs:
        p = 8 + sstart + o
        if utf8:
            n = d[p]; p += 2 if n & 0x80 else 1
            n2 = d[p]; p += 1
            if n2 & 0x80: n2 = ((n2 & 0x7f) << 8) | d[p]; p += 1
            out.append((d[p:p + n2].decode('utf8'), p, n2, 'utf8'))
        else:
            n = struct.unpack_from('<H', d, p)[0]
            out.append((d[p + 2:p + 2 + 2 * n].decode('utf-16le'), p + 2, n, 'utf16'))
    return out, 8 + size

def attributes(d):
    """Yield (element, attr_name, value_type, data, offset_of_data) for every attribute."""
    strs, p = _strings(d)
    name = lambda i: strs[i][0] if i != 0xffffffff else None
    while p < len(d):
        t, hs, size = struct.unpack_from('<HHI', d, p)
        if t == 0x0102:  # start element
            ns, el, aoff, asz, acnt = struct.unpack_from('<IIHHH', d, p + 16)
            a = p + 16 + aoff
            for k in range(acnt):
                ans, an, araw, vsize, _, vtype, vdata = struct.unpack_from('<IIIHBBI', d, a + k * asz)
                yield name(el), name(an), vtype, vdata, a + k * asz + 16, (strs[araw][0] if araw != 0xffffffff else None)
        p += size

def strings(d):
    return _strings(d)[0]


def _encode(s, utf8):
    if utf8:
        b = s.encode('utf8')
        def ln(n):
            return bytes([n]) if n < 0x80 else bytes([0x80 | (n >> 8), n & 0xff])
        return ln(len(s)) + ln(len(b)) + b + b'\0'
    if len(s) > 0x7fff:
        raise ValueError('string too long')
    return struct.pack('<H', len(s)) + s.encode('utf-16le') + b'\0\0'


def replace_string(d, old, new):
    """Return a copy of the binary XML with string `old` in the string pool replaced by `new`.

    The pool is rebuilt, so the new string may have a different length. Other chunks refer to
    strings by index, so they stay valid; only the chunk and file sizes change.
    """
    t, hs, size = struct.unpack_from('<HHI', d, 8)
    cnt, styles, flags, sstart, stylestart = struct.unpack_from('<IIIII', d, 16)
    if t != 0x0001 or styles:
        raise ValueError('unsupported string pool')
    utf8 = bool(flags & 0x100)
    strs = [x[0] for x in _strings(d)[0]]
    if old not in strs:
        raise ValueError('string not found: %r' % old)
    strs = [new if x == old else x for x in strs]
    data, offs = b'', []
    for x in strs:
        offs.append(len(data))
        data += _encode(x, utf8)
    data += b'\0' * ((-len(data)) % 4)
    head = 28 + 4 * cnt
    pool = struct.pack('<HHIIIIII', 0x0001, hs, head + len(data), cnt, 0, flags, head, 0)
    pool += struct.pack('<%dI' % cnt, *offs) + data
    rest = d[8 + size:]
    body = pool + rest
    return struct.pack('<HHI', 0x0003, 8, 8 + len(body)) + body
