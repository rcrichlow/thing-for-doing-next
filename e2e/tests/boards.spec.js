// @ts-check
import { test, expect, open, acceptConfirm, runSql } from "./fixtures.js";

/** @param {import("@playwright/test").Page} page */
const boardCards = (page) => page.getByTestId("board-card");
/** @param {import("@playwright/test").Page} page */
const archivedCards = (page) => page.getByTestId("archived-board-card");

/**
 * Creates a board directly in the database and returns its id.
 * @param {string} title
 * @param {{ archived?: boolean }} [options]
 * @returns {number}
 */
function insertBoard(title, { archived = false } = {}) {
  const quoted = `'${title.replaceAll("'", "''")}'`;
  const archivedAt = archived ? "now()" : "NULL";
  return Number(runSql(`INSERT INTO boards (title, archived_at) VALUES (${quoted}, ${archivedAt}) RETURNING id`).trim());
}

test.describe("boards index", () => {
  test("creates the first board from the empty state", async ({ page }) => {
    await open(page, "/boards");
    await expect(page.getByRole("heading", { name: "No boards yet" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Boards", exact: true })).toHaveAttribute("aria-current", "page");

    await page.getByTestId("new-board-btn").click();
    const input = page.getByTestId("board-title-input");
    await expect(input).toBeFocused();
    await expect(page.getByTestId("board-submit-btn")).toBeDisabled();
    await input.fill("  Home  ");
    await input.press("Enter");

    await expect(boardCards(page)).toHaveCount(1);
    await expect(boardCards(page).first()).toContainText("Home");
    await expect(boardCards(page).first()).toContainText(`Created ${new Date().toLocaleDateString()}`);
    await expect(page.getByRole("heading", { name: "No boards yet" })).toBeHidden();
    await expect(page.getByRole("button", { name: "Create New Board" })).toBeVisible();
  });

  test("the create tile opens a form that Cancel and Escape close", async ({ page }) => {
    insertBoard("Existing");
    await open(page, "/boards");
    await page.getByRole("button", { name: "Create New Board" }).click();
    await page.getByTestId("board-title-input").fill("Draft");
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("board-title-input")).toBeHidden();

    await page.getByRole("button", { name: "Create New Board" }).click();
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.getByTestId("board-title-input")).toBeHidden();

    await page.getByRole("button", { name: "Create New Board" }).click();
    await page.getByTestId("board-title-input").fill("Work");
    await page.getByTestId("board-submit-btn").click();
    await expect(boardCards(page)).toHaveText([/Existing/, /Work/]);
  });

  test("archiving asks first and moves the board to Archived Boards", async ({ page }) => {
    insertBoard("Keep");
    insertBoard("Old plans");
    await open(page, "/boards");

    page.once("dialog", (dialog) => dialog.dismiss());
    await page.getByRole("button", { name: "Archive board Old plans" }).click();
    await expect(boardCards(page)).toHaveCount(2);

    acceptConfirm(page, 'Archive board "Old plans"?');
    await page.getByRole("button", { name: "Archive board Old plans" }).click();
    await expect(boardCards(page)).toHaveText([/Keep/]);

    acceptConfirm(page, 'Archive board "Keep"?');
    await page.getByRole("button", { name: "Archive board Keep" }).click();
    await expect(page.getByRole("heading", { name: "No boards yet" })).toBeVisible();

    await page.getByRole("link", { name: "Archived Boards" }).click();
    await expect(archivedCards(page)).toHaveText([/Keep/, /Old plans/]);
  });

  test("clicking a board opens it", async ({ page }) => {
    const id = insertBoard("Roadmap");
    await open(page, "/boards");
    await boardCards(page).getByRole("link", { name: "Roadmap" }).click();
    await expect(page).toHaveURL(`/boards/${id}`);
    await expect(page).toHaveTitle("Roadmap · Thing for Doing Next");
  });
});

test.describe("archived boards", () => {
  test("unarchive restores and permanent delete removes, ending in the empty state", async ({ page }) => {
    insertBoard("Restore me", { archived: true });
    insertBoard("Delete me", { archived: true });
    await open(page, "/boards/archived");
    await expect(archivedCards(page)).toHaveCount(2);

    await page.getByRole("button", { name: "Unarchive board Restore me" }).click();
    await expect(archivedCards(page)).toHaveText([/Delete me/]);

    acceptConfirm(page, 'Permanently delete board "Delete me"? This cannot be undone.');
    await page.getByRole("button", { name: "Delete board Delete me permanently" }).click();
    await expect(page.getByRole("heading", { name: "No archived boards" })).toBeVisible();

    await page.getByRole("link", { name: "Back to Boards" }).first().click();
    await expect(boardCards(page)).toHaveText([/Restore me/]);
  });
});

test.describe("board page", () => {
  test("renaming saves on Enter or blur, cancels on Escape, and ignores blank", async ({ page }) => {
    const id = insertBoard("Roadmap");
    await open(page, `/boards/${id}`);
    const input = page.getByTestId("board-title-input");

    await page.getByRole("button", { name: "Roadmap" }).click();
    await expect(input).toBeFocused();
    await input.fill("Roadmap 2027");
    await input.press("Enter");
    await expect(page.getByRole("button", { name: "Roadmap 2027" })).toBeVisible();

    await page.getByRole("button", { name: "Roadmap 2027" }).click();
    await input.fill("Nope");
    await input.press("Escape");
    await expect(page.getByRole("button", { name: "Roadmap 2027" })).toBeVisible();

    await page.getByRole("button", { name: "Roadmap 2027" }).click();
    await input.fill("   ");
    await input.press("Enter");
    await expect(page.getByRole("button", { name: "Roadmap 2027" })).toBeVisible();

    await page.getByRole("button", { name: "Roadmap 2027" }).click();
    await input.fill("Plans");
    await page.getByRole("heading", { name: "Start your workflow" }).click();
    await expect(page.getByRole("button", { name: "Plans" })).toBeVisible();

    await page.reload();
    await expect(page.getByRole("button", { name: "Plans" })).toBeVisible();
    // Confirmations quote the new title without a reload.
    await expect(page.getByRole("button", { name: "Archive" })).toHaveAttribute(
      "hx-confirm",
      'Archive board "Plans"? It will be moved to Archived Boards.',
    );
  });

  test("archive and unarchive from the board page return to the boards list", async ({ page }) => {
    const id = insertBoard("Quarter");
    await open(page, `/boards/${id}`);

    await page.getByRole("button", { name: "Quarter" }).click();
    await page.getByTestId("board-title-input").fill("Quarter 3");
    await page.getByTestId("board-title-input").press("Enter");
    acceptConfirm(page, 'Archive board "Quarter 3"? It will be moved to Archived Boards.');
    await page.getByRole("button", { name: "Archive", exact: true }).click();
    await expect(page).toHaveURL("/boards");
    await expect(page.getByRole("heading", { name: "No boards yet" })).toBeVisible();

    await open(page, `/boards/${id}`);
    await expect(page.getByText("This board is archived.")).toBeVisible();
    await expect(page.getByText("Archived", { exact: true })).toBeVisible();
    await expect(page.getByRole("link", { name: "← Back to Archived" })).toHaveAttribute("href", "/boards/archived");
    await page.getByTestId("unarchive-board-btn").click();
    await expect(page).toHaveURL("/boards");
    await expect(boardCards(page)).toHaveText([/Quarter 3/]);
  });

  test("delete from the board page removes it permanently", async ({ page }) => {
    const id = insertBoard("Scratch");
    await open(page, `/boards/${id}`);
    acceptConfirm(page, 'Permanently delete board "Scratch"? This cannot be undone.');
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(page).toHaveURL("/boards");
    await expect(page.getByRole("heading", { name: "No boards yet" })).toBeVisible();
  });
});

test.describe("missing boards", () => {
  // The browser logs the 404 response as a console error.
  test.use({ allowedErrors: [/status of 404/] });

  test("missing boards show a not-found page", async ({ page }) => {
    const response = await page.goto("/boards/999999");
    expect(response?.status()).toBe(404);
    await expect(page.getByRole("heading", { name: "Board not found" })).toBeVisible();
    await page.getByRole("link", { name: "Return to Boards" }).click();
    await expect(page).toHaveURL("/boards");
  });
});
