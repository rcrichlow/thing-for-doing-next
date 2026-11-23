/**
 * @file Application behaviour that HTMX attributes can't express. HTMX still
 * performs every request and swap; this script only handles keyboard and
 * focus behaviour, dialogs, and failure alerts. There is no build step: keep
 * it dependency-free and document every function with JSDoc.
 *
 * Behaviour is attached through data attributes:
 * - `data-autogrow` (textarea): grows with its content.
 * - `data-focus` (input, textarea): focused, cursor at the end, when inserted.
 * - `data-submit-on-enter` (textarea): Enter submits, Shift+Enter adds a line.
 * - `data-require-field="name"` (form): submit buttons are disabled while that
 *   field is blank; blank and repeated submissions are ignored.
 * - `data-cancel-on-escape` (form): Escape clicks its `[data-cancel]` button.
 * - `data-inline-edit` (form): click-to-edit field. Enter or leaving the
 *   `[data-inline-field]` saves; Escape, or saving blank or unchanged text,
 *   clicks its hidden `[data-inline-cancel]` button to restore the view.
 *   With `data-inline-allow-blank`, blank text is saved instead. In a
 *   textarea without `data-submit-on-enter`, Enter adds a line.
 * - `data-modal` (dialog): opened as a modal when inserted. Escape, a
 *   backdrop click, or a `[data-modal-close]` button closes it.
 * - `data-sets-confirm` (select): choosing an option copies its
 *   `data-confirm` to the form's `hx-confirm`.
 * - `data-local-date` (time): shows its `datetime` as a local date.
 * - `data-updated-at` (any element): localized "last changed" tooltip.
 * - `data-composer` (dialog): the working-memory composer; typing anywhere
 *   opens it.
 */
(() => {
  "use strict";

  /**
   * The parts of an HTMX 4 event's `detail` this script reads.
   * @typedef {object} HtmxEventDetail
   * @property {{ response?: { status: number } }} [ctx] The request context.
   * @property {unknown} [error] Set on `htmx:error`.
   */

  /** A text field this script manages. @typedef {HTMLInputElement | HTMLTextAreaElement} TextField */

  /** How long a failure alert stays visible, in milliseconds. */
  const ALERT_DURATION_MS = 8000;

  // --- Fields ---------------------------------------------------------------

  /**
   * Whether an element is a text field this script manages.
   * @param {unknown} element
   * @returns {element is TextField}
   */
  function isTextField(element) {
    return element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement;
  }

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
   * Focuses a field with the cursor after its last character.
   * @param {TextField} field
   * @returns {void}
   */
  function focusAtEnd(field) {
    field.focus();
    const end = field.value.length;
    field.setSelectionRange(end, end);
  }

  /**
   * Shows a `<time data-local-date>` element's `datetime` as a local date.
   * @param {HTMLTimeElement} time
   * @returns {void}
   */
  function localizeDate(time) {
    const date = new Date(time.dateTime);
    if (!Number.isNaN(date.getTime())) time.textContent = date.toLocaleDateString();
  }

  /**
   * Returns `root` (if it matches) and its descendants matching `selector`.
   * @param {Element} root
   * @param {string} selector
   * @returns {Element[]}
   */
  function selfAndDescendants(root, selector) {
    const found = root.matches(selector) ? [root] : [];
    found.push(...root.querySelectorAll(selector));
    return found;
  }

  /**
   * Applies data-attribute behaviour to `root` and its descendants. Runs for
   * the initial page and for every inserted element, rather than in HTMX swap
   * events, because the element that issued a request may be detached.
   * @param {Element} root
   * @returns {void}
   */
  function prepare(root) {
    for (const element of selfAndDescendants(root, "textarea[data-autogrow]")) {
      autogrow(/** @type {HTMLTextAreaElement} */ (element));
    }
    for (const element of selfAndDescendants(root, "time[data-local-date]")) {
      localizeDate(/** @type {HTMLTimeElement} */ (element));
    }
    for (const element of selfAndDescendants(root, "form[data-require-field]")) {
      updateRequired(/** @type {HTMLFormElement} */ (element));
    }
    for (const element of selfAndDescendants(root, "[data-focus]")) {
      element.removeAttribute("data-focus");
      if (isTextField(element)) focusAtEnd(element);
    }
    for (const element of selfAndDescendants(root, "dialog[data-modal]")) {
      const dialog = /** @type {HTMLDialogElement} */ (element);
      if (!dialog.open) dialog.showModal();
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
   * Grows textareas as they are typed in and keeps required-field forms'
   * submit buttons in sync.
   * @param {Event} event
   * @returns {void}
   */
  function onInput(event) {
    const target = event.target;
    if (target instanceof HTMLTextAreaElement && target.matches("[data-autogrow]")) autogrow(target);
    if (isTextField(target) && target.form?.matches("[data-require-field]")) updateRequired(target.form);
  }

  // --- Required fields ------------------------------------------------------

  /**
   * The field named by a form's `data-require-field`, if present.
   * @param {HTMLFormElement} form
   * @returns {TextField | null}
   */
  function requiredField(form) {
    const field = form.elements.namedItem(form.dataset.requireField ?? "");
    return isTextField(field) ? field : null;
  }

  /**
   * Whether a required-field form's field is blank.
   * @param {HTMLFormElement} form
   * @returns {boolean}
   */
  function isBlank(form) {
    return (requiredField(form)?.value.trim() ?? "") === "";
  }

  /**
   * Disables the form's submit buttons, including ones outside the form
   * associated through their `form` attribute, while its field is blank.
   * @param {HTMLFormElement} form
   * @returns {void}
   */
  function updateRequired(form) {
    const blank = isBlank(form);
    for (const element of form.elements) {
      if (element instanceof HTMLButtonElement && element.type === "submit") element.disabled = blank;
    }
  }

  /**
   * Stops blank or already-pending submissions of required-field forms before
   * they reach HTMX. Registered as a capture listener so it runs before
   * HTMX's own submit handler on the form.
   * @param {SubmitEvent} event
   * @returns {void}
   */
  function onRequiredSubmit(event) {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || !form.matches("[data-require-field]")) return;
    if (form.dataset.pending || isBlank(form)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    form.dataset.pending = "true";
  }

  /**
   * Allows a required-field form to submit again once its request finishes.
   * @param {Event} event An HTMX request event.
   * @returns {void}
   */
  function clearPending(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const form = target.closest("form[data-require-field]");
    if (form instanceof HTMLFormElement) delete form.dataset.pending;
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
   * The composer's form, if this page has a composer.
   * @returns {HTMLFormElement | null}
   */
  function composerForm() {
    return composer()?.querySelector("form") ?? null;
  }

  /**
   * Whether keystrokes are already going to a visible editable element.
   * Focus can linger for a moment on a field inside a dialog that just
   * closed; keystrokes sent there would be lost, so that doesn't count.
   * @param {Element | null} element
   * @returns {boolean}
   */
  function isTypingTarget(element) {
    const editable =
      isTextField(element) ||
      element instanceof HTMLSelectElement ||
      (element instanceof HTMLElement && element.isContentEditable);
    return editable && element.checkVisibility();
  }

  /**
   * Discards the composer's draft and any validation message.
   * @returns {void}
   */
  function resetComposer() {
    const form = composerForm();
    if (!form) return;
    form.reset();
    delete form.dataset.pending;
    form.querySelector("#composer-error")?.replaceChildren();
    prepare(form);
  }

  /**
   * Opens the composer when a printable character is typed anywhere on the
   * page, starting the draft with that character. The character is inserted
   * explicitly: browsers don't reliably deliver a keystroke to an element
   * that received focus during its keydown.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onTypeAnywhere(event) {
    const dialog = composer();
    const field = composerForm()?.querySelector("textarea");
    if (!dialog || !field || document.querySelector("dialog[open]")) return;
    if (event.ctrlKey || event.metaKey || event.altKey || event.isComposing) return;
    if (event.key.length !== 1 || /\s/.test(event.key)) return;
    if (isTypingTarget(document.activeElement)) return;
    event.preventDefault();
    resetComposer();
    dialog.showModal();
    field.value = event.key;
    focusAtEnd(field);
    field.dispatchEvent(new Event("input", { bubbles: true }));
  }

  /**
   * Closes the composer and discards its draft. Every way of closing it goes
   * through here rather than the dialog's `close` event, which is dispatched
   * asynchronously and could wipe a draft started by the next keystroke.
   * @returns {void}
   */
  function closeComposer() {
    const dialog = composer();
    if (!dialog?.open) return;
    dialog.close();
    resetComposer();
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
    if (target === dialog || target.closest("[data-composer-close]")) closeComposer();
  }

  /**
   * Handles Escape, which the browser reports as `cancel` before closing.
   * @param {Event} event
   * @returns {void}
   */
  function onComposerCancel(event) {
    if (event.target !== composer()) return;
    event.preventDefault();
    closeComposer();
  }

  // --- Inline editing -------------------------------------------------------

  /**
   * Leaves edit mode without saving by clicking the form's hidden
   * `[data-inline-cancel]` button, which fetches the read-only view.
   * @param {HTMLFormElement} form A `data-inline-edit` form.
   * @returns {void}
   */
  function cancelEdit(form) {
    form.dataset.done = "true";
    /** @type {HTMLButtonElement | null} */
    const cancel = form.querySelector("[data-inline-cancel]");
    cancel?.click();
  }

  /**
   * Saves an edit, unless the text is unchanged or blank (when blank isn't
   * allowed), which just leaves edit mode. Runs at most once per form.
   * @param {HTMLFormElement} form A `data-inline-edit` form.
   * @returns {void}
   */
  function saveEdit(form) {
    if (form.dataset.done) return;
    const field = form.querySelector("[data-inline-field]");
    if (!isTextField(field)) return;
    const value = field.value.trim();
    const blank = value === "" && !form.matches("[data-inline-allow-blank]");
    if (blank || value === field.defaultValue.trim()) return cancelEdit(form);
    form.dataset.done = "true";
    form.requestSubmit();
  }

  /**
   * Keyboard handling in text fields: Enter saves inline edits and submits
   * `data-submit-on-enter` textareas (Shift+Enter inserts a newline), and
   * Escape cancels inline edits and `data-cancel-on-escape` forms. Inline
   * textareas without `data-submit-on-enter` keep Enter for new lines.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onFieldKeydown(event) {
    const field = event.target;
    if (!isTextField(field) || event.isComposing) return;
    const form = field.form;
    const inline = form?.matches("[data-inline-edit]") ? form : null;

    if (event.key === "Escape") {
      if (inline) {
        event.preventDefault();
        cancelEdit(inline);
      } else if (form?.matches("[data-cancel-on-escape]")) {
        event.preventDefault();
        /** @type {HTMLButtonElement | null} */
        const cancel = form.querySelector("[data-cancel]");
        cancel?.click();
      }
      return;
    }
    if (event.key !== "Enter" || event.shiftKey) return;
    const submitsOnEnter = field.matches("[data-submit-on-enter]");
    if (inline) {
      if (field instanceof HTMLTextAreaElement && !submitsOnEnter) return;
      event.preventDefault();
      saveEdit(inline);
    } else if (field instanceof HTMLTextAreaElement && submitsOnEnter) {
      event.preventDefault();
      form?.requestSubmit();
    }
  }

  /**
   * Leaving an inline edit field saves it, as in the original app.
   * @param {FocusEvent} event
   * @returns {void}
   */
  function onInlineFocusOut(event) {
    const field = event.target;
    if (!isTextField(field) || !field.matches("[data-inline-field]")) return;
    const form = field.form;
    if (form?.matches("[data-inline-edit]")) saveEdit(form);
  }

  // --- Dialogs --------------------------------------------------------------

  /**
   * Closes a `data-modal` dialog from its close buttons or a backdrop click,
   * which targets the dialog element itself. The dialog stays in the
   * document so any save it started can still swap in its response. Dialogs
   * have no `id`: HTMX's settle step would otherwise copy the old dialog's
   * attributes onto its replacement and then remove `open`.
   * @param {MouseEvent} event
   * @returns {void}
   */
  function onModalClick(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const dialog = target.closest("dialog[data-modal]");
    if (!(dialog instanceof HTMLDialogElement)) return;
    if (target === dialog || target.closest("[data-modal-close]")) dialog.close();
  }

  /**
   * Copies the chosen option's `data-confirm` to its form's `hx-confirm`.
   * @param {Event} event
   * @returns {void}
   */
  function onConfirmSelect(event) {
    const select = event.target;
    if (!(select instanceof HTMLSelectElement) || !select.matches("[data-sets-confirm]")) return;
    const message = select.selectedOptions[0]?.dataset.confirm;
    if (message) select.form?.setAttribute("hx-confirm", message);
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
   * The form an HTMX event came from, if any.
   * @param {Event} event
   * @returns {HTMLFormElement | null}
   */
  function eventForm(event) {
    const target = event.target;
    return target instanceof Element ? target.closest("form") : null;
  }

  /**
   * Closes the composer after a successful save and re-enables an inline
   * edit whose save failed, so it can be retried.
   * @param {Event} event `htmx:after:request`
   * @returns {void}
   */
  function onAfterRequest(event) {
    clearPending(event);
    const status = responseStatus(event);
    const form = eventForm(event);
    if (!form || status === undefined) return;
    if (status === 201 && form === composerForm()) closeComposer();
    if (status >= 500 && form.matches("[data-inline-edit]")) delete form.dataset.done;
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
    const form = eventForm(event);
    if (form?.matches("[data-inline-edit]")) delete form.dataset.done;
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

  prepare(document.body);
  new MutationObserver(onMutations).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener("input", onInput);
  window.addEventListener("keydown", onTypeAnywhere);
  document.addEventListener("keydown", onFieldKeydown);
  document.addEventListener("click", onComposerClick);
  document.addEventListener("click", onModalClick);
  document.addEventListener("change", onConfirmSelect);
  document.addEventListener("click", onAlertDismiss);
  // `cancel` and `submit` are captured: `cancel` doesn't bubble, and the
  // submit guard must run before HTMX's listener on the form.
  document.addEventListener("cancel", onComposerCancel, true);
  document.addEventListener("submit", onRequiredSubmit, true);
  document.addEventListener("focusout", onInlineFocusOut);
  document.addEventListener("htmx:after:request", onAfterRequest);
  document.addEventListener("htmx:response:error", onResponseError);
  document.addEventListener("htmx:error", onRequestError);
  document.addEventListener("mouseover", onTimestampHover);
})();
