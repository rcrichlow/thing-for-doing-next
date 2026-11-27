// @ts-check
import { test, expect, open, runSql } from "./fixtures.js";

/** @param {import('@playwright/test').Page} page */
const modal = (page) => page.getByRole("dialog", { name: "Send to board" });

/** @param {import('@playwright/test').Page} page */
async function openSend(page) {
  await open(page, "/");
  await page.getByRole("button", { name: "Send to board" }).click();
  await expect(modal(page)).toBeVisible();
}

test("send to an existing list keeps the entry and appends the card", async ({ page }) => {
  runSql(`INSERT INTO working_memory_entries (content) VALUES (E'First line\nSecond <line>');
    INSERT INTO boards (title) VALUES ('Active'), ('Archived');
    UPDATE boards SET archived_at = now() WHERE title = 'Archived';
    INSERT INTO lists (board_id, title) VALUES (1, 'Todo'), (2, 'Hidden');
    INSERT INTO cards (list_id, title, position) VALUES (1, 'Existing', 0);`);
  await openSend(page);
  await expect(modal(page).getByTestId("send-to-board-entry-preview")).toHaveText("Entry: First line\nSecond <line>");
  const board = modal(page).getByLabel("Board", { exact: true });
  await expect(board.locator("option")).toHaveText(["Select a board", "Active", "+ Create new board"]);
  await expect(modal(page).getByLabel("List", { exact: true })).toBeDisabled();
  await board.selectOption({ label: "Active" });
  await expect(modal(page).getByLabel("List", { exact: true })).toBeEnabled();
  await modal(page).getByLabel("List", { exact: true }).selectOption({ label: "Todo" });
  await expect(modal(page).getByRole("button", { name: "Create card" })).toBeEnabled();
  await modal(page).getByRole("button", { name: "Create card" }).click();
  await expect(modal(page)).toBeHidden();
  await expect(page.getByTestId("wm-entry-1")).toContainText("First line\nSecond <line>");
  await open(page, "/boards/1");
  await expect(page.locator("#list-1")).toContainText("First line Second <line>");
  expect(runSql("SELECT string_agg(title, '|' ORDER BY position) FROM cards WHERE list_id = 1").trim()).toBe("Existing|First line Second <line>");
});

test("create a board and list inside the dialog and reopen it", async ({ page }) => {
  runSql("INSERT INTO working_memory_entries (content) VALUES ('Capture');");
  await openSend(page);
  await modal(page).getByLabel("Board", { exact: true }).selectOption("new");
  const boardName = modal(page).getByRole("textbox", { name: "New board name" });
  await expect(boardName).toBeFocused();
  await boardName.fill("Projects");
  await boardName.press("Enter");
  await expect(modal(page).getByLabel("Board", { exact: true })).toHaveValue("1");
  await modal(page).getByLabel("List", { exact: true }).selectOption("new");
  const listName = modal(page).getByRole("textbox", { name: "New list name" });
  await expect(listName).toBeFocused();
  await listName.fill("Next up");
  await listName.press("Enter");
  await expect(modal(page).getByLabel("List", { exact: true })).toHaveValue("1");
  await modal(page).getByRole("button", { name: "Create card" }).click();
  await expect(modal(page)).toBeHidden();
  await page.getByRole("button", { name: "Send to board" }).click();
  await expect(modal(page)).toBeVisible();
  await expect(modal(page).getByLabel("Board", { exact: true })).toHaveValue("");
  await page.keyboard.press("Escape");
  await expect(modal(page)).toBeHidden();
  expect(runSql("SELECT title FROM cards").trim()).toBe("Capture");
});

test.describe("stale destinations", () => {
  test.use({ allowedErrors: [/422/] });
  test("changing boards resets the list and stale destinations are rejected", async ({ page }) => {
    runSql("INSERT INTO working_memory_entries (content) VALUES ('Capture'); INSERT INTO boards (title) VALUES ('One'), ('Two'); INSERT INTO lists (board_id, title) VALUES (1, 'First'), (2, 'Second');");
    await openSend(page);
    await modal(page).getByLabel("Board", { exact: true }).selectOption("1");
    await expect(modal(page).getByLabel("List", { exact: true }).locator("option[value='1']")).toHaveCount(1);
    await modal(page).getByLabel("List", { exact: true }).selectOption("1");
    await expect(modal(page).getByRole("button", { name: "Create card" })).toBeEnabled();
    await modal(page).getByLabel("Board", { exact: true }).selectOption("2");
    await expect(modal(page).getByLabel("List", { exact: true })).toHaveValue("");
    await modal(page).getByLabel("List", { exact: true }).selectOption("2");
    await expect(modal(page).getByRole("button", { name: "Create card" })).toBeEnabled();
    runSql("DELETE FROM lists WHERE id = 2");
    await modal(page).getByRole("button", { name: "Create card" }).click();
    await expect(modal(page).getByRole("alert")).toContainText("destination is no longer available");
    await expect(modal(page).getByRole("button", { name: "Create card" })).toBeDisabled();
    expect(runSql("SELECT count(*) FROM cards").trim()).toBe("0");
  });
});

test.describe("a deleted entry", () => {
  test.use({ allowedErrors: [/404/] });
  test("shows a closable message instead of creating a card", async ({ page }) => {
    runSql("INSERT INTO working_memory_entries (content) VALUES ('Capture'); INSERT INTO boards (title) VALUES ('Board'); INSERT INTO lists (board_id, title) VALUES (1, 'List');");
    await openSend(page);
    await modal(page).getByLabel("Board", { exact: true }).selectOption("1");
    await expect(modal(page).getByLabel("List", { exact: true })).toBeEnabled();
    await modal(page).getByLabel("List", { exact: true }).selectOption("1");
    await expect(modal(page).getByRole("button", { name: "Create card" })).toBeEnabled();
    runSql("DELETE FROM working_memory_entries");
    await modal(page).getByRole("button", { name: "Create card" }).click();
    await expect(modal(page).getByRole("alert")).toHaveText("This entry no longer exists.");
    await modal(page).getByRole("button", { name: "Close" }).click();
    await expect(modal(page)).toBeHidden();
    expect(runSql("SELECT count(*) FROM cards").trim()).toBe("0");
  });
});
