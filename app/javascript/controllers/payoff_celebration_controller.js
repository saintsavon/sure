import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { url: String };

  connect() {
    if (!this.hasUrlValue) return;

    this.element.classList.add("motion-safe:animate-pulse");
    setTimeout(
      () => this.element.classList.remove("motion-safe:animate-pulse"),
      1200,
    );
    fetch(this.urlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
          ?.content,
      },
      credentials: "same-origin",
    });
  }
}
