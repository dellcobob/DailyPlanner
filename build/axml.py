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
