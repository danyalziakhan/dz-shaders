"""Generate the spatiotemporal blue noise mask that PHDRPlus dithers with.

Void-and-cluster, extended to three dimensions the way Wolfe, Morrical and
Ramamoorthi describe in "Scalar Spatiotemporal Blue Noise Masks". Energy is only
exchanged between voxels that share a slice (spatial term) or share a pixel
(temporal term), never both, which is what leaves every slice blue noise in 2D
while each pixel's run down the time axis is blue noise in 1D.

Three independent volumes go into the red, green and blue channels, so the shader
gets a decorrelated pattern per colour channel out of a single fetch.

Output is a PNG atlas: DEPTH slices of WIDTH x HEIGHT laid out left to right, top
to bottom. Regenerating with the same SEED reproduces the file byte for byte.

    python tools/make_stbn.py Textures/dz_stbn_512x256.png
"""

import struct
import sys
import zlib

import numpy as np

WIDTH, HEIGHT, DEPTH = 64, 64, 32
COLS, ROWS = 8, 4
SIGMA = 1.9
INITIAL_DENSITY = 0.10
SEED = 20260817

# Past about three sigma the gaussian contributes nothing an 8-bit rank can see,
# and truncating keeps each update to a small patch instead of the whole slice.
RADIUS = 6


def spatial_kernel():
    ys, xs = np.mgrid[-RADIUS : RADIUS + 1, -RADIUS : RADIUS + 1]
    return np.exp(-(xs * xs + ys * ys) / (2.0 * SIGMA * SIGMA)).astype(np.float32)


def temporal_kernel():
    # Wraps, so the distance between two slices is the shorter way round the loop.
    dz = np.arange(DEPTH)
    dz = np.minimum(dz, DEPTH - dz)
    k = np.exp(-(dz * dz) / (2.0 * SIGMA * SIGMA)).astype(np.float32)
    k[0] = 0.0  # the slice's own voxel is already covered by the spatial term
    return k


class Energy:
    """Energy field over the volume, updated in place as voxels come and go."""

    def __init__(self):
        self.field = np.zeros((DEPTH, HEIGHT, WIDTH), dtype=np.float32)
        self.spatial = spatial_kernel()
        self.temporal = temporal_kernel()
        off = np.arange(-RADIUS, RADIUS + 1)
        self.off = off
        self.zrange = np.arange(DEPTH)

    def _splat(self, idx, sign):
        z, y, x = idx
        iy = (y + self.off) % HEIGHT
        ix = (x + self.off) % WIDTH
        self.field[z][np.ix_(iy, ix)] += sign * self.spatial
        dz = (self.zrange - z) % DEPTH
        self.field[:, y, x] += sign * self.temporal[dz]

    def add(self, idx):
        self._splat(idx, 1.0)

    def remove(self, idx):
        self._splat(idx, -1.0)


def unravel(flat):
    return np.unravel_index(flat, (DEPTH, HEIGHT, WIDTH))


def tightest_cluster(energy, pattern, scratch):
    """Where the ones are most crowded: highest energy among the ones."""
    np.copyto(scratch, energy.field)
    scratch[~pattern] = -np.inf
    return unravel(int(np.argmax(scratch)))


def largest_void(energy, pattern, scratch):
    """Where the ones are sparsest: lowest energy among the zeros.

    Phase three of the classic algorithm looks for the tightest cluster of zeros
    instead, but on a wrapping volume the kernel sums to the same total at every
    voxel, so the energy of the zeros is a constant minus the energy of the ones.
    The two searches pick the same voxel and phase two can simply run to the end.
    """
    np.copyto(scratch, energy.field)
    scratch[pattern] = np.inf
    return unravel(int(np.argmin(scratch)))


def generate(rng):
    n = DEPTH * HEIGHT * WIDTH
    count = int(n * INITIAL_DENSITY)

    pattern = np.zeros(n, dtype=bool)
    pattern[rng.choice(n, count, replace=False)] = True
    pattern = pattern.reshape(DEPTH, HEIGHT, WIDTH)

    energy = Energy()
    scratch = np.empty_like(energy.field)
    for idx in zip(*np.nonzero(pattern)):
        energy.add(idx)

    # Even out the starting pattern: pull the most crowded voxel and drop it in
    # the emptiest gap, until doing so would put it straight back.
    while True:
        cluster = tightest_cluster(energy, pattern, scratch)
        pattern[cluster] = False
        energy.remove(cluster)

        void = largest_void(energy, pattern, scratch)
        if void == cluster:
            pattern[cluster] = True
            energy.add(cluster)
            break

        pattern[void] = True
        energy.add(void)

    ranks = np.full((DEPTH, HEIGHT, WIDTH), -1, dtype=np.int32)

    # Rank the starting voxels downwards by pulling the tightest cluster each time.
    working = pattern.copy()
    for rank in range(count - 1, -1, -1):
        idx = tightest_cluster(energy, working, scratch)
        working[idx] = False
        energy.remove(idx)
        ranks[idx] = rank

    # Then rank upwards from the starting pattern by filling the largest void.
    working = pattern.copy()
    energy.field[:] = 0.0
    for idx in zip(*np.nonzero(working)):
        energy.add(idx)

    for rank in range(count, n):
        idx = largest_void(energy, working, scratch)
        working[idx] = True
        energy.add(idx)
        ranks[idx] = rank

    assert ranks.min() >= 0, "every voxel must get a rank"

    # Ranks to bytes. Scaling by 256/n rather than 255/(n-1) keeps the histogram
    # exactly flat: every one of the 256 values gets the same number of voxels,
    # which is what the dither needs to stay unbiased.
    return ((ranks.astype(np.int64) * 256) // n).astype(np.uint8)


def to_atlas(volumes):
    atlas = np.zeros((ROWS * HEIGHT, COLS * WIDTH, 4), dtype=np.uint8)
    atlas[:, :, 3] = 255
    for channel, volume in enumerate(volumes):
        for z in range(DEPTH):
            row, col = divmod(z, COLS)
            y0, x0 = row * HEIGHT, col * WIDTH
            atlas[y0 : y0 + HEIGHT, x0 : x0 + WIDTH, channel] = volume[z]
    return atlas


def write_png(path, image):
    height, width, _ = image.shape
    raw = b"".join(b"\x00" + image[y].tobytes() for y in range(height))

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")

    with open(path, "wb") as handle:
        handle.write(blob)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Textures/dz_stbn_512x256.png"

    volumes = []
    for channel in range(3):
        rng = np.random.default_rng(SEED + channel)
        print(f"channel {channel}: generating {WIDTH}x{HEIGHT}x{DEPTH} ...", flush=True)
        volumes.append(generate(rng))

    atlas = to_atlas(volumes)
    write_png(out, atlas)
    print(f"wrote {out} ({atlas.shape[1]}x{atlas.shape[0]})")


if __name__ == "__main__":
    main()
