// @ts-check
import { test, expect, open, runSql } from "./fixtures.js";

/** @returns {number} A board with three lists and a card in each. */
function setupBoard() {
  const board = Number(runSql("INSERT INTO boards (title) VALUES ('Board') RETURNING id").trim());
  for (const [position, title] of ["One", "Two", "Three"].entries()) {
    const list = Number(runSql(`INSERT INTO lists (board_id, title, position) VALUES (${board}, '${title}', ${position}) RETURNING id`).trim());
    runSql(`INSERT INTO cards (list_id, title, position) VALUES (${list}, '${title} card', 0)`);
  }
  return board;
}

/** @param {import('@playwright/test').Page} page */
const columns = (page) => page.getByTestId("list-column");
/** @param {import('@playwright/test').Page} page */
const titles = (page) => columns(page).locator('[id^="list-title-"]');
/** @param {import('@playwright/test').Page} page */
const moved = (page) => page.waitForResponse((response) => response.url().endsWith("/list-order"));

test("dragging a list saves its order and keeps cards in their columns", async ({ page }) => {
  const board = setupBoard();
  await open(page, `/boards/${board}`);
  const source = columns(page).nth(2).locator("[data-list-handle]");
  const target = columns(page).nth(0);
  const from = await source.boundingBox();
  const to = await target.boundingBox();
  if (!from || !to) throw new Error("columns not visible");
  const response = moved(page);
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x - 12, from.y + 10);
  await page.mouse.move(to.x + 20, from.y + 10, { steps: 10 });
  await page.mouse.up();
  expect((await response).status()).toBe(200);
  await expect(titles(page)).toHaveText(["Three", "One", "Two"]);
  await page.reload();
  await expect(titles(page)).toHaveText(["Three", "One", "Two"]);
  for (const [index, title] of ["Three", "One", "Two"].entries()) {
    await expect(columns(page).nth(index).getByTestId("card-item")).toHaveText([`${title} card`]);
  }
  await page.getByTestId("list-title-input").fill("Four");
  await page.getByTestId("add-list-btn").click();
  await expect(titles(page)).toHaveText(["Three", "One", "Two", "Four"]);
});

test("keyboard and buttons move lists, and Escape cancels a drag", async ({ page }) => {
  const board = setupBoard();
  await open(page, `/boards/${board}`);
  const handle = columns(page).nth(1).locator("[data-list-handle]");
  await handle.focus();
  let response = moved(page);
  await page.keyboard.press("Alt+ArrowLeft");
  await response;
  await expect(titles(page)).toHaveText(["Two", "One", "Three"]);
  await expect(columns(page).first().locator("[data-list-handle]")).toBeFocused();
  response = moved(page);
  await columns(page).first().getByRole("button", { name: "Move list right" }).click();
  await response;
  await expect(titles(page)).toHaveText(["One", "Two", "Three"]);

  const from = await columns(page).first().locator("[data-list-handle]").boundingBox();
  const to = await columns(page).nth(1).boundingBox();
  if (!from || !to) throw new Error("columns not visible");
  await page.mouse.move(from.x + 5, from.y + 5);
  await page.mouse.down();
  await page.mouse.move(to.x + to.width - 10, from.y + 5, { steps: 8 });
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(titles(page)).toHaveText(["One", "Two", "Three"]);
  await page.reload();
  await expect(titles(page)).toHaveText(["One", "Two", "Three"]);
});

test("a touch hold can drag a list", async ({ page }) => {
  const board = setupBoard();
  await open(page, `/boards/${board}`);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true });
  const from = await columns(page).nth(2).locator("[data-list-handle]").boundingBox();
  const to = await columns(page).first().boundingBox();
  if (!from || !to) throw new Error("columns not visible");
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: from.x + 5, y: from.y + 5 }] });
  await expect(page.locator("html")).toHaveAttribute("data-dragging-list", "");
  const response = moved(page);
  await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: to.x + 20, y: from.y + 5 }] });
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await response;
  await expect(titles(page)).toHaveText(["Three", "One", "Two"]);
  await page.reload();
  await expect(titles(page)).toHaveText(["Three", "One", "Two"]);
  await cdp.detach();
});

test("a list created while a move is pending is appended without undoing the move", async ({ page }) => {
  const board = setupBoard();
  await open(page, `/boards/${board}`);
  await page.route("**/list-order", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });
  await page.getByTestId("list-title-input").fill("Four");
  const response = moved(page);
  await columns(page).nth(1).getByRole("button", { name: "Move list left" }).click();
  await page.getByTestId("add-list-btn").click();
  await response;
  await expect(titles(page)).toHaveText(["Two", "One", "Three", "Four"]);
  await page.reload();
  await expect(titles(page)).toHaveText(["Two", "One", "Three", "Four"]);
});

test("a pending create response does not undo a list move", async ({ page }) => {
  const board = setupBoard();
  await open(page, `/boards/${board}`);
  await page.route(`**/boards/${board}/lists`, async (route) => {
    const response = await route.fetch();
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.fulfill({ response });
  });
  await page.getByTestId("list-title-input").fill("Four");
  await page.getByTestId("add-list-btn").click();
  const response = moved(page);
  await columns(page).nth(1).getByRole("button", { name: "Move list left" }).click();
  await response;
  await expect(titles(page)).toHaveText(["Two", "One", "Three", "Four"]);
  await page.reload();
  await expect(titles(page)).toHaveText(["Two", "One", "Three", "Four"]);
});

test.describe("when saving fails", () => {
  test.use({ allowedErrors: [/status of 500/] });
  test("restores the previous order and shows an alert", async ({ page }) => {
    const board = setupBoard();
    await open(page, `/boards/${board}`);
    await page.route("**/list-order", (route) => route.fulfill({ status: 500, body: "" }));
    await columns(page).nth(1).getByRole("button", { name: "Move list left" }).click();
    await expect(page.locator("#app-alert")).toBeVisible();
    await expect(titles(page)).toHaveText(["One", "Two", "Three"]);
    await expect(page.locator("#list-move-status")).toContainText("previous order was restored");
  });
});
