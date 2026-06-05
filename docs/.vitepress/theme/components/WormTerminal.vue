<template>
  <div class="worm-card terminal-card">
    <div class="terminal-shell">
      <div class="terminal-header">
        <div class="terminal-dots" aria-hidden="true">
          <span class="terminal-dot dot-red"></span>
          <span class="terminal-dot dot-yellow"></span>
          <span class="terminal-dot dot-green"></span>
        </div>
        <div class="terminal-title">bun client.ts --port 6389</div>
        <div class="terminal-state">simulated</div>
      </div>

      <div class="terminal-body" ref="terminalBody">
        <div v-for="(line, index) in history" :key="index" class="terminal-line">
          <template v-if="line.type === 'input'">
            <span class="terminal-prompt">wormdb&gt;</span> {{ line.text }}
          </template>
          <template v-else>
            <span :class="line.colorClass">{{ line.text }}</span>
          </template>
        </div>

        <div class="terminal-input-row">
          <span class="terminal-prompt">wormdb&gt;</span>
          <input
            ref="inputField"
            v-model="currentInput"
            type="text"
            class="terminal-input-field"
            placeholder="Type HELP or choose a command"
            @keydown.enter="handleCommand"
            @keydown.up.prevent="historyUp"
            @keydown.down.prevent="historyDown"
            @focus="isFocused = true"
            @blur="isFocused = false"
          />
          <span v-if="!isFocused" class="terminal-cursor" aria-hidden="true"></span>
        </div>
      </div>
    </div>

    <div class="command-hints" aria-label="Command suggestions">
      <button
        v-for="cmd in suggestions"
        :key="cmd.label"
        class="command-hint-btn"
        type="button"
        :title="cmd.desc"
        @click="runPreset(cmd.command)"
      >
        {{ cmd.label }}
      </button>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, nextTick } from 'vue'

const currentInput = ref('')
const terminalBody = ref(null)
const inputField = ref(null)
const isFocused = ref(false)

const suggestions = [
  { label: 'WORM write', command: 'SET audit:tx-92 "hash:f810" WORM', desc: 'Seal an immutable audit record' },
  { label: 'Overwrite check', command: 'SET audit:tx-92 "new-hash"', desc: 'Try to overwrite the WORM record' },
  { label: 'Read key', command: 'GET audit:tx-92', desc: 'Read a stored key' },
  { label: 'Increment', command: 'EXEC increment counter 5', desc: 'Run an atomic counter procedure' },
  { label: 'Transfer', command: 'EXEC transfer acct:a acct:b 200', desc: 'Run a two-key atomic procedure' },
  { label: 'Vector stats', command: 'EXEC vstats vec:articles:', desc: 'Inspect a vector namespace' },
  { label: 'Server status', command: 'STATUS', desc: 'Show machine-readable status fields' },
  { label: 'Cluster status', command: 'CLUSTER STATUS', desc: 'Preview cluster status fields' },
]

const dbStore = ref(new Map([
  ['acct:a', { value: '1000', flags: 0 }],
  ['acct:b', { value: '500', flags: 0 }],
  ['counter', { value: '0', flags: 0 }],
]))

const vectorStore = ref(new Map([
  ['doc-001', { vector: [0.10, 0.90, -0.40], namespace: 'vec:articles:', metric: 'cosine', worm: true }],
  ['doc-002', { vector: [0.14, 0.82, -0.32], namespace: 'vec:articles:', metric: 'cosine', worm: true }],
]))

const history = ref([
  { type: 'output', text: 'WormDB reference client walkthrough', colorClass: 'color-cyan' },
  { type: 'output', text: 'The real server speaks WormWire v1 binary frames after the WW handshake.', colorClass: 'color-dim' },
  { type: 'output', text: 'Seed data: acct:a=1000, acct:b=500, counter=0, vec:articles: has 2 vectors.', colorClass: 'color-dim' },
  { type: 'output', text: '', colorClass: '' },
])

const cmdHistory = ref([])
const cmdHistoryIdx = ref(-1)

const scrollToBottom = () => {
  nextTick(() => {
    if (terminalBody.value) {
      terminalBody.value.scrollTop = terminalBody.value.scrollHeight
    }
  })
}

const runPreset = (cmd) => {
  currentInput.value = cmd
  handleCommand()
  inputField.value?.focus()
}

const historyUp = () => {
  if (cmdHistory.value.length === 0) return
  if (cmdHistoryIdx.value === -1) {
    cmdHistoryIdx.value = cmdHistory.value.length - 1
  } else if (cmdHistoryIdx.value > 0) {
    cmdHistoryIdx.value -= 1
  }
  currentInput.value = cmdHistory.value[cmdHistoryIdx.value]
}

const historyDown = () => {
  if (cmdHistoryIdx.value === -1) return
  if (cmdHistoryIdx.value < cmdHistory.value.length - 1) {
    cmdHistoryIdx.value += 1
    currentInput.value = cmdHistory.value[cmdHistoryIdx.value]
  } else {
    cmdHistoryIdx.value = -1
    currentInput.value = ''
  }
}

const handleCommand = () => {
  const input = currentInput.value.trim()
  if (!input) return

  history.value.push({ type: 'input', text: input })
  cmdHistory.value.push(input)
  cmdHistoryIdx.value = -1
  currentInput.value = ''

  const parts = parseArgs(input)
  const cmd = parts[0]?.toUpperCase() ?? ''

  processCommand(cmd, parts)
  scrollToBottom()
}

const parseArgs = (str) => {
  const matches = str.match(/"[^"]*"|\S+/g) || []
  return matches.map((m) => m.replace(/^"|"$/g, ''))
}

const readInt = (key) => {
  const item = dbStore.value.get(key)
  if (!item) return null
  const parsed = Number.parseInt(item.value, 10)
  return Number.isFinite(parsed) ? parsed : null
}

const dotProduct = (a, b) => a.reduce((sum, val, i) => sum + val * (b[i] || 0), 0)
const magnitude = (a) => Math.sqrt(a.reduce((sum, val) => sum + val * val, 0))
const cosineSimilarity = (a, b) => {
  const magA = magnitude(a)
  const magB = magnitude(b)
  if (magA === 0 || magB === 0) return 0
  return dotProduct(a, b) / (magA * magB)
}

const push = (text, colorClass = 'color-dim') => {
  history.value.push({ type: 'output', text, colorClass })
}

const processCommand = (cmd, parts) => {
  switch (cmd) {
    case 'HELP':
      push('Available examples:', 'color-cyan')
      push('  SET <key> <value> [WORM]             Write a key, optionally immutable')
      push('  GET <key>                            Read a key')
      push('  DEL <key>                            Delete a mutable key')
      push('  EXEC increment <key> [delta]          Atomic counter')
      push('  EXEC transfer <from> <to> <amount>    Atomic two-key update')
      push('  EXEC vinsert <key> <f32> [worm] [ns]  Store an embedding')
      push('  EXEC vsearch <query_key> <k> [ns]     Search local vector namespace')
      push('  EXEC vstats [namespace]               Inspect vector namespace')
      push('  STATUS | CLUSTER STATUS | CLEAR')
      break

    case 'CLEAR':
      history.value = []
      break

    case 'SET':
      handleSet(parts)
      break

    case 'GET':
      handleGet(parts)
      break

    case 'DEL':
      handleDelete(parts)
      break

    case 'EXEC':
      handleExec(parts)
      break

    case 'STATUS':
      handleStatus()
      break

    case 'CLUSTER':
      handleCluster(parts)
      break

    default:
      push(`error: Unknown command "${cmd}". Type HELP for available examples.`, 'color-red')
  }
}

const handleSet = (parts) => {
  if (parts.length < 3) {
    push('ERR SET requires key and value', 'color-red')
    return
  }

  const key = parts[1]
  const value = parts[2]
  const isWorm = parts.slice(3).some((part) => part.toUpperCase() === 'WORM')
  const existing = dbStore.value.get(key)

  if (existing?.flags === 1) {
    push('ERR WORM violation: key is immutable', 'color-red')
    return
  }

  dbStore.value.set(key, { value, flags: isWorm ? 1 : 0 })
  push(isWorm ? 'OK (WORM record sealed)' : 'OK', 'color-green')
}

const handleGet = (parts) => {
  if (parts.length < 2) {
    push('ERR GET requires key', 'color-red')
    return
  }

  const item = dbStore.value.get(parts[1])
  if (!item) {
    push('(null)')
    return
  }

  push(`${item.value}${item.flags === 1 ? ' [WORM]' : ''}`, 'color-cyan')
}

const handleDelete = (parts) => {
  if (parts.length < 2) {
    push('ERR DEL requires key', 'color-red')
    return
  }

  const key = parts[1]
  const item = dbStore.value.get(key)
  if (!item) {
    push('(null)')
    return
  }

  if (item.flags === 1) {
    push('ERR WORM violation: key is immutable', 'color-red')
    return
  }

  dbStore.value.delete(key)
  push('OK', 'color-green')
}

const handleExec = (parts) => {
  const proc = parts[1]?.toLowerCase()
  if (!proc) {
    push('ERR EXEC requires procedure_name and args', 'color-red')
    return
  }

  if (proc === 'increment') {
    const key = parts[2]
    if (!key) {
      push('ERR increment requires <key> [delta]', 'color-red')
      return
    }

    const current = readInt(key) ?? 0
    const delta = parts[3] ? Number.parseInt(parts[3], 10) : 1
    if (!Number.isFinite(delta)) {
      push('ERR increment delta must be an integer', 'color-red')
      return
    }

    const item = dbStore.value.get(key)
    if (item?.flags === 1) {
      push('ERR WORM violation: key is immutable', 'color-red')
      return
    }

    const next = current + delta
    dbStore.value.set(key, { value: String(next), flags: 0 })
    push(String(next), 'color-green')
    return
  }

  if (proc === 'transfer') {
    const from = parts[2]
    const to = parts[3]
    const amount = Number.parseInt(parts[4], 10)
    if (!from || !to || !Number.isFinite(amount)) {
      push('ERR transfer requires <from_key> <to_key> <amount>', 'color-red')
      return
    }
    if (amount <= 0) {
      push('ERR amount must be positive', 'color-red')
      return
    }

    const fromBalance = readInt(from)
    const toBalance = readInt(to)
    if (fromBalance == null) {
      push('ERR from account not found', 'color-red')
      return
    }
    if (toBalance == null) {
      push('ERR to account not found', 'color-red')
      return
    }
    if (fromBalance < amount) {
      push('ERR insufficient_funds', 'color-red')
      return
    }

    dbStore.value.set(from, { value: String(fromBalance - amount), flags: 0 })
    dbStore.value.set(to, { value: String(toBalance + amount), flags: 0 })
    push('OK', 'color-green')
    push(`${from}=${fromBalance - amount} ${to}=${toBalance + amount}`)
    return
  }

  if (proc === 'vstats') {
    const namespace = parts[2] ?? 'vec:'
    const rows = Array.from(vectorStore.value.values()).filter((item) => item.namespace === namespace)
    const dim = rows[0]?.vector.length ?? 0
    const metric = rows[0]?.metric ?? 'cosine'
    push(`{"namespace":"${namespace}","count":${rows.length},"dimensions":${dim},"hnsw":{"metric":"${metric}","live":${rows.length}}}`, 'color-cyan')
    return
  }

  if (proc === 'vinsert') {
    const key = parts[2]
    const vectorToken = parts[3]
    const namespace = parts[5] ?? 'vec:'
    const metric = parts[6] ?? 'cosine'
    if (!key || !vectorToken) {
      push('ERR vinsert requires <key> <vector_bytes> [worm] [namespace] [metric]', 'color-red')
      return
    }

    vectorStore.value.set(key, {
      vector: [0.12, 0.88, -0.35],
      namespace,
      metric,
      worm: parts[4] !== '0',
    })
    push(`OK (stored ${namespace}${key}, metric=${metric}, dim=3)`, 'color-green')
    return
  }

  if (proc === 'vsearch') {
    const queryKey = parts[2]
    const limit = Number.parseInt(parts[3] ?? '10', 10)
    const namespace = parts[4] ?? 'vec:'
    const query = vectorStore.value.get(queryKey)
    if (!query) {
      push('ERR vsearch: query key not found', 'color-red')
      return
    }

    const results = Array.from(vectorStore.value.entries())
      .filter(([key, item]) => key !== queryKey && item.namespace === namespace)
      .map(([key, item]) => ({ key, score: cosineSimilarity(query.vector, item.vector) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, Number.isFinite(limit) ? limit : 10)

    push(JSON.stringify(results.map((r) => ({ k: r.key, s: Number(r.score.toFixed(5)) }))), 'color-cyan')
    return
  }

  if (proc === 'vreindex') {
    const namespace = parts[2] ?? 'vec:'
    const rows = Array.from(vectorStore.value.values()).filter((item) => item.namespace === namespace)
    push(`{"namespace":"${namespace}","inserted":${rows.length},"skipped":0}`, 'color-cyan')
    return
  }

  push(`ERR unknown procedure: ${proc}`, 'color-red')
}

const handleStatus = () => {
  const wormKeys = Array.from(dbStore.value.values()).filter((item) => item.flags === 1).length
  push('keys=' + dbStore.value.size, 'color-cyan')
  push('worm_keys=' + wormKeys, 'color-cyan')
  push('wal_size=256', 'color-cyan')
  push('cluster_enabled=0', 'color-cyan')
  push('backend=threadpool', 'color-cyan')
}

const handleCluster = (parts) => {
  const subcommand = parts[1]?.toUpperCase()
  if (subcommand !== 'STATUS') {
    push('ERR supported cluster example: CLUSTER STATUS', 'color-red')
    return
  }

  push('cluster_enabled=1', 'color-cyan')
  push('cluster_nodes=3', 'color-cyan')
  push('cluster_alive=3', 'color-cyan')
  push('cluster_suspected=0', 'color-cyan')
  push('cluster_dead=0', 'color-cyan')
  push('replication_factor=0', 'color-cyan')
}

onMounted(() => {
  scrollToBottom()
})
</script>
