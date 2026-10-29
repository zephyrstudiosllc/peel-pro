(() => {
  "use strict";

  const config = window.PEEL_SITE_CONFIG || {};
  const status = document.querySelector("[data-release-status]");
  const releaseCTAs = Array.from(document.querySelectorAll("[data-release-cta]"));
  const releaseNotes = document.querySelector("[data-release-notes]");
  const peelProLink = document.querySelector("[data-peel-pro-link]");

  const isApprovedHTTPSURL = (value) => {
    if (typeof value !== "string" || value.trim() === "") {
      return false;
    }

    try {
      const url = new URL(value);
      return url.protocol === "https:" && url.hostname.length > 0;
    } catch {
      return false;
    }
  };

  const showPreviewMessage = () => {
    if (!status) {
      return;
    }

    status.textContent = "Peel Pro 2.0 is not released yet.";
    status.classList.add("is-visible");
  };

  if (isApprovedHTTPSURL(config.hostDownloadUrl)) {
    releaseCTAs.forEach((cta) => {
      cta.href = config.hostDownloadUrl;
      cta.removeAttribute("aria-disabled");
      cta.target = "_blank";
      cta.rel = "noopener";
      const label = cta.querySelector("[data-release-label]");
      if (label) {
        label.textContent = "Get Peel Pro";
      }
    });

    if (status) {
      status.textContent = "Peel Pro download is available. See the release notes for supported features.";
    }
  } else {
    releaseCTAs.forEach((cta) => {
      cta.setAttribute("aria-disabled", "true");
      cta.addEventListener("click", (event) => {
        event.preventDefault();
        showPreviewMessage();
      });
    });
  }

  if (isApprovedHTTPSURL(config.peelProAppStoreUrl) && peelProLink) {
    peelProLink.href = config.peelProAppStoreUrl;
    peelProLink.target = "_blank";
    peelProLink.rel = "noopener";
    peelProLink.removeAttribute("aria-disabled");
  } else if (peelProLink) {
    peelProLink.setAttribute("aria-disabled", "true");
    peelProLink.addEventListener("click", (event) => {
      event.preventDefault();
    });
  }

  if (isApprovedHTTPSURL(config.releaseNotesUrl) && releaseNotes) {
    releaseNotes.href = config.releaseNotesUrl;
    releaseNotes.removeAttribute("aria-disabled");
    releaseNotes.target = "_blank";
    releaseNotes.rel = "noopener";
  }
  // With no public release notes, retain the useful in-page release-goals link.
})();
