import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog-opener"
//
// Generic pairing for a trigger button + an inline `<dialog>` that both live
// in the DOM already (as opposed to the DS::Dialog turbo-frame pattern,
// where a link navigation loads the dialog's markup on demand). Wrap both
// the trigger and the `<dialog>` in an element with this controller, then
// point the trigger's `data-action` at `dialog-opener#open`.
export default class extends Controller {
  open() {
    const dialog = this.element.querySelector("dialog");
    if (!dialog) return;

    // DS--dialog only records prior focus (and restores it on close) when it
    // auto-opens on connect. Since we open it on demand here, capture the
    // trigger ourselves and return focus to it on close so keyboard and
    // screen-reader users aren't dropped to <body>.
    const trigger = document.activeElement;
    dialog.addEventListener(
      "close",
      () => {
        if (trigger && typeof trigger.focus === "function" && document.body.contains(trigger)) {
          trigger.focus();
        }
      },
      { once: true },
    );

    dialog.showModal();
  }
}
