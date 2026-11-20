#!/usr/bin/env python3
"""Check WebRTC native bootstrap classes and methods in the release APK."""
import struct
import zipfile

def uint(data, offset):
    return struct.unpack_from('<I', data, offset)[0]

def leb(data, offset):
    result = 0
    for shift in range(0, 35, 7):
        value = data[offset]
        offset += 1
        result |= (value & 127) << shift
        if not value & 128:
            return result, offset
    raise ValueError('Invalid DEX LEB128')

def classes(data):
    strings = []
    for i in range(uint(data, 56)):
        offset = uint(data, uint(data, 60) + 4 * i)
        _, offset = leb(data, offset)
        strings.append(data[offset:data.index(b'\0', offset)].decode('utf-8', errors='replace'))
    types = [strings[uint(data, uint(data, 68) + 4*i)] for i in range(uint(data, 64))]
    methods = [strings[uint(data, uint(data, 92) + 8*i + 4)] for i in range(uint(data, 88))]
    for i in range(uint(data, 96)):
        base = uint(data, 100) + 32*i
        name = types[uint(data, base)]
        offset = uint(data, base + 24)
        names = set()
        if offset:
            counts = []
            for _ in range(4):
                count, offset = leb(data, offset)
                counts.append(count)
            for _ in range(counts[0] + counts[1]):
                _, offset = leb(data, offset)
                _, offset = leb(data, offset)
            for count in counts[2:]:
                method = 0
                for _ in range(count):
                    delta, offset = leb(data, offset)
                    method += delta
                    _, offset = leb(data, offset)
                    _, offset = leb(data, offset)
                    names.add(methods[method])
        yield name, names

REQUIRED = {
    'Lorg/jni_zero/JniZero;': {'init', 'crashIfMultiplexingMisaligned'},
    'Lorg/jni_zero/CommonApis;': {'arrayToMap', 'mapToArray'},
    'Lorg/webrtc/PeerConnectionFactory;': {'initialize'},
    'Lorg/webrtc/PeerConnection$RTCConfiguration;': set(),
    'Lorg/webrtc/RtpTransceiver;': {'setDirection'},
}


def verify(archive, abi):
    with zipfile.ZipFile(archive) as apk:
        if f'lib/{abi}/libjingle_peerconnection_so.so' not in apk.namelist():
            raise SystemExit(f'Missing WebRTC native library for {abi}')
        pending = dict(REQUIRED)
        for path in apk.namelist():
            if not path.startswith('classes') or not path.endswith('.dex'):
                continue
            for name, methods in classes(apk.read(path)):
                if name not in pending:
                    continue
                missing = pending.pop(name) - methods
                if missing:
                    raise SystemExit(f'Missing WebRTC JNI methods in {name}: {sorted(missing)}')
        if pending:
            raise SystemExit(f'Missing WebRTC JNI classes: {", ".join(pending)}')
    print(f'Verified WebRTC native bootstrap in the {abi} APK')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk')
    parser.add_argument('--abi', default='arm64-v8a')
    args = parser.parse_args()
    verify(args.apk, args.abi)
