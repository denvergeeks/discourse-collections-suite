import { tracked } from "@glimmer/tracking";

class CollectionsLauncherState {
  @tracked isReady = false;
  @tracked isExpanded = false;
  @tracked collectionName = "";
  @tracked currentTitle = "";
  @tracked previousTitle = "";
  @tracked nextTitle = "";
  @tracked currentIndex = 0;
  @tracked totalItems = 0;
  @tracked canGoPrev = false;
  @tracked canGoNext = false;
  @tracked openModal = null;
  @tracked goPrev = null;
  @tracked goNext = null;

  reset() {
    this.isReady = false;
    this.isExpanded = !!settings.slider_starts_expanded;
    this.collectionName = "";
    this.currentTitle = "";
    this.previousTitle = "";
    this.nextTitle = "";
    this.currentIndex = 0;
    this.totalItems = 0;
    this.canGoPrev = false;
    this.canGoNext = false;
    this.openModal = null;
    this.goPrev = null;
    this.goNext = null;
  }

  setExpanded(value) {
    this.isExpanded = !!value;
  }

  toggleExpanded() {
    this.isExpanded = !this.isExpanded;
  }

  update({
    collectionName,
    currentTitle,
    previousTitle,
    nextTitle,
    currentIndex,
    totalItems,
    canGoPrev,
    canGoNext,
    openModal,
    goPrev,
    goNext,
  }) {
    this.isReady = true;
    this.collectionName = collectionName || "";
    this.currentTitle = currentTitle || "";
    this.previousTitle = previousTitle || "";
    this.nextTitle = nextTitle || "";
    this.currentIndex = currentIndex ?? 0;
    this.totalItems = totalItems ?? 0;
    this.canGoPrev = !!canGoPrev;
    this.canGoNext = !!canGoNext;
    this.openModal = openModal || null;
    this.goPrev = goPrev || null;
    this.goNext = goNext || null;
  }
}

const state = new CollectionsLauncherState();
state.reset();

export default state;
