<template>
  <div class="worm-landing">
    <section class="worm-section worm-section-intro">
      <div class="worm-container worm-split">
        <div class="worm-copy">
          <p class="worm-kicker">Documentation map</p>
          <h2>Start with the invariant, then choose the workflow.</h2>
          <p>
            WormDB is not a text-protocol cache with an immutability option. It
            is a binary key-value server where WORM records, server-side
            procedures, event streams, vector indexes, and mesh replication all
            share one execution path.
          </p>
          <div class="worm-inline-actions">
            <a class="worm-button worm-button-primary" :href="withBase('/getting-started/quick-start')">
              Build and run
            </a>
            <a class="worm-button" :href="withBase('/architecture/')">
              See the runtime
            </a>
          </div>
        </div>

        <div class="worm-command-card" aria-label="First local run commands">
          <div class="worm-card-label">First local run</div>
          <pre><code>git submodule update --init --recursive
zig build -Doptimize=ReleaseSmall
zig build run -- --port 6389 --data ./data

# In another terminal
bun run apps/bun/src/bin/client.ts SET audit:001 "created" --worm
bun run apps/bun/src/bin/client.ts STATUS</code></pre>
        </div>
      </div>
    </section>

    <section class="worm-section">
      <div class="worm-container">
        <div class="worm-section-header">
          <p class="worm-kicker">Read by task</p>
          <h2>Pick the page that matches what you are trying to do.</h2>
          <p>
            The landing page should get people unstuck quickly. These routes
            point readers to the first useful page for each role.
          </p>
        </div>

        <div class="worm-path-grid">
          <a
            v-for="path in docPaths"
            :key="path.href"
            class="worm-path-card"
            :href="withBase(path.href)"
          >
            <span class="worm-card-meta">{{ path.meta }}</span>
            <h3>{{ path.title }}</h3>
            <p>{{ path.text }}</p>
            <span class="worm-card-link">Open guide</span>
          </a>
        </div>
      </div>
    </section>

    <section class="worm-section worm-section-alt">
      <div class="worm-container">
        <div class="worm-section-header">
          <p class="worm-kicker">Command model</p>
          <h2>Try the shape of a WormDB session.</h2>
          <p>
            This browser walkthrough mirrors the reference client command
            strings. The real server speaks WormWire binary frames, so raw
            telnet or netcat sessions are intentionally rejected.
          </p>
        </div>

        <WormTerminal />
      </div>
    </section>

    <section class="worm-section">
      <div class="worm-container">
        <div class="worm-section-header">
          <p class="worm-kicker">Runtime map</p>
          <h2>The server is small, but the boundaries are deliberate.</h2>
          <p>
            Every backend feeds the same protocol decoder and executor. That is
            the thread to follow when you need to understand behavior.
          </p>
        </div>

        <div class="worm-runtime">
          <div
            v-for="(layer, index) in runtimeLayers"
            :key="layer.title"
            class="worm-runtime-step"
          >
            <div class="worm-runtime-index">{{ index + 1 }}</div>
            <h3>{{ layer.title }}</h3>
            <p>{{ layer.text }}</p>
            <a :href="withBase(layer.href)">{{ layer.link }}</a>
          </div>
        </div>
      </div>
    </section>

    <section class="worm-section worm-section-alt">
      <div class="worm-container">
        <div class="worm-section-header">
          <p class="worm-kicker">Production notes</p>
          <h2>Know these before you deploy or benchmark.</h2>
        </div>

        <div class="worm-note-grid">
          <article v-for="note in productionNotes" :key="note.title" class="worm-note">
            <h3>{{ note.title }}</h3>
            <p>{{ note.text }}</p>
            <a :href="withBase(note.href)">{{ note.link }}</a>
          </article>
        </div>
      </div>
    </section>

    <section class="worm-section worm-final">
      <div class="worm-container worm-final-inner">
        <div>
          <p class="worm-kicker">Next step</p>
          <h2>Build it locally, then trace one command through the stack.</h2>
          <p>
            A first run plus the architecture page gives you the whole mental
            model: command frame, executor, sharded store, WAL, event bus, and
            optional replication.
          </p>
        </div>
        <div class="worm-inline-actions">
          <a class="worm-button worm-button-primary" :href="withBase('/getting-started/quick-start')">
            Quick start
          </a>
          <a class="worm-button" :href="withBase('/architecture/')">
            Architecture
          </a>
        </div>
      </div>
    </section>
  </div>
</template>

<script setup>
import { withBase } from 'vitepress'
import WormTerminal from './WormTerminal.vue'

const docPaths = [
  {
    meta: 'New readers',
    title: 'Build and verify a local node',
    text: 'Install the submodules, build with Zig 0.16, start the default threadpool server, and confirm STATUS output.',
    href: '/getting-started/quick-start',
  },
  {
    meta: 'Client authors',
    title: 'Encode WormWire correctly',
    text: 'Read the WW handshake, frame header, command IDs, payload layouts, response codes, and pub/sub event format.',
    href: '/protocol/',
  },
  {
    meta: 'Procedure authors',
    title: 'Use EXEC without race windows',
    text: 'Learn the Ctx API, shard locking rules, durable write helpers, and how built-in increment and transfer are registered.',
    href: '/architecture/procedures',
  },
  {
    meta: 'Operators',
    title: 'Deploy with the right persistence model',
    text: 'Compare full WAL persistence, snapshots, cluster verification, STATUS fields, and troubleshooting paths.',
    href: '/operations/',
  },
  {
    meta: 'Vector workloads',
    title: 'Store embeddings next to KV data',
    text: 'Understand namespace metrics, HNSW, RaBitQ/BQ fallback, vstats, vreindex, tombstones, and local-node search limits.',
    href: '/VECTOR_SEARCH',
  },
  {
    meta: 'Windows users',
    title: 'Run the supported single-node path',
    text: 'Use the threadpool backend on Windows and see which Linux-only features are intentionally unavailable.',
    href: '/WINDOWS',
  },
]

const runtimeLayers = [
  {
    title: 'Transport',
    text: 'threadpool, epoll, and io_uring accept connections without owning command semantics.',
    href: '/architecture/server-backends',
    link: 'Backends',
  },
  {
    title: 'Protocol',
    text: 'WormWire validates the WW/WR preface and decodes framed binary payloads.',
    href: '/protocol/',
    link: 'WormWire',
  },
  {
    title: 'Executor',
    text: 'A transport-agnostic dispatcher applies commands to the store, bus, procedures, and cluster.',
    href: '/architecture/',
    link: 'System design',
  },
  {
    title: 'Storage',
    text: 'The 256-shard map, WAL, WORM checks, and snapshots keep local commit authoritative.',
    href: '/operations/persistence',
    link: 'Persistence',
  },
  {
    title: 'Extensions',
    text: 'Procedures, pub/sub, vector search, and mesh replication build on the same command path.',
    href: '/architecture/procedures',
    link: 'Procedures',
  },
]

const productionNotes = [
  {
    title: 'Linux is the full-feature platform',
    text: 'Clustering plus the epoll and io_uring backends are Linux-only. Windows is supported for single-node threadpool use.',
    href: '/WINDOWS',
    link: 'Platform guide',
  },
  {
    title: 'Vector search is local-node today',
    text: 'Vector writes replicate, but vsearch does not scatter to peers and merge top-K results yet.',
    href: '/VECTOR_SEARCH#current-limitations',
    link: 'Vector limitations',
  },
  {
    title: 'Index recovery has a rebuild path',
    text: 'Snapshot v2 persists vector indexes, but raw SET ingest or WAL-only catch-up may need EXEC vreindex for serving indexes.',
    href: '/operations/persistence',
    link: 'Recovery notes',
  },
]
</script>
