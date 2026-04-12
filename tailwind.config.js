/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        // Things 3 Dark Mode palette
        'things-bg': '#2D2D2F',
        'things-sidebar': '#323234',
        'things-sidebar-hover': '#3A3A3C',
        'things-sidebar-active': '#48484A',
        'things-surface': '#323234',
        'things-border': '#3A3A3C',
        'things-border-subtle': '#38383A',
        accent: '#5FA0F4',
        'accent-teal': '#64D2FF',
        'text-primary': '#F5F5F7',
        'text-secondary': '#98989D',
        'text-tertiary': '#636366',
        'done-green': '#30D158',
        'priority-a': '#FF453A',
        'priority-b': '#FF9F0A',
        'priority-c': '#5FA0F4',
        'priority-d': '#636366',
        // Sidebar icon dot colors (Things 3 style)
        'dot-yellow': '#FFD60A',
        'dot-blue': '#5FA0F4',
        'dot-purple': '#BF5AF2',
        'dot-red': '#FF453A',
        'dot-green': '#30D158',
        'dot-orange': '#FF9F0A',
        'dot-gray': '#636366',
      },
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
