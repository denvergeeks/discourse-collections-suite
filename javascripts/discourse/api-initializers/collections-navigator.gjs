import { apiInitializer } from "discourse/lib/api";
import launcherState from "../lib/collections-launcher-state";

export default apiInitializer("1.24.0", (api) => {
  let keyboardHandlerBound = false;
  let resizerBound = false;
  let activeModalState = null;
  let currentCleanup = null;
  let sidebarObserver = null;
  let rebuildScheduled = false;

  const KEYBOARD_THROTTLE_MS = 150;
  const SCROLL_THROTTLE_MS = 50;

  const debug = (...args) => {
    if (settings.collections_navigator_debug) {
      // eslint-disable-next-line no-console
      console.debug("[collections-navigator]", ...args);
    }
  };

  const externalLinkIcon = `
    <svg
      class="fa d-icon svg-icon svg-string"
      width="1em"
      height="1em"
      viewBox="0 0 512 512"
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
    >
      <use href="#collections-suite-open-external-link"></use>
    </svg>
  `;

  const navigatorLauncherIcon = `
    <svg
      class="fa d-icon svg-icon svg-string"
      width="1em"
      height="1em"
      viewBox="0 0 512 512"
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
    >
      <use href="#collections-suite-open-navigator"></use>
    </svg>
  `;

  function getScrollBehavior() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches
      ? "auto"
      : "smooth";
  }

  function throttle(func, wait) {
    let timeout;

    return function executedFunction(...args) {
      const later = () => {
        clearTimeout(timeout);
        func(...args);
      };

      clearTimeout(timeout);
      timeout = setTimeout(later, wait);
    };
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function normalizePath(url) {
    if (!url) {
      return window.location.pathname;
    }

    try {
      return url.startsWith("http") ? new URL(url).pathname : url;
    } catch {
      return window.location.pathname;
    }
  }

  function getCssPxNumber(element, varName, fallback) {
    const raw = getComputedStyle(element).getPropertyValue(varName).trim();

    if (!raw) {
      return fallback;
    }

    if (
      raw.startsWith("min(") ||
      raw.startsWith("max(") ||
      raw.startsWith("clamp(")
    ) {
      return fallback;
    }

    const parsed = parseFloat(raw.replace("px", ""));
    return Number.isNaN(parsed) ? fallback : parsed;
  }

  function isExternalUrl(href) {
    if (!href) {
      return false;
    }

    if (href.startsWith("http://") || href.startsWith("https://")) {
      try {
        const url = new URL(href);
        return url.hostname !== window.location.hostname;
      } catch {
        return false;
      }
    }

    return false;
  }

  function getTopicIdFromHref(href) {
    if (!href || isExternalUrl(href)) {
      return null;
    }

    const idMatch = href.match(/\/(\d+)$/);
    return idMatch ? idMatch[1] : null;
  }

  function getTopicSlugFromHref(href) {
    if (!href || isExternalUrl(href)) {
      return null;
    }

    try {
      const path = href.startsWith("http") ? new URL(href).pathname : href;
      const parts = path.split("/");
      return parts[2] || null;
    } catch {
      return null;
    }
  }

  function buildItems(links) {
    return Array.from(links).map((link) => {
      const href = link.getAttribute("href");

      let title = link
        .querySelector(".collection-link-content-text")
        ?.textContent?.trim();

      if (!title) {
        title = link
          .querySelector(".sidebar-section-link-content-text")
          ?.textContent?.trim();
      }

      if (!title) {
        title = link
          .querySelector("[class*='content-text']")
          ?.textContent?.trim();
      }

      if (!title) {
        title = link.textContent?.trim();
      }

      if (!title) {
        title = "Untitled";
      }

      const external = isExternalUrl(href);

      return {
        title,
        href,
        topicId: getTopicIdFromHref(href),
        slug: getTopicSlugFromHref(href),
        external,
      };
    });
  }

  function getPostContentNode() {
    let content = document.querySelector(
      ".topic-post[data-post-number='1'] .cooked"
    );

    if (!content) {
      content = document.querySelector(".topic-body .cooked");
    }

    return content?.cloneNode(true) || null;
  }

  function getTopicInsertAnchor() {
    return (
      document.querySelector(".posts") ||
      document.querySelector(".post-stream") ||
      document.querySelector(".topic-area") ||
      document.querySelector(".topic-body") ||
      document.querySelector(".topic-post") ||
      document.querySelector("#main-outlet")
    );
  }

  function enhanceCooked(element) {
    if (!element) {
      return;
    }

    api.applyDecoratorsToElement?.(element);
  }

  function cleanupExistingUi() {
    currentCleanup?.();
    currentCleanup = null;

    document
      .querySelectorAll(".collections-nav-injected")
      .forEach((el) => el.remove());
    document
      .querySelectorAll(".collections-nav-modal-overlay")
      .forEach((el) => el.remove());

    if (activeModalState?.hide) {
      activeModalState.hide();
    }

    activeModalState = null;
    launcherState.reset();
    document.body.classList.remove("collections-launcher-expanded");
    document.body.classList.remove("collections-is-resizing");
  }

  function ensureSidebarResizer(modal) {
    if (!modal) {
      return null;
    }

    let resizer = modal.querySelector(".collections-sidebar-resizer");
    if (resizer) {
      return resizer;
    }

    const splitBody = modal.querySelector(".modal-body-split");
    const contentArea = modal.querySelector(".modal-content-area");

    if (!splitBody || !contentArea) {
      return null;
    }

    resizer = document.createElement("div");
    resizer.className = "collections-sidebar-resizer";
    resizer.setAttribute("role", "separator");
    resizer.setAttribute("aria-orientation", "vertical");
    resizer.setAttribute("aria-label", "Resize collection sidebar");
    resizer.setAttribute("aria-valuemin", "240");
    resizer.tabIndex = 0;

    splitBody.insertBefore(resizer, contentArea);
    return resizer;
  }

  function bindSidebarResizer() {
    if (resizerBound) {
      return;
    }

    const onPointerDown = (event) => {
      const resizer = event.target.closest(".collections-sidebar-resizer");
      if (!resizer) {
        return;
      }

      const modal = resizer.closest(".collections-nav-modal");
      if (!modal || window.matchMedia("(max-width: 767px)").matches) {
        return;
      }

      const splitBody = modal.querySelector(".modal-body-split");
      if (!splitBody) {
        return;
      }

      event.preventDefault();

      const splitRect = splitBody.getBoundingClientRect();
      const minWidth = getCssPxNumber(
        modal,
        "--collections-sidebar-min-width",
        240
      );
      const maxWidthFallback = Math.max(
        minWidth,
        Math.floor(splitRect.width * 0.45)
      );
      const maxWidth = getCssPxNumber(
        modal,
        "--collections-sidebar-max-width",
        maxWidthFallback
      );

      resizer.setAttribute("aria-valuemax", String(Math.round(maxWidth)));

      modal.classList.add("is-resizing");
      document.body.classList.add("collections-is-resizing");

      const updateWidth = (clientX) => {
        const proposed = clientX - splitRect.left;
        const nextWidth = clamp(proposed, minWidth, maxWidth);
        modal.style.setProperty("--collections-sidebar-width", `${nextWidth}px`);
        resizer.setAttribute("aria-valuenow", String(Math.round(nextWidth)));
      };

      updateWidth(event.clientX);

      const onPointerMove = (moveEvent) => {
        updateWidth(moveEvent.clientX);
      };

      const stopDragging = () => {
        modal.classList.remove("is-resizing");
        document.body.classList.remove("collections-is-resizing");
        window.removeEventListener("pointermove", onPointerMove);
        window.removeEventListener("pointerup", stopDragging);
        window.removeEventListener("pointercancel", stopDragging);
      };

      window.addEventListener("pointermove", onPointerMove);
      window.addEventListener("pointerup", stopDragging);
      window.addEventListener("pointercancel", stopDragging);
    };

    const onKeyDown = (event) => {
      const resizer = event.target.closest(".collections-sidebar-resizer");
      if (!resizer) {
        return;
      }

      const modal = resizer.closest(".collections-nav-modal");
      if (!modal) {
        return;
      }

      const currentWidth = getCssPxNumber(
        modal,
        "--collections-sidebar-width",
        320
      );
      const minWidth = getCssPxNumber(
        modal,
        "--collections-sidebar-min-width",
        240
      );
      const splitBody = modal.querySelector(".modal-body-split");
      const splitRect = splitBody?.getBoundingClientRect();
      const maxWidthFallback = splitRect
        ? Math.max(minWidth, Math.floor(splitRect.width * 0.45))
        : 520;
      const maxWidth = getCssPxNumber(
        modal,
        "--collections-sidebar-max-width",
        maxWidthFallback
      );

      let nextWidth = null;

      if (event.key === "ArrowLeft") {
        nextWidth = currentWidth - 24;
      } else if (event.key === "ArrowRight") {
        nextWidth = currentWidth + 24;
      } else if (event.key === "Home") {
        nextWidth = minWidth;
      } else if (event.key === "End") {
        nextWidth = maxWidth;
      }

      if (nextWidth === null) {
        return;
      }

      event.preventDefault();
      nextWidth = clamp(nextWidth, minWidth, maxWidth);
      modal.style.setProperty("--collections-sidebar-width", `${nextWidth}px`);
      resizer.setAttribute("aria-valuenow", String(Math.round(nextWidth)));
      resizer.setAttribute("aria-valuemax", String(Math.round(maxWidth)));
    };

    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    resizerBound = true;
  }

  function renderNavText(collectionName, item, index, totalItems) {
    return `${collectionName}: ${item.title} (${index + 1}/${totalItems})`;
  }

  function renderCollectionItem(item, idx, activeIndex) {
    const isActive = idx === activeIndex;

    return `
      <li class="collection-item ${isActive ? "active" : ""}">
        <button
          class="collection-item-link ${item.external ? "external-link" : ""} ${isActive ? "active" : ""}"
          data-index="${idx}"
          title="${escapeHtml(item.title)}"
          type="button"
          aria-current="${isActive ? "true" : "false"}"
        >
          <span class="item-number">${idx + 1}</span>
          <span class="item-title">${escapeHtml(item.title)}</span>
          ${
            isActive
              ? '<span class="d-icon d-icon-check collections-active-check" aria-hidden="true"></span>'
              : ""
          }
          ${
            item.external
              ? `<span class="collections-external-link-button" aria-hidden="true">${externalLinkIcon}</span>`
              : ""
          }
        </button>
      </li>
    `;
  }

  function renderSliderItem(item, idx, activeIndex, totalItems) {
    const isActive = idx === activeIndex;

    return `
      <button
        class="slider-item ${isActive ? "active" : ""}"
        data-index="${idx}"
        title="${escapeHtml(item.title)}"
        type="button"
        aria-pressed="${isActive ? "true" : "false"}"
      >
        ${item.external ? externalLinkIcon : ""}
        <span class="slider-item-title">${escapeHtml(item.title)}</span>
        <span class="slider-item-count">${idx + 1}/${totalItems}</span>
      </button>
    `;
  }

  function loadExternalContent(url) {
    return `
      <div class="iframe-loading">Loading external content...</div>
      <iframe
        src="${escapeHtml(url)}"
        class="external-topic-iframe"
        sandbox="allow-same-origin allow-scripts allow-popups allow-forms allow-downloads allow-top-navigation"
        loading="lazy"
        title="External content: ${escapeHtml(url)}"
      ></iframe>
    `;
  }

  function buildNavigator(currentPath) {
    if (!settings.collections_navigator_enabled) {
      debug("navigator disabled by setting");
      cleanupExistingUi();
      return;
    }

    const sidebarPanel = document.querySelector(
      ".discourse-collections-sidebar-panel"
    );
    const insertAnchor = getTopicInsertAnchor();

    if (!sidebarPanel || !insertAnchor || !insertAnchor.parentNode) {
      debug("sidebar or insert anchor missing");
      cleanupExistingUi();
      return;
    }

    const links = sidebarPanel.querySelectorAll(".collection-sidebar-link");
    const items = buildItems(links);

    if (items.length < 2) {
      debug("not enough items to render navigator");
      cleanupExistingUi();
      return;
    }

    const collectionTitleEl = document.querySelector(".collection-sidebar__title");
    const collectionDescEl = document.querySelector(".collection-sidebar__desc");
    const collectionName =
      collectionTitleEl?.textContent?.trim() || "Collection";
    const collectionDesc = collectionDescEl?.textContent?.trim() || "";

    const currentIndex = items.findIndex((item) => {
      if (item.external || !item.slug) {
        return false;
      }

      return currentPath.includes(item.slug);
    });

    if (currentIndex === -1) {
      debug("current topic not found in collection", currentPath);
      cleanupExistingUi();
      return;
    }

    const existingNav = document.querySelector(".collections-item-nav-bar");
    const existingModal = document.querySelector(".collections-nav-modal-overlay");

    if (existingNav && existingModal) {
      debug("navigator already present");
      return;
    }

    cleanupExistingUi();

    const currentItem = items[currentIndex];
    const totalItems = items.length;
    const cookedNode = getPostContentNode();

    let selectedIndex = currentIndex;
    let sidebarOpen = false;
    let modalRequestId = 0;
    let pageRequestId = 0;

    launcherState.setExpanded(!!settings.slider_starts_expanded);
    document.body.classList.toggle(
      "collections-launcher-expanded",
      launcherState.isExpanded
    );

    const cleanupFns = [];
    const addCleanup = (fn) => cleanupFns.push(fn);

    const navBar = document.createElement("div");
    navBar.className = "collections-item-nav-bar collections-nav-injected";
    navBar.innerHTML = `
      <button class="btn btn--primary collections-nav-toggle" title="Open collection navigator" type="button">
        ${navigatorLauncherIcon}
        <span class="nav-text">${escapeHtml(
          renderNavText(collectionName, currentItem, currentIndex, totalItems)
        )}</span>
      </button>
      <div class="collections-quick-nav">
        <button class="btn btn--secondary collections-nav-prev" ${
          currentIndex === 0 ? "disabled" : ""
        } title="Previous (arrow key)" type="button">
          <svg class="fa d-icon d-icon-arrow-left svg-icon fa-width-auto svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
            <use href="#arrow-left"></use>
          </svg>
        </button>
        <button class="btn btn--secondary collections-nav-next" ${
          currentIndex === totalItems - 1 ? "disabled" : ""
        } title="Next (arrow key)" type="button">
          <svg class="fa d-icon d-icon-arrow-right svg-icon fa-width-auto svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
            <use href="#arrow-right"></use>
          </svg>
        </button>
      </div>
    `;
    insertAnchor.parentNode.insertBefore(navBar, insertAnchor);

    const modalOverlay = document.createElement("div");
    modalOverlay.className = "collections-nav-modal-overlay";
    modalOverlay.innerHTML = `
      <div class="collections-nav-modal collections-modal-with-content" role="dialog" aria-modal="true" aria-label="${escapeHtml(collectionName)} navigator">
        <div class="modal-header">
          <div class="modal-header-side modal-header-side-left">
            <button class="modal-sidebar-toggle btn btn-flat btn--toggle no-text btn-icon narrow-desktop" aria-label="Toggle sidebar" type="button" title="Toggle sidebar">
              <svg class="fa d-icon d-icon-discourse-sidebar svg-icon svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
                <use href="#discourse-sidebar"></use>
              </svg>
            </button>
          </div>

          <div class="modal-header-center">
            <div class="modal-header-content">
              <h2 class="modal-title">${escapeHtml(collectionName)}</h2>
              ${
                collectionDesc
                  ? `<p class="collection-description">${escapeHtml(collectionDesc)}</p>`
                  : ""
              }

              <div class="topic-slider-shell">
                <button class="topic-slider-edge topic-slider-edge-prev" type="button" aria-label="Previous items">
                  <svg class="fa d-icon d-icon-chevron-left svg-icon svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
                    <use href="#chevron-left"></use>
                  </svg>
                </button>

                <div class="topic-slider-container">
                  <div class="topic-slider">
                    ${items
                      .map((item, idx) =>
                        renderSliderItem(item, idx, currentIndex, totalItems)
                      )
                      .join("")}
                  </div>
                </div>

                <button class="topic-slider-edge topic-slider-edge-next" type="button" aria-label="Next items">
                  <svg class="fa d-icon d-icon-chevron-right svg-icon svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
                    <use href="#chevron-right"></use>
                  </svg>
                </button>
              </div>
            </div>
          </div>

          <div class="modal-header-side modal-header-side-right">
            <button class="modal-close-btn" aria-label="Close modal" type="button">
              <svg class="fa d-icon d-icon-xmark svg-icon svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
                <use href="#xmark"></use>
              </svg>
            </button>
          </div>
        </div>

        <div class="modal-body-split">
          <div class="modal-items-sidebar collapsed">
            <ul class="collection-items-list">
              ${items
                .map((item, idx) => renderCollectionItem(item, idx, currentIndex))
                .join("")}
            </ul>
          </div>

          <div class="modal-content-area">
            <div class="content-header">
              <h3 class="content-title">${escapeHtml(currentItem.title)}</h3>
              <div class="content-header-actions"></div>
            </div>
            <div class="cooked-content"></div>
          </div>
        </div>

        <div class="modal-nav-footer">
          <button class="btn btn--secondary modal-content-prev" title="Previous item" type="button" ${
            currentIndex === 0 ? "disabled" : ""
          }>
            <svg class="fa d-icon d-icon-arrow-left svg-icon fa-width-auto svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
              <use href="#arrow-left"></use>
            </svg>
            Previous
          </button>
          <div class="modal-paging">
            <span class="paging-text">${currentIndex + 1}/${totalItems}</span>
          </div>
          <button class="btn btn--secondary modal-content-next" title="Next item" type="button" ${
            currentIndex === totalItems - 1 ? "disabled" : ""
          }>
            Next
            <svg class="fa d-icon d-icon-arrow-right svg-icon fa-width-auto svg-string" width="1em" height="1em" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
              <use href="#arrow-right"></use>
            </svg>
          </button>
        </div>
      </div>
    `;
    document.body.appendChild(modalOverlay);

    const modalPanel = modalOverlay.querySelector(".collections-nav-modal");
    ensureSidebarResizer(modalPanel);
    bindSidebarResizer();

    const contentArea = modalOverlay.querySelector(".cooked-content");
    if (cookedNode && contentArea) {
      contentArea.replaceChildren(cookedNode);
      enhanceCooked(contentArea);
    } else if (contentArea) {
      contentArea.innerHTML = "<p>Loading content...</p>";
    }

    const toggleBtn = navBar.querySelector(".collections-nav-toggle");
    const prevBtn = navBar.querySelector(".collections-nav-prev");
    const nextBtn = navBar.querySelector(".collections-nav-next");
    const closeBtn = modalOverlay.querySelector(".modal-close-btn");
    const contentTitle = modalOverlay.querySelector(".content-title");
    const contentHeaderActions = modalOverlay.querySelector(
      ".content-header-actions"
    );
    const sidebarToggle = modalOverlay.querySelector(".modal-sidebar-toggle");
    const sidebar = modalOverlay.querySelector(".modal-items-sidebar");
    const collectionList = modalOverlay.querySelector(".collection-items-list");
    const modalContentPrev = modalOverlay.querySelector(".modal-content-prev");
    const modalContentNext = modalOverlay.querySelector(".modal-content-next");
    const pagingText = modalOverlay.querySelector(".paging-text");
    const topicSliderContainer = modalOverlay.querySelector(
      ".topic-slider-container"
    );
    const topicSliderShell = modalOverlay.querySelector(".topic-slider-shell");
    const topicSlider = modalOverlay.querySelector(".topic-slider");
    const mobileMq = window.matchMedia("(max-width: 767px)");

    function rerenderSidebarList(activeIndex) {
      if (!collectionList) {
        return;
      }

      collectionList.innerHTML = items
        .map((item, idx) => renderCollectionItem(item, idx, activeIndex))
        .join("");
    }

    function rerenderSlider(activeIndex) {
      if (!topicSlider) {
        return;
      }

      topicSlider.innerHTML = items
        .map((item, idx) =>
          renderSliderItem(item, idx, activeIndex, totalItems)
        )
        .join("");
    }

    const syncSliderEdgeState = () => {
      if (!topicSliderContainer || !topicSliderShell) {
        return;
      }

      const maxScrollLeft =
        topicSliderContainer.scrollWidth - topicSliderContainer.clientWidth;
      const isScrollable = maxScrollLeft > 4;

      topicSliderShell.classList.toggle("is-scrollable", isScrollable);
      topicSliderShell.classList.toggle(
        "at-start",
        !isScrollable || topicSliderContainer.scrollLeft <= 2
      );
      topicSliderShell.classList.toggle(
        "at-end",
        !isScrollable || topicSliderContainer.scrollLeft >= maxScrollLeft - 2
      );
    };

    const scrollSliderByPage = (direction) => {
      if (!topicSliderContainer) {
        return;
      }

      const amount = Math.max(
        180,
        Math.floor(topicSliderContainer.clientWidth * 0.7)
      );

      topicSliderContainer.scrollBy({
        left: direction * amount,
        behavior: getScrollBehavior(),
      });
    };

    const scrollSliderToActive = () => {
      const activeSlider = modalOverlay.querySelector(".slider-item.active");

      if (activeSlider && !topicSliderShell?.classList.contains("collapsed")) {
        activeSlider.scrollIntoView({
          behavior: getScrollBehavior(),
          block: "nearest",
          inline: "center",
        });
      }
    };

    const applyResponsiveState = () => {
      if (mobileMq.matches) {
        sidebarOpen = false;
        sidebar?.classList.add("collapsed");
        modalPanel?.classList.remove("collections-sidebar-open");
        topicSliderShell?.classList.remove("collapsed");
      } else {
        sidebar?.classList.toggle("collapsed", !sidebarOpen);
        modalPanel?.classList.toggle("collections-sidebar-open", sidebarOpen);
        topicSliderShell?.classList.toggle("collapsed", sidebarOpen);
      }

      window.requestAnimationFrame(() => {
        syncSliderEdgeState();
        scrollSliderToActive();
      });
    };

    const setSidebarVisibility = (open) => {
      if (mobileMq.matches) {
        sidebarOpen = false;
        sidebar?.classList.add("collapsed");
        modalPanel?.classList.remove("collections-sidebar-open");
        topicSliderShell?.classList.remove("collapsed");
      } else {
        sidebarOpen = open;
        sidebar?.classList.toggle("collapsed", !open);
        modalPanel?.classList.toggle("collections-sidebar-open", open);
        topicSliderShell?.classList.toggle("collapsed", open);
      }

      window.requestAnimationFrame(() => {
        syncSliderEdgeState();
        scrollSliderToActive();
      });
    };

    const hideModal = () => {
      modalOverlay.classList.remove("is-visible");

      if (activeModalState?.modal === modalOverlay) {
        activeModalState = null;
      }
    };

    const showModal = () => {
      modalOverlay.classList.add("is-visible");
      applyResponsiveState();

      activeModalState = {
        modal: modalOverlay,
        totalItems,
        selectedIndexRef: () => selectedIndex,
        prev: () => {
          if (selectedIndex > 0) {
            updateModalContent(selectedIndex - 1);
          }
        },
        next: () => {
          if (selectedIndex < totalItems - 1) {
            updateModalContent(selectedIndex + 1);
          }
        },
        hide: () => {
          hideModal();
        },
      };

      window.requestAnimationFrame(() => {
        syncSliderEdgeState();
        scrollSliderToActive();
      });
    };

    const syncLauncherState = () => {
      const current = items[selectedIndex];
      const previous = selectedIndex > 0 ? items[selectedIndex - 1] : null;
      const next =
        selectedIndex < totalItems - 1 ? items[selectedIndex + 1] : null;

      launcherState.update({
        collectionName,
        currentTitle: current?.title,
        previousTitle: previous?.title,
        nextTitle: next?.title,
        currentIndex: selectedIndex,
        totalItems,
        canGoPrev: selectedIndex > 0,
        canGoNext: selectedIndex < totalItems - 1,
        openModal: showModal,
        goPrev: () => {
          if (selectedIndex > 0) {
            updatePageContent(selectedIndex - 1);
          }
        },
        goNext: () => {
          if (selectedIndex < totalItems - 1) {
            updatePageContent(selectedIndex + 1);
          }
        },
      });
    };

    const updateNavState = (index) => {
      const navText = navBar.querySelector(".nav-text");

      if (navText) {
        navText.textContent = renderNavText(
          collectionName,
          items[index],
          index,
          totalItems
        );
      }

      prevBtn.disabled = index === 0;
      nextBtn.disabled = index === totalItems - 1;
      modalContentPrev.disabled = index === 0;
      modalContentNext.disabled = index === totalItems - 1;
      pagingText.textContent = `${index + 1}/${totalItems}`;
      contentTitle.textContent = items[index].title;

      rerenderSidebarList(index);
      rerenderSlider(index);

      window.requestAnimationFrame(() => {
        scrollSliderToActive();
        syncSliderEdgeState();
      });
    };

    const setupIframeHandlers = (container) => {
      const iframe = container.querySelector(".external-topic-iframe");
      const loadingDiv = container.querySelector(".iframe-loading");
      const wrapper = container;

      if (
        !iframe ||
        !wrapper ||
        !wrapper.classList.contains("external-url-content-wrapper")
      ) {
        return;
      }

      wrapper.style.visibility = "hidden";
      wrapper.style.overflow = "hidden";

      const adjustIframe = () => {
        wrapper.style.visibility = "visible";
        iframe.style.display = "block";
        iframe.style.width = "100%";
        iframe.style.height = "100%";
        iframe.style.minHeight = "100%";
        iframe.style.border = "none";
      };

      const onResize = throttle(adjustIframe, 100);

      const onLoad = () => {
        if (loadingDiv) {
          loadingDiv.style.display = "none";
        }

        adjustIframe();
        window.addEventListener("resize", onResize);
      };

      const onError = () => {
        if (loadingDiv) {
          loadingDiv.style.display = "none";
        }

        wrapper.style.visibility = "visible";
        iframe.style.display = "none";
        window.removeEventListener("resize", onResize);
      };

      iframe.addEventListener("load", onLoad, { once: true });
      iframe.addEventListener("error", onError, { once: true });

      addCleanup(() => {
        window.removeEventListener("resize", onResize);
      });
    };

    const fetchTopicJson = async (topicId, requestId, mode) => {
      const response = await fetch(`/t/${topicId}.json`);

      if (!response.ok) {
        throw new Error(`Topic fetch failed: ${response.status}`);
      }

      const data = await response.json();

      if (mode === "modal" && requestId !== modalRequestId) {
        return null;
      }

      if (mode === "page" && requestId !== pageRequestId) {
        return null;
      }

      return data;
    };

    const updatePageContent = async (index) => {
      if (index < 0 || index >= totalItems) {
        return;
      }

      const item = items[index];
      if (item.external || !item.topicId) {
        return;
      }

      selectedIndex = index;
      updateNavState(index);
      syncLauncherState();

      const requestId = ++pageRequestId;

      try {
        const data = await fetchTopicJson(item.topicId, requestId, "page");
        if (!data) {
          return;
        }

        document.title = item.title;

        let targetContent = document.querySelector(
          ".topic-post[data-post-number='1'] .cooked"
        );

        if (!targetContent) {
          targetContent = document.querySelector(".topic-body .cooked");
        }
        if (!targetContent) {
          targetContent = document.querySelector(".post-stream .posts .boxed-body");
        }
        if (!targetContent) {
          targetContent = document.querySelector(".post-content");
        }
        if (!targetContent) {
          targetContent = document.querySelector("[data-post-id] .cooked");
        }
        if (!targetContent) {
          targetContent = document.querySelector(".cooked");
        }

        const cooked = data.post_stream?.posts?.[0]?.cooked;

        if (targetContent && cooked) {
          targetContent.innerHTML = cooked;
          enhanceCooked(targetContent);
        }

        if (contentArea && cooked) {
          contentArea.innerHTML = cooked;
          enhanceCooked(contentArea);
        }
      } catch (error) {
        debug("error updating page content", error);
      }
    };

    const updateModalContent = throttle(async (index) => {
      if (index < 0 || index >= totalItems) {
        return;
      }

      const item = items[index];
      selectedIndex = index;
      updateNavState(index);
      syncLauncherState();
      contentHeaderActions.innerHTML = "";

      if (item.external) {
        modalPanel.classList.add("external-url-active");
        contentArea.classList.add("external-url-content-wrapper");
        contentArea.innerHTML = loadExternalContent(item.href);
        setupIframeHandlers(contentArea);

        contentHeaderActions.innerHTML = `
          <a href="${escapeHtml(
            item.href
          )}" target="_blank" rel="noopener noreferrer" class="btn btn-primary collections-open-external-button">
            ${externalLinkIcon}
            Open in New Tab
          </a>
        `;

        if (mobileMq.matches) {
          setSidebarVisibility(false);
        }

        return;
      }

      modalPanel.classList.remove("external-url-active");
      contentArea.classList.remove("external-url-content-wrapper");
      contentArea.style.visibility = "";
      contentArea.style.overflow = "";
      contentArea.innerHTML = "<p>Loading...</p>";

      if (!item.topicId) {
        contentArea.innerHTML = "<p>No content</p>";
        return;
      }

      const requestId = ++modalRequestId;

      try {
        const data = await fetchTopicJson(item.topicId, requestId, "modal");
        if (!data) {
          return;
        }

        const cooked = data.post_stream?.posts?.[0]?.cooked;
        contentArea.innerHTML = cooked || "<p>No content</p>";
        enhanceCooked(contentArea);
      } catch (error) {
        if (requestId !== modalRequestId) {
          return;
        }

        debug("error updating modal content", error);
        contentArea.innerHTML = "<p>Error loading</p>";
      }
    }, SCROLL_THROTTLE_MS);

    applyResponsiveState();

    const onResize = throttle(() => {
      syncSliderEdgeState();
      scrollSliderToActive();
    }, 50);

    window.addEventListener("resize", onResize);
    addCleanup(() => window.removeEventListener("resize", onResize));

    toggleBtn.addEventListener("click", showModal);
    addCleanup(() => toggleBtn.removeEventListener("click", showModal));

    const onSidebarToggleClick = () => setSidebarVisibility(!sidebarOpen);
    sidebarToggle?.addEventListener("click", onSidebarToggleClick);
    addCleanup(() =>
      sidebarToggle?.removeEventListener("click", onSidebarToggleClick)
    );

    closeBtn?.addEventListener("click", hideModal);
    addCleanup(() => closeBtn?.removeEventListener("click", hideModal));

    const onSliderShellClick = (event) => {
      const prevEdge = event.target.closest(".topic-slider-edge-prev");
      if (prevEdge) {
        scrollSliderByPage(-1);
        return;
      }

      const nextEdge = event.target.closest(".topic-slider-edge-next");
      if (nextEdge) {
        scrollSliderByPage(1);
      }
    };
    topicSliderShell?.addEventListener("click", onSliderShellClick);
    addCleanup(() =>
      topicSliderShell?.removeEventListener("click", onSliderShellClick)
    );

    const onSliderScroll = throttle(syncSliderEdgeState, 30);
    topicSliderContainer?.addEventListener("scroll", onSliderScroll);
    addCleanup(() =>
      topicSliderContainer?.removeEventListener("scroll", onSliderScroll)
    );

    const onPrevClick = () => {
      if (selectedIndex > 0) {
        updatePageContent(selectedIndex - 1);
      }
    };
    prevBtn.addEventListener("click", onPrevClick);
    addCleanup(() => prevBtn.removeEventListener("click", onPrevClick));

    const onNextClick = () => {
      if (selectedIndex < totalItems - 1) {
        updatePageContent(selectedIndex + 1);
      }
    };
    nextBtn.addEventListener("click", onNextClick);
    addCleanup(() => nextBtn.removeEventListener("click", onNextClick));

    const onModalPrevClick = () => {
      if (selectedIndex > 0) {
        updateModalContent(selectedIndex - 1);
      }
    };
    modalContentPrev?.addEventListener("click", onModalPrevClick);
    addCleanup(() =>
      modalContentPrev?.removeEventListener("click", onModalPrevClick)
    );

    const onModalNextClick = () => {
      if (selectedIndex < totalItems - 1) {
        updateModalContent(selectedIndex + 1);
      }
    };
    modalContentNext?.addEventListener("click", onModalNextClick);
    addCleanup(() =>
      modalContentNext?.removeEventListener("click", onModalNextClick)
    );

    const onCollectionListClick = (event) => {
      const button = event.target.closest(".collection-item-link");
      if (!button) {
        return;
      }

      const index = parseInt(button.getAttribute("data-index"), 10);
      if (Number.isNaN(index)) {
        return;
      }

      updateModalContent(index);
    };
    collectionList?.addEventListener("click", onCollectionListClick);
    addCleanup(() =>
      collectionList?.removeEventListener("click", onCollectionListClick)
    );

    const onSliderClick = (event) => {
      const button = event.target.closest(".slider-item");
      if (!button) {
        return;
      }

      const index = parseInt(button.getAttribute("data-index"), 10);
      if (Number.isNaN(index)) {
        return;
      }

      updateModalContent(index);
    };
    topicSlider?.addEventListener("click", onSliderClick);
    addCleanup(() => topicSlider?.removeEventListener("click", onSliderClick));

    const overlayClickHandler = (event) => {
      if (event.target === modalOverlay) {
        hideModal();
      }
    };
    modalOverlay.addEventListener("click", overlayClickHandler);
    addCleanup(() =>
      modalOverlay.removeEventListener("click", overlayClickHandler)
    );

    currentCleanup = () => {
      cleanupFns.forEach((fn) => fn());
      cleanupFns.length = 0;
      modalRequestId++;
      pageRequestId++;
      activeModalState = null;
      modalOverlay.remove();
      navBar.remove();
    };

    if (!keyboardHandlerBound) {
      let lastKeyPress = 0;

      document.addEventListener("keydown", (event) => {
        if (
          !activeModalState ||
          !activeModalState.modal.classList.contains("is-visible")
        ) {
          return;
        }

        const now = Date.now();
        const selected = activeModalState.selectedIndexRef();
        const maxIndex = activeModalState.totalItems - 1;

        if (event.key === "ArrowLeft" && selected > 0) {
          if (now - lastKeyPress < KEYBOARD_THROTTLE_MS) {
            return;
          }

          if (
            document.activeElement?.classList?.contains(
              "collections-sidebar-resizer"
            )
          ) {
            return;
          }

          lastKeyPress = now;
          event.preventDefault();
          activeModalState.prev();
        } else if (event.key === "ArrowRight" && selected < maxIndex) {
          if (now - lastKeyPress < KEYBOARD_THROTTLE_MS) {
            return;
          }

          if (
            document.activeElement?.classList?.contains(
              "collections-sidebar-resizer"
            )
          ) {
            return;
          }

          lastKeyPress = now;
          event.preventDefault();
          activeModalState.next();
        } else if (event.key === "Escape") {
          event.preventDefault();
          activeModalState.hide();
        }
      });

      keyboardHandlerBound = true;
    }

    syncLauncherState();
    syncSliderEdgeState();
    debug("navigator built", {
      collectionName,
      currentIndex,
      totalItems,
      currentPath,
    });
  }

  function scheduleRebuild(currentPath) {
    if (rebuildScheduled) {
      return;
    }

    rebuildScheduled = true;

    requestAnimationFrame(() => {
      rebuildScheduled = false;
      buildNavigator(currentPath);
    });
  }

  function setupSidebarObserver(getCurrentPath) {
    if (sidebarObserver) {
      sidebarObserver.disconnect();
    }

    if (!settings.collections_navigator_enabled) {
      return;
    }

    sidebarObserver = new MutationObserver(() => {
      scheduleRebuild(getCurrentPath());
    });

    sidebarObserver.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "style"],
    });
  }

  api.onPageChange((url) => {
    const getCurrentPath = () => normalizePath(url || window.location.pathname);

    cleanupExistingUi();

    if (!settings.collections_navigator_enabled) {
      debug("skipping page build because navigator is disabled");
      return;
    }

    scheduleRebuild(getCurrentPath());
    setupSidebarObserver(getCurrentPath);
  });
});
