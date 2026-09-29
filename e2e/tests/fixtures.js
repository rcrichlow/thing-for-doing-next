// @ts-check
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test as base, expect } from "@playwright/test";

/** The repository root, where `docker compose` finds compose.yaml. */
const repoRoot = fileURLToPath(new URL("../..", import.meta.url));

/** Only this database is ever reset. */
const database = "thing_for_doing_next_e2e";

/**
 * Empties every application table in the e2e database, keeping the schema
 * and migration history.
 * @returns {void}
 */
export function resetDatabase() {
  const sql = `
    DO $$
    DECLARE tables text;
    BEGIN
      SELECT string_agg(format('%I', tablename), ', ') INTO tables
      FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations';
      IF tables IS NOT NULL THEN
        EXECUTE 'TRUNCATE ' || tables || ' RESTART IDENTITY CASCADE';
      END IF;
    END $$;`;
  runSql(sql);
}

/**
 * Runs SQL against the e2e database and returns psql's unaligned output.
 * @param {string} sql
 * @returns {string}
 */
export function runSql(sql) {
  return execFileSync(
    "docker",
    ["compose", "exec", "-T", "db", "psql", "-U", "thing_for_doing", "-d", database, "-v", "ON_ERROR_STOP=1", "-qtAc", sql],
    { cwd: repoRoot, encoding: "utf8" },
  );
}

/**
 * Tests start from an empty database and fail on any page error or console
 * error, including failed requests, unless it matches `allowedErrors`.
 * @type {import("@playwright/test").TestType<
 *   import("@playwright/test").PlaywrightTestArgs & import("@playwright/test").PlaywrightTestOptions & { allowedErrors: RegExp[] },
 *   import("@playwright/test").PlaywrightWorkerArgs & import("@playwright/test").PlaywrightWorkerOptions
 * >}
 */
export const test = base.extend({
  allowedErrors: [[], { option: true }],
  page: async ({ page, allowedErrors }, use) => {
    resetDatabase();
    /** @type {string[]} */
    const errors = [];
    /** @param {string} message */
    const record = (message) => {
      if (!allowedErrors.some((pattern) => pattern.test(message))) errors.push(message);
    };
    page.on("pageerror", (error) => record(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") record(message.text());
    });
    await use(page);
    expect(errors, "page errors").toEqual([]);
  },
});

export { expect };

/**
 * Loads a page and waits for HTMX and app.js to be ready.
 * @param {import("@playwright/test").Page} page
 * @param {string} path
 * @returns {Promise<void>}
 */
export async function open(page, path) {
  await page.goto(path);
  await page.waitForFunction(() => "htmx" in window);
}

/**
 * Accepts the next native confirm() dialog, asserting its message.
 * @param {import("@playwright/test").Page} page
 * @param {string} message
 * @returns {void}
 */
export function acceptConfirm(page, message) {
  page.once("dialog", async (dialog) => {
    expect(dialog.type()).toBe("confirm");
    expect(dialog.message()).toBe(message);
    await dialog.accept();
  });
}
