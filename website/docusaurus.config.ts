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

  // Stitch "Lakehouse Technical Documentation" theme fonts + icons
  stylesheets: [
    {
      href: "https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap",
      type: "text/css",
    },
    {
      href: "https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0&display=block",
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
    // Tailwind CDN — load FIRST so the `tailwind` global exists before
    // the config script below can attach our custom design tokens to it.
    {
      tagName: "script",
      attributes: {
        src: "https://cdn.tailwindcss.com?plugins=forms,container-queries",
      },
    },
    // Tailwind config applied AFTER the CDN initializes. This mirrors
    // Stitch's own HTML which sets `tailwind.config = {...}` post-CDN.
    {
      tagName: "script",
      attributes: { id: "tailwind-config", type: "text/javascript" },
      innerHTML: `
        tailwind.config = {
          darkMode: 'class',
          theme: {
            extend: {
              colors: {
                primary: '#ffb4aa',
                'primary-container': '#ff5c4d',
                'on-primary-container': '#610002',
                secondary: '#79d1ff',
                'secondary-container': '#00a7de',
                'on-secondary-container': '#00374d',
                tertiary: '#c0c1ff',
                error: '#ffb4ab',
                surface: '#0c1322',
                'surface-bright': '#323949',
                'surface-variant': '#2e3545',
                'surface-container': '#191f2f',
                'surface-container-low': '#141b2b',
                'surface-container-lowest': '#070e1d',
                'surface-container-high': '#232a3a',
                'surface-container-highest': '#2e3545',
                'on-surface': '#dce2f7',
                'on-surface-variant': '#aab0c4',
                outline: '#4a5160',
                'outline-variant': '#5a403d',
              },
              spacing: {
                unit: '4px',
                xs: '4px',
                sm: '8px',
                md: '16px',
                lg: '24px',
                xl: '32px',
                gutter: '24px',
                'sidebar-width': '280px',
                'container-max': '1280px',
              },
              fontFamily: {
                'headline-lg': ['DM Sans'],
                'headline-md': ['DM Sans'],
                'body-md': ['DM Sans'],
                'body-lg': ['DM Sans'],
                display: ['DM Sans'],
                'code-block': ['JetBrains Mono'],
                'label-sm': ['JetBrains Mono'],
              },
              fontSize: {
                display: ['48px', { lineHeight: '56px', letterSpacing: '-0.02em', fontWeight: '700' }],
                'headline-lg': ['32px', { lineHeight: '40px', letterSpacing: '-0.01em', fontWeight: '700' }],
                'headline-md': ['24px', { lineHeight: '32px', fontWeight: '600' }],
                'body-lg': ['18px', { lineHeight: '28px', fontWeight: '400' }],
                'body-md': ['16px', { lineHeight: '24px', fontWeight: '400' }],
                'code-block': ['14px', { lineHeight: '20px', fontWeight: '400' }],
                'label-sm': ['12px', { lineHeight: '16px', letterSpacing: '0.05em', fontWeight: '500' }],
              },
            },
          },
        };
      `,
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
      title: "lake ts",
      hideOnScroll: false,
      items: [
        {
          to: "/intro",
          label: "Documentation",
          position: "left",
          className: "navbar-link-docs",
          activeBaseRegex: "/(intro|guides)",
        },
        {
          to: "/reference/api-reference",
          label: "API Reference",
          position: "left",
          activeBaseRegex: "/reference",
        },
        {
          href: "https://github.com/databricks-solutions/lakets/discussions",
          label: "Community",
          position: "left",
        },
        {
          href: "https://github.com/databricks-solutions/lakets",
          label: "GitHub",
          position: "right",
          className: "navbar-link-github",
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
