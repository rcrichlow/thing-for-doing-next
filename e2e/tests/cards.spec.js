// @ts-check
import { test, expect, open, acceptConfirm, runSql } from "./fixtures.js";

/**
 * Creates a board with lists directly in the database and returns their ids.
 * @param {string[]} titles
 * @returns {{ board: number, lists: number[] }}
 */
function insertBoardWithLists(titles) {
  const board = Number(runSql("INSERT INTO boards (title) VALUES ('Roadmap') RETURNING id").trim());
  const lists = titles.map((title) =>
    Number(runSql(`INSERT INTO lists (board_id, title) VALUES (${board}, '${title}') RETURNING id`).trim()),
  );
  return { board, lists };
}

/**
 * Adds cards to the end of a list directly in the database.
 * @param {number} list
 * @param {string[]} titles
 * @returns {void}
 */
function insertCards(list, titles) {
  titles.forEach((title, position) =>
    runSql(`INSERT INTO cards (list_id, title, position) VALUES (${list}, '${title}', ${position})`),
  );
}

/** @param {import("@playwright/test").Page} page */
const columns = (page) => page.getByTestId("list-column");

test("adding cards appends them to the list and closes the form", async ({ page }) => {
  const { board } = insertBoardWithLists(["To do"]);
  await open(page, `/boards/${board}`);
  const column = columns(page).first();

  await column.getByTestId("add-card-btn").click();
  const input = column.getByTestId("card-title-input");
  await expect(input).toBeFocused();
  await input.fill("Draft");
  await input.press("Escape");
  await expect(input).toBeHidden();
  await expect(column).toContainText("No cards yet");

  await column.getByTestId("add-card-btn").click();
  await column.getByTestId("card-title-input").fill("First card");
  await column.getByTestId("card-title-input").press("Enter");
  await expect(column.getByTestId("card-item")).toHaveText(["First card"]);
  await expect(column).toContainText("1 card");
  await expect(column).not.toContainText("No cards yet");
  await expect(column.getByTestId("card-title-input")).toBeHidden();

  await column.getByTestId("add-card-btn").click();
  await column.getByTestId("card-title-input").fill("Second card");
  await column.getByRole("button", { name: "Add", exact: true }).click();
  await expect(column.getByTestId("card-item")).toHaveText(["First card", "Second card"]);
  await expect(column).toContainText("2 cards");

  await page.reload();
  await expect(columns(page).first().getByTestId("card-item")).toHaveText(["First card", "Second card"]);
});

test("card details edit the title and description and update the board", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["To do"]);
  insertCards(lists[0], ["Write spec"]);
  await open(page, `/boards/${board}`);

  await page.getByTestId("card-item").click();
  const dialog = page.getByTestId("card-detail");
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("heading", { name: "Card details" })).toBeVisible();
  await expect(dialog.getByTestId("card-detail-description-text")).toHaveText("Click to add description");

  await dialog.getByTestId("card-detail-title-text").click();
  const title = dialog.getByTestId("card-detail-title-input");
  await expect(title).toBeFocused();
  await title.fill("Draft");
  await title.press("Escape");
  await expect(dialog.getByTestId("card-detail-title-text")).toHaveText("Write spec");
  await expect(dialog).toBeVisible();

  await dialog.getByTestId("card-detail-title-text").click();
  await expect(title).toBeFocused();
  await title.fill("Write the spec");
  await title.press("Enter");
  await expect(dialog.getByTestId("card-detail-title-text")).toHaveText("Write the spec");

  await dialog.getByTestId("card-detail-description-text").click();
  const description = dialog.getByTestId("card-detail-description-input");
  await expect(description).toBeFocused();
  await description.press("Shift+Home");
  await description.pressSequentially("First line");
  await description.press("Enter");
  await description.pressSequentially("Second line");
  await expect(description).toHaveValue("First line\nSecond line");
  await dialog.getByRole("button", { name: "Done" }).click();
  await expect(dialog).toBeHidden();

  const card = page.getByTestId("card-item");
  await expect(card).toContainText("Write the spec");
  await expect(card).toContainText("First line");

  await page.reload();
  await page.getByTestId("card-item").click();
  await expect(page.getByTestId("card-detail-description-text")).toHaveText("First line\nSecond line");

  // Clearing the description is allowed.
  await page.getByTestId("card-detail-description-text").click();
  await page.getByTestId("card-detail-description-input").fill("");
  await page.getByTestId("card-detail").getByRole("heading", { name: "Card details" }).click();
  await expect(page.getByTestId("card-detail-description-text")).toHaveText("Click to add description");
});

test("the card dialog closes with Escape, the close button, and the backdrop", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["To do"]);
  insertCards(lists[0], ["A card"]);
  await open(page, `/boards/${board}`);
  const dialog = page.getByTestId("card-detail");

  await page.getByTestId("card-item").click();
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();

  await page.getByTestId("card-item").click();
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(dialog).toBeHidden();

  await page.getByTestId("card-item").click();
  await expect(dialog).toBeVisible();
  await page.mouse.click(5, 5);
  await expect(dialog).toBeHidden();
});

test("deleting a card asks first, then closes the dialog", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["To do"]);
  insertCards(lists[0], ["Keep", "Remove"]);
  await open(page, `/boards/${board}`);
  const column = columns(page).first();

  await column.getByTestId("card-item").filter({ hasText: "Remove" }).click();
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByTestId("card-detail-delete-btn").click();
  await expect(page.getByTestId("card-detail")).toBeVisible();

  acceptConfirm(page, "Are you sure you want to delete this card? This action cannot be undone.");
  await page.getByTestId("card-detail-delete-btn").click();
  await expect(page.getByTestId("card-detail")).toBeHidden();
  await expect(column.getByTestId("card-item")).toHaveText(["Keep"]);
  await expect(column).toContainText("1 card");
});

test("deleting a list with cards can move them to another list", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Moved 1", "Moved 2"]);
  insertCards(lists[1], ["Already done"]);
  await open(page, `/boards/${board}`);

  await columns(page).first().hover();
  await page.getByRole("button", { name: "Delete Doing list" }).click();
  const dialog = page.getByTestId("list-delete-modal");
  await expect(dialog).toBeVisible();
  await expect(dialog).toContainText("Doing has 2 cards.");

  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toBeHidden();
  await expect(columns(page)).toHaveCount(2);

  await columns(page).first().hover();
  await page.getByRole("button", { name: "Delete Doing list" }).click();
  await page.getByTestId("transfer-list-select").selectOption({ label: "Done" });
  acceptConfirm(page, 'Are you sure you want to delete this list and move its cards to "Done"? This action cannot be undone.');
  await page.getByTestId("confirm-delete-list-btn").click();

  await expect(dialog).toBeHidden();
  await expect(columns(page)).toHaveCount(1);
  await expect(columns(page).first().getByTestId("card-item")).toHaveText(["Already done", "Moved 1", "Moved 2"]);
  await expect(columns(page).first()).toContainText("3 cards");
  await page.reload();
  await expect(columns(page).first().getByTestId("card-item")).toHaveText(["Already done", "Moved 1", "Moved 2"]);
});

test("deleting a list with cards without a transfer deletes the cards", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Gone"]);
  await open(page, `/boards/${board}`);

  await columns(page).first().hover();
  await page.getByRole("button", { name: "Delete Doing list" }).click();
  acceptConfirm(page, "Are you sure you want to delete this list? All cards in it will also be deleted. This action cannot be undone.");
  await page.getByTestId("confirm-delete-list-btn").click();
  await expect(page.getByTestId("list-delete-modal")).toBeHidden();
  await expect(columns(page)).toHaveText([/Done/]);
  expect(runSql("SELECT count(*) FROM cards").trim()).toBe("0");
});
