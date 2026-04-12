/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        'things-bg': 'rgb(var(--things-bg) / <alpha-value>)',
        'things-sidebar': 'rgb(var(--things-sidebar) / <alpha-value>)',
        'things-sidebar-hover': 'rgb(var(--things-sidebar-hover) / <alpha-value>)',
        'things-sidebar-active': 'rgb(var(--things-sidebar-active) / <alpha-value>)',
        'things-surface': 'rgb(var(--things-surface) / <alpha-value>)',
        'things-border': 'rgb(var(--things-border) / <alpha-value>)',
        'things-border-subtle': 'rgb(var(--things-border-subtle) / <alpha-value>)',
        accent: 'rgb(var(--accent) / <alpha-value>)',
        'accent-teal': 'rgb(var(--accent-teal) / <alpha-value>)',
        'text-primary': 'rgb(var(--text-primary) / <alpha-value>)',
        'text-secondary': 'rgb(var(--text-secondary) / <alpha-value>)',
        'text-tertiary': 'rgb(var(--text-tertiary) / <alpha-value>)',
        'done-green': 'rgb(var(--done-green) / <alpha-value>)',
        'priority-a': 'rgb(var(--priority-a) / <alpha-value>)',
        'priority-b': 'rgb(var(--priority-b) / <alpha-value>)',
        'priority-c': 'rgb(var(--priority-c) / <alpha-value>)',
        'priority-d': 'rgb(var(--priority-d) / <alpha-value>)',
        'dot-yellow': 'rgb(var(--dot-yellow) / <alpha-value>)',
        'dot-blue': 'rgb(var(--dot-blue) / <alpha-value>)',
        'dot-purple': 'rgb(var(--dot-purple) / <alpha-value>)',
        'dot-red': 'rgb(var(--dot-red) / <alpha-value>)',
        'dot-green': 'rgb(var(--dot-green) / <alpha-value>)',
        'dot-orange': 'rgb(var(--dot-orange) / <alpha-value>)',
        'dot-gray': 'rgb(var(--dot-gray) / <alpha-value>)',
      },
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
