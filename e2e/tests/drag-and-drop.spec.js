// @ts-check
import { test, expect, open, runSql } from "./fixtures.js";

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

/**
 * A list's card titles in position order, as stored.
 * @param {number} list
 * @returns {string[]}
 */
function storedTitles(list) {
  const out = runSql(`SELECT title FROM cards WHERE list_id = ${list} ORDER BY position, id`).trim();
  return out === "" ? [] : out.split("\n");
}

/** @param {import("@playwright/test").Page} page */
const columns = (page) => page.getByTestId("list-column");

/**
 * @param {import("@playwright/test").Locator} locator
 * @returns {Promise<{ x: number, y: number, width: number, height: number }>}
 */
async function box(locator) {
  const result = await locator.boundingBox();
  if (!result) throw new Error("element is not visible");
  return result;
}

/**
 * Presses the mouse on a card and moves it past the drag threshold.
 * @param {import("@playwright/test").Page} page
 * @param {import("@playwright/test").Locator} card
 * @returns {Promise<void>}
 */
async function pickUp(page, card) {
  const from = await box(card);
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x + from.width / 2 + 12, from.y + from.height / 2 + 12, { steps: 3 });
}

/**
 * Drags a card with the mouse and drops it at a point.
 * @param {import("@playwright/test").Page} page
 * @param {import("@playwright/test").Locator} card
 * @param {{ x: number, y: number }} to
 * @returns {Promise<void>}
 */
async function dragTo(page, card, to) {
  await pickUp(page, card);
  await page.mouse.move(to.x, to.y, { steps: 10 });
  await page.mouse.up();
}

/**
 * The point just inside the top of an element, where a dragged card drops
 * before it.
 * @param {import("@playwright/test").Locator} locator
 */
async function topOf(locator) {
  const target = await box(locator);
  return { x: target.x + target.width / 2, y: target.y + 4 };
}

/**
 * A point on a column's "Add a card" footer, which drops at the list's end.
 * @param {import("@playwright/test").Locator} column
 */
async function endOf(column) {
  return topOf(column.getByTestId("add-card-btn"));
}

/**
 * Waits for the card move request to finish.
 * @param {import("@playwright/test").Page} page
 */
const moved = (page) => page.waitForResponse((response) => response.url().endsWith("/card-order"));

test("dragging a card to another list moves it and keeps its data", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Backlog", "In Progress"]);
  insertCards(lists[0], ["Task to Move", "Another Task"]);
  insertCards(lists[1], ["Already There"]);
  runSql(`UPDATE cards SET description = 'Details' WHERE title = 'Task to Move'`);
  await open(page, `/boards/${board}`);
  const [backlog, progress] = [columns(page).nth(0), columns(page).nth(1)];
  const card = backlog.getByTestId("card-item").filter({ hasText: "Task to Move" });

  const response = moved(page);
  await dragTo(page, card, await endOf(progress));
  expect((await response).status()).toBe(200);

  await expect(progress.getByTestId("card-item")).toHaveText(["Already There", /Task to Move/]);
  await expect(backlog.getByTestId("card-item")).toHaveText(["Another Task"]);
  await expect(backlog).toContainText("1 card");
  await expect(progress).toContainText("2 cards");
  // Dropping doesn't open the card.
  await expect(page.getByTestId("card-detail")).toHaveCount(0);
  expect(storedTitles(lists[1])).toEqual(["Already There", "Task to Move"]);

  await progress.getByTestId("card-item").filter({ hasText: "Task to Move" }).click();
  const dialog = page.getByTestId("card-detail");
  await expect(dialog).toBeVisible();
  await expect(dialog.getByTestId("card-detail-description-text")).toHaveText("Details");
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();

  await page.reload();
  await expect(columns(page).nth(1).getByTestId("card-item")).toHaveText(["Already There", /Task to Move/]);
});

test("dragging reorders cards within a list", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["To do"]);
  insertCards(lists[0], ["One", "Two", "Three"]);
  await open(page, `/boards/${board}`);
  const cards = columns(page).first().getByTestId("card-item");

  let response = moved(page);
  await dragTo(page, cards.filter({ hasText: "Three" }), await topOf(cards.filter({ hasText: "One" })));
  await response;
  await expect(cards).toHaveText(["Three", "One", "Two"]);
  expect(storedTitles(lists[0])).toEqual(["Three", "One", "Two"]);

  response = moved(page);
  await dragTo(page, cards.filter({ hasText: "Three" }), await endOf(columns(page).first()));
  await response;
  await expect(cards).toHaveText(["One", "Two", "Three"]);
  expect(storedTitles(lists[0])).toEqual(["One", "Two", "Three"]);
});

test("a card dragged into an empty list replaces its placeholder", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Only card"]);
  await open(page, `/boards/${board}`);
  const [doing, done] = [columns(page).nth(0), columns(page).nth(1)];

  await pickUp(page, doing.getByTestId("card-item"));
  const placeholder = done.getByText("No cards yet");
  await page.mouse.move((await box(done)).x + 40, (await box(placeholder)).y + 10, { steps: 10 });
  await expect(placeholder).toBeHidden();
  const response = moved(page);
  await page.mouse.up();
  await response;

  await expect(done.getByTestId("card-item")).toHaveText(["Only card"]);
  await expect(doing).toContainText("No cards yet");
  await expect(doing).toContainText("0 cards");
  await expect(done).not.toContainText("No cards yet");
  // Done now has cards and Doing has none, so their delete buttons swap.
  await done.hover();
  await expect(done.locator('[hx-get$="/delete"]')).toHaveCount(1);
  await expect(doing.locator('[hx-get$="/delete"]')).toHaveCount(0);
});

test("Escape cancels a drag, and a click without dragging still opens the card", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Stay"]);
  await open(page, `/boards/${board}`);
  let requests = 0;
  page.on("request", (request) => {
    if (request.url().endsWith("/card-order")) requests += 1;
  });
  const card = columns(page).first().getByTestId("card-item");

  await pickUp(page, card);
  const target = await endOf(columns(page).nth(1));
  await page.mouse.move(target.x, target.y, { steps: 10 });
  await expect(columns(page).nth(1).getByTestId("card-item")).toHaveCount(1);
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(columns(page).first().getByTestId("card-item")).toHaveText(["Stay"]);
  await expect(columns(page).nth(1).getByTestId("card-item")).toHaveCount(0);
  await expect(page.getByTestId("card-detail")).toHaveCount(0);

  await card.click();
  await expect(page.getByTestId("card-detail")).toBeVisible();
  expect(requests).toBe(0);
});

test("the dragged copy follows the pointer without lagging", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Follow"]);
  await open(page, `/boards/${board}`);
  const card = columns(page).first().getByTestId("card-item");
  const start = await box(card);
  await pickUp(page, card);
  const overlay = page.locator("[data-drag-overlay]");
  await expect(overlay).toHaveCount(1);

  for (const [dx, dy] of [[150, 20], [300, 60], [40, 100]]) {
    const pointer = { x: start.x + start.width / 2 + dx, y: start.y + start.height / 2 + dy };
    await page.mouse.move(pointer.x, pointer.y);
    // The card was picked up at its centre. Any easing would leave the copy
    // behind the pointer when read straight after the move.
    const copy = await box(overlay);
    expect(Math.abs(copy.x + copy.width / 2 - pointer.x)).toBeLessThan(2);
    expect(Math.abs(copy.y + copy.height / 2 - pointer.y)).toBeLessThan(2);
  }
  await page.keyboard.press("Escape");
  await page.mouse.up();
});

test("Alt+Arrow keys move the focused card between and within lists", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["First", "Second"]);
  insertCards(lists[1], ["Shipped"]);
  await open(page, `/boards/${board}`);
  const [doing, done] = [columns(page).nth(0), columns(page).nth(1)];

  await doing.getByTestId("card-item").filter({ hasText: "Second" }).focus();
  let response = moved(page);
  await page.keyboard.press("Alt+ArrowUp");
  await response;
  await expect(doing.getByTestId("card-item")).toHaveText(["Second", "First"]);
  await expect(page.getByTestId("card-item").filter({ hasText: "Second" })).toBeFocused();

  response = moved(page);
  await page.keyboard.press("Alt+ArrowRight");
  await response;
  await expect(done.getByTestId("card-item")).toHaveText(["Second", "Shipped"]);
  await expect(doing.getByTestId("card-item")).toHaveText(["First"]);
  await expect(page.getByTestId("card-item").filter({ hasText: "Second" })).toBeFocused();
  expect(storedTitles(lists[1])).toEqual(["Second", "Shipped"]);

  // Enter still opens the card.
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("card-detail")).toBeVisible();
});

test("overlapping moves are applied in order without showing stale columns", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["A", "B", "C"]);
  await open(page, `/boards/${board}`);
  const [doing, done] = [columns(page).nth(0), columns(page).nth(1)];
  /** @type {string[]} */
  const bodies = [];
  // Slow responses down so the moves overlap.
  await page.route("**/card-order", async (route) => {
    bodies.push(route.request().postData() ?? "");
    await new Promise((resolve) => setTimeout(resolve, 200));
    await route.continue();
  });
  // A draft in the add-list form must not be sent with the moves.
  await page.getByTestId("list-title-input").fill("Draft");
  /** @type {number[]} */
  const doingCounts = [];
  await page.exposeFunction("recordCount", (/** @type {number} */ count) => doingCounts.push(count));
  await page.evaluate(() => {
    const record = () => {
      const list = document.querySelector("[data-card-list]");
      /** @type {any} */ (window).recordCount(list?.querySelectorAll("[data-card]").length ?? -1);
    };
    new MutationObserver(record).observe(/** @type {Element} */ (document.querySelector("#board-lists")), {
      childList: true,
      subtree: true,
    });
  });

  await doing.getByTestId("card-item").filter({ hasText: "A" }).focus();
  await page.keyboard.press("Alt+ArrowRight");
  await doing.getByTestId("card-item").filter({ hasText: "B" }).focus();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(done.getByTestId("card-item")).toHaveText(["B", "A"]);
  await expect.poll(() => storedTitles(lists[1])).toEqual(["B", "A"]);
  await expect(doing).toContainText("1 card");
  await expect(done).toContainText("2 cards");
  expect(storedTitles(lists[0])).toEqual(["C"]);
  await expect(page.getByTestId("card-item").filter({ hasText: "B" })).toBeFocused();
  // Doing only ever lost cards; the first response, made before B moved,
  // didn't bring B back.
  expect(doingCounts).toEqual([...doingCounts].sort((a, b) => b - a));
  expect(bodies).toHaveLength(2);
  for (const body of bodies) expect(body).not.toContain("title");
});

test.describe("when the server fails", () => {
  test.use({ allowedErrors: [/status of 500/] });

  test("a failed move puts the card back and shows the alert", async ({ page }) => {
    const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
    insertCards(lists[0], ["Stuck"]);
    await open(page, `/boards/${board}`);
    await page.route("**/card-order", (route) => route.fulfill({ status: 500, body: "" }));

    await dragTo(page, columns(page).first().getByTestId("card-item"), await endOf(columns(page).nth(1)));
    await expect(page.locator("#app-alert")).toBeVisible();
    await expect(columns(page).first().getByTestId("card-item")).toHaveText(["Stuck"]);
    await expect(columns(page).nth(1).getByTestId("card-item")).toHaveCount(0);
    expect(storedTitles(lists[0])).toEqual(["Stuck"]);
  });
});

test("a column skipped while a card was dragged in it is refreshed afterwards", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["A", "B", "C"]);
  await open(page, `/boards/${board}`);
  const [doing, done] = [columns(page).nth(0), columns(page).nth(1)];
  await page.route("**/card-order", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });

  // A leaves Doing; B is picked up in Doing before the server answers.
  await doing.getByTestId("card-item").filter({ hasText: "A" }).focus();
  const response = moved(page);
  await page.keyboard.press("Alt+ArrowRight");
  await pickUp(page, doing.getByTestId("card-item").filter({ hasText: "B" }));
  await response;
  await expect(done).toContainText("1 card");
  // Doing is left as the page has it while B is held.
  await expect(doing).toContainText("3 cards");

  const refreshed = page.waitForResponse((r) => r.url().endsWith(`/lists/${lists[0]}/column`));
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await refreshed;
  await expect(doing).toContainText("2 cards");
  await expect(doing.getByTestId("card-item")).toHaveText(["B", "C"]);
});

test.describe("when the list is gone", () => {
  test.use({ allowedErrors: [/status of 404/] });

  test("a card dropped on a list deleted elsewhere returns to its real list", async ({ page }) => {
    const { board, lists } = insertBoardWithLists(["Doing", "Gone"]);
    insertCards(lists[0], ["Stay"]);
    await open(page, `/boards/${board}`);
    runSql(`DELETE FROM lists WHERE id = ${lists[1]}`);

    const response = moved(page);
    await dragTo(page, columns(page).first().getByTestId("card-item"), await endOf(columns(page).nth(1)));
    expect((await response).status()).toBe(404);
    await expect(columns(page)).toHaveCount(1);
    await expect(columns(page).first().getByTestId("card-item")).toHaveText(["Stay"]);
    await expect(page.locator("#app-alert")).toBeHidden();
    expect(storedTitles(lists[0])).toEqual(["Stay"]);
  });
});

test("a card deleted elsewhere disappears when dropped", async ({ page }) => {
  const { board, lists } = insertBoardWithLists(["Doing", "Done"]);
  insertCards(lists[0], ["Keep", "Deleted"]);
  await open(page, `/boards/${board}`);
  runSql(`DELETE FROM cards WHERE title = 'Deleted'`);

  const response = moved(page);
  await dragTo(page, columns(page).first().getByTestId("card-item").filter({ hasText: "Deleted" }), await endOf(columns(page).nth(1)));
  expect((await response).status()).toBe(200);
  await expect(page.getByTestId("card-item")).toHaveText(["Keep"]);
  await expect(columns(page).first()).toContainText("1 card");
  await expect(columns(page).nth(1)).toContainText("No cards yet");
});
