import React from "react";
import Layout from "@theme/Layout";
import Link from "@docusaurus/Link";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import styles from "./index.module.css";

// 1:1 replica of the Stitch "Lake TS - Desktop Home (Dark Mode)" screen
// (projects/10067549973504610213). The structure is preserved verbatim
// from the Stitch HTML; links are wired to real Docusaurus routes.

function Icon({ name, className }: { name: string; className?: string }) {
  return (
    <span
      className={`material-symbols-outlined ${className ?? ""}`}
      aria-hidden="true"
    >
      {name}
    </span>
  );
}

function StitchHeader() {
  return (
    <header className="fixed top-0 w-full z-50 bg-surface/80 backdrop-blur-xl border-b border-outline-variant/30 shadow-sm">
      <div className="flex justify-between items-center px-gutter h-16 w-full max-w-container-max mx-auto">
        <Link
          to="/"
          className="flex items-center gap-sm cursor-pointer active:scale-95 transition-transform no-underline"
        >
          <Icon name="waves" className="text-primary text-headline-md" />
          <span className="text-headline-md font-headline-md font-bold text-on-surface">
            lake ts
          </span>
        </Link>
        <div className="hidden md:flex items-center gap-lg">
          <nav className="flex gap-md">
            <Link
              to="/intro"
              className="text-primary font-bold hover:opacity-80 transition-opacity no-underline"
            >
              Docs
            </Link>
            <Link
              to="/reference/api-reference"
              className="text-on-surface-variant hover:opacity-80 transition-opacity no-underline"
            >
              API
            </Link>
            <a
              href="https://github.com/databricks-solutions/lakets/discussions"
              className="text-on-surface-variant hover:opacity-80 transition-opacity no-underline"
            >
              Community
            </a>
          </nav>
          <div className="flex items-center gap-sm bg-surface-container-high px-md py-xs rounded-full border border-outline-variant/30 cursor-pointer">
            <Icon name="search" className="text-on-surface-variant" />
            <span className="text-label-sm text-on-surface-variant uppercase tracking-wider">
              Search...
            </span>
            <span className="ml-xl px-xs py-[2px] bg-surface-container text-on-surface-variant border border-outline-variant/50 rounded text-[10px]">
              CMD K
            </span>
          </div>
        </div>
        <div className="flex items-center gap-md">
          <Icon
            name="search"
            className="text-on-surface cursor-pointer active:scale-95 transition-transform md:hidden"
          />
          <a
            href="https://github.com/databricks-solutions/lakets"
            className="no-underline"
          >
            <Icon
              name="open_in_new"
              className="text-on-surface cursor-pointer active:scale-95 transition-transform"
            />
          </a>
        </div>
      </div>
    </header>
  );
}

function StitchSidebar() {
  const navItems = [
    { icon: "rocket_launch", label: "Getting Started", to: "/guides/getting-started", active: true },
    { icon: "auto_graph", label: "How It Works", to: "/guides/how-it-works" },
    { icon: "api", label: "API Reference", to: "/reference/api-reference" },
    { icon: "query_stats", label: "Function Reference", to: "/reference/function-reference" },
    { icon: "verified", label: "Lakehouse Sync", to: "/guides/lakehouse-sync-setup" },
  ];
  const advanced = [
    { label: "ChronoTables", to: "/reference/api-reference#chronotable-management" },
    { label: "RollUp engine", to: "/guides/how-it-works" },
    { label: "Unity Catalog", to: "/reference/api-reference" },
  ];
  return (
    <aside className="hidden md:flex h-full w-sidebar-width fixed left-0 top-0 z-40 bg-surface-container border-r border-outline-variant/30 flex-col pt-16">
      <div className="flex flex-col py-lg pr-md overflow-y-auto h-full">
        <div className="px-lg mb-md">
          <span className="text-label-sm text-primary uppercase font-bold tracking-widest">
            Documentation
          </span>
        </div>
        <nav className="space-y-1">
          {navItems.map((item) => (
            <Link
              key={item.label}
              to={item.to}
              className={`flex items-center gap-md px-lg py-sm rounded-r-full cursor-pointer transition-colors no-underline ${
                item.active
                  ? "bg-secondary-container text-on-secondary-container font-bold"
                  : "text-on-surface-variant hover:bg-surface-variant"
              }`}
            >
              <Icon name={item.icon} />
              <span className="font-body-md">{item.label}</span>
            </Link>
          ))}
        </nav>
        <div className="mt-xl px-lg pt-xl border-t border-outline-variant/20">
          <span className="text-label-sm text-on-surface-variant/60 uppercase font-medium tracking-widest">
            Advanced
          </span>
          <div className="mt-md space-y-2">
            {advanced.map((a) => (
              <Link
                key={a.label}
                to={a.to}
                className="block text-body-md text-on-surface-variant hover:text-on-surface cursor-pointer no-underline"
              >
                {a.label}
              </Link>
            ))}
          </div>
        </div>
      </div>
    </aside>
  );
}

function StitchHero() {
  return (
    <section className="relative w-full overflow-hidden bg-surface-container-lowest border-b border-outline-variant/20">
      <div className="max-w-container-max mx-auto px-gutter py-xl md:py-[80px] grid md:grid-cols-2 items-center gap-xl">
        <div className="z-10">
          <div className="inline-flex items-center gap-sm px-md py-xs rounded-full bg-primary/10 border border-primary/20 mb-lg">
            <span className="w-2 h-2 rounded-full bg-primary animate-pulse" />
            <span className="text-label-sm text-primary uppercase font-bold">
              New: v0.1.2 Live
            </span>
          </div>
          <h1 className="font-display text-display text-on-surface leading-tight mb-md">
            Supercharge <span className="text-primary">Time-Series</span> on
            Databricks Lakebase
          </h1>
          <p className="font-body-lg text-body-lg text-on-surface-variant mb-xl max-w-xl">
            A pure-SQL toolkit for Databricks Lakebase designed for massive-scale
            time-series analysis. Achieve sub-10ms latest-state queries and
            incremental rollups with zero custom extensions.
          </p>
          <div className="flex flex-wrap gap-md">
            <Link
              to="/guides/getting-started"
              className="px-xl py-md bg-primary-container text-on-primary-container font-bold rounded-lg hover:opacity-90 transition-all active:scale-95 shadow-lg shadow-primary/10 no-underline"
            >
              Get Started Free
            </Link>
            <Link
              to="/reference/api-reference"
              className="px-xl py-md border border-outline text-on-surface font-bold rounded-lg hover:bg-surface-variant transition-all active:scale-95 no-underline"
            >
              View API Docs
            </Link>
          </div>
        </div>
        <div className="relative group">
          <div className="absolute -inset-4 bg-primary/5 rounded-full blur-3xl group-hover:bg-primary/10 transition-colors duration-1000" />
          <div className="relative bg-surface-container-high rounded-xl border border-outline-variant/30 overflow-hidden shadow-2xl aspect-video">
            <div className="absolute inset-0">
              <div className={styles.heroGrid} />
            </div>
            <div className="absolute inset-0 flex items-center justify-center">
              <div className={styles.heroGlow}>
                <Icon name="waves" className={styles.heroDelta} />
              </div>
            </div>
            <div className="absolute inset-0 bg-gradient-to-t from-surface-container-high/60 to-transparent" />
          </div>
        </div>
      </div>
    </section>
  );
}

function FeatureBento() {
  return (
    <section className="max-w-container-max mx-auto px-gutter py-xl">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-lg">
        <FeatureCard
          icon="speed"
          iconColor="text-primary"
          iconHover="group-hover:bg-primary/20"
          title="Sub-Second Queries"
          body="Last Value Cache + native time-series indexing for blazing-fast lookups on hot data, with cold-tier Delta queries via Photon."
        />
        <FeatureCard
          icon="view_agenda"
          iconColor="text-secondary"
          iconHover="group-hover:bg-secondary/20"
          title="Native Time Bucketing"
          body="time_bucket, gap-fill, locf, first/last, delta, rate, histogram — purpose-built SQL operators, not bolted-on window functions."
        />
        <FeatureCard
          icon="cloud_sync"
          iconColor="text-tertiary"
          iconHover="group-hover:bg-tertiary/20"
          title="Delta Integrated"
          body="Hot Lakebase + cold Delta Lake hybrid with Lakehouse Sync CDC, automatic tiering, retention, and Unity Catalog registration."
        />
      </div>
    </section>
  );
}

function FeatureCard({
  icon,
  iconColor,
  iconHover,
  title,
  body,
}: {
  icon: string;
  iconColor: string;
  iconHover: string;
  title: string;
  body: string;
}) {
  return (
    <div className="p-lg bg-surface-container-low rounded-xl border border-outline-variant/20 hover:border-primary/40 transition-colors group">
      <div
        className={`w-12 h-12 bg-surface-container-highest rounded-lg flex items-center justify-center mb-md transition-colors ${iconHover}`}
      >
        <Icon name={icon} className={iconColor} />
      </div>
      <h3 className="font-headline-md text-headline-md mb-sm text-on-surface">
        {title}
      </h3>
      <p className="text-body-md text-on-surface-variant m-0">{body}</p>
    </div>
  );
}

function CodeDemo() {
  return (
    <section className="max-w-container-max mx-auto px-gutter py-xl">
      <div className="flex flex-col gap-lg">
        <div className="flex items-center justify-between mb-sm">
          <div>
            <h2 className="font-headline-lg text-headline-lg text-on-surface">
              Effortless Aggregation
            </h2>
            <p className="text-body-md text-on-surface-variant">
              The <code>time_bucket()</code> function handles alignment and
              gap-filling automatically.
            </p>
          </div>
          <div className="flex gap-sm">
            <span className="px-md py-xs bg-surface-variant rounded-full text-label-sm text-on-surface-variant">
              SQL
            </span>
            <span className="px-md py-xs bg-surface-variant/40 rounded-full text-label-sm text-on-surface-variant/60">
              PYTHON
            </span>
          </div>
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-5 gap-xl items-start">
          <div className="lg:col-span-3 rounded-xl overflow-hidden bg-surface-container-highest shadow-xl border border-outline-variant/30">
            <div className="flex items-center justify-between px-md py-sm bg-surface-container-high border-b border-outline-variant/30">
              <div className="flex items-center gap-xs">
                <div className="w-3 h-3 rounded-full bg-error/40" />
                <div className="w-3 h-3 rounded-full bg-primary/40" />
                <div className="w-3 h-3 rounded-full bg-secondary/40" />
              </div>
              <div className="flex items-center gap-md">
                <span className="text-label-sm text-on-surface-variant">
                  agg_sensor_data.sql
                </span>
                <Icon
                  name="content_copy"
                  className="text-on-surface-variant text-body-md cursor-pointer hover:text-on-surface"
                />
              </div>
            </div>
            <div className={`p-lg font-code-block text-code-block overflow-x-auto ${styles.codeScroll}`}>
              <pre className="leading-relaxed">
{<span className={styles.tokenComment}>{`-- Aggregating 1B sensor readings into 5-minute buckets`}</span>}
{"\n"}
{<span className={styles.tokenKeyword}>SELECT</span>}
{"\n  "}
{<span className={styles.tokenFunction}>time_bucket</span>}({<span className={styles.tokenString}>'5 minutes'</span>}, observation_time) {<span className={styles.tokenKeyword}>AS</span>} bucket,
{"\n  "}
{<span className={styles.tokenFunction}>avg</span>}(temperature) {<span className={styles.tokenKeyword}>AS</span>} avg_temp,
{"\n  "}
{<span className={styles.tokenFunction}>max</span>}(humidity) {<span className={styles.tokenKeyword}>AS</span>} max_hum
{"\n"}
{<span className={styles.tokenKeyword}>FROM</span>}
{"\n  "}lake_ts_table
{"\n"}
{<span className={styles.tokenKeyword}>WHERE</span>}
{"\n  "}device_type = {<span className={styles.tokenString}>'industrial_v4'</span>}
{"\n"}
{<span className={styles.tokenKeyword}>GROUP BY</span>}
{"\n  "}bucket
{"\n"}
{<span className={styles.tokenKeyword}>ORDER BY</span>}
{"\n  "}bucket {<span className={styles.tokenKeyword}>DESC</span>}
{"\n"}
{<span className={styles.tokenKeyword}>LIMIT</span>} {<span className={styles.tokenString}>100</span>};
              </pre>
            </div>
          </div>
          <div className="lg:col-span-2 flex flex-col gap-md">
            <div className="relative bg-surface-container rounded-xl border border-outline-variant/30 overflow-hidden group aspect-square">
              <div className="absolute inset-0 bg-gradient-to-br from-surface-container-high to-surface-container-lowest" />
              <div className="absolute inset-0 flex items-center justify-center">
                <Icon name="trending_up" className={styles.demoIcon} />
              </div>
              <div className="absolute bottom-md left-md bg-surface-container-highest/80 backdrop-blur-md px-md py-sm rounded-lg border border-outline-variant/30">
                <span className="text-label-sm text-primary font-bold">
                  LIVE RESULT VIEW
                </span>
              </div>
            </div>
            <div className="p-md bg-primary-container/10 rounded-lg border border-primary/20">
              <p className="text-body-md text-on-surface font-medium m-0">
                <Icon
                  name="tips_and_updates"
                  className="align-middle mr-xs text-primary"
                />
                Use{" "}
                <code className="bg-surface-container px-xs py-0.5 rounded text-primary">
                  locf()
                </code>{" "}
                to fill missing intervals in your data series effortlessly.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function StitchFooter() {
  return (
    <footer className="max-w-container-max mx-auto px-gutter py-xl border-t border-outline-variant/10 mt-xl text-center md:text-left">
      <div className="flex flex-col md:flex-row justify-between items-center gap-lg">
        <div>
          <div className="flex items-center gap-xs mb-sm">
            <Icon name="waves" className="text-primary" />
            <span className="font-bold">lake ts</span>
          </div>
          <p className="text-label-sm text-on-surface-variant m-0">
            © {new Date().getFullYear()} Databricks Inc. Licensed under the
            Databricks License.
          </p>
        </div>
        <div className="flex gap-xl text-label-sm text-on-surface-variant uppercase tracking-widest font-bold">
          <a
            href="https://github.com/databricks-solutions/lakets/security/policy"
            className="hover:text-primary transition-colors no-underline"
          >
            Security
          </a>
          <a
            href="https://github.com/databricks-solutions/lakets/blob/main/LICENSE.md"
            className="hover:text-primary transition-colors no-underline"
          >
            License
          </a>
          <a
            href="https://github.com/databricks-solutions/lakets"
            className="hover:text-primary transition-colors no-underline"
          >
            GitHub
          </a>
        </div>
      </div>
    </footer>
  );
}

function MobileBottomNav() {
  return (
    <nav className="md:hidden fixed bottom-0 left-0 w-full flex justify-around items-center h-16 px-4 bg-surface/80 backdrop-blur-xl border-t border-outline-variant/30 z-50">
      <Link
        to="/"
        className="flex flex-col items-center justify-center bg-secondary-container text-on-secondary-container rounded-full px-4 py-1 touch-manipulation active:scale-90 transition-all no-underline"
      >
        <Icon name="home" />
        <span className="text-label-sm">Home</span>
      </Link>
      <Link
        to="/intro"
        className="flex flex-col items-center justify-center text-on-surface-variant touch-manipulation active:scale-90 transition-all no-underline"
      >
        <Icon name="description" />
        <span className="text-label-sm">Docs</span>
      </Link>
      <Link
        to="/reference/api-reference"
        className="flex flex-col items-center justify-center text-on-surface-variant touch-manipulation active:scale-90 transition-all no-underline"
      >
        <Icon name="api" />
        <span className="text-label-sm">API</span>
      </Link>
      <a
        href="https://github.com/databricks-solutions/lakets"
        className="flex flex-col items-center justify-center text-on-surface-variant touch-manipulation active:scale-90 transition-all no-underline"
      >
        <Icon name="open_in_new" />
        <span className="text-label-sm">GitHub</span>
      </a>
    </nav>
  );
}

export default function Home(): JSX.Element {
  const { siteConfig } = useDocusaurusContext();

  // Mark the body so global CSS in custom.css can hide the Docusaurus
  // navbar (the Stitch header replaces it on this page only).
  React.useEffect(() => {
    document.body.classList.add("stitch-home");
    return () => document.body.classList.remove("stitch-home");
  }, []);

  return (
    <Layout
      title={siteConfig.title}
      description="LakeTS — pure-SQL time series toolkit for Databricks Lakebase, with a hot Lakebase + cold Delta tier hybrid architecture."
      noFooter
    >
      <div className={`bg-surface font-body-md text-on-surface ${styles.root}`}>
        <StitchHeader />
        <StitchSidebar />
        <main className="md:ml-sidebar-width pt-16 min-h-screen">
          <StitchHero />
          <FeatureBento />
          <CodeDemo />
          <StitchFooter />
        </main>
        <MobileBottomNav />
      </div>
    </Layout>
  );
}
