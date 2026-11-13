#!/usr/bin/env python3
"""Checks that the Metal encoder emits identical records for identical frames.

Hosts that compare encoded records between frames (Vibepollo's adaptive FEC policy
does) need a still picture to produce byte-identical block records, apart from the
3-bit sequence counter. This builds a clip A, B, A, A, A from the first two frames
of a y4m file, encodes it, and compares the records of the three trailing A frames
block by block.

usage: recordcheck.py <pwmetal> <source.y4m> <bytes_per_frame> [cpu|surface]
"""

import os
import struct
import subprocess
import sys
import tempfile


def read_y4m_frames(path, count):
    with open(path, "rb") as f:
        header = f.readline()
        tokens = header.split()
        width = int(next(t for t in tokens if t.startswith(b"W"))[1:])
        height = int(next(t for t in tokens if t.startswith(b"H"))[1:])
        colour = next((t for t in tokens if t.startswith(b"C")), b"C420")
        samples = width * height * (3 if b"444" in colour else 1.5)
        frame_bytes = int(samples) * (2 if b"p1" in colour else 1)
        frames = []
        for _ in range(count):
            if not f.readline().startswith(b"FRAME"):
                raise SystemExit("source has too few frames")
            frames.append(f.read(frame_bytes))
        return header, frames


def read_container_frames(path):
    """Returns one bytes object per frame (packets concatenated)."""
    with open(path, "rb") as f:
        if f.read(8) != b"PYROWAVE":
            raise SystemExit("not a PyroWave container")
        f.read(32)
        packets = []
        while True:
            raw = f.read(4)
            if len(raw) < 4:
                break
            packets.append(f.read(struct.unpack("<I", raw)[0]))
    return packets


def records(frame):
    """Maps block index to record bytes with the sequence counter masked out."""
    out = {}
    offset = 0
    while offset + 8 <= len(frame):
        _ballot, word1, word2 = struct.unpack_from("<HHI", frame, offset)
        payload_words = word1 & 0x0FFF
        extended = word1 >> 15
        size = 8 if extended else payload_words * 4
        if size < 8 or offset + size > len(frame):
            raise SystemExit(f"record walk failed at byte {offset} (size {size})")
        record = bytearray(frame[offset:offset + size])
        record[3] &= 0x8F  # clear sequence (bits 12-14 of the second 16-bit word)
        key = ("extended", len(out)) if extended else word2 >> 8
        out[key] = bytes(record)
        offset += size
    if offset != len(frame):
        raise SystemExit(f"{len(frame) - offset} trailing bytes after the last record")
    return out


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    pwmetal, source, budget = sys.argv[1:4]
    mode = sys.argv[4] if len(sys.argv) > 4 else "cpu"

    header, (a, b) = read_y4m_frames(source, 2)
    with tempfile.TemporaryDirectory() as tmp:
        clip = os.path.join(tmp, "abaaa.y4m")
        stream = os.path.join(tmp, "abaaa.pyrowave")
        with open(clip, "wb") as f:
            f.write(header)
            for frame in (a, b, a, a, a):
                f.write(b"FRAME\n" + frame)
        subprocess.run([pwmetal, "encode", clip, stream, budget, mode], check=True,
                       stderr=subprocess.DEVNULL)
        frames = read_container_frames(stream)

    if len(frames) != 5:
        raise SystemExit(f"expected 5 single-packet frames, got {len(frames)}")

    parsed = [records(frame) for frame in frames]
    failures = 0
    for left, right in ((2, 3), (3, 4)):
        keys = set(parsed[left]) | set(parsed[right])
        differing = [k for k in keys if parsed[left].get(k) != parsed[right].get(k)]
        status = "ok  " if not differing else "FAIL"
        print(f"  {status} frames {left} and {right}: {len(differing)} of {len(keys)} records differ")
        failures += bool(differing)

    changed = sum(1 for k in parsed[1] if parsed[1].get(k) != parsed[2].get(k))
    print(f"  info frames 1 and 2 (different pictures): {changed} of {len(parsed[1])} records differ")
    return failures


if __name__ == "__main__":
    sys.exit(main())
