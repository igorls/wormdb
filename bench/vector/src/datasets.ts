// ann-benchmarks HDF5 dataset loader.
//
// Each file has four datasets:
//   train:     [N × dim] float32   — corpus to index
//   test:      [Q × dim] float32   — query vectors
//   neighbors: [Q × 100] int32     — ground-truth top-100 indices per query
//   distances: [Q × 100] float32   — ground-truth distances (unused here)
//
// We only load the three we need. The hdf5 file is downloaded once into
// ./data/ and reused across runs.

import * as h5wasm from "h5wasm";
import type { Dataset as H5Dataset } from "h5wasm";

export type Dataset = {
  name: string;
  train: Float32Array;      // row-major, length = N * dim
  test: Float32Array;       // row-major, length = Q * dim
  neighbors: Int32Array;    // row-major, length = Q * gtK (typically 100)
  N: number;
  Q: number;
  dim: number;
  gtK: number;
  metric: "l2" | "cosine";
};

const DATASETS: Record<string, { url: string; metric: "l2" | "cosine" }> = {
  "sift-128-euclidean": {
    url: "https://ann-benchmarks.com/sift-128-euclidean.hdf5",
    metric: "l2",
  },
  "glove-100-angular": {
    url: "https://ann-benchmarks.com/glove-100-angular.hdf5",
    metric: "cosine",
  },
};

export async function loadDataset(name: string, dataDir: string): Promise<Dataset> {
  if (name === "synthetic-small") return makeSynthetic(2_000, 100, 128);
  if (name === "synthetic") return makeSynthetic(10_000, 500, 128);

  const meta = DATASETS[name];
  if (!meta) throw new Error(`Unknown dataset: ${name} (known: ${Object.keys(DATASETS).join(", ")}, or synthetic, synthetic-small)`);

  const path = `${dataDir}/${name}.hdf5`;
  if (!(await Bun.file(path).exists())) {
    console.log(`Dataset not found at ${path}; downloading from ${meta.url} ...`);
    await download(meta.url, path);
  }

  await h5wasm.ready;
  const bytes = new Uint8Array(await Bun.file(path).arrayBuffer());
  const mountPath = `/${name}.hdf5`;
  const FS = h5wasm.FS as { writeFile(path: string, data: Uint8Array): void } | null;
  if (!FS) throw new Error("h5wasm FS not ready");
  FS.writeFile(mountPath, bytes);
  const h5 = new h5wasm.File(mountPath, "r");

  const trainDS = h5.get("train") as H5Dataset;
  const testDS = h5.get("test") as H5Dataset;
  const neighborsDS = h5.get("neighbors") as H5Dataset;

  const trainShape = trainDS.shape as number[];
  const testShape = testDS.shape as number[];
  const neighborsShape = neighborsDS.shape as number[];

  const [N, dim] = [trainShape[0], trainShape[1]];
  const [Q, testDim] = [testShape[0], testShape[1]];
  const [nbQ, gtK] = [neighborsShape[0], neighborsShape[1]];
  if (testDim !== dim) throw new Error(`train/test dim mismatch: ${dim} vs ${testDim}`);
  if (nbQ !== Q) throw new Error(`neighbors row count (${nbQ}) != test Q (${Q})`);

  const train = new Float32Array((trainDS.value as Float32Array).buffer.slice(0));
  const test = new Float32Array((testDS.value as Float32Array).buffer.slice(0));
  const neighborsRaw = neighborsDS.value as Int32Array | Uint32Array;
  const neighbors = new Int32Array(neighborsRaw.length);
  for (let i = 0; i < neighborsRaw.length; i += 1) neighbors[i] = neighborsRaw[i];

  h5.close();

  return { name, train, test, neighbors, N, Q, dim, gtK, metric: meta.metric };
}

async function download(url: string, outPath: string): Promise<void> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download failed: ${res.status} ${res.statusText}`);
  const buf = await res.arrayBuffer();
  await Bun.write(outPath, buf);
  console.log(`Downloaded ${(buf.byteLength / 1e6).toFixed(1)} MB → ${outPath}`);
}

export function rowView(flat: Float32Array, row: number, dim: number): Float32Array {
  return flat.subarray(row * dim, (row + 1) * dim);
}

/**
 * Synthetic dataset with exact brute-force ground truth — used for smoke
 * testing the harness without downloading a real dataset.
 */
function makeSynthetic(N: number, Q: number, dim: number): Dataset {
  const rng = mulberry32(0x1234);
  const gaussian = (): number => {
    const u1 = Math.max(rng(), 1e-12);
    const u2 = rng();
    return Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  };
  const train = new Float32Array(N * dim);
  for (let i = 0; i < N * dim; i += 1) train[i] = gaussian();
  const test = new Float32Array(Q * dim);
  for (let i = 0; i < Q * dim; i += 1) test[i] = gaussian();

  const gtK = 100;
  const neighbors = new Int32Array(Q * gtK);
  const scratch = new Float32Array(N);
  for (let q = 0; q < Q; q += 1) {
    for (let i = 0; i < N; i += 1) {
      let d = 0;
      for (let j = 0; j < dim; j += 1) {
        const delta = train[i * dim + j] - test[q * dim + j];
        d += delta * delta;
      }
      scratch[i] = d;
    }
    const idx = Array.from({ length: N }, (_, i) => i).sort((a, b) => scratch[a] - scratch[b]);
    for (let k = 0; k < gtK; k += 1) neighbors[q * gtK + k] = idx[k];
  }
  return { name: "synthetic", train, test, neighbors, N, Q, dim, gtK, metric: "l2" };
}

function mulberry32(seed: number): () => number {
  let t = seed >>> 0;
  return () => {
    t = (t + 0x6d2b79f5) >>> 0;
    let x = t;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}
