import DefaultTheme from 'vitepress/theme'
import { h } from 'vue'
import './custom.css'
import HomeFeaturesAfter from './components/HomeFeaturesAfter.vue'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      'home-features-after': () => h(HomeFeaturesAfter)
    })
  },
  enhanceApp({ app }) {
    // Custom logic if needed
  }
}