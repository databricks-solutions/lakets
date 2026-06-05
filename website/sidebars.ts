import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: "category",
      label: "Getting Started",
      collapsed: false,
      items: [
        "guides/getting-started",
        "guides/lakebase-cdf-setup",
      ],
    },
    {
      type: "category",
      label: "How-to guides",
      collapsed: false,
      items: [
        "how-to/index",
        "how-to/rollups",
        "how-to/last-value-cache",
        "how-to/bulk-ingest",
        "how-to/alerts",
        "how-to/lifecycle",
        "how-to/monitoring",
        "how-to/cardinality",
        "how-to/export-to-uc",
        "how-to/upgrading",
      ],
    },
    {
      type: "category",
      label: "How It Works",
      collapsed: false,
      items: [
        "guides/how-it-works/index",
        "guides/how-it-works/chronotables",
        "guides/how-it-works/time-series-functions",
        "guides/how-it-works/rollups",
        "guides/how-it-works/tiering-and-retention",
        "guides/how-it-works/lakebase-cdf-internals",
      ],
    },
    {
      type: "category",
      label: "Demos",
      collapsed: false,
      items: [
        {
          type: "category",
          label: "Live Demo",
          link: { type: "doc", id: "guides/live-demo/index" },
          items: [
            "guides/live-demo/prerequisites",
            "guides/live-demo/setup",
            "guides/live-demo/enable-cdf",
            "guides/live-demo/deploy-and-run",
            "guides/live-demo/how-it-works",
            "guides/live-demo/grafana",
            "guides/live-demo/teardown",
          ],
        },
      ],
    },
    {
      type: "category",
      label: "Reference",
      collapsed: false,
      items: [
        "reference/index",
        "reference/chronotables",
        "reference/time-series-functions",
        "reference/rollups",
        "reference/lifecycle",
        "reference/lakebase-cdf",
        "reference/multi-metric-tables",
        "reference/last-value-cache",
        "reference/alerts",
        "reference/bulk-ingest",
        "reference/monitoring",
        "reference/metadata-tables",
        "reference/workflow-jobs",
      ],
    },
    "limitations",
    "roadmap",
    "changelog",
    "troubleshooting",
    "glossary",
  ],
};

export default sidebars;
