import { defineConfig } from 'vitepress'

export default defineConfig({
  title: "WormDB",
  description: "Distributed key-value store in Zig with WORM semantics, procedure execution, and mesh clustering.",
  ignoreDeadLinks: true,
  head: [
    ['link', { rel: 'icon', href: '/logo.svg' }]
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
            { text: 'Server Backends', link: '/architecture/server-backends' },
            { text: 'Stored Procedures', link: '/architecture/procedures' },
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
      { icon: 'github', link: 'https://github.com/WormDB/wormdb' } // Placeholder
    ]
  }
})