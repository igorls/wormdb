# Bun runtime for WormDB Notepad server
FROM oven/bun:1-slim

WORKDIR /app

# Copy the Bun app source
COPY apps/bun/package.json apps/bun/bun.lock* ./
RUN bun install --frozen-lockfile 2>/dev/null || bun install

COPY apps/bun/src ./src

EXPOSE 8081

CMD ["bun", "run", "src/bin/notepad.ts"]
