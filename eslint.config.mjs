const browserGlobals = {
  clearInterval: "readonly",
  clearTimeout: "readonly",
  console: "readonly",
  document: "readonly",
  fetch: "readonly",
  globalThis: "readonly",
  localStorage: "readonly",
  module: "readonly",
  setInterval: "readonly",
  setTimeout: "readonly",
  URL: "readonly",
  window: "readonly",
};

const nodeGlobals = {
  Buffer: "readonly",
  console: "readonly",
  process: "readonly",
  setTimeout: "readonly",
};

export default [
  {
    ignores: [
      ".wiki/**",
      "coverage/**",
      "coverage-js/**",
      "local-*/**",
      "parts/**",
      "prime/**",
      "stage/**",
      "tests/node_modules/**",
    ],
  },
  {
    files: ["snap/local/assets/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      globals: browserGlobals,
      sourceType: "script",
    },
    rules: {
      "comma-dangle": ["warn", "always-multiline"],
      "eol-last": ["warn", "always"],
      "no-tabs": "error",
      "no-trailing-spaces": "warn",
      quotes: ["warn", "double", { allowTemplateLiterals: true, avoidEscape: true }],
      semi: ["warn", "always"],
    },
  },
  {
    files: ["tests/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      globals: nodeGlobals,
      sourceType: "module",
    },
    rules: {
      "comma-dangle": ["warn", "always-multiline"],
      "eol-last": ["warn", "always"],
      "no-tabs": "error",
      "no-trailing-spaces": "warn",
      quotes: ["warn", "double", { allowTemplateLiterals: true, avoidEscape: true }],
      semi: ["warn", "always"],
    },
  },
];
