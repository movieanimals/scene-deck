"""Package our generated PNG representations in the native ICNS container."""
from pathlib import Path
import struct
import sys
source, target = map(Path, sys.argv[1:])
representations = [(b'icp4', '16x16'), (b'icp5', '32x32'), (b'ic07', '128x128'), (b'ic08', '256x256'), (b'ic09', '512x512'), (b'ic10', '512x512@2x')]
chunks = []
for tag, name in representations:
    data = (source / f'icon_{name}.png').read_bytes()
    chunks.append(tag + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
target.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
