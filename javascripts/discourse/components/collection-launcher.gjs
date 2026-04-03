import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import DButton from "discourse/components/d-button";
import launcherState from "../lib/collections-launcher-state";

export default class CollectionLauncher extends Component {
  @service site;

  get state() {
    return launcherState;
  }

  get isHidden() {
    return settings.launcher_mode === "hidden";
  }

  get isSliderMode() {
    return settings.launcher_mode === "slider";
  }

  get launcherLabel() {
    return settings.launcher_label || "Browse Collection";
  }

  get isMobile() {
    return this.site.mobileView;
  }

  get showOnThisDevice() {
    if (this.isMobile && !settings.enable_mobile_launcher) {
      return false;
    }

    if (!this.isMobile && !settings.enable_desktop_launcher) {
      return false;
    }

    return true;
  }

  get shouldRender() {
    return !this.isHidden && this.showOnThisDevice && this.state.isReady;
  }

  truncateLabel(value) {
    const max = settings.max_side_label_chars || 22;

    if (!value || value.length <= max) {
      return value || "";
    }

    return `${value.slice(0, max - 1).trimEnd()}…`;
  }

  get centerLabel() {
    if (settings.show_center_current_title && this.state.currentTitle) {
      return this.state.currentTitle;
    }

    return this.launcherLabel;
  }

  get leftLabel() {
    return this.state.canGoPrev
      ? this.truncateLabel(this.state.previousTitle)
      : "";
  }

  get rightLabel() {
    return this.state.canGoNext
      ? this.truncateLabel(this.state.nextTitle)
      : "";
  }

  get pagerText() {
    if (!settings.show_pager_text || !this.state.totalItems) {
      return "";
    }

    return `${this.state.currentIndex + 1}/${this.state.totalItems}`;
  }

  get expanded() {
    return this.state.isExpanded;
  }

  syncExpandedClass() {
    document.body.classList.toggle(
      "collections-launcher-expanded",
      this.state.isExpanded
    );
  }

  collapseSliderIfNeeded() {
    if (!settings.collapse_after_navigation) {
      return;
    }

    this.state.setExpanded(false);
    this.syncExpandedClass();
  }

  @action
  toggleInlineSlider() {
    this.state.toggleExpanded();
    this.syncExpandedClass();
  }

  @action
  openNavigatorModal() {
    this.collapseSliderIfNeeded();
    this.state.openModal?.();
  }

  @action
  goPrev() {
    this.collapseSliderIfNeeded();
    this.state.goPrev?.();
  }

  @action
  goNext() {
    this.collapseSliderIfNeeded();
    this.state.goNext?.();
  }

  <template>
    {{#if this.shouldRender}}
      <div
        class="collection-launcher-root"
        data-mode={{if this.isSliderMode "slider" "button"}}
        data-placement={{settings.launcher_placement}}
        data-sticky-mobile-only={{if settings.sticky_mobile_only "true" "false"}}
      >
        {{#if this.isSliderMode}}
          <div
            class="collection-inline-slider-shell"
            data-expanded={{if this.expanded "true" "false"}}
          >
            <div
              class="collection-inline-slider-track"
              aria-label="Collection navigation"
            >
              <div
                class="collection-inline-slider-side collection-inline-slider-side-left"
              >
                {{#if this.state.canGoPrev}}
                  <DButton
                    @action={{this.goPrev}}
                    @icon="chevron-left"
                    @translatedLabel={{this.leftLabel}}
                    class="collection-inline-nav collection-inline-nav-prev btn-flat"
                    title={{this.state.previousTitle}}
                  />
                {{/if}}
              </div>

              <div class="collection-inline-slider-center">
                <button
                  type="button"
                  class="collection-inline-slider-toggle"
                  aria-expanded={{if this.expanded "true" "false"}}
                  aria-label="Toggle collection quick navigator"
                  title="Toggle collection quick navigator"
                  {{on "click" this.toggleInlineSlider}}
                >
                  <span class="collection-inline-slider-title">
                    {{this.centerLabel}}
                  </span>

                  {{#if this.pagerText}}
                    <span class="collection-inline-slider-meta">
                      {{this.pagerText}}
                    </span>
                  {{/if}}
                </button>
              </div>

              <div
                class="collection-inline-slider-side collection-inline-slider-side-right"
              >
                {{#if this.state.canGoNext}}
                  <DButton
                    @action={{this.goNext}}
                    @translatedLabel={{this.rightLabel}}
                    @icon="chevron-right"
                    class="collection-inline-nav collection-inline-nav-next btn-flat"
                    title={{this.state.nextTitle}}
                  />
                {{/if}}
              </div>
            </div>

            {{#if settings.show_modal_action}}
              <DButton
                @action={{this.openNavigatorModal}}
                @icon={{settings.modal_action_icon}}
                class="collection-inline-slider-modal-trigger btn-flat"
                title="Open collection navigator"
              />
            {{/if}}
          </div>
        {{else}}
          <DButton
            @action={{this.openNavigatorModal}}
            @icon="bars"
            @translatedLabel={{this.centerLabel}}
            class="collection-launcher-button"
            title="Open collection navigator"
          />
        {{/if}}
      </div>
    {{/if}}
  </template>
}
