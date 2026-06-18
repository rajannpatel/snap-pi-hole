module.exports = {
  arrowParens: "always",
  bracketSpacing: true,
  endOfLine: "lf",
  printWidth: 100,
  proseWrap: "preserve",
  semi: true,
  singleQuote: false,
  tabWidth: 2,
  trailingComma: "all",
  useTabs: false,
  overrides: [
    {
      files: ["*.yml", "*.yaml"],
      options: {
        tabWidth: 2,
      },
    },
    {
      files: ["*.html", "*.css", "*.json", "*.md"],
      options: {
        tabWidth: 2,
      },
    },
  ],
};
