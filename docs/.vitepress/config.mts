import { defineConfig } from 'vitepress'

export default defineConfig({
  base: '/wormdb/',
  title: "WormDB",
  description: "Distributed key-value store in Zig with WORM semantics, procedure execution, and mesh clustering.",
  ignoreDeadLinks: true,
  head: [
    ['link', { rel: 'icon', href: '/wormdb/logo.svg' }]
  ],
  themeConfig: {
    logo: '/logo.svg',
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Getting Started', link: '/getting-started/' },
      { text: 'Architecture', link: '/architecture/' },
      { text: 'Operations', link: '/operations/' },
      { text: 'Protocol', link: '/protocol/' },
      { text: 'Reference', link: '/reference/cli/' }
    ],

    sidebar: {
      '/getting-started/': [
        {
          text: 'Getting Started',
          items: [
            { text: 'What is WormDB?', link: '/getting-started/' },
            { text: 'Quick Start', link: '/getting-started/quick-start' },
            { text: 'Clients & Commands', link: '/getting-started/clients' },
          ]
        }
      ],
      '/operations/': [
        {
          text: 'Operations',
          items: [
            { text: 'Overview', link: '/operations/' },
            { text: 'Persistence Modes', link: '/operations/persistence' },
            { text: 'Clustering', link: '/operations/clustering' },
            { text: 'Gateways & Light-API', link: '/operations/gateways' },
            { text: 'Troubleshooting', link: '/operations/troubleshooting' },
          ]
        }
      ],
      '/architecture/': [
        {
          text: 'Architecture',
          items: [
            { text: 'System Design', link: '/architecture/' },
            { text: 'WORM Semantics', link: '/architecture/worm-semantics' },
            { text: 'Replication Proofs', link: '/architecture/replication-proofs' },
            { text: 'Server Backends', link: '/architecture/server-backends' },
            { text: 'Stored Procedures', link: '/architecture/procedures' },
            { text: 'Vector Search', link: '/architecture/vector-search' },
            { text: 'Agent Memory', link: '/architecture/agent-memory' },
            { text: 'Pub/Sub', link: '/architecture/pubsub' },
            { text: 'Benchmarks', link: '/architecture/benchmarks' },
          ]
        }
      ],
      '/protocol/': [
        {
          text: 'Protocol',
          items: [
            { text: 'WormWire v1', link: '/protocol/' },
            { text: 'Command Reference', link: '/protocol/commands' },
            { text: 'Verifiable Append Log', link: '/protocol/append-log' },
            { text: 'Verifiable Proof Bundles', link: '/protocol/proofs' },
          ]
        }
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'CLI Flags', link: '/reference/cli/' },
            { text: 'Status Fields', link: '/reference/status-fields' },
          ]
        }
      ],
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/igorls/wormdb' }
    ]
  }
})
