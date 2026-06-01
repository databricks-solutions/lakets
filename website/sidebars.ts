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
      label: "Architecture Patterns",
      collapsed: false,
      items: ["architecture-patterns"],
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
        "how-to/downsampling",
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
      label: "Examples",
      collapsed: false,
      items: ["examples/sensor-reading-journey"],
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
        "reference/downsampling",
        "reference/alerts",
        "reference/bulk-ingest",
        "reference/monitoring",
        "reference/metadata-tables",
        "reference/workflow-jobs",
      ],
    },
    "troubleshooting",
    "glossary",
  ],
};

export default sidebars;
