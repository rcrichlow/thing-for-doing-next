/**
 * @file Application behaviour that HTMX attributes can't express: keyboard
 * handling, the working-memory composer dialog, and request failure alerts.
 * HTMX still performs every request and swap. There is no build step; keep
 * this file dependency-free and document every function with JSDoc.
 */
(() => {
  "use strict";

  /**
   * The parts of an HTMX 4 event's `detail` this script reads.
   * @typedef {object} HtmxEventDetail
   * @property {{ response?: { status: number } }} [ctx] The request context.
   * @property {unknown} [error] Set on `htmx:error`.
   */

  /** How long a failure alert stays visible, in milliseconds. */
  const ALERT_DURATION_MS = 8000;

  // --- Textareas ------------------------------------------------------------

  /**
   * Resizes a textarea to fit its content, up to its CSS max-height.
   * @param {HTMLTextAreaElement} textarea
   * @returns {void}
   */
  function autogrow(textarea) {
    textarea.style.height = "auto";
    const borders = textarea.offsetHeight - textarea.clientHeight;
    textarea.style.height = `${textarea.scrollHeight + borders}px`;
  }

  /**
   * Focuses a textarea with the cursor after its last character.
   * @param {HTMLTextAreaElement} textarea
   * @returns {void}
   */
  function focusAtEnd(textarea) {
    textarea.focus();
    const end = textarea.value.length;
    textarea.setSelectionRange(end, end);
  }

  /**
   * Applies `data-autogrow` and `data-focus` to `root` and its descendants.
   * Swapped-in content is prepared here rather than in HTMX swap events,
   * because the element that issued a request may already be detached.
   * @param {Element} root
   * @returns {void}
   */
  function prepare(root) {
    const selector = "textarea[data-autogrow], textarea[data-focus]";
    /** @type {HTMLTextAreaElement[]} */
    const elements = root instanceof HTMLTextAreaElement && root.matches(selector) ? [root] : [];
    elements.push(...root.querySelectorAll("textarea"));
    for (const element of elements) {
      if (!element.matches(selector)) continue;
      if (element.hasAttribute("data-autogrow")) autogrow(element);
      if (element.hasAttribute("data-focus")) {
        element.removeAttribute("data-focus");
        focusAtEnd(element);
      }
    }
  }

  /**
   * Prepares every element added to the document.
   * @param {MutationRecord[]} mutations
   * @returns {void}
   */
  function onMutations(mutations) {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node instanceof Element) prepare(node);
      }
    }
  }

  /**
   * Grows textareas as they are typed in and keeps the composer's submit
   * button in sync with its content.
   * @param {Event} event
   * @returns {void}
   */
  function onInput(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (target instanceof HTMLTextAreaElement && target.matches("[data-autogrow]")) autogrow(target);
    if (target.closest("#working-memory-form")) updateComposerSubmit();
  }

  // --- Composer -------------------------------------------------------------

  /**
   * The working-memory composer dialog, if this page has one.
   * @returns {HTMLDialogElement | null}
   */
  function composer() {
    return document.querySelector("dialog[data-composer]");
  }

  /**
   * The composer's content field, if this page has a composer.
   * @returns {HTMLTextAreaElement | null}
   */
  function composerInput() {
    return composer()?.querySelector("textarea") ?? null;
  }

  /**
   * Disables the composer's submit button while its content is blank.
   * @returns {void}
   */
  function updateComposerSubmit() {
    /** @type {HTMLButtonElement | null | undefined} */
    const submit = composer()?.querySelector("[data-composer-submit]");
    const input = composerInput();
    if (submit && input) submit.disabled = input.value.trim() === "";
  }

  /**
   * Whether keystrokes are already going to an editable element.
   * @param {Element | null} element
   * @returns {boolean}
   */
  function isTypingTarget(element) {
    return (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement ||
      (element instanceof HTMLElement && element.isContentEditable)
    );
  }

  /**
   * Opens the composer when a printable character is typed anywhere on the
   * page. Focus moves during keydown, so the browser inserts the character
   * into the composer.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onTypeAnywhere(event) {
    const dialog = composer();
    const input = composerInput();
    if (!dialog || !input || document.querySelector("dialog[open]")) return;
    if (event.ctrlKey || event.metaKey || event.altKey || event.isComposing) return;
    if (event.key.length !== 1 || /\s/.test(event.key)) return;
    if (isTypingTarget(document.activeElement)) return;
    // Also reset here: the `close` event that normally clears the draft is
    // dispatched asynchronously and may not have run yet.
    resetComposer();
    dialog.showModal();
    input.focus();
  }

  /**
   * Closes the composer from its Close/Cancel buttons or a backdrop click.
   * Clicks on the `::backdrop` target the dialog element itself.
   * @param {MouseEvent} event
   * @returns {void}
   */
  function onComposerClick(event) {
    const dialog = composer();
    const target = event.target;
    if (!dialog || !(target instanceof Element)) return;
    if (target === dialog || target.closest("[data-composer-close]")) dialog.close();
  }

  /**
   * Discards the composer's draft and any validation message.
   * @returns {void}
   */
  function resetComposer() {
    const form = composer()?.querySelector("form");
    const input = composerInput();
    form?.reset();
    form?.querySelector("#composer-error")?.replaceChildren();
    if (input) autogrow(input);
    updateComposerSubmit();
  }

  /**
   * Discards the draft whenever the composer closes (Escape, backdrop,
   * Cancel, or after saving).
   * @param {Event} event
   * @returns {void}
   */
  function onComposerClose(event) {
    if (event.target === composer()) resetComposer();
  }

  /**
   * Stops blank or already-pending composer submissions before they reach
   * HTMX. Registered as a capture listener so it runs before HTMX's own
   * submit handler on the form.
   * @param {SubmitEvent} event
   * @returns {void}
   */
  function onComposerSubmit(event) {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || form.id !== "working-memory-form") return;
    const content = /** @type {HTMLTextAreaElement} */ (form.elements.namedItem("content"));
    if (form.dataset.pending || content.value.trim() === "") {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    form.dataset.pending = "true";
  }

  /**
   * Allows the composer to submit again after its request finishes.
   * @param {Event} event An HTMX request event.
   * @returns {void}
   */
  function clearPending(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const form = target.closest("#working-memory-form");
    if (form instanceof HTMLFormElement) delete form.dataset.pending;
  }

  // --- Inline editing -------------------------------------------------------

  /**
   * Leaves edit mode without saving by triggering the form's hidden
   * `data-entry-cancel` button, which fetches the read-only entry.
   * @param {HTMLFormElement} form A `data-entry-edit` form.
   * @returns {void}
   */
  function cancelEdit(form) {
    form.dataset.done = "true";
    /** @type {HTMLButtonElement | null} */
    const cancel = form.querySelector("[data-entry-cancel]");
    cancel?.click();
  }

  /**
   * Saves an edit, unless the text is blank or unchanged, which just leaves
   * edit mode. Runs at most once per form.
   * @param {HTMLFormElement} form A `data-entry-edit` form.
   * @returns {void}
   */
  function saveEdit(form) {
    if (form.dataset.done) return;
    const textarea = form.querySelector("textarea");
    if (!textarea) return;
    const value = textarea.value.trim();
    if (value === "" || value === textarea.defaultValue.trim()) return cancelEdit(form);
    form.dataset.done = "true";
    form.requestSubmit();
  }

  /**
   * Keyboard handling inside textareas: Enter saves, Shift+Enter inserts a
   * newline, and Escape cancels an inline edit.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onTextareaKeydown(event) {
    const textarea = event.target;
    if (!(textarea instanceof HTMLTextAreaElement) || event.isComposing) return;
    const editForm = textarea.closest("form[data-entry-edit]");

    if (event.key === "Escape" && editForm instanceof HTMLFormElement) {
      event.preventDefault();
      cancelEdit(editForm);
      return;
    }
    if (event.key !== "Enter" || event.shiftKey || !textarea.matches("[data-submit-on-enter]")) return;
    event.preventDefault();
    if (editForm instanceof HTMLFormElement) {
      saveEdit(editForm);
    } else if (textarea.value.trim() !== "") {
      textarea.form?.requestSubmit();
    }
  }

  /**
   * Leaving an inline edit field saves it, as in the original app.
   * @param {FocusEvent} event
   * @returns {void}
   */
  function onEditFocusOut(event) {
    const textarea = event.target;
    if (!(textarea instanceof HTMLTextAreaElement)) return;
    const form = textarea.closest("form[data-entry-edit]");
    if (form instanceof HTMLFormElement) saveEdit(form);
  }

  // --- Request outcomes -----------------------------------------------------

  /** @type {number | undefined} */
  let alertTimer;

  /**
   * The page-level failure alert from the layout.
   * @returns {HTMLElement | null}
   */
  function alertElement() {
    return document.getElementById("app-alert");
  }

  /**
   * Shows the failure alert for `ALERT_DURATION_MS`.
   * @returns {void}
   */
  function showAlert() {
    const alert = alertElement();
    if (!alert) return;
    alert.hidden = false;
    clearTimeout(alertTimer);
    alertTimer = setTimeout(() => (alert.hidden = true), ALERT_DURATION_MS);
  }

  /**
   * Hides the failure alert when its dismiss button is clicked.
   * @param {MouseEvent} event
   * @returns {void}
   */
  function onAlertDismiss(event) {
    const target = event.target;
    const alert = alertElement();
    if (alert && target instanceof Element && target.closest("[data-alert-dismiss]")) alert.hidden = true;
  }

  /**
   * Reads the response status from an HTMX event, if it has one.
   * @param {Event} event
   * @returns {number | undefined}
   */
  function responseStatus(event) {
    const detail = /** @type {CustomEvent<HtmxEventDetail>} */ (event).detail;
    return detail?.ctx?.response?.status;
  }

  /**
   * Closes the composer after a successful save and re-enables an inline
   * edit form whose save failed, so it can be retried.
   * @param {Event} event `htmx:after:request`
   * @returns {void}
   */
  function onAfterRequest(event) {
    clearPending(event);
    const status = responseStatus(event);
    const target = event.target;
    const form = target instanceof Element ? target.closest("form") : null;
    if (!form || status === undefined) return;
    if (status === 201 && form.id === "working-memory-form") composer()?.close();
    if (status >= 500 && form.matches("[data-entry-edit]")) delete form.dataset.done;
  }

  /**
   * Shows the alert for server errors. HTMX is configured not to swap 5xx
   * responses, so the page is otherwise unchanged.
   * @param {Event} event `htmx:response:error`
   * @returns {void}
   */
  function onResponseError(event) {
    const status = responseStatus(event);
    if (status !== undefined && status >= 500) showAlert();
  }

  /**
   * Handles network failures and other request errors.
   * @param {Event} event `htmx:error`
   * @returns {void}
   */
  function onRequestError(event) {
    clearPending(event);
    const target = event.target;
    if (target instanceof Element) target.closest("[data-entry-edit]")?.removeAttribute("data-done");
    showAlert();
  }

  /**
   * Sets a localized "last changed" tooltip on first hover.
   * @param {MouseEvent} event
   * @returns {void}
   */
  function onTimestampHover(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const element = target.closest("[data-updated-at]");
    if (!(element instanceof HTMLElement) || element.title) return;
    const date = new Date(element.dataset.updatedAt ?? "");
    if (!Number.isNaN(date.getTime())) element.title = date.toLocaleString();
  }

  new MutationObserver(onMutations).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener("input", onInput);
  window.addEventListener("keydown", onTypeAnywhere);
  document.addEventListener("keydown", onTextareaKeydown);
  document.addEventListener("click", onComposerClick);
  document.addEventListener("click", onAlertDismiss);
  // `close` and `submit` are captured: `close` doesn't bubble, and the submit
  // guard must run before HTMX's listener on the form.
  document.addEventListener("close", onComposerClose, true);
  document.addEventListener("submit", onComposerSubmit, true);
  document.addEventListener("focusout", onEditFocusOut);
  document.addEventListener("htmx:after:request", onAfterRequest);
  document.addEventListener("htmx:response:error", onResponseError);
  document.addEventListener("htmx:error", onRequestError);
  document.addEventListener("mouseover", onTimestampHover);
})();
