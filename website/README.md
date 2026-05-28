# LakeTS docs site

Docusaurus 3 documentation site, deployed to GitHub Pages at https://databricks-solutions.github.io/lakets/.

## Local development

```bash
cd website
npm install
npm start
```

Opens http://localhost:3000 with live reload.

## Build

```bash
npm run build
npm run serve   # preview the production build locally
```

## Deploy

The `.github/workflows/deploy-docs.yml` workflow builds and publishes the site to GitHub Pages on every push to `main` and on tagged releases. No manual deploy is needed.

## Adding docs

1. Drop a Markdown file under `docs/`.
2. Add it to the appropriate section in [`sidebars.ts`](./sidebars.ts).
3. Open a PR.

For frontmatter conventions and embedding code/images, see the [Docusaurus docs](https://docusaurus.io/docs).
