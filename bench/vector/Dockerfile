FROM oven/bun:1-slim

WORKDIR /work

# Install the harness deps first so layer is cached across source edits.
COPY bench/vector/package.json bench/vector/bun.lock* /work/bench/vector/
RUN cd /work/bench/vector && bun install --frozen-lockfile 2>/dev/null || (cd /work/bench/vector && bun install)

# Copy the repo-side bun client (imported by the WormDB adapter).
COPY apps/bun/package.json /work/apps/bun/package.json
COPY apps/bun/src /work/apps/bun/src

# Copy the harness source last — changes here shouldn't invalidate the deps layer.
COPY bench/vector/src /work/bench/vector/src
COPY bench/vector/tsconfig.json /work/bench/vector/tsconfig.json

WORKDIR /work/bench/vector
ENTRYPOINT ["bun", "run", "src/run.ts"]
