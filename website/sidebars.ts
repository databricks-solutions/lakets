import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  docsSidebar: [
    "intro",
    {
      type: "category",
      label: "Guides",
      collapsed: false,
      items: [
        // Add migrated guides here, e.g.:
        // "guides/getting-started",
        // "guides/how-it-works",
        // "guides/lakehouse-sync-setup",
      ],
    },
    {
      type: "category",
      label: "Reference",
      collapsed: false,
      items: [
        // Add API reference pages here, e.g.:
        // "reference/api",
        // "reference/functions",
      ],
    },
  ],
};

export default sidebars;
