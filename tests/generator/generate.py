"""
Write the asm-snappy vector files.

Usage: generate.py OUT_DIR
Environment: SNAPPY_SOURCE, the google/snappy checkout at the pinned commit,
and SNAPPY_LIBRARY, its shared library (run.sh builds both).

Expected results:
- Block format: the google/snappy library at the pinned commit, through its C
  interface. cramjam 2.11.0 (requirements.txt), the library under the
  python-snappy that consensus-specs pins, must agree on every case.
- Framing format: the model in frame_model(), which follows framing_format.txt
  and the requirements of snappy_frame_uncompress. It uses google/snappy for
  each compressed chunk. cramjam must agree wherever the case allows a check.
The file format is in README.md.
"""

import ctypes
import hashlib
import os
import random
import re
import struct
import sys
import tarfile
import urllib.request

import cramjam

# include/snappy.inc
OK, BUFFER_TOO_SMALL, CORRUPT, TOO_LARGE = 0, 1, 2, 3
STREAM_IDENTIFIER, UNSKIPPABLE_CHUNK, CHUNK_LENGTH, CHECKSUM, TRUNCATED, TOO_LONG = 4, 5, 6, 7, 8, 9

KIND_BLOCK_VALID, KIND_BLOCK_REJECT, KIND_FRAME_VALID, KIND_FRAME_REJECT, KIND_COMPRESS = 1, 2, 3, 4, 5

TESTDATA = [
    "alice29.txt", "asyoulik.txt", "fireworks.jpeg", "geo.protodata", "html", "html_x_4",
    "kppkn.gtb", "lcet10.txt", "paper-100k.pdf", "plrabn12.txt", "urls.10K",
]
BADDATA = ["baddata1.snappy", "baddata2.snappy", "baddata3.snappy"]

CONSENSUS_RELEASE = "v1.7.0-beta.4"
CONSENSUS_URL = "https://github.com/ethereum/consensus-specs/releases/download/" + CONSENSUS_RELEASE + "/"
CONSENSUS_ARCHIVE = ("minimal.tar.gz", "26d09aea70c62ed235a120a95082d544ab1c2e6fe36bd35ea1bd5da62f3b7b68")
# The live mainnet forks only.
CONSENSUS_CASES = re.compile(
    r"tests/minimal/(phase0|altair|bellatrix|capella|deneb|electra|fulu)/ssz_static/[A-Za-z0-9]+/ssz_random/case_[0-4]/serialized\.ssz_snappy$"
)

disagreements = []

# Block cases where cramjam differs from google/snappy, the pinned reference.
# The vectors keep the google/snappy result. Any other difference stops the run.
# - A literal in long form, at the end of the input, with fewer than 4 bytes of
#   length and data: google/snappy accepts it, cramjam rejects it.
# - A length header of 6 to 10 bytes: google/snappy rejects it, cramjam accepts it.
KNOWN_DISAGREEMENTS = re.compile(r"^block crafted_(literal_[12]_form_[12]|header_([6-9]|10)_bytes):")


# ---------------------------------------------------------------- References


class Reference:
    """google/snappy through its C interface (snappy-c.h)."""

    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        self.lib.snappy_max_compressed_length.restype = ctypes.c_size_t
        self.lib.snappy_max_compressed_length.argtypes = [ctypes.c_size_t]

    def uncompressed_length(self, data):
        n = ctypes.c_size_t(0)
        status = self.lib.snappy_uncompressed_length(data, ctypes.c_size_t(len(data)), ctypes.byref(n))
        return (status == 0), n.value

    def uncompress(self, data):
        ok, n = self.uncompressed_length(data)
        if not ok:
            return None
        buf = ctypes.create_string_buffer(max(n, 1))
        size = ctypes.c_size_t(n)
        if self.lib.snappy_uncompress(data, ctypes.c_size_t(len(data)), buf, ctypes.byref(size)) != 0:
            return None
        return buf.raw[:n]

    def compress(self, data):
        cap = self.lib.snappy_max_compressed_length(len(data))
        buf = ctypes.create_string_buffer(max(cap, 1))
        size = ctypes.c_size_t(cap)
        assert self.lib.snappy_compress(data, ctypes.c_size_t(len(data)), buf, ctypes.byref(size)) == 0
        return buf.raw[: size.value]


def cramjam_uncompress(data):
    try:
        return bytes(cramjam.snappy.decompress_raw(data))
    except Exception:
        return None


def cramjam_frame_uncompress(data):
    try:
        return bytes(cramjam.snappy.decompress(data))
    except Exception:
        return None


def block_uncompress(ref, data, name):
    """google/snappy's result for data, after checking that cramjam agrees."""
    got = ref.uncompress(data)
    other = cramjam_uncompress(data)
    if got != other:
        disagreements.append(f"block {name}: google/snappy {'accepts' if got is not None else 'rejects'}, "
                             f"cramjam {'accepts' if other is not None else 'rejects'}: {data[:48].hex()}")
    return got


# ---------------------------------------------------------------- CRC-32C


def _crc_table():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
        table.append(c)
    return table


CRC_TABLE = _crc_table()


def masked_crc32c(data):
    c = 0xFFFFFFFF
    for b in data:
        c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >> 8)
    c ^= 0xFFFFFFFF
    return (((c >> 15) | (c << 17)) + 0xA282EAD8) & 0xFFFFFFFF


# ---------------------------------------------------------------- Builders


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def literal(data, form=None):
    """A literal element. form: None for the shortest, or 0 to 4 extra length bytes."""
    n = len(data) - 1
    if form is None:
        form = 0 if n < 60 else 1 if n < 1 << 8 else 2 if n < 1 << 16 else 3 if n < 1 << 24 else 4
    if form == 0:
        return bytes([n << 2]) + data
    return bytes([(59 + form) << 2]) + n.to_bytes(form, "little") + data


def copy1(offset, length):
    return bytes([((offset >> 8) << 5) | ((length - 4) << 2) | 1, offset & 0xFF])


def copy2(offset, length):
    return bytes([((length - 1) << 2) | 2]) + offset.to_bytes(2, "little")


def copy4(offset, length):
    return bytes([((length - 1) << 2) | 3]) + offset.to_bytes(4, "little")


def chunk(kind, body):
    return bytes([kind]) + len(body).to_bytes(3, "little") + body


STREAM_ID = chunk(0xFF, b"sNaPpY")


def data_chunk(raw, compressed=True, crc=None):
    crc = masked_crc32c(raw) if crc is None else crc
    body = cramjam_raw(raw) if compressed else raw
    return chunk(0x00 if compressed else 0x01, crc.to_bytes(4, "little") + body)


def cramjam_raw(raw):
    return bytes(cramjam.snappy.compress_raw(raw))


# ---------------------------------------------------------------- Framing model


def frame_model(ref, data, n):
    """(status, consumed, output, end of the chunk with the fault) for snappy_frame_uncompress."""
    if n == 0:
        return OK, 0, b"", 0
    pos, out, first = 0, bytearray(), True
    while len(out) < n:
        if pos + 4 > len(data):
            return TRUNCATED, 0, b"", None
        kind = data[pos]
        length = int.from_bytes(data[pos + 1 : pos + 4], "little")
        end = pos + 4 + length
        if first and kind != 0xFF:
            return STREAM_IDENTIFIER, 0, b"", min(end, len(data))
        if 0x02 <= kind <= 0x7F:
            return UNSKIPPABLE_CHUNK, 0, b"", min(end, len(data))
        if end > len(data):
            return TRUNCATED, 0, b"", None
        body = data[pos + 4 : end]
        if kind == 0xFF:
            if body != b"sNaPpY":
                return STREAM_IDENTIFIER, 0, b"", end
        elif kind in (0x00, 0x01):
            if length < 4:
                return CHUNK_LENGTH, 0, b"", end
            crc, payload = int.from_bytes(body[:4], "little"), body[4:]
            if kind == 0x01:
                if len(payload) > 65536:
                    return CHUNK_LENGTH, 0, b"", end
                if len(payload) > n - len(out):
                    return TOO_LONG, 0, b"", None
                raw = payload
            else:
                ok, size = ref.uncompressed_length(payload)
                if not ok:
                    return CORRUPT, 0, b"", end
                if size > 65536:
                    return CHUNK_LENGTH, 0, b"", end
                if size > n - len(out):
                    return TOO_LONG, 0, b"", None
                raw = ref.uncompress(payload)
                if raw is None:
                    return CORRUPT, 0, b"", end
            if masked_crc32c(raw) != crc:
                return CHECKSUM, 0, b"", end
            out += raw
        pos = end
        first = False
    return OK, pos, bytes(out), None


def frame_case(ref, data, n, name, valid, reject):
    status, consumed, output, fault_end = frame_model(ref, data, n)
    if status == OK:
        if n and cramjam_frame_uncompress(data[:consumed]) != output:
            disagreements.append(f"frame {name}: cramjam does not give the model's output")
        valid.add(name, blob(data) + u64(n) + u64(consumed) + blob(output))
    else:
        if fault_end is not None and status != STREAM_IDENTIFIER and cramjam_frame_uncompress(data[:fault_end]) is not None:
            disagreements.append(f"frame {name}: cramjam accepts what the model refuses with {status}")
        reject.add(name, blob(data) + u64(n) + u64(status))


# ---------------------------------------------------------------- Files


def u64(v):
    return struct.pack("<Q", v)


def blob(b):
    return u64(len(b)) + b


class VectorFile:
    def __init__(self, kind):
        self.kind, self.cases, self.seen = kind, [], set()

    def add(self, name, body):
        key = hashlib.sha256(body).digest()
        if key in self.seen:
            return
        self.seen.add(key)
        self.cases.append(blob(name.encode()) + body)

    def write(self, path):
        with open(path, "wb") as f:
            f.write(b"SNPVEC01" + u64(self.kind) + u64(len(self.cases)))
            for c in self.cases:
                f.write(c)


def fetch(out, url, name, sha256):
    path = os.path.join(out, "sources", name)
    if os.path.exists(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        if h.hexdigest() == sha256:
            return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "asm-snappy-generator"})
    h = hashlib.sha256()
    with urllib.request.urlopen(request) as r, open(path + ".part", "wb") as f:
        for block in iter(lambda: r.read(1 << 20), b""):
            h.update(block)
            f.write(block)
    if h.hexdigest() != sha256:
        sys.exit(f"{name}: SHA-256 {h.hexdigest()}, pinned {sha256}")
    os.replace(path + ".part", path)
    return path


# ---------------------------------------------------------------- Inputs


def inputs(rng):
    """Uncompressed inputs: sizes around every boundary, with several kinds of content."""
    out = []
    sizes = list(range(0, 80)) + [100, 255, 256, 257, 1000, 4095, 4096, 4097, 65535, 65536, 65537,
                                  2 * 65536 + 7, 1 << 20]
    for size in sizes:
        out.append((f"zeros_{size}", bytes(size)))
        out.append((f"random_{size}", bytes(rng.randrange(256) for _ in range(size))))
        text = b"the quick brown fox jumps over the lazy dog, " * (size // 45 + 1)
        out.append((f"text_{size}", text[:size]))
    for period in (1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 64, 65, 1000, 2047, 2048, 2049, 65535, 65536):
        unit = bytes(rng.randrange(256) for _ in range(period))
        out.append((f"period_{period}", (unit * (300000 // period + 1))[:300000]))
    # Half random, half repeats: literals and copies of every length.
    mixed = bytearray()
    while len(mixed) < 1 << 20:
        if rng.random() < 0.5:
            mixed += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 300)))
        elif len(mixed) > 4:
            back = rng.randrange(1, min(len(mixed), 70000))
            for _ in range(rng.randrange(4, 200)):
                mixed.append(mixed[-back])
    out.append(("mixed_1MiB", bytes(mixed)))
    return out


def crafted_blocks(rng):
    """Hand-built block streams: every element form, and faults."""
    cases = []
    data = bytes(rng.randrange(256) for _ in range(70000))
    for n in (1, 2, 59, 60, 61, 62, 255, 256, 257, 65535, 65536, 65537):
        part = (data * 4)[:n]
        for form in range(0, 5):
            if form == 0 and n > 60:
                continue
            if form and n - 1 >= 1 << (8 * form):
                continue
            cases.append((f"literal_{n}_form_{form}", varint(n) + literal(part, form)))
    long = bytes(rng.randrange(256) for _ in range((1 << 24) + 3))
    cases.append(("literal_2_24_plus_3", varint(len(long)) + literal(long)))
    seed = bytes(rng.randrange(256) for _ in range(2048))
    for length in range(4, 12):
        for offset in (1, 2, 3, 7, 8, 255, 256, 1024, 2047):
            cases.append((f"copy1_len_{length}_off_{offset}", varint(2048 + length) + literal(seed, 2) + copy1(offset, length)))
    for length in (1, 2, 4, 8, 16, 33, 63, 64):
        for offset in (1, 3, 8, 2048, 65535):
            base = (seed * 40)[: max(offset, 1)]
            cases.append((f"copy2_len_{length}_off_{offset}", varint(len(base) + length) + literal(base) + copy2(offset, length)))
            cases.append((f"copy4_len_{length}_off_{offset}", varint(len(base) + length) + literal(base) + copy4(offset, length)))
    far = bytes(rng.randrange(256) for _ in range(70000))
    for offset in (65536, 65537, 69999, 70000):
        cases.append((f"copy4_far_{offset}", varint(70000 + 64) + literal(far) + copy4(offset, 64)))
    cases.append(("overlap_run", varint(1 + 64 * 100) + literal(b"z") + copy2(1, 64) * 100))
    cases.append(("empty", varint(0)))
    cases.append(("empty_long_header", b"\x80\x00"))
    cases.append(("two_literals", varint(6) + literal(b"abc") + literal(b"def")))
    cases.append(("header_max_5_bytes", b"\x80\x80\x80\x80\x0f"))
    # Faults.
    cases.append(("no_input", b""))
    for k in range(6, 11):
        cases.append((f"header_{k}_bytes", b"\x80" * (k - 1) + b"\x00"))
    cases.append(("header_5th_byte_16", b"\x80\x80\x80\x80\x10"))
    cases.append(("header_cut", b"\x80"))
    cases.append(("copy_offset_0", varint(8) + literal(b"abcd") + copy2(0, 4)))
    cases.append(("copy_before_start", varint(9) + literal(b"abcd") + copy2(5, 4)))
    cases.append(("copy_first", varint(4) + copy1(1, 4)))
    cases.append(("copy_past_end", varint(7) + literal(b"abcd") + copy2(4, 4)))
    cases.append(("literal_past_end", varint(3) + literal(b"abcd")))
    cases.append(("literal_cut", varint(4) + literal(b"abcd")[:-1]))
    cases.append(("output_short", varint(5) + literal(b"abcd")))
    cases.append(("trailing_tag", varint(4) + literal(b"abcd") + b"\x02"))
    cases.append(("literal_length_2_32", varint(4) + b"\xfc\xff\xff\xff\xff" + b"abcd"))
    cases.append(("literal_length_bytes_cut", varint(70) + b"\xf4\x45"[:1]))
    cases.append(("copy4_offset_huge", varint(8) + literal(b"abcd") + copy4(0xFFFFFFFF, 4)))
    return cases


def mutations(enc, rng, limit):
    out = []
    for k in range(min(len(enc), limit)):
        out.append((f"cut_{k}", enc[:k]))
    for b in (0x00, 0x01, 0x02, 0x03, 0xFF):
        out.append((f"extend_{b:02x}", enc + bytes([b])))
    for i in range(min(len(enc), limit)):
        for v in (0x00, 0x01, 0x02, 0x03, 0x7F, 0x80, 0xFC, 0xFF, enc[i] ^ 0x01, enc[i] ^ 0x80):
            if v != enc[i]:
                out.append((f"byte_{i}_{v:02x}", enc[:i] + bytes([v]) + enc[i + 1 :]))
    return out


# ---------------------------------------------------------------- Main


def main(out):
    assert cramjam.__version__ == "2.11.0", cramjam.__version__
    ref = Reference(os.environ["SNAPPY_LIBRARY"])
    source = os.environ["SNAPPY_SOURCE"]
    rng = random.Random(1478)
    bv, br = VectorFile(KIND_BLOCK_VALID), VectorFile(KIND_BLOCK_REJECT)
    fv, fr = VectorFile(KIND_FRAME_VALID), VectorFile(KIND_FRAME_REJECT)
    cv = VectorFile(KIND_COMPRESS)
    official = {"bv": VectorFile(KIND_BLOCK_VALID), "br": VectorFile(KIND_BLOCK_REJECT), "cv": VectorFile(KIND_COMPRESS)}

    def block(name, enc, valid, reject):
        raw = block_uncompress(ref, enc, name)
        if raw is not None:
            valid.add(name, blob(enc) + blob(raw))
        else:
            ok, size = ref.uncompressed_length(enc)
            reject.add(name, blob(enc) + u64(OK if ok else CORRUPT) + u64(size if ok else 0))

    # Official: the google/snappy test corpus, and its bad inputs.
    for name in TESTDATA:
        with open(os.path.join(source, "testdata", name), "rb") as f:
            raw = f.read()
        official["cv"].add(f"testdata/{name}", blob(raw))
        block(f"testdata/{name}", ref.compress(raw), official["bv"], official["br"])
    for name in BADDATA:
        with open(os.path.join(source, "testdata", name), "rb") as f:
            block(f"testdata/{name}", f.read(), official["bv"], official["br"])

    # Official: consensus-spec-tests ssz_static encodings, made by python-snappy.
    archive = fetch(out, CONSENSUS_URL + CONSENSUS_ARCHIVE[0], CONSENSUS_ARCHIVE[0], CONSENSUS_ARCHIVE[1])
    consensus = VectorFile(KIND_BLOCK_VALID)
    consensus_reject = VectorFile(KIND_BLOCK_REJECT)
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile() and CONSENSUS_CASES.search(member.name):
                enc = tar.extractfile(member).read()
                block(member.name.split("tests/", 1)[1], enc, consensus, consensus_reject)
    assert not consensus_reject.cases, "a consensus-spec-tests encoding does not decode"

    # Generated block cases.
    small = []
    for name, raw in inputs(rng):
        cv.add(name, blob(raw))
        for who, enc in (("google", ref.compress(raw)), ("cramjam", cramjam_raw(raw))):
            block(f"{who}_{name}", enc, bv, br)
            if len(enc) <= 64:
                small.append(enc)
    for name, enc in crafted_blocks(rng):
        block(f"crafted_{name}", enc, bv, br)
        if len(enc) <= 64:
            small.append(enc)
    for i, enc in enumerate(small[:400]):
        for change, m in mutations(enc, rng, 64):
            block(f"mutation_{i}_{change}", m, bv, br)

    # Generated framing cases.
    for name, raw in inputs(rng):
        framed = bytes(cramjam.snappy.compress(raw))
        frame_case(ref, framed, len(raw), f"cramjam_{name}", fv, fr)
        if len(raw) > 1:
            frame_case(ref, framed, len(raw) - 1, f"cramjam_{name}_one_short", fv, fr)
            frame_case(ref, framed[:-1], len(raw), f"cramjam_{name}_cut", fv, fr)
    raw = bytes(rng.randrange(256) for _ in range(200000))
    parts = [raw[:65536], raw[65536:131072], raw[131072:]]
    built = {
        "uncompressed_chunks": STREAM_ID + b"".join(data_chunk(p, False) for p in parts),
        "mixed_chunks": STREAM_ID + data_chunk(parts[0]) + data_chunk(parts[1], False) + data_chunk(parts[2]),
        "padding_and_skippable": STREAM_ID + chunk(0xFE, bytes(10)) + data_chunk(parts[0]) + chunk(0x80, b"x")
        + chunk(0xFD, bytes(300)) + data_chunk(parts[1]) + chunk(0xFE, b"") + data_chunk(parts[2]),
        "repeated_identifier": STREAM_ID + data_chunk(parts[0]) + STREAM_ID + data_chunk(parts[1]) + STREAM_ID
        + data_chunk(parts[2]),
        "empty_data_chunks": STREAM_ID + data_chunk(b"") + data_chunk(parts[0]) + data_chunk(b"", False)
        + data_chunk(parts[1]) + data_chunk(parts[2]),
    }
    for name, framed in built.items():
        frame_case(ref, framed, len(raw), f"built_{name}", fv, fr)
        frame_case(ref, framed + STREAM_ID + data_chunk(b"next"), len(raw), f"built_{name}_then_more", fv, fr)
    small_raw = b"hello snappy framing"
    good = STREAM_ID + data_chunk(small_raw)
    faults = {
        "no_identifier": data_chunk(small_raw),
        "padding_first": chunk(0xFE, b"") + good,
        "identifier_short": chunk(0xFF, b"sNaPp") + data_chunk(small_raw),
        "identifier_wrong": chunk(0xFF, b"SNAPPY") + data_chunk(small_raw),
        "identifier_later_wrong": STREAM_ID + chunk(0xFF, b"sNaPpX") + data_chunk(small_raw),
        "unskippable_02": STREAM_ID + chunk(0x02, b"") + data_chunk(small_raw),
        "unskippable_7f": STREAM_ID + chunk(0x7F, bytes(4)) + data_chunk(small_raw),
        "unskippable_cut": STREAM_ID + bytes([0x40, 0xFF, 0xFF, 0x00]),
        "data_chunk_0": STREAM_ID + chunk(0x00, b""),
        "data_chunk_3": STREAM_ID + chunk(0x01, b"abc"),
        "uncompressed_65537": STREAM_ID + data_chunk(bytes(65537), False),
        "compressed_65537": STREAM_ID + chunk(0x00, masked_crc32c(bytes(65537)).to_bytes(4, "little") + ref.compress(bytes(65537))),
        "checksum_compressed": STREAM_ID + data_chunk(small_raw, True, masked_crc32c(small_raw) ^ 1),
        "checksum_uncompressed": STREAM_ID + data_chunk(small_raw, False, masked_crc32c(small_raw) ^ 0x80000000),
        "checksum_big_endian": STREAM_ID + chunk(0x01, masked_crc32c(small_raw).to_bytes(4, "big") + small_raw),
        "corrupt_block": STREAM_ID + chunk(0x00, masked_crc32c(small_raw).to_bytes(4, "little") + varint(len(small_raw)) + copy1(1, 4)),
        "header_cut": STREAM_ID + b"\x00\x10",
        "body_cut": good[:-3],
        "ends_early": good,
        "too_long_compressed": STREAM_ID + data_chunk(small_raw + b"!"),
        "too_long_uncompressed": STREAM_ID + data_chunk(small_raw + b"!", False),
        "empty_input": b"",
    }
    for name, framed in faults.items():
        frame_case(ref, framed, len(small_raw) + (5 if name == "ends_early" else 0), f"fault_{name}", fv, fr)
    bases = [(good, len(small_raw)), (STREAM_ID + data_chunk(small_raw, False), len(small_raw)),
             (STREAM_ID + chunk(0xFE, b"ab") + data_chunk(b"xyz"), 3)]
    for i, (framed, n) in enumerate(bases):
        for change, m in mutations(framed, rng, 64):
            frame_case(ref, m, n, f"mutation_{i}_{change}", fv, fr)
    frame_case(ref, b"", 0, "zero_length_empty", fv, fr)
    frame_case(ref, good, 0, "zero_length_reads_nothing", fv, fr)

    known = [d for d in disagreements if KNOWN_DISAGREEMENTS.match(d)]
    unknown = [d for d in disagreements if not KNOWN_DISAGREEMENTS.match(d)]
    print(f"known differences between google/snappy and cramjam: {len(known)} cases")
    for d in unknown[:20]:
        print("DISAGREE", d)
    assert not unknown, f"{len(unknown)} cases where google/snappy, cramjam or the model disagree"

    for kind in (STREAM_IDENTIFIER, UNSKIPPABLE_CHUNK, CHUNK_LENGTH, CHECKSUM, TRUNCATED, TOO_LONG, CORRUPT):
        assert any(c.endswith(u64(kind)) for c in fr.cases), f"no frame reject case for status {kind}"

    files = {
        "testdata-block-valid.bin": official["bv"],
        "testdata-block-reject.bin": official["br"],
        "testdata-compress.bin": official["cv"],
        "consensus-block-valid.bin": consensus,
        "generated-block-valid.bin": bv,
        "generated-block-reject.bin": br,
        "generated-frame-valid.bin": fv,
        "generated-frame-reject.bin": fr,
        "generated-compress.bin": cv,
    }
    manifest = []
    for name in sorted(files):
        path = os.path.join(out, name)
        files[name].write(path)
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for block_ in iter(lambda: fh.read(1 << 20), b""):
                h.update(block_)
        manifest.append(f"{name} {len(files[name].cases)} {h.hexdigest()}")
        print(f"{name}: {len(files[name].cases)} cases")
    with open(os.path.join(out, "manifest.txt"), "w") as fh:
        fh.write("\n".join(manifest) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
