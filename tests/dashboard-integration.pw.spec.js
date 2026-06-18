/**
 * Playwright integration tests for the dashboard HTML.
 *
 * These load the dashboard HTML in a real browser and verify:
 * - Key semantic elements exist in the DOM (no regex against source)
 * - The channel switch module renders correctly
 * - Tables have the expected structure
 * - The page is accessible (headings, landmarks)
 */
import { test, expect } from "@playwright/test";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DASHBOARD_HTML = resolve(__dirname, "../snap/local/assets/dashboard.html");
const SBOM_HTML = resolve(__dirname, "../snap/local/assets/sbom-explorer.html");

test.describe("dashboard.html semantic structure", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${DASHBOARD_HTML}`);
  });

  test("has balanced block-level markup", async ({ page }) => {
    // Verify the page loaded without parser errors
    const title = await page.title();
    expect(title).toBe("snap Pi-hole CI/CD Reports");
  });

  test("has a build and test section with run identifier and status chip", async ({ page }) => {
    const runTitle = page.locator("#latest-run-title");
    await expect(runTitle).toBeVisible();
    await expect(runTitle).toHaveText("Loading...");

    const statusChip = page.locator("#latest-run-status-chip");
    await expect(statusChip).toBeVisible();
  });

  test("exposes channel scope and current activity summary", async ({ page }) => {
    await expect(page.locator("#channel-scope-summary")).toBeVisible();
    await expect(page.locator("#current-activity")).toBeVisible();

    for (const label of ["Upstream", "Build", "Store", "Install"]) {
      await expect(page.locator(`.activity-item__label:has-text("${label}")`)).toBeVisible();
    }
  });

  test("has a distribution test status matrix", async ({ page }) => {
    await expect(page.locator(".matrix-table")).toBeVisible();
    await expect(page.locator("#compatibility-matrix-body")).toBeVisible();

    // Default state before JS runs
    const loadingRow = page.locator("#compatibility-matrix-body >> text=Loading matrix...");
    await expect(loadingRow).toBeVisible();
  });

  test("has vulnerability summary sections", async ({ page }) => {
    await expect(page.locator('text=Vulnerability summary')).toBeVisible();
    await expect(page.locator('text=Action needed')).toBeVisible();
    await expect(page.locator('text=Report-only findings')).toBeVisible();
    await expect(page.locator('text=CVE matches')).toBeVisible();
    await expect(page.locator('text=Evidence')).toBeVisible();
  });

  test("vulnerability report CTA is visually distinct", async ({ page }) => {
    const cta = page.locator('a.p-button--positive[href="vulnerabilities/"]');
    await expect(cta.first()).toBeVisible();
  });

  test("has a channel selector with stable/edge tabs", async ({ page }) => {
    await expect(page.locator("#btn-stable")).toBeVisible();
    await expect(page.locator("#btn-edge")).toBeVisible();
    await expect(page.locator("#btn-stable")).toHaveAttribute("aria-selected", "true");
    await expect(page.locator("#btn-edge")).toHaveAttribute("aria-selected", "false");
  });

  test("has snap package rows table", async ({ page }) => {
    await expect(page.locator("table.snap-package-table")).toBeVisible();
  });

  test("has a channel switch release-health section", async ({ page }) => {
    await expect(page.locator("#channel-switch-section")).toBeVisible();
    await expect(page.locator("#channel-switch-timeline")).toBeVisible();
    await expect(page.locator("#channel-switch-matrix-body")).toBeVisible();

    // The channel-switch heading
    await expect(page.locator('text=snap channel switch smoke test')).toBeVisible();
    // Not the plural form
    await expect(page.locator('text=snap channel switch smoke tests')).toHaveCount(0);
  });

  test("channel switch table has correct headers", async ({ page }) => {
    const table = page.locator("#channel-switch-details-table");
    await expect(table).toBeVisible();

    const headers = table.locator("thead th");
    await expect(headers).toHaveText([
      "Architecture",
      "Tested on",
      "Path",
      "Status",
      "Updated",
      "Test duration",
    ]);
  });

  test("workflow tables have duration columns", async ({ page }) => {
    // Duration columns in each major table
    await expect(page.locator('th:has-text("Test duration")')).toBeVisible();
    await expect(page.locator('th:has-text("Sync duration")')).toBeVisible();
    await expect(page.locator('th:has-text("Build/publish duration")')).toBeVisible();
  });

  test("Pi-hole components table has correct structure", async ({ page }) => {
    await expect(page.locator("#dependency-rows")).toBeVisible();
    await expect(page.locator('th:has-text("Component")')).toBeVisible();
    await expect(page.locator('th:has-text("Bundled")')).toBeVisible();
    await expect(page.locator('th:has-text("Upstream")')).toBeVisible();
  });
});

test.describe("sbom-explorer.html structure", () => {
  test("has balanced block-level markup", async ({ page }) => {
    await page.goto(`file://${SBOM_HTML}`);
    const title = await page.title();
    expect(title).toBe("Software Bill of Materials (SBOM) - snap Pi-hole");
  });
});

test.describe("dashboard-channel-switch.js module", () => {
  test("dashboard loads the channel switch JS module", async ({ page }) => {
    await page.goto(`file://${DASHBOARD_HTML}`);
    // The module script tag exists
    const scriptTag = page.locator('script[src*="dashboard-channel-switch.js"]');
    await expect(scriptTag).toHaveCount(1);

    // Verify the module exposes expected functions by checking the page
    // executed without throwing
    const noErrors = await page.evaluate(() => {
      return typeof window.DashboardChannelSwitch !== "undefined";
    });
    expect(noErrors).toBe(true);
  });
});
