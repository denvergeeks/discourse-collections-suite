import { apiInitializer } from "discourse/lib/api";
import CollectionLauncher from "../components/collection-launcher";

export default apiInitializer("1.24.0", (api) => {
  const placement = settings.launcher_placement || "topic-above-posts";

  const outletMap = {
    "topic-title": "topic-title",
    "topic-above-posts": "topic-above-posts",
    "mobile-sticky-bottom": "topic-above-posts",
  };

  const targetOutlet = outletMap[placement] || "topic-above-posts";

  api.renderInOutlet(targetOutlet, CollectionLauncher);
});
