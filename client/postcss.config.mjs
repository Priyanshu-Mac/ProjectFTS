export default {
  content: ["*"],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: "#1a73e8",
          light: "#4d9efc",
          dark: "#1558b0",
        },
        accent: {
          DEFAULT: "#fbbc04",
          light: "#ffcf40",
          dark: "#c68a00",
        },
      },
    },
  },
   plugins: {
    "@tailwindcss/postcss": {},
  },
}
