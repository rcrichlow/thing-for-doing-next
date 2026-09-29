// @ts-check
import { existsSync } from "node:fs";
import { defineConfig } from "@playwright/test";

/**
 * Browser tests run against the `app-e2e` compose service (see
 * ../scripts/e2e), which serves the app on port 3001 backed by the isolated
 * `thing_for_doing_next_e2e` database. Tests reset that database, so they run
 * one at a time.
 */

/** The system Chromium, used unless CHROMIUM_PATH points elsewhere. */
const chromium = process.env.CHROMIUM_PATH ?? "/usr/bin/chromium";

export default defineConfig({
  testDir: "./tests",
  workers: 1,
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  reporter: "list",
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://localhost:3001",
    viewport: { width: 1280, height: 800 },
    // Falls back to Playwright's own browser (`npx playwright install chromium`).
    launchOptions: existsSync(chromium) ? { executablePath: chromium } : {},
    trace: "retain-on-failure",
  },
});
