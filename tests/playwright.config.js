// @ts-check
import { defineConfig } from "@playwright/test";

const chromiumExecutablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || null;

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.pw.spec.js",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: "file://",
    viewport: { width: 1280, height: 900 },
  },
  projects: [
    {
      name: "chromium",
      use: {
        browserName: "chromium",
        ...(chromiumExecutablePath
          ? { launchOptions: { executablePath: chromiumExecutablePath } }
          : {}),
      },
    },
  ],
});
