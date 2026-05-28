import { themes as prismThemes } from "prism-react-renderer";
import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";

const config: Config = {
  title: "LakeTS",
  tagline: "Time Series Toolkit for Databricks Lakebase",
  favicon: "img/favicon.ico",

  url: "https://databricks-solutions.github.io",
  baseUrl: "/lakets/",

  organizationName: "databricks-solutions",
  projectName: "lakets",
  trailingSlash: false,

  onBrokenLinks: "warn",
  onBrokenMarkdownLinks: "warn",

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  presets: [
    [
      "classic",
      {
        docs: {
          sidebarPath: "./sidebars.ts",
          editUrl:
            "https://github.com/databricks-solutions/lakets/edit/main/website/",
          showLastUpdateAuthor: true,
          showLastUpdateTime: true,
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: "img/social-card.png",
    navbar: {
      title: "LakeTS",
      items: [
        {
          type: "docSidebar",
          sidebarId: "docsSidebar",
          position: "left",
          label: "Docs",
        },
        {
          href: "https://github.com/databricks-solutions/lakets/releases",
          label: "Releases",
          position: "right",
        },
        {
          href: "https://github.com/databricks-solutions/lakets",
          label: "GitHub",
          position: "right",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Docs",
          items: [
            { label: "Getting Started", to: "/docs/intro" },
          ],
        },
        {
          title: "Community",
          items: [
            {
              label: "Discussions",
              href: "https://github.com/databricks-solutions/lakets/discussions",
            },
            {
              label: "Issues",
              href: "https://github.com/databricks-solutions/lakets/issues",
            },
          ],
        },
        {
          title: "More",
          items: [
            {
              label: "GitHub",
              href: "https://github.com/databricks-solutions/lakets",
            },
            {
              label: "Releases",
              href: "https://github.com/databricks-solutions/lakets/releases",
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Databricks, Inc. Licensed under the Databricks License.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ["sql", "bash", "python"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
