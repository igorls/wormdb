<template>
  <div class="worm-card">
    <div class="section-header" style="margin-bottom: 2rem; text-align: left;">
      <h3 style="font-size: 1.5rem; font-weight: bold; color: #ffffff; margin-bottom: 0.5rem;">
        Decentralized Mesh Clustering
      </h3>
      <p style="color: #94a3b8; font-size: 0.95rem;">
        No centralized coordinators like ZooKeeper or Consul. Nodes discover peers via <strong>SWIM Gossip</strong> 
        and replicate writes securely over <strong>ChaCha20-Poly1305 / WireGuard</strong> tunnels.
      </p>
    </div>

    <div class="cluster-layout">
      <!-- SVG Canvas -->
      <div class="canvas-wrapper">
        <svg class="canvas-svg">
          <!-- Connection Paths -->
          <line 
            v-for="link in links" 
            :key="link.id"
            :x1="getNodeX(link.from)"
            :y1="getNodeY(link.from)"
            :x2="getNodeX(link.to)"
            :y2="getNodeY(link.to)"
            stroke="rgba(255,255,255,0.06)"
            stroke-width="1.5"
          />

          <!-- Moving Packets -->
          <circle 
            v-for="pkt in packets" 
            :key="pkt.id"
            :cx="getPacketX(pkt)"
            :cy="getPacketY(pkt)"
            :r="pkt.type === 'write' ? 5 : 3"
            :fill="pkt.type === 'write' ? '#00ccff' : '#00ff88'"
            :filter="pkt.type === 'write' ? 'url(#glow-cyan)' : 'url(#glow-green)'"
          />

          <!-- Nodes -->
          <g 
            v-for="node in nodes" 
            :key="node.id"
            @click="toggleNode(node.id)"
            style="cursor: pointer;"
          >
            <!-- Invisible click target for easy clicking -->
            <circle 
              :cx="node.x" 
              :cy="node.y" 
              :r="25" 
              fill="rgba(0, 0, 0, 0)"
            />
            <!-- Pulsing outer ring -->
            <circle 
              :cx="node.x" 
              :cy="node.y" 
              :r="22" 
              fill="transparent"
              :stroke="node.status === 'active' ? 'rgba(0, 255, 136, 0.15)' : 'rgba(244, 63, 94, 0.15)'"
              stroke-width="2"
              class="pulsing-ring"
              v-if="node.status === 'active' || node.status === 'dead'"
            />
            <!-- Node Circle -->
            <circle 
              :cx="node.x" 
              :cy="node.y" 
              :r="12" 
              :fill="node.status === 'active' ? '#00ff88' : '#f43f5e'"
              :filter="node.status === 'active' ? 'url(#glow-green)' : 'url(#glow-red)'"
            />
            <!-- Node Label -->
            <text 
              :x="node.x" 
              :y="node.y - 18" 
              text-anchor="middle" 
              fill="#cbd5e1" 
              font-size="10" 
              font-family="var(--vp-font-family-mono)"
            >
              {{ node.name }}
            </text>
            <!-- Status Badge -->
            <text 
              :x="node.x" 
              :y="node.y + 24" 
              text-anchor="middle" 
              :fill="node.status === 'active' ? '#00ff88' : '#f43f5e'"
              font-size="8" 
              font-family="var(--vp-font-family-mono)"
              font-weight="bold"
            >
              {{ node.status.toUpperCase() }}
            </text>
          </g>

          <!-- SVG Filters for Glow -->
          <defs>
            <filter id="glow-green" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="3" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
            <filter id="glow-cyan" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="4" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
            <filter id="glow-red" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="3" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
          </defs>
        </svg>

        <div style="position: absolute; bottom: 8px; left: 8px; font-size: 0.65rem; color: #64748b; font-family: var(--vp-font-family-mono);">
          Click any node to toggle failed/active state
        </div>
      </div>

      <!-- Controls & Logs -->
      <div class="cluster-controls">
        <button class="cluster-btn" @click="simulateWrite">
          ⚡ Simulate Write on node-1
        </button>
        <button class="cluster-btn" @click="addNode" :disabled="nodes.length >= 6">
          ➕ Spawn & Join Node
        </button>
        <button class="cluster-btn cluster-btn-danger" @click="resetCluster">
          🔄 Reset Mesh
        </button>

        <!-- Log Window -->
        <div class="cluster-logs" ref="logWindow">
          <div v-for="(log, idx) in logs" :key="idx" class="log-entry">
            <span class="log-time">{{ log.time }}</span>
            <span :style="{ color: log.color }">{{ log.msg }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick } from 'vue'

const nodes = ref([
  { id: 1, name: 'node-1 (seed)', x: 60, y: 120, status: 'active' },
  { id: 2, name: 'node-2', x: 200, y: 60, status: 'active' },
  { id: 3, name: 'node-3', x: 340, y: 120, status: 'active' },
  { id: 4, name: 'node-4', x: 200, y: 220, status: 'active' }
])

const links = ref([
  { id: '1-2', from: 1, to: 2 },
  { id: '2-3', from: 2, to: 3 },
  { id: '3-4', from: 3, to: 4 },
  { id: '4-1', from: 4, to: 1 },
  { id: '1-3', from: 1, to: 3 },
  { id: '2-4', from: 2, to: 4 }
])

const packets = ref([])
const logs = ref([])
const logWindow = ref(null)

let packetCounter = 0
let simInterval = null
let tickInterval = null

const getNode = (id) => nodes.value.find(n => n.id === id)
const getNodeX = (id) => getNode(id)?.x || 0
const getNodeY = (id) => getNode(id)?.y || 0

const getPacketX = (pkt) => {
  const fromX = getNodeX(pkt.from)
  const toX = getNodeX(pkt.to)
  return fromX + (toX - fromX) * (pkt.progress / 100)
}

const getPacketY = (pkt) => {
  const fromY = getNodeY(pkt.from)
  const toY = getNodeY(pkt.to)
  return fromY + (toY - fromY) * (pkt.progress / 100)
}

const addLog = (msg, type = 'info') => {
  const now = new Date()
  const timeStr = now.toTimeString().split(' ')[0]
  
  let color = '#cbd5e1'
  if (type === 'swim') color = '#00ff88'
  if (type === 'write') color = '#00ccff'
  if (type === 'fail') color = '#f43f5e'

  logs.value.push({ time: timeStr, msg, color })
  
  if (logs.value.length > 50) {
    logs.value.shift()
  }

  nextTick(() => {
    if (logWindow.value) {
      logWindow.value.scrollTop = logWindow.value.scrollHeight
    }
  })
}

const toggleNode = (id) => {
  const node = getNode(id)
  if (!node) return

  if (node.status === 'active') {
    node.status = 'dead'
    addLog(`[SWIM] node-${id} disconnected from physical network`, 'fail')
  } else {
    node.status = 'active'
    addLog(`[SWIM] node-${id} booted, triggering anti-entropy synchronization`, 'swim')
    // Trigger sync waves
    nodes.value.forEach(peer => {
      if (peer.id !== id && peer.status === 'active') {
        createPacket(peer.id, id, 'write')
      }
    })
  }
}

const addNode = () => {
  if (nodes.value.length >= 6) return
  const id = nodes.value.length + 1
  
  // Calculate a layout coordinate
  let x = 200
  let y = 140
  if (id === 5) { x = 100; y = 240 }
  if (id === 6) { x = 300; y = 240 }

  const name = `node-${id}`
  nodes.value.push({ id, name, x, y, status: 'active' })
  
  // Create links to all existing nodes
  nodes.value.forEach(peer => {
    if (peer.id !== id) {
      links.value.push({
        id: `${Math.min(peer.id, id)}-${Math.max(peer.id, id)}`,
        from: peer.id,
        to: id
      })
    }
  })

  addLog(`[SWIM] ${name} joined mesh. Seeding node discovery...`, 'swim')
  createPacket(id, 1, 'swim') // Discover seed
}

const simulateWrite = () => {
  const seed = getNode(1)
  if (seed.status !== 'active') {
    addLog(`[WRITE] Cannot write. node-1 (seed) is offline!`, 'fail')
    return
  }

  addLog(`[WRITE] Local commit on node-1, appending WAL record...`, 'write')
  
  // Propagate to all active nodes
  nodes.value.forEach(peer => {
    if (peer.id !== 1) {
      if (peer.status === 'active') {
        createPacket(1, peer.id, 'write')
      } else {
        addLog(`[WRITE] Queueing peer replication for offline node-${peer.id}`, 'fail')
      }
    }
  })
}

const createPacket = (from, to, type) => {
  packetCounter++
  packets.value.push({
    id: packetCounter,
    from,
    to,
    progress: 0,
    type
  })
}

const resetCluster = () => {
  nodes.value = [
    { id: 1, name: 'node-1 (seed)', x: 60, y: 120, status: 'active' },
    { id: 2, name: 'node-2', x: 200, y: 60, status: 'active' },
    { id: 3, name: 'node-3', x: 340, y: 120, status: 'active' },
    { id: 4, name: 'node-4', x: 200, y: 220, status: 'active' }
  ]
  links.value = [
    { id: '1-2', from: 1, to: 2 },
    { id: '2-3', from: 2, to: 3 },
    { id: '3-4', from: 3, to: 4 },
    { id: '4-1', from: 4, to: 1 },
    { id: '1-3', from: 1, to: 3 },
    { id: '2-4', from: 2, to: 4 }
  ]
  packets.value = []
  logs.value = []
  addLog(`[SWIM] Cluster reset. Meshguard interfaces reinitialized.`, 'swim')
}

// Gossip background simulation
const runGossipStep = () => {
  const activeNodes = nodes.value.filter(n => n.status === 'active')
  if (activeNodes.length < 2) return

  // Pick a random sender
  const sender = activeNodes[Math.floor(Math.random() * activeNodes.length)]
  
  // Pick any receiver (active or dead, to simulate ping/probe)
  const peers = nodes.value.filter(n => n.id !== sender.id)
  if (peers.length === 0) return
  const receiver = peers[Math.floor(Math.random() * peers.length)]

  createPacket(sender.id, receiver.id, 'swim')
}

onMounted(() => {
  addLog(`[SWIM] Gossip daemon listening on UDP :51821`, 'swim')
  addLog(`[SWIM] Encrypted peer replication open on TCP :6389`, 'swim')
  
  // Tick packets animation
  tickInterval = setInterval(() => {
    packets.value = packets.value.map(pkt => {
      pkt.progress += 2.5 // increment progress
      return pkt
    }).filter(pkt => {
      if (pkt.progress >= 100) {
        // Handle packet arrival log
        const destNode = getNode(pkt.to)
        if (pkt.type === 'write') {
          if (destNode.status === 'active') {
            addLog(`[WRITE] node-${pkt.to} fully replicated write`, 'write')
          } else {
            addLog(`[WRITE] Replication failed to node-${pkt.to}: connection timeout`, 'fail')
          }
        } else if (pkt.type === 'swim') {
          if (destNode.status === 'active') {
            addLog(`[SWIM] node-${pkt.from} received gossip ack from node-${pkt.to}`, 'swim')
          } else {
            addLog(`[SWIM] node-${pkt.from} detected node-${pkt.to} fail! Probing alternate paths...`, 'fail')
          }
        }
        return false // filter out
      }
      return true
    })
  }, 40)

  // Trigger random gossip pings
  simInterval = setInterval(() => {
    runGossipStep()
  }, 2200)
})

onUnmounted(() => {
  clearInterval(tickInterval)
  clearInterval(simInterval)
})
</script>

<style scoped>
.pulsing-ring {
  transform-origin: center;
  animation: pulse 2s infinite ease-out;
}

@keyframes pulse {
  0% {
    r: 14px;
    opacity: 0.8;
  }
  100% {
    r: 26px;
    opacity: 0;
  }
}
</style>
