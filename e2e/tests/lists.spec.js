// @ts-check
import { test, expect, open, acceptConfirm, runSql } from "./fixtures.js";

/**
 * Creates a board directly in the database and returns its id.
 * @param {string} title
 * @param {boolean} [archived]
 * @returns {number}
 */
function insertBoard(title, archived = false) {
  const quoted = `'${title.replaceAll("'", "''")}'`;
  return Number(runSql(`INSERT INTO boards (title, archived_at) VALUES (${quoted}, ${archived ? "now()" : "NULL"}) RETURNING id`).trim());
}

/** @param {import("@playwright/test").Page} page */
const listColumns = (page) => page.getByTestId("list-column");

const deleteMessage = "Are you sure you want to delete this list? This action cannot be undone.";

test("the empty state creates the first list, then the sidebar form adds more", async ({ page }) => {
  const id = insertBoard("Roadmap");
  await open(page, `/boards/${id}`);
  await expect(page.getByRole("heading", { name: "Start your workflow" })).toBeVisible();
  const input = page.getByTestId("list-title-input");
  await expect(input).toBeFocused();
  await expect(page.getByTestId("add-list-btn")).toBeDisabled();
  await expect(page.getByTestId("add-list-btn")).toHaveText("Create List");

  await input.fill("  To do  ");
  await input.press("Enter");
  await expect(listColumns(page)).toHaveCount(1);
  await expect(listColumns(page).first()).toContainText("0 cards");
  await expect(listColumns(page).first()).toContainText("No cards yet");
  await expect(page.getByRole("heading", { name: "Start your workflow" })).toBeHidden();
  await expect(page.getByTestId("add-list-btn")).toHaveText("Add List");

  await page.getByTestId("list-title-input").fill("Done");
  await page.getByTestId("add-list-btn").click();
  await expect(listColumns(page)).toHaveText([/To do/, /Done/]);
  await expect(page.getByTestId("list-title-input")).toHaveValue("");
});

test("list titles save on Enter or blur, cancel on Escape, and ignore blank", async ({ page }) => {
  const id = insertBoard("Roadmap");
  const listId = Number(runSql(`INSERT INTO lists (board_id, title) VALUES (${id}, 'To do') RETURNING id`).trim());
  await open(page, `/boards/${id}`);
  const edit = page.getByTestId(`list-title-edit-input-${listId}`);
  const title = (/** @type {string} */ name) => page.getByRole("button", { name, exact: true });

  await title("To do").click();
  await expect(edit).toBeFocused();
  await edit.fill("Draft");
  await edit.press("Escape");
  await expect(title("To do")).toBeVisible();

  await title("To do").click();
  await expect(edit).toBeFocused();
  await edit.fill("   ");
  await edit.press("Enter");
  await expect(title("To do")).toBeVisible();

  await title("To do").click();
  await expect(edit).toBeFocused();
  await edit.fill("In progress");
  await listColumns(page).getByText("0 cards").click();
  await expect(title("In progress")).toBeVisible();
  await page.reload();
  await expect(listColumns(page)).toHaveText([/In progress/]);
  await expect(page.getByRole("button", { name: "Delete In progress list" })).toBeAttached();
});

test("deleting asks first, and deleting the last list restores the empty state", async ({ page }) => {
  const id = insertBoard("Roadmap");
  runSql(`INSERT INTO lists (board_id, title) VALUES (${id}, 'One'), (${id}, 'Two')`);
  await open(page, `/boards/${id}`);
  const deleteButton = (/** @type {string} */ name) => page.getByRole("button", { name: `Delete ${name} list` });

  await expect(deleteButton("One")).toHaveCSS("opacity", "0");
  await listColumns(page).first().hover();
  await expect(deleteButton("One")).toHaveCSS("opacity", "1");

  page.once("dialog", (dialog) => dialog.dismiss());
  await deleteButton("One").click();
  await expect(listColumns(page)).toHaveCount(2);

  acceptConfirm(page, deleteMessage);
  await deleteButton("One").click();
  await expect(listColumns(page)).toHaveText([/Two/]);

  await listColumns(page).first().hover();
  acceptConfirm(page, deleteMessage);
  await deleteButton("Two").click();
  await expect(page.getByRole("heading", { name: "Start your workflow" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "Start your workflow" })).toBeVisible();
});

test("lists belong to their board and archived boards remain editable", async ({ page }) => {
  const first = insertBoard("First", true);
  const second = insertBoard("Second");
  await open(page, `/boards/${first}`);
  await expect(page.getByText("This board is archived.")).toBeVisible();
  await page.getByTestId("list-title-input").fill("Archived list");
  await page.getByTestId("add-list-btn").click();
  await expect(listColumns(page)).toHaveCount(1);
  await open(page, `/boards/${second}`);
  await expect(listColumns(page)).toHaveCount(0);
  await open(page, `/boards/${first}`);
  await expect(listColumns(page)).toHaveText([/Archived list/]);
});

test("board content uses the app's contained width and lists scroll within it", async ({ page }) => {
  const id = insertBoard("Wide board");
  runSql(`INSERT INTO lists (board_id, title) SELECT ${id}, 'List ' || n FROM generate_series(1, 8) AS n`);

  for (const width of [1600, 375]) {
    await page.setViewportSize({ width, height: 900 });
    await open(page, `/boards/${id}`);
    const dimensions = await page.evaluate(() => {
      const header = document.querySelector("header > div");
      const content = document.querySelector("main > div");
      const scroller = document.getElementById("board-lists")?.parentElement;
      if (!header || !content || !scroller) throw new Error("Missing layout elements");
      const headerRect = header.getBoundingClientRect();
      const contentRect = content.getBoundingClientRect();
      return {
        headerLeft: headerRect.left,
        headerRight: headerRect.right,
        contentLeft: contentRect.left,
        contentRight: contentRect.right,
        scrollWidth: scroller.scrollWidth,
        clientWidth: scroller.clientWidth,
        documentWidth: document.documentElement.scrollWidth,
      };
    });
    expect(dimensions.contentLeft).toBe(dimensions.headerLeft);
    expect(dimensions.contentRight).toBe(dimensions.headerRight);
    expect(dimensions.scrollWidth).toBeGreaterThan(dimensions.clientWidth);
    expect(dimensions.documentWidth).toBe(width);
  }
});
