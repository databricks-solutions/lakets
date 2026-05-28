import React from "react";
import Layout from "@theme/Layout";
import Link from "@docusaurus/Link";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import styles from "./index.module.css";

// Port of the Stitch design for the LakeTS homepage
// ("Lake TS - Desktop Home (Dark Mode)", projects/10067549973504610213).
// Layout: glassmorphic header → hero → 3-up feature bento → SQL code demo
// → footer. Mobile bottom nav at the viewport bottom on small screens.
// Uses the Tailwind CDN (configured in docusaurus.config.ts headTags).

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

function HomepageContent() {
  return (
    <div className={`bg-surface font-body-md text-on-surface ${styles.root}`}>
      {/* Hero ------------------------------------------------------------- */}
      <section className="relative w-full overflow-hidden bg-surface-container-lowest border-b border-outline-variant/20">
        <div className="max-w-container-max mx-auto px-gutter py-xl md:py-[80px] grid md:grid-cols-2 items-center gap-xl">
          <div className="z-10">
            <div className="inline-flex items-center gap-sm px-md py-xs rounded-full bg-primary/10 border border-primary/20 mb-lg">
              <span className="w-2 h-2 rounded-full bg-primary animate-pulse" />
              <span className="text-label-sm text-primary uppercase font-bold">
                Latest: v0.1.2 released
              </span>
            </div>
            <h1 className="font-display text-display text-on-surface leading-tight mb-md">
              Supercharge{" "}
              <span className="text-primary">Time Series</span> on Databricks
              Lakebase
            </h1>
            <p className="font-body-lg text-body-lg text-on-surface-variant mb-xl max-w-xl">
              LakeTS is a pure-SQL toolkit that turns Lakebase into a full
              time series database. Automatic partitioning, gap-filling,
              incremental rollups, and Delta tiering — no custom extensions.
            </p>
            <div className="flex flex-wrap gap-md">
              <Link
                to="/guides/getting-started"
                className="px-xl py-md bg-primary-container text-on-primary-container font-bold rounded-lg hover:opacity-90 transition-all active:scale-95 shadow-lg shadow-primary/10 no-underline"
              >
                Get started
              </Link>
              <Link
                to="/reference/api-reference"
                className="px-xl py-md border border-outline text-on-surface font-bold rounded-lg hover:bg-surface-variant transition-all active:scale-95 no-underline"
              >
                View API reference
              </Link>
            </div>
          </div>
          <div className="relative group">
            <div className="absolute -inset-4 bg-primary/5 rounded-full blur-3xl group-hover:bg-primary/10 transition-colors duration-1000" />
            <div className="relative bg-surface-container-high rounded-xl border border-outline-variant/30 overflow-hidden shadow-2xl aspect-video">
              <div className="absolute inset-0 grid grid-cols-12 gap-px opacity-20">
                {Array.from({ length: 12 * 8 }).map((_, i) => (
                  <div key={i} className="bg-primary/10" />
                ))}
              </div>
              <div className="absolute inset-0 flex items-center justify-center">
                <Icon name="waves" className="text-primary text-[180px] opacity-30" />
              </div>
              <div className="absolute bottom-md left-md right-md flex items-center justify-between text-label-sm">
                <span className="bg-surface-container-highest/80 backdrop-blur-md px-md py-sm rounded-lg border border-outline-variant/30 text-primary font-bold">
                  LAKEBASE → DELTA
                </span>
                <span className="bg-surface-container-highest/80 backdrop-blur-md px-md py-sm rounded-lg border border-outline-variant/30 text-secondary font-bold">
                  CDC SHADOW SYNC
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Feature bento ---------------------------------------------------- */}
      <section className="max-w-container-max mx-auto px-gutter py-xl">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-lg">
          <FeatureCard
            icon="speed"
            iconColor="text-primary"
            iconBg="group-hover:bg-primary/20"
            title="Sub-10ms latest state"
            body="Last Value Cache for instant 'what's the current reading?' queries. Trigger-maintained, no polling, no scans."
          />
          <FeatureCard
            icon="view_agenda"
            iconColor="text-secondary"
            iconBg="group-hover:bg-secondary/20"
            title="Native time bucketing"
            body="time_bucket, gap-fill, locf, first/last, delta, rate, histogram — purpose-built SQL for time series, not bolted-on windows."
          />
          <FeatureCard
            icon="cloud_sync"
            iconColor="text-tertiary"
            iconBg="group-hover:bg-tertiary/20"
            title="Hot + cold tiering"
            body="Lakebase for sub-second hot reads, Delta Lake for cheap retention. Lakehouse Sync replicates between them via CDC."
          />
        </div>
      </section>

      {/* Code demo -------------------------------------------------------- */}
      <section className="max-w-container-max mx-auto px-gutter py-xl">
        <div className="flex flex-col gap-lg">
          <div className="flex items-center justify-between mb-sm">
            <div>
              <h2 className="font-headline-lg text-headline-lg text-on-surface">
                Pure SQL, no extensions
              </h2>
              <p className="text-body-md text-on-surface-variant">
                Everything lives in the <code>lakets</code> schema and runs
                on stock PostgreSQL 16.
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
                    hourly_metrics.sql
                  </span>
                  <Icon
                    name="content_copy"
                    className="text-on-surface-variant text-body-md cursor-pointer hover:text-on-surface"
                  />
                </div>
              </div>
              <div className="p-lg font-code-block text-code-block overflow-x-auto">
                <pre className="leading-relaxed">
                  <span className={styles.tokenComment}>
                    -- Convert a regular table into a ChronoTable
                  </span>
                  {"\n"}
                  <span className={styles.tokenKeyword}>SELECT</span>{" "}
                  <span className={styles.tokenFunction}>
                    lakets.create_chronotable
                  </span>
                  (<span className={styles.tokenString}>'metrics'</span>,{" "}
                  <span className={styles.tokenString}>'time'</span>,{" "}
                  <span className={styles.tokenString}>'1 day'</span>);
                  {"\n\n"}
                  <span className={styles.tokenComment}>
                    -- Hourly averages with gap-filling
                  </span>
                  {"\n"}
                  <span className={styles.tokenKeyword}>SELECT</span>
                  {"\n  "}
                  <span className={styles.tokenFunction}>
                    lakets.time_bucket
                  </span>
                  (<span className={styles.tokenString}>'1 hour'</span>::interval,
                  time) <span className={styles.tokenKeyword}>AS</span> hour,
                  {"\n  "}
                  <span className={styles.tokenFunction}>avg</span>(cpu){" "}
                  <span className={styles.tokenKeyword}>AS</span> avg_cpu,
                  {"\n  "}
                  <span className={styles.tokenFunction}>lakets.last</span>(cpu,
                  time) <span className={styles.tokenKeyword}>AS</span> latest
                  {"\n"}
                  <span className={styles.tokenKeyword}>FROM</span> metrics
                  {"\n"}
                  <span className={styles.tokenKeyword}>WHERE</span> time &gt;{" "}
                  <span className={styles.tokenFunction}>now</span>() - interval{" "}
                  <span className={styles.tokenString}>'1 day'</span>
                  {"\n"}
                  <span className={styles.tokenKeyword}>GROUP BY</span> 1
                  {"\n"}
                  <span className={styles.tokenKeyword}>ORDER BY</span> 1{" "}
                  <span className={styles.tokenKeyword}>DESC</span>;
                </pre>
              </div>
            </div>
            <div className="lg:col-span-2 flex flex-col gap-md">
              <div className="bg-surface-container rounded-xl border border-outline-variant/30 p-lg">
                <h3 className="font-headline-md text-headline-md mb-md text-on-surface">
                  RollUp engine
                </h3>
                <p className="text-body-md text-on-surface-variant mb-md">
                  Incremental aggregates with per-bucket refresh, DAG
                  orchestration, and Delta export. Only dirty buckets are
                  recomputed.
                </p>
                <Link
                  to="/guides/how-it-works"
                  className="text-body-md text-secondary font-bold hover:text-primary transition-colors no-underline"
                >
                  How it works →
                </Link>
              </div>
              <div className="p-md bg-primary-container/10 rounded-lg border border-primary/20">
                <p className="text-body-md text-on-surface font-medium m-0">
                  <Icon
                    name="tips_and_updates"
                    className="align-middle mr-xs text-primary"
                  />
                  Need cold-tier analytics? Enable Lakehouse Sync and query the
                  same data via Photon on Delta.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* What's included quick grid -------------------------------------- */}
      <section className="max-w-container-max mx-auto px-gutter py-xl border-t border-outline-variant/10">
        <h2 className="font-headline-lg text-headline-lg text-on-surface mb-lg">
          Everything in the box
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-md text-body-md text-on-surface-variant">
          {[
            { i: "schedule", t: "ChronoTables" },
            { i: "labels", t: "Multi-metric tables" },
            { i: "functions", t: "Time series functions" },
            { i: "all_inclusive", t: "Gap-filling" },
            { i: "trending_up", t: "RollUp engine" },
            { i: "archive", t: "Compression & tiering" },
            { i: "auto_delete", t: "Retention" },
            { i: "sync_alt", t: "Lakehouse Sync" },
            { i: "bolt", t: "Last Value Cache" },
            { i: "verified", t: "Unity Catalog integration" },
            { i: "upload", t: "Bulk ingest" },
            { i: "notification_important", t: "SQL-native alerts" },
          ].map((f) => (
            <div
              key={f.t}
              className="flex items-center gap-sm p-md rounded-lg border border-outline-variant/15 hover:border-primary/40 transition-colors"
            >
              <Icon name={f.i} className="text-primary" />
              <span>{f.t}</span>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function FeatureCard({
  icon,
  iconColor,
  iconBg,
  title,
  body,
}: {
  icon: string;
  iconColor: string;
  iconBg: string;
  title: string;
  body: string;
}) {
  return (
    <div className="p-lg bg-surface-container-low rounded-xl border border-outline-variant/20 hover:border-primary/40 transition-colors group">
      <div
        className={`w-12 h-12 bg-surface-container-highest rounded-lg flex items-center justify-center mb-md transition-colors ${iconBg}`}
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

export default function Home(): JSX.Element {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description={
        "LakeTS — pure-SQL time series toolkit for Databricks Lakebase, with a hot Lakebase + cold Delta tier hybrid architecture."
      }
    >
      <HomepageContent />
    </Layout>
  );
}
