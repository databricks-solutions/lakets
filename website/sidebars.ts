import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  docsSidebar: [
    "intro",
    {
      type: "category",
      label: "Guides",
      collapsed: false,
      items: [
        "guides/getting-started",
        "guides/how-it-works",
        "guides/lakehouse-sync-setup",
      ],
    },
    {
      type: "category",
      label: "Reference",
      collapsed: false,
      items: [
        "reference/api-reference",
        "reference/function-reference",
      ],
    },
  ],
};

export default sidebars;
