/**
 * @file Application behaviour that HTMX attributes can't express. HTMX still
 * performs every request and swap; this script handles keyboard and focus
 * behaviour, dialogs, card drag and drop, and failure alerts. There is no
 * build step: keep it dependency-free and document every function with JSDoc.
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
 * - `data-local-date` (time): shows its `datetime` as a local date.
 * - `data-updated-at` (any element): localized "last changed" tooltip.
 * - `data-composer` (dialog): the working-memory composer; typing anywhere
 *   opens it.
 * - `data-card="id"` (card in a `[data-card-list="id"]` container, inside a
 *   `[data-list-column]`): dragged between and within lists, or moved with
 *   Alt+Arrow keys. Each move is shown at once and sent to
 *   `PUT /cards/{id}/position`, whose response re-renders the affected
 *   columns; a failed move is undone. Moves are issued from `#card-moves`
 *   (with `hx-sync="queue all"`). `[data-board-scroll]` scrolls while
 *   dragging near its edges, and `[data-no-cards]` hides while a card is
 *   over its list.
 */
(() => {
  "use strict";

  /**
   * The parts of an HTMX 4 event's `detail` this script reads.
   * @typedef {object} HtmxEventDetail
   * @property {{ response?: { status: number }, cardMove?: CardMove }} [ctx] The request context.
   * @property {unknown} [error] Set on `htmx:error`.
   * @property {SwapTask[]} [tasks] Set on `htmx:before:swap`; may be edited.
   */

  /**
   * One swap of a response, such as a `<template hx type="partial">`.
   * @typedef {object} SwapTask
   * @property {Element | string | null} [target]
   */

  /**
   * The parts of the HTMX API this script calls.
   * @typedef {object} Htmx
   * @property {(verb: string, path: string, context: object) => Promise<void>} ajax
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

  // --- Card drag and drop ---------------------------------------------------

  /** How far, in pixels, a mouse press moves before it becomes a drag. */
  const DRAG_DISTANCE = 8;
  /** How long, in milliseconds, a touch is held before it becomes a drag. */
  const TOUCH_DELAY_MS = 250;
  /** How far, in pixels, a touch may move while being held; further scrolls. */
  const TOUCH_TOLERANCE = 5;
  /** Distance from a scrollable edge, in pixels, that scrolls while dragging. */
  const SCROLL_EDGE = 48;
  /** Pixels scrolled per animation frame near an edge. */
  const SCROLL_STEP = 12;
  /** Duration of the shift and drop animations, in milliseconds. */
  const MOVE_ANIMATION_MS = 150;

  /**
   * Where a card is: its list and its index among that list's other cards.
   * @typedef {object} CardPlace
   * @property {string} listId
   * @property {number} index
   */

  /**
   * A move sent to the server that hasn't finished.
   * @typedef {object} CardMove
   * @property {HTMLElement} card
   * @property {CardPlace} from Where to put the card back if the move fails.
   * @property {string[]} listIds The lists it changes.
   */

  /**
   * A pointer press on a card. It becomes a drag once the pointer moves far
   * enough, or for touch, once it is held long enough.
   * @typedef {object} Press
   * @property {HTMLElement} card
   * @property {number} pointerId
   * @property {boolean} touch
   * @property {number} startX
   * @property {number} startY
   * @property {number} x Latest pointer position.
   * @property {number} y
   * @property {number} [timer] The touch hold timer.
   * @property {Drag} [drag] Set once dragging.
   */

  /**
   * An active drag. The card itself stays in the lists, invisible, marking
   * where it will drop; a copy follows the pointer.
   * @typedef {object} Drag
   * @property {HTMLElement} overlay The copy under the pointer.
   * @property {number} offsetX The pointer's offset within the card.
   * @property {number} offsetY
   * @property {CardPlace} from
   * @property {number} frame The auto-scroll animation frame.
   */

  /** @type {Press | null} */
  let press = null;
  /**
   * Moves in the order they were sent. `#card-moves` queues them, so the
   * server applies them in this order too.
   * @type {CardMove[]}
   */
  const pendingMoves = [];
  /** Set as a drag ends, so its trailing click doesn't open the card. */
  let suppressClick = false;
  /** The card to refocus after a move response replaces it. @type {string | null} */
  let refocusCard = null;

  /**
   * The HTMX API, loaded before this script.
   * @returns {Htmx}
   */
  function htmxApi() {
    return /** @type {{ htmx: Htmx }} */ (/** @type {unknown} */ (window)).htmx;
  }

  /**
   * Whether animations should be skipped.
   * @returns {boolean}
   */
  function reducedMotion() {
    return matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  /**
   * The cards in a `[data-card-list]` container, in order.
   * @param {Element} list
   * @returns {HTMLElement[]}
   */
  function cardsIn(list) {
    return /** @type {HTMLElement[]} */ ([...list.querySelectorAll(":scope > [data-card]")]);
  }

  /**
   * The `[data-card-list]` container a card is in.
   * @param {HTMLElement} card
   * @returns {HTMLElement | null}
   */
  function listOf(card) {
    const list = card.parentElement;
    return list?.matches("[data-card-list]") ? list : null;
  }

  /**
   * The `[data-card-list]` container with the given list id.
   * @param {string} listId
   * @returns {HTMLElement | null}
   */
  function listById(listId) {
    return document.querySelector(`[data-card-list="${CSS.escape(listId)}"]`);
  }

  /**
   * Where a card currently is.
   * @param {HTMLElement} card
   * @returns {CardPlace | null}
   */
  function placeOf(card) {
    const list = listOf(card);
    if (!list) return null;
    return { listId: list.dataset.cardList ?? "", index: cardsIn(list).indexOf(card) };
  }

  /**
   * Hides a list's "No cards yet" placeholder while it holds a card.
   * @param {HTMLElement | null} list
   * @returns {void}
   */
  function updatePlaceholder(list) {
    const placeholder = list?.querySelector(":scope > [data-no-cards]");
    if (list && placeholder instanceof HTMLElement) placeholder.hidden = cardsIn(list).length > 0;
  }

  /**
   * Moves a card to `index` among the other cards of `list`, sliding the
   * cards it passes into their new places.
   * @param {HTMLElement} card
   * @param {HTMLElement} list
   * @param {number} index
   * @returns {void}
   */
  function placeCard(card, list, index) {
    const from = listOf(card);
    const others = cardsIn(list).filter((other) => other !== card);
    const before = others[index] ?? null;
    if (from === list && cardsIn(list)[index] === card) return;

    const shifting = [...new Set([...(from ? cardsIn(from) : []), ...others])].filter((other) => other !== card);
    const tops = new Map(shifting.map((other) => [other, other.getBoundingClientRect().top]));
    list.insertBefore(card, before);
    updatePlaceholder(from);
    updatePlaceholder(list);
    if (reducedMotion()) return;
    for (const other of shifting) {
      const shift = (tops.get(other) ?? 0) - other.getBoundingClientRect().top;
      if (shift === 0) continue;
      other.animate([{ transform: `translateY(${shift}px)` }, { transform: "none" }], {
        duration: MOVE_ANIMATION_MS,
        easing: "ease",
      });
    }
  }

  /**
   * Sends a card's move from `from` to where it is now, unless it is back
   * where it started. The response re-renders the affected columns.
   * @param {HTMLElement} card
   * @param {CardPlace} from
   * @returns {void}
   */
  function commitMove(card, from) {
    const to = placeOf(card);
    if (!to || (to.listId === from.listId && to.index === from.index)) return;
    /** @type {CardMove} */
    const move = { card, from, listIds: [from.listId, to.listId] };
    pendingMoves.push(move);
    void htmxApi().ajax("PUT", `/cards/${card.dataset.card}/position`, {
      source: "#card-moves",
      swap: "none",
      values: { list_id: to.listId, position: String(to.index) },
      cardMove: move,
    });
  }

  /**
   * Where a card dragged to (`x`, `y`) would drop: the list of the column
   * under the pointer, before the first other card whose middle is below the
   * pointer. Layout offsets are used rather than on-screen positions, which
   * shift while cards animate.
   * @param {HTMLElement} card
   * @param {number} x
   * @param {number} y
   * @returns {{ list: HTMLElement, index: number } | null}
   */
  function dropTarget(card, x, y) {
    const column = document.elementFromPoint(x, y)?.closest("[data-list-column]");
    const list = column?.querySelector("[data-card-list]");
    if (!(list instanceof HTMLElement)) return null;
    const top = y - list.getBoundingClientRect().top - list.clientTop + list.scrollTop;
    const others = cardsIn(list).filter((other) => other !== card);
    const index = others.findIndex((other) => top < other.offsetTop + other.offsetHeight / 2);
    return { list, index: index < 0 ? others.length : index };
  }

  /**
   * Moves the dragged copy to the pointer and the card to where it would
   * drop. Over no list, the card stays where it was last placed.
   * @returns {void}
   */
  function followPointer() {
    const drag = press?.drag;
    if (!press || !drag) return;
    drag.overlay.style.left = `${press.x - drag.offsetX}px`;
    drag.overlay.style.top = `${press.y - drag.offsetY}px`;
    const target = dropTarget(press.card, press.x, press.y);
    if (target) placeCard(press.card, target.list, target.index);
  }

  /**
   * Scrolls `element` by one step along `axis` when `at` is near its edge.
   * @param {Element | null | undefined} element
   * @param {number} at The pointer's coordinate along `axis`.
   * @param {"x" | "y"} axis
   * @returns {boolean} Whether it scrolled.
   */
  function scrollNearEdge(element, at, axis) {
    if (!(element instanceof HTMLElement)) return false;
    const rect = element.getBoundingClientRect();
    const [start, end] = axis === "x" ? [rect.left, rect.right] : [rect.top, rect.bottom];
    const step = at < start + SCROLL_EDGE ? -SCROLL_STEP : at > end - SCROLL_EDGE ? SCROLL_STEP : 0;
    if (step === 0) return false;
    const position = () => (axis === "x" ? element.scrollLeft : element.scrollTop);
    const before = position();
    element.scrollBy(axis === "x" ? { left: step } : { top: step });
    return position() !== before;
  }

  /**
   * Each animation frame of a drag, scrolls the board sideways and the list
   * under the pointer up or down when the pointer is near their edges.
   * @returns {void}
   */
  function autoScroll() {
    const drag = press?.drag;
    if (!press || !drag) return;
    const board = press.card.closest("[data-board-scroll]");
    const column = document.elementFromPoint(press.x, press.y)?.closest("[data-list-column]");
    const sideways = scrollNearEdge(board, press.x, "x");
    const vertical = scrollNearEdge(column?.querySelector("[data-card-list]"), press.y, "y");
    if (sideways || vertical) followPointer();
    drag.frame = requestAnimationFrame(autoScroll);
  }

  /**
   * Turns the press into a drag: hides the card, leaving its space, and
   * shows a lifted copy under the pointer, as in the original app.
   * @returns {void}
   */
  function startDrag() {
    if (!press || press.drag) return;
    const { card } = press;
    const from = placeOf(card);
    if (!from || !card.isConnected) {
      press = null;
      return;
    }
    const rect = card.getBoundingClientRect();
    const overlay = /** @type {HTMLElement} */ (card.cloneNode(true));
    for (const attribute of [...overlay.attributes]) {
      if (attribute.name !== "class") overlay.removeAttribute(attribute.name);
    }
    overlay.setAttribute("aria-hidden", "true");
    overlay.dataset.dragOverlay = "";
    overlay.classList.remove("shadow-sm", "border-zinc-700", "transition-all");
    overlay.classList.add("shadow-xl", "border-violet-500", "rotate-1");
    // The card's transition duration would otherwise ease every move, so
    // the copy would trail the pointer.
    Object.assign(overlay.style, {
      transition: "none",
      position: "fixed",
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      margin: "0",
      zIndex: "50",
      pointerEvents: "none",
    });
    document.body.append(overlay);
    card.style.transition = "none";
    card.style.opacity = "0";
    document.documentElement.dataset.draggingCard = "";
    getSelection()?.removeAllRanges();
    press.drag = {
      overlay,
      offsetX: press.startX - rect.left,
      offsetY: press.startY - rect.top,
      from,
      frame: requestAnimationFrame(autoScroll),
    };
    followPointer();
  }

  /**
   * Animates the dragged copy onto the card's place, then shows the card.
   * @param {HTMLElement} overlay
   * @param {HTMLElement} card
   * @returns {void}
   */
  function settleOverlay(overlay, card) {
    const finish = () => {
      overlay.remove();
      card.style.opacity = "";
      card.style.transition = "";
    };
    if (!card.isConnected || reducedMotion()) return finish();
    const from = overlay.getBoundingClientRect();
    const to = card.getBoundingClientRect();
    const shift = `translate(${to.left - from.left}px, ${to.top - from.top}px)`;
    overlay
      .animate([{ transform: "none" }, { transform: shift, rotate: "0deg" }], {
        duration: MOVE_ANIMATION_MS,
        easing: "ease",
        fill: "forwards",
      })
      .finished.then(finish, finish);
  }

  /**
   * Ends a press. A drag drops the card where it is and sends the move, or
   * when cancelled, puts it back where it started.
   * @param {boolean} cancelled
   * @returns {void}
   */
  function endPress(cancelled) {
    const current = press;
    press = null;
    if (!current) return;
    clearTimeout(current.timer);
    const { card, drag } = current;
    if (!drag) return;
    cancelAnimationFrame(drag.frame);
    delete document.documentElement.dataset.draggingCard;
    const list = listById(drag.from.listId);
    if (cancelled && list && card.isConnected) placeCard(card, list, drag.from.index);
    suppressClick = true;
    setTimeout(() => (suppressClick = false), 0);
    settleOverlay(drag.overlay, card);
    if (!cancelled && card.isConnected) commitMove(card, drag.from);
  }

  /**
   * Starts tracking a primary-button or touch press on a card.
   * @param {PointerEvent} event
   * @returns {void}
   */
  function onCardPointerDown(event) {
    if (press || !event.isPrimary || event.button !== 0) return;
    const target = event.target;
    const card = target instanceof Element ? target.closest("[data-card]") : null;
    if (!(card instanceof HTMLElement) || !listOf(card)) return;
    const { clientX: x, clientY: y } = event;
    const touch = event.pointerType === "touch";
    press = { card, pointerId: event.pointerId, touch, startX: x, startY: y, x, y };
    if (touch) press.timer = setTimeout(startDrag, TOUCH_DELAY_MS);
  }

  /**
   * Starts a mouse drag once the pointer has moved far enough, gives up on
   * a touch that moves before it is held long enough (letting it scroll),
   * and follows the pointer while dragging.
   * @param {PointerEvent} event
   * @returns {void}
   */
  function onPointerMove(event) {
    if (!press || event.pointerId !== press.pointerId) return;
    press.x = event.clientX;
    press.y = event.clientY;
    // The button was released outside the window.
    if (!press.touch && event.buttons === 0) return endPress(false);
    if (press.drag) return followPointer();
    const distance = Math.hypot(press.x - press.startX, press.y - press.startY);
    if (press.touch) {
      if (distance > TOUCH_TOLERANCE) endPress(true);
    } else if (distance > DRAG_DISTANCE) {
      startDrag();
    }
  }

  /**
   * Drops the card when the press ends.
   * @param {PointerEvent} event
   * @returns {void}
   */
  function onPointerUp(event) {
    if (press && event.pointerId === press.pointerId) endPress(false);
  }

  /**
   * Cancels the drag when the browser takes the pointer, e.g. to scroll.
   * @param {PointerEvent} event
   * @returns {void}
   */
  function onPointerCancel(event) {
    if (press && event.pointerId === press.pointerId) endPress(true);
  }

  /**
   * Escape cancels a drag.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onDragKeydown(event) {
    if (!press?.drag || event.key !== "Escape") return;
    event.preventDefault();
    endPress(true);
  }

  /**
   * Keeps a touch drag from scrolling the page. Registered as non-passive.
   * @param {TouchEvent} event
   * @returns {void}
   */
  function onTouchMove(event) {
    if (press?.drag) event.preventDefault();
  }

  /**
   * Keeps a touch held on a card from opening the context menu.
   * @param {Event} event
   * @returns {void}
   */
  function onCardContextMenu(event) {
    if (press?.touch) event.preventDefault();
  }

  /**
   * Swallows the click that follows a drag, so dropping doesn't open the
   * card. Registered as a capture listener so it runs before HTMX's.
   * @param {MouseEvent} event
   * @returns {void}
   */
  function onClickAfterDrag(event) {
    if (!suppressClick) return;
    suppressClick = false;
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  /**
   * Alt+Up/Down moves the focused card within its list, and Alt+Left/Right
   * moves it to the same place in the neighbouring list. Enter still opens it.
   * @param {KeyboardEvent} event
   * @returns {void}
   */
  function onCardKeydown(event) {
    const card = event.target;
    if (!(card instanceof HTMLElement) || !card.matches("[data-card]") || press) return;
    if (!event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    const list = listOf(card);
    const from = placeOf(card);
    if (!list || !from) return;
    let target = list;
    let index = from.index;
    if (event.key === "ArrowUp") {
      index -= 1;
    } else if (event.key === "ArrowDown") {
      index += 1;
    } else if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      const lists = [...document.querySelectorAll("[data-card-list]")];
      const next = lists[lists.indexOf(list) + (event.key === "ArrowLeft" ? -1 : 1)];
      if (next instanceof HTMLElement) target = next;
      index = Math.min(index, cardsIn(target).filter((other) => other !== card).length);
    } else {
      return;
    }
    // Alt+Left/Right would otherwise navigate the history.
    event.preventDefault();
    if (index < 0 || index >= cardsIn(target).filter((other) => other !== card).length + 1) return;
    placeCard(card, target, index);
    // Moving the card in the document took its focus.
    card.focus();
    card.scrollIntoView({ block: "nearest", inline: "nearest" });
    commitMove(card, from);
  }

  /**
   * The pending card move an HTMX event belongs to, if any.
   * @param {Event} event
   * @returns {CardMove | undefined}
   */
  function eventMove(event) {
    return /** @type {CustomEvent<HtmxEventDetail>} */ (event).detail?.ctx?.cardMove;
  }

  /**
   * Before a move response re-renders its columns, skips columns that a
   * later pending move (or the card being dragged) still changes; that
   * move's response re-renders them. Notes the focused card, if replaced.
   * @param {Event} event `htmx:before:swap`
   * @returns {void}
   */
  function onMoveBeforeSwap(event) {
    const move = eventMove(event);
    const tasks = /** @type {CustomEvent<HtmxEventDetail>} */ (event).detail?.tasks;
    if (!move || !tasks) return;
    const later = new Set(pendingMoves.slice(pendingMoves.indexOf(move) + 1).flatMap((other) => other.listIds));
    const focused = document.activeElement?.closest("[data-card]");
    for (let i = tasks.length - 1; i >= 0; i -= 1) {
      const target = tasks[i].target;
      const element = typeof target === "string" ? document.querySelector(target) : target;
      if (!element) continue;
      const listId = element.querySelector("[data-card-list]")?.getAttribute("data-card-list");
      if ((listId && later.has(listId)) || (press?.drag && element.contains(press.card))) {
        tasks.splice(i, 1);
      } else if (focused instanceof HTMLElement && element.contains(focused)) {
        refocusCard = focused.dataset.card ?? null;
      }
    }
  }

  /**
   * Refocuses the card a move response replaced.
   * @param {Event} event `htmx:after:swap`
   * @returns {void}
   */
  function onMoveAfterSwap(event) {
    if (!eventMove(event) || refocusCard === null) return;
    const card = document.querySelector(`[data-card="${CSS.escape(refocusCard)}"]`);
    refocusCard = null;
    if (card instanceof HTMLElement && (document.activeElement === document.body || !document.activeElement)) {
      card.focus();
    }
  }

  /**
   * Forgets a finished move, and puts the card back if the server refused
   * it or couldn't be reached. Server errors also show the alert.
   * @param {Event} event `htmx:finally:request`
   * @returns {void}
   */
  function onMoveFinished(event) {
    const move = eventMove(event);
    if (!move) return;
    pendingMoves.splice(pendingMoves.indexOf(move), 1);
    const status = /** @type {CustomEvent<HtmxEventDetail>} */ (event).detail.ctx?.response?.status;
    if (status !== undefined && status < 400) return;
    const list = listById(move.from.listId);
    if (list && move.card.isConnected) placeCard(move.card, list, move.from.index);
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
  document.addEventListener("pointerdown", onCardPointerDown);
  window.addEventListener("pointermove", onPointerMove);
  window.addEventListener("pointerup", onPointerUp);
  window.addEventListener("pointercancel", onPointerCancel);
  window.addEventListener("blur", () => endPress(true));
  window.addEventListener("click", onClickAfterDrag, true);
  document.addEventListener("keydown", onDragKeydown);
  document.addEventListener("keydown", onCardKeydown);
  document.addEventListener("touchmove", onTouchMove, { passive: false });
  document.addEventListener("contextmenu", onCardContextMenu);
  document.addEventListener("htmx:before:swap", onMoveBeforeSwap);
  document.addEventListener("htmx:after:swap", onMoveAfterSwap);
  document.addEventListener("htmx:finally:request", onMoveFinished);
})();
