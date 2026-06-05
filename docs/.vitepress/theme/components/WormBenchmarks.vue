<template>
  <div class="worm-card">
    <div class="benchmark-layout">
      <!-- Info Column -->
      <div>
        <h3 style="font-size: 1.5rem; font-weight: bold; margin-bottom: 1rem; color: #ffffff;">
          SIMD Vector Acceleration
        </h3>
        <p style="color: #94a3b8; font-size: 0.95rem; line-height: 1.6; margin-bottom: 1.5rem;">
          WormDB embeds a co-located vector search engine optimized for AI agent memory. By leveraging 
          <strong>AVX2/NEON SIMD hardware</strong> and <strong>RaBitQ 1-bit quantization</strong>, WormDB compresses embeddings by 32× and ranks candidates in Hamming space before performing exact distance refinements.
        </p>

        <!-- Dimension Buttons -->
        <div class="dim-selector">
          <button 
            v-for="dim in dimensions" 
            :key="dim.val" 
            class="dim-btn"
            :class="{ active: currentDim === dim.val }"
            @click="currentDim = dim.val"
          >
            {{ dim.val }} Dimensions
          </button>
        </div>

        <!-- Speedup Metrics -->
        <div style="background: rgba(255, 255, 255, 0.02); border: 1px solid rgba(255, 255, 255, 0.05); padding: 1rem; border-radius: 8px;">
          <div style="font-size: 0.75rem; text-transform: uppercase; color: #64748b; font-family: var(--vp-font-family-mono); margin-bottom: 0.25rem;">
            Quantization Speedup
          </div>
          <div style="font-size: 2.25rem; font-weight: 800; color: #00ff88; font-family: var(--vp-font-family-mono);">
            {{ speedup }}× <span style="font-size: 1rem; font-weight: 500; color: #94a3b8;">throughput boost</span>
          </div>
          <div class="speedup-badge" style="margin-top: 0.25rem;">
            AVX2 Cosine Metric (N=50K vectors, K=10)
          </div>
        </div>
      </div>

      <!-- Chart Column -->
      <div class="chart-container">
        <!-- Brute-Force Row -->
        <div class="chart-row">
          <div class="chart-info">
            <span class="chart-label">Brute-Force Cosine</span>
            <span class="chart-value" style="color: #ef4444;">{{ activeData.brute }} QPS</span>
          </div>
          <div class="chart-bar-bg">
            <div 
              class="chart-bar-fill bar-bruteforce"
              :style="{ width: bruteWidthPercent + '%' }"
            ></div>
          </div>
          <span style="font-size: 0.75rem; color: #64748b;">Requires full floating-point SIMD traversal of the search space.</span>
        </div>

        <!-- BQ Quantized Row -->
        <div class="chart-row">
          <div class="chart-info">
            <span class="chart-label" style="color: #00ff88;">BQ Prefilter + Refine (WormDB)</span>
            <span class="chart-value" style="color: #00ff88;">{{ activeData.bq }} QPS</span>
          </div>
          <div class="chart-bar-bg">
            <div 
              class="chart-bar-fill bar-quantized"
              :style="{ width: bqWidthPercent + '%' }"
            ></div>
          </div>
          <span style="font-size: 0.75rem; color: #64748b;">Ranks Hamming distances first using bitwise POPCNT, then refines.</span>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const currentDim = ref(384)

const dimensions = [
  { val: 384, brute: 220, bq: 3520 },
  { val: 768, brute: 115, bq: 2440 },
  { val: 1536, brute: 59, bq: 1210 }
]

const activeData = computed(() => {
  return dimensions.find(d => d.val === currentDim.value)
})

const speedup = computed(() => {
  return (activeData.value.bq / activeData.value.brute).toFixed(1)
})

// Scale relative to the maximum QPS in our dataset (3520) for visual weight consistency
const maxQps = 3520

const bruteWidthPercent = computed(() => {
  return Math.max(4, (activeData.value.brute / maxQps) * 100)
})

const bqWidthPercent = computed(() => {
  return (activeData.value.bq / maxQps) * 100
})
</script>
