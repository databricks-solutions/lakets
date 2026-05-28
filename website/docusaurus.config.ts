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

  // Stitch "Lakehouse Technical Documentation" theme fonts
  stylesheets: [
    {
      href: "https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap",
      type: "text/css",
    },
  ],
  headTags: [
    {
      tagName: "link",
      attributes: { rel: "preconnect", href: "https://fonts.googleapis.com" },
    },
    {
      tagName: "link",
      attributes: {
        rel: "preconnect",
        href: "https://fonts.gstatic.com",
        crossorigin: "true",
      },
    },
  ],

  presets: [
    [
      "classic",
      {
        docs: {
          routeBasePath: "/",
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
    colorMode: {
      defaultMode: "dark",
      respectPrefersColorScheme: true,
    },
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
            { label: "Introduction", to: "/" },
            { label: "Getting Started", to: "/guides/getting-started" },
            { label: "How It Works", to: "/guides/how-it-works" },
            { label: "API Reference", to: "/reference/api-reference" },
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
            {
              label: "License",
              href: "https://github.com/databricks-solutions/lakets/blob/main/LICENSE.md",
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Databricks, Inc. Licensed under the <a href="https://github.com/databricks-solutions/lakets/blob/main/LICENSE.md" style="color:inherit;text-decoration:underline">Databricks License</a>.`,
    },
    prism: {
      theme: prismThemes.oneLight,
      darkTheme: prismThemes.oneDark,
      additionalLanguages: ["sql", "bash", "python"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
