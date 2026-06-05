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
            LakeTS
          </span>
        </Link>
        <div className="hidden md:flex items-center gap-lg">
          <nav className="flex gap-md">
            <Link
              to="/guides/getting-started"
              className="text-primary font-bold hover:opacity-80 transition-opacity no-underline"
            >
              Docs
            </Link>
            <Link
              to="/reference/"
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
          <Link
            to="/search"
            className="flex items-center gap-sm bg-surface-container-high px-md py-xs rounded-full border border-outline-variant/30 cursor-pointer hover:border-primary/40 transition-colors no-underline"
          >
            <Icon name="search" className="text-on-surface-variant" />
            <span className="text-label-sm text-on-surface-variant uppercase tracking-wider">
              Search...
            </span>
            <span className="ml-xl px-xs py-[2px] bg-surface-container text-on-surface-variant border border-outline-variant/50 rounded text-[10px]">
              CMD K
            </span>
          </Link>
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

function HotColdAnimation() {
  return (
    <section className="max-w-container-max mx-auto px-gutter py-xl">
      <div className="flex flex-col items-center text-center mb-lg">
        <span className="text-label-sm text-primary uppercase font-bold tracking-widest mb-sm">
          How LakeTS works
        </span>
        <h2 className="font-headline-lg text-headline-lg text-on-surface mb-sm">
          Hot Lakebase, cold Unity Catalog — one query surface
        </h2>
        <p className="text-body-md text-on-surface-variant max-w-xl m-0">
          Recent rows live in Lakebase for sub-10ms reads. Lakebase CDF streams
          older data into a Unity Catalog Managed Table for cheap, long-horizon retention.
        </p>
      </div>
      <video
        src="/lakets/video/hot-cold-tier.mp4"
        poster="/lakets/video/hot-cold-tier-poster.png"
        autoPlay
        loop
        muted
        playsInline
        className="w-full rounded-xl border border-outline-variant/30 shadow-2xl shadow-primary/5"
      />
    </section>
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
              New: Version 0.1.2 Live
            </span>
          </div>
          <h1 className="font-display text-display text-on-surface leading-tight mb-md">
            Supercharge <span className="text-primary">Time-Series</span> on
            Databricks
          </h1>
          <p className="font-body-lg text-body-lg text-on-surface-variant mb-xl max-w-xl">
            A toolkit that brings time-series capabilities to the Databricks
            Data Intelligence Platform — built on Lakebase, native to Unity
            Catalog.
          </p>
          <div className="flex flex-wrap gap-md">
            <Link
              to="/guides/getting-started"
              className="px-xl py-md bg-primary-container text-on-primary-container font-bold rounded-lg hover:opacity-90 transition-all active:scale-95 shadow-lg shadow-primary/10 no-underline"
            >
              Get Started
            </Link>
            <Link
              to="/reference/"
              className="px-xl py-md border border-outline text-on-surface font-bold rounded-lg hover:bg-surface-variant transition-all active:scale-95 no-underline"
            >
              View API Docs
            </Link>
          </div>
        </div>
        <div className="relative group">
          <div className="absolute -inset-4 bg-primary/5 rounded-full blur-3xl group-hover:bg-primary/10 transition-colors duration-1000" />
          <div className="relative bg-surface-container-high rounded-xl border border-outline-variant/30 overflow-hidden shadow-2xl aspect-video">
            <img
              src="/lakets/img/stitch/hero.png"
              alt="Databricks delta logo with glowing data-flow streaks"
              className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity duration-500"
            />
            <div className="absolute inset-0 bg-gradient-to-t from-surface-container-high/60 to-transparent" />
          </div>
        </div>
      </div>
    </section>
  );
}

function ChronoTableShowcase() {
  return (
    <section className="max-w-container-max mx-auto px-gutter py-xl">
      <div className="grid grid-cols-1 lg:grid-cols-5 gap-xl items-center">
        <div className="lg:col-span-3 rounded-xl overflow-hidden bg-surface-container-highest shadow-xl border border-outline-variant/30">
          <div className="flex items-center justify-between px-md py-sm bg-surface-container-high border-b border-outline-variant/30">
            <div className="flex items-center gap-xs">
              <div className="w-3 h-3 rounded-full bg-error/40" />
              <div className="w-3 h-3 rounded-full bg-primary/40" />
              <div className="w-3 h-3 rounded-full bg-secondary/40" />
            </div>
            <span className="text-label-sm text-on-surface-variant">
              create_chronotable.sql
            </span>
          </div>
          <div className={styles.codeBlock}>
            <pre>
{<span className={styles.tokenComment}>{`-- One call turns any table into a time-partitioned ChronoTable`}</span>}
{"\n"}
{<span className={styles.tokenKeyword}>CREATE TABLE</span>} metrics (
{"\n  "}time   {<span className={styles.tokenKeyword}>TIMESTAMPTZ NOT NULL</span>},
{"\n  "}device {<span className={styles.tokenKeyword}>TEXT</span>},
{"\n  "}cpu    {<span className={styles.tokenKeyword}>DOUBLE PRECISION</span>}
{"\n"});
{"\n"}
{"\n"}{<span className={styles.tokenKeyword}>SELECT</span>} {<span className={styles.tokenFunction}>lakets.create_chronotable</span>}(
{"\n  "}{<span className={styles.tokenString}>'metrics'</span>}, {<span className={styles.tokenString}>'time'</span>}, {<span className={styles.tokenString}>'1 day'</span>}
{"\n"});
{"\n"}
{"\n"}{<span className={styles.tokenComment}>{`-- Or: InfluxDB-style table + chunks + indexes in one call`}</span>}
{"\n"}{<span className={styles.tokenKeyword}>SELECT</span>} {<span className={styles.tokenFunction}>lakets.create_metric_table</span>}(
{"\n  "}{<span className={styles.tokenString}>'system_metrics'</span>},
{"\n  "}tag_columns    {<span className={styles.tokenKeyword}>:=</span>} {<span className={styles.tokenKeyword}>ARRAY</span>}[{<span className={styles.tokenString}>'host'</span>}, {<span className={styles.tokenString}>'region'</span>}, {<span className={styles.tokenString}>'env'</span>}],
{"\n  "}field_columns  {<span className={styles.tokenKeyword}>:=</span>} {<span className={styles.tokenKeyword}>ARRAY</span>}[{<span className={styles.tokenString}>'cpu'</span>}, {<span className={styles.tokenString}>'memory'</span>}],
{"\n  "}chunk_interval {<span className={styles.tokenKeyword}>:=</span>} {<span className={styles.tokenString}>'1 day'</span>}
{"\n"});
            </pre>
          </div>
        </div>
        <div className="lg:col-span-2">
          <span className="text-label-sm text-primary uppercase font-bold tracking-widest">
            ChronoTables
          </span>
          <h2 className="font-headline-lg text-headline-lg text-on-surface mt-sm mb-md">
            From regular table to ChronoTable in one call
          </h2>
          <p className="text-body-md text-on-surface-variant mb-md">
            LakeTS partitions your table by time, pre-creates future chunks, and
            adds BRIN indexes for fast time-range scans. The metadata registry
            wires the table into <code>time_bucket</code>, RollUps, and Lakehouse
            Sync automatically.
          </p>
          <p className="text-body-md text-on-surface-variant mb-lg">
            Drop a 30-day-old chunk in milliseconds — no row-by-row{" "}
            <code>DELETE</code>, no manual partition juggling.
          </p>
          <Link
            to="/guides/getting-started"
            className="inline-flex items-center gap-xs text-primary font-bold hover:opacity-80 transition-opacity no-underline"
          >
            Get started <Icon name="arrow_forward" />
          </Link>
        </div>
      </div>
    </section>
  );
}

interface CriticalFeature {
  icon: string;
  iconColor: string;
  iconHover: string;
  title: string;
  body: string;
  href: string;
  internal: boolean;
}

const CRITICAL_FEATURES: CriticalFeature[] = [
  {
    icon: "auto_awesome_motion",
    iconColor: "text-primary",
    iconHover: "group-hover:bg-primary/20",
    title: "ChronoTables",
    body: "Time-partitioned tables with pre-created future chunks, BRIN indexes, and instant chunk drops for retention.",
    href: "/guides/getting-started#2-create-your-first-chronotable",
    internal: true,
  },
  {
    icon: "query_stats",
    iconColor: "text-secondary",
    iconHover: "group-hover:bg-secondary/20",
    title: "Time series functions",
    body: "time_bucket, first, last, locf, interpolate, delta, rate, gapfill — all native PL/pgSQL, no extensions.",
    href: "/reference/time-series-functions",
    internal: true,
  },
  {
    icon: "account_tree",
    iconColor: "text-tertiary",
    iconHover: "group-hover:bg-tertiary/20",
    title: "Incremental RollUps",
    body: "Per-bucket DELETE+INSERT with watermark + invalidation log. DAG cascade refreshes hierarchical aggregates in topological order.",
    href: "/guides/how-it-works/rollups",
    internal: true,
  },
  {
    icon: "bolt",
    iconColor: "text-primary",
    iconHover: "group-hover:bg-primary/20",
    title: "Last Value Cache",
    body: "Trigger-maintained \"current state\" table. Sub-10ms reads on the latest value per key, perfect for status widgets.",
    href: "/how-to/last-value-cache",
    internal: true,
  },
  {
    icon: "cloud_sync",
    iconColor: "text-secondary",
    iconHover: "group-hover:bg-secondary/20",
    title: "Lakebase CDF",
    body: "CDC replication to a Unity Catalog Managed Table via shadow tables. RollUps stay in Lakebase, raw data tiers out for long-horizon analytics.",
    href: "/guides/lakebase-cdf-setup",
    internal: true,
  },
  {
    icon: "notifications_active",
    iconColor: "text-tertiary",
    iconHover: "group-hover:bg-tertiary/20",
    title: "Alerts + Bulk Ingest",
    body: "SQL-native threshold and deadman alerts. JSONB batch ingest from edge devices and Prometheus-compatible writers.",
    href: "/how-to/alerts",
    internal: true,
  },
];

function CriticalFeaturesGrid() {
  return (
    <section className="max-w-container-max mx-auto px-gutter py-xl">
      <div className="flex flex-col items-center text-center mb-lg">
        <span className="text-label-sm text-primary uppercase font-bold tracking-widest mb-sm">
          Critical features
        </span>
        <h2 className="font-headline-lg text-headline-lg text-on-surface m-0">
          Everything you need for time series at scale
        </h2>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-lg">
        {CRITICAL_FEATURES.map((f) => (
          <FeatureCard key={f.title} {...f} />
        ))}
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
  href,
  internal,
}: CriticalFeature) {
  const cardClasses =
    "p-lg bg-surface-container-low rounded-xl border border-outline-variant/20 hover:border-primary/40 transition-colors group no-underline flex flex-col h-full";
  const inner = (
    <>
      <div
        className={`w-12 h-12 bg-surface-container-highest rounded-lg flex items-center justify-center mb-md transition-colors ${iconHover}`}
      >
        <Icon name={icon} className={iconColor} />
      </div>
      <h3 className="font-headline-md text-headline-md mb-sm text-on-surface">
        {title}
      </h3>
      <p className="text-body-md text-on-surface-variant m-0 flex-1">{body}</p>
      <span className="mt-md text-label-sm text-primary uppercase font-bold tracking-widest">
        Learn more →
      </span>
    </>
  );
  return internal ? (
    <Link to={href} className={cardClasses}>
      {inner}
    </Link>
  ) : (
    <a href={href} className={cardClasses}>
      {inner}
    </a>
  );
}

function StitchFooter() {
  return (
    <footer className="max-w-container-max mx-auto px-gutter py-xl border-t border-outline-variant/10 mt-xl text-center md:text-left">
      <div className="flex flex-col md:flex-row justify-between items-center gap-lg">
        <div>
          <div className="flex items-center gap-xs mb-sm">
            <Icon name="waves" className="text-primary" />
            <span className="font-bold">LakeTS</span>
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
        to="/guides/getting-started"
        className="flex flex-col items-center justify-center text-on-surface-variant touch-manipulation active:scale-90 transition-all no-underline"
      >
        <Icon name="description" />
        <span className="text-label-sm">Docs</span>
      </Link>
      <Link
        to="/reference/"
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

  // Cmd/Ctrl + K → navigate to the search page (the Stitch header's
  // search pill is a visual mock of the Docusaurus search input).
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        window.location.assign(`${siteConfig.baseUrl}search`);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [siteConfig.baseUrl]);

  return (
    <Layout
      title={siteConfig.title}
      description="LakeTS — pure-SQL time series toolkit for the Databricks Data Intelligence Platform, with a hot Lakebase + cold Unity Catalog Managed Table hybrid architecture."
      noFooter
    >
      <div className={`bg-surface font-body-md text-on-surface ${styles.root}`}>
        <StitchHeader />
        <main className="pt-16 min-h-screen">
          <StitchHero />
          <HotColdAnimation />
          <ChronoTableShowcase />
          <CriticalFeaturesGrid />
          <StitchFooter />
        </main>
        <MobileBottomNav />
      </div>
    </Layout>
  );
}
