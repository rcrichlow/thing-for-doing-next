// @ts-check
import { test, expect, open, acceptConfirm } from "./fixtures.js";

/** @param {import("@playwright/test").Page} page */
const entries = (page) => page.locator("#entries [data-testid^=wm-entry-]");
/** @param {import("@playwright/test").Page} page */
const composer = (page) => page.getByRole("dialog", { name: "New working memory entry" });
/** @param {import("@playwright/test").Page} page */
const editField = (page) => page.getByRole("textbox", { name: "Edit entry" });

/**
 * Opens the composer by typing and saves an entry.
 * @param {import("@playwright/test").Page} page
 * @param {string} text
 */
async function addEntry(page, text) {
  await page.keyboard.type(text);
  await page.keyboard.press("Enter");
  await expect(composer(page)).toBeHidden();
}

test.describe("working memory", () => {
  test.beforeEach(async ({ page }) => {
    await open(page, "/");
  });

  test("typing anywhere opens the composer and keeps the first keystroke", async ({ page }) => {
    await page.keyboard.type("Remember");
    await expect(composer(page)).toBeVisible();
    await expect(composer(page).getByRole("textbox")).toHaveValue("Remember");
    await expect(page.getByRole("button", { name: "Save entry" })).toBeEnabled();
  });

  test("the composer is centred in the window", async ({ page }) => {
    await page.keyboard.type("x");
    const box = await composer(page).boundingBox();
    const viewport = page.viewportSize();
    if (!box || !viewport) throw new Error("no layout");
    expect(Math.abs(box.x + box.width / 2 - viewport.width / 2)).toBeLessThan(2);
    expect(Math.abs(box.y + box.height / 2 - viewport.height / 2)).toBeLessThan(2);
  });

  test("Enter saves, Shift+Enter adds lines, newest first", async ({ page }) => {
    await page.keyboard.type("Remember");
    await page.keyboard.press("Shift+Enter");
    await page.keyboard.type("line two");
    await page.keyboard.press("Enter");
    await expect(composer(page)).toBeHidden();
    await expect(entries(page)).toHaveCount(1);
    await expect(entries(page).first()).toContainText("Remember\nline two");

    await addEntry(page, "Second");
    await expect(entries(page).first()).toContainText("Second");
  });

  test("typing right after saving or closing starts a new draft without losing keystrokes", async ({ page }) => {
    // Focus lingers on the closed dialog's field for a moment; keystrokes
    // arriving then used to be dropped.
    for (let i = 0; i < 10; i++) {
      await page.keyboard.type(`Entry ${i}`);
      await page.keyboard.press("Enter");
      await expect(composer(page)).toBeHidden();
      await page.keyboard.type("Next");
      await expect(composer(page).getByRole("textbox")).toHaveValue("Next");
      await page.keyboard.press("Escape");
      await expect(composer(page)).toBeHidden();
      await page.keyboard.type("Again");
      await expect(composer(page).getByRole("textbox")).toHaveValue("Again");
      await page.keyboard.press("Escape");
      await expect(composer(page)).toBeHidden();
    }
    await expect(entries(page)).toHaveCount(10);
  });

  test("Save entry button saves", async ({ page }) => {
    await page.keyboard.type("via button");
    await page.getByRole("button", { name: "Save entry" }).click();
    await expect(composer(page)).toBeHidden();
    await expect(entries(page)).toHaveText(["via button"]);
  });

  test("Escape and backdrop clicks discard the draft; blank can't be saved", async ({ page }) => {
    await page.keyboard.type("draft");
    await page.keyboard.press("Escape");
    await expect(composer(page)).toBeHidden();
    await page.keyboard.type("x");
    await expect(composer(page).getByRole("textbox")).toHaveValue("x");
    await page.mouse.click(5, 5);
    await expect(composer(page)).toBeHidden();

    await page.keyboard.type("a");
    await page.keyboard.press("Backspace");
    await expect(page.getByRole("button", { name: "Save entry" })).toBeDisabled();
    await page.keyboard.press("Enter");
    await expect(composer(page)).toBeVisible();
    await expect(entries(page)).toHaveCount(0);
  });

  test("inline editing saves on Enter or blur, cancels on Escape, reverts when emptied", async ({ page }) => {
    await addEntry(page, "First");
    await addEntry(page, "Second");
    const second = entries(page).first();
    const first = entries(page).nth(1);

    /**
     * Clicks an entry's text and waits for its edit field, as a person
     * would, before typing.
     * @param {import("@playwright/test").Locator} entry
     * @param {string} text
     */
    async function startEditing(entry, text) {
      await entry.getByRole("button", { name: text, exact: true }).click();
      await expect(editField(page)).toBeFocused();
    }

    await startEditing(second, "Second");
    await page.keyboard.type(" edited");
    await page.keyboard.press("Enter");
    await expect(second.getByRole("button", { name: "Second edited" })).toBeVisible();

    await startEditing(second, "Second edited");
    await page.keyboard.type(" nope");
    await page.keyboard.press("Escape");
    await expect(second.getByRole("button", { name: "Second edited" })).toBeVisible();

    await startEditing(first, "First");
    await page.keyboard.type(" blurred");
    await page.getByRole("heading", { name: "Working Memory", exact: true }).click();
    await expect(first.getByRole("button", { name: "First blurred" })).toBeVisible();

    await startEditing(second, "Second edited");
    await editField(page).fill("");
    await page.keyboard.press("Enter");
    await expect(second.getByRole("button", { name: "Second edited" })).toBeVisible();

    await startEditing(second, "Second edited");
    await page.keyboard.type("z");
    await expect(composer(page)).toBeHidden();
  });

  test("delete and Clear All ask first and persist", async ({ page }) => {
    await addEntry(page, "Keep");
    await addEntry(page, "Remove");

    page.once("dialog", (dialog) => dialog.dismiss());
    await entries(page).first().getByRole("button", { name: "Delete entry" }).click();
    await expect(entries(page)).toHaveCount(2);

    acceptConfirm(page, "Are you sure you want to delete this working memory entry? This action cannot be undone.");
    await entries(page).first().getByRole("button", { name: "Delete entry" }).click();
    await expect(entries(page)).toHaveText(["Keep"]);

    await page.reload();
    await expect(entries(page)).toHaveText(["Keep"]);

    acceptConfirm(page, "Are you sure you want to clear all working memory entries? This action cannot be undone.");
    await page.getByRole("button", { name: "Clear all working memory entries" }).click();
    await expect(entries(page)).toHaveCount(0);
  });
});
