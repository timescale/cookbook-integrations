# Query Tiger Cloud Data from Snowflake

Use Apache Iceberg to make a Tiger Cloud time-series table queryable from Snowflake — no ETL pipelines, no data duplication, no copy jobs. By the end you'll have NYC film permit data flowing from Tiger Cloud into Snowflake, joined with a Snowflake-native reference table to answer: *which NYC borough has the most film permits per capita?*

## Overview

This tutorial shows how to set up a one-way bridge between two cloud data systems using an open table format:

- **Tiger Cloud** stores your operational time-series data (in this tutorial: NYC Film Permits, ~16k rows). It writes a continuously-updated copy into **Apache Iceberg** tables on **AWS S3 Tables** in *your* AWS account.
- **Snowflake** reads those Iceberg tables in place via a Catalog Integration. It never copies the data — every query in Snowflake reads the same files Tiger Cloud writes.

**Why bother?** Two reasons:
1. You can keep using Tiger Cloud's strengths (real-time inserts, hypertables, continuous aggregates) for operational workloads, and Snowflake's strengths (analytical SQL across many sources, BI tool ecosystem) for cross-domain analytics.
2. You can join your time-series data with reference tables, customer data, or other warehouse content that already lives in Snowflake — without ever moving the time-series data out of your AWS account.

**One important caveat upfront:** the connection is **read-only from Snowflake's side**. Snowflake can `SELECT` from the Iceberg tables but cannot `INSERT`, `UPDATE`, or `DELETE`. Writes always go through Tiger Cloud.

By the end of this tutorial you'll have:
- A Tiger Cloud service running with the NYC Film Permits dataset loaded into a hypertable
- An Iceberg connector syncing that data to S3 Tables in your AWS account
- A Snowflake Catalog Integration reading those tables
- A working analytical query that joins time-series film data (Iceberg) with borough population data (Snowflake-native)

## Getting Started

### What You'll Need

In rough order of "you probably have this" → "you may need to set this up":

- **A terminal and `psql`** — for running setup.sql against Tiger Cloud. Comes with most PostgreSQL installs; on macOS run `brew install libpq && brew link --force libpq`.
- **Python 3.10+** — for the data loader script. [python.org/downloads](https://www.python.org/downloads/)
- **A Python package manager** — we use `pip` in this tutorial; [`uv`](https://docs.astral.sh/uv/) and `conda` work too.
- **An AWS account** — Tiger Lake writes to S3 Tables in *your* AWS account. The S3 Tables free tier covers small datasets like this one. [aws.amazon.com](https://aws.amazon.com/)
- **AWS CLI v2** — for creating the IAM role and granting Lake Formation permissions. [Install instructions](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). No-install alternative: use [AWS CloudShell](https://console.aws.amazon.com/cloudshell/) directly in the browser.
- **A Tiger Cloud account** — sign up at [console.cloud.tigerdata.com](https://console.cloud.tigerdata.com). The free trial covers everything in this tutorial.
- **A Snowflake account with `ACCOUNTADMIN` access** — `CREATE CATALOG INTEGRATION` requires the `ACCOUNTADMIN` role specifically (not `SYSADMIN`). If you're on a corporate Snowflake account where you don't have this role, sign up for a free trial at [signup.snowflake.com](https://signup.snowflake.com/) — you'll be `ACCOUNTADMIN` on your own trial account.

> **Cost note** — The free tiers of Tiger Cloud, AWS S3 Tables, and Snowflake comfortably cover everything in this tutorial. The biggest gotcha is **cross-region data transfer**: if your Tiger Cloud service and your S3 Table Bucket are in different AWS regions, AWS will charge you per-GB transfer fees. Step 3 walks you through matching them.

### Verify your setup

Before going further, confirm your AWS CLI works and you know which account you're in:

```bash
aws sts get-caller-identity
```

You should see something like:

```json
{
    "UserId": "AIDA...",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/your-name"
}
```

Note the `Account` value — that's your `<YOUR_AWS_ACCOUNT_ID>` for the rest of the tutorial.

## Step 1 — Create a Tiger Cloud service and load the dataset

Before there's anything to query from Snowflake, you need data in Tiger Cloud.

**Create the service:**

1. Sign in at [console.cloud.tigerdata.com](https://console.cloud.tigerdata.com).
2. Click `Create service`.
3. Choose `Time series and analytics`.
4. **Pick an AWS region you'll remember** — write it down. The S3 Table Bucket in Step 3 needs to be in the same region or AWS will charge cross-region transfer fees.
5. Click `Create service`.
6. When the service is ready, copy the **Service URL** from the connection info panel. It looks like `postgres://tsdbadmin:PASSWORD@HOST.tsdb.cloud.timescale.com:5432/tsdb?sslmode=require`.

**Run the schema setup:**

Clone this repo (or just download `setup.sql` and `load.py` from this folder), then:

```bash
git clone https://github.com/timescale/cookbook-integrations.git
cd cookbook-integrations/snowflake
psql "postgres://tsdbadmin:PASSWORD@HOST.tsdb.cloud.timescale.com:5432/tsdb?sslmode=require" -f setup.sql
```

`setup.sql` enables TimescaleDB, creates the `film_permits` hypertable, and inserts 12 sample rows so you have something to query immediately. You should see output ending with:

```
 total_rows |        earliest        |         latest         | boroughs
------------+------------------------+------------------------+----------
         12 | 2024-12-10 01:00:00+00 | 2025-12-21 14:00:00+00 |        4
```

**Load the full dataset (~16k rows):**

```bash
cp .env.example .env
# Open .env and paste your Tiger Cloud Service URL into TIGER_SERVICE_URL
pip install -r requirements.txt
python load.py
```

The script pages through the NYC Open Data Socrata API and bulk-inserts every permit. It's idempotent — re-run it any time and it'll only insert rows that aren't already there. You should see something like:

```
Connecting to Tiger Cloud...
  fetching rows 0–5,000...
  fetching rows 5,000–10,000...
  fetching rows 10,000–15,000...
  fetching rows 15,000–20,000...

Done! Saw 16,864 API rows, inserted 16,852 new rows.
```

> **What's a hypertable?** A hypertable looks and behaves like a regular PostgreSQL table, but TimescaleDB transparently partitions it into chunks by time under the hood. That makes time-range queries fast even on billions of rows. For this tutorial, the partitioning happens by month on the `enddatetime` column.

Now you have real time-series data in Tiger Cloud. Next, we'll mirror it into Iceberg.

## Step 2 — Enable the Tiger Lake Iceberg connector

This step provisions the AWS resources Tiger Cloud needs to write Iceberg tables on your behalf, and turns on the continuous sync.

> **What's Apache Iceberg?** [Iceberg](https://iceberg.apache.org/) is an open table format for storing large datasets on object storage (like S3). Think of it as a universal "table" file — any compatible engine (Snowflake, Spark, Athena, Trino, DuckDB) can read it directly without copying data.

> **What's an S3 Table Bucket?** A regular S3 bucket purpose-built for Iceberg tables — AWS handles the metadata, compaction, and cataloging behind the scenes.

**Set up the connector:**

1. In the Tiger Cloud Console, open the service you created in Step 1.
2. Click the `Connectors` tab.
3. Choose `Destination connectors` from the left sidebar.
4. Pick `Apache Iceberg for Amazon S3 Tables`.
5. Tiger Cloud opens AWS CloudFormation in a new tab with a pre-filled template. **Make sure the AWS region selector at the top right of the AWS Console matches the region of your Tiger Cloud service** before you create the stack.
6. Give the stack a name (e.g. `tiger-iceberg-tutorial`) and a `BucketName` (e.g. `tiger-film-permits`).
7. Check the IAM resources acknowledgement box and click `Submit`.
8. Wait until the stack status reaches `CREATE_COMPLETE` (usually 2–3 minutes).
9. Open the `Outputs` tab of the CloudFormation stack and copy the `S3TableBucketArn` value. It looks like `arn:aws:s3tables:us-east-1:111122223333:bucket/tiger-film-permits`.
10. Back in the Tiger Cloud Console connector flow, paste the ARN values it asks for and click `Connect`.

**Verify the sync started:**

In the Tiger Cloud Console, the connector status should show `Active` within about a minute. The first full sync of all 16k rows usually completes within 5 minutes; subsequent updates land within ~120 seconds of being inserted.

### Find your namespace

Inside your S3 Table Bucket, Tiger Cloud creates a *namespace* (logical grouping of tables). You'll need its name for the Snowflake setup. Run:

```bash
aws s3tables list-namespaces \
  --table-bucket-arn arn:aws:s3tables:<YOUR_AWS_REGION>:<YOUR_AWS_ACCOUNT_ID>:bucket/<YOUR_BUCKET_NAME> \
  --region <YOUR_AWS_REGION>
```

You should see something like:

```json
{
    "namespaces": [
        {
            "namespace": ["tiger_xxx_xxx"],
            "createdAt": "2026-04-17T10:23:11.000Z",
            "createdBy": "111122223333",
            "ownerAccountId": "111122223333"
        }
    ]
}
```

Write down the `namespace` value — that's your `<YOUR_NAMESPACE>` for the rest of the tutorial.

> **No namespaces returned?** The first sync hasn't completed yet. Wait a minute and try again. Still empty after 5 minutes? Check the connector status in Tiger Cloud Console.

### Placeholder reference

Use this table to find each placeholder you'll see in the steps below:

| Placeholder | What it is | Where to get it |
|---|---|---|
| `<YOUR_AWS_REGION>` | The AWS region where your S3 Table Bucket lives | The segment after `s3tables:` in your `S3TableBucketArn`, e.g. `us-east-1` |
| `<YOUR_AWS_ACCOUNT_ID>` | Your 12-digit AWS account number | The segment after the region in your `S3TableBucketArn`. Or run `aws sts get-caller-identity` |
| `<YOUR_BUCKET_NAME>` | The name of your S3 Table Bucket | The segment after `bucket/` in your `S3TableBucketArn` |
| `<YOUR_NAMESPACE>` | The Tiger Cloud-created namespace | Output of the `aws s3tables list-namespaces` command above |
| `<API_AWS_IAM_USER_ARN>` | Snowflake's AWS identity | Output of `DESC INTEGRATION` in Step 4 |
| `<API_AWS_EXTERNAL_ID>` | Snowflake's external ID | Output of `DESC INTEGRATION` in Step 4 |

**Worked example.** If your `S3TableBucketArn` is `arn:aws:s3tables:us-east-1:111122223333:bucket/tiger-film-permits`, then:

- `<YOUR_AWS_REGION>` → `us-east-1`
- `<YOUR_AWS_ACCOUNT_ID>` → `111122223333`
- `<YOUR_BUCKET_NAME>` → `tiger-film-permits`

Now let's wire up Snowflake.

## Step 3 — Create the Catalog Integration in Snowflake

A **Catalog Integration** is how Snowflake learns where to find your Iceberg tables and how to authenticate to them. You'll create it now and complete the auth handshake over the next two steps.

> **What's a Catalog?** Iceberg separates "the data" (Parquet files) from "the catalog" (metadata about which files belong to which table). For S3 Tables, the catalog is AWS Glue. The Catalog Integration tells Snowflake to ask Glue what tables exist and then read the underlying files from S3.

Open a Snowflake worksheet **as the `ACCOUNTADMIN` role** and run:

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE CATALOG INTEGRATION tiger_s3tables_catalog
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = '<YOUR_NAMESPACE>'
  REST_CONFIG = (
    CATALOG_URI = 'https://glue.<YOUR_AWS_REGION>.amazonaws.com/iceberg'
    CATALOG_API_TYPE = AWS_GLUE
    WAREHOUSE = '<YOUR_AWS_ACCOUNT_ID>:s3tablescatalog/<YOUR_BUCKET_NAME>'
    ACCESS_DELEGATION_MODE = VENDED_CREDENTIALS
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-s3tables-reader'
    SIGV4_SIGNING_REGION = '<YOUR_AWS_REGION>'
  )
  REFRESH_INTERVAL_SECONDS = 120
  ENABLED = TRUE;
```

You should see `Statement executed successfully.`

> **Why does this reference a role that doesn't exist yet?** `snowflake-s3tables-reader` is the IAM role you'll create in Step 5. You're naming it here in advance so Snowflake knows which role to assume when it tries to read your data.

### Get Snowflake's AWS identity

Snowflake just generated an AWS identity that *it* will use. You need both pieces of that identity to set up the trust on the AWS side:

```sql
DESC INTEGRATION tiger_s3tables_catalog;
```

From the output, find and copy these two values:

| Field | What it looks like |
|---|---|
| `API_AWS_IAM_USER_ARN` | `arn:aws:iam::111122223333:user/abc123` |
| `API_AWS_EXTERNAL_ID` | `ABC12345_SFCRole=2_xxxx=` |

Keep these handy — you'll paste them into the IAM trust policy in the next step.

## Step 4 — Create a dedicated IAM role for Snowflake

> **Why a separate role?** Tiger Cloud's IAM role is scoped to the *write* path (writing Iceberg files into your bucket). Creating a separate read-only role for Snowflake means: (1) Tiger Cloud's sync is never affected by Snowflake configuration changes, (2) you can revoke Snowflake's access independently, and (3) each role has only the permissions it actually needs (least-privilege).

> **What's an IAM trust policy?** Two things are happening here. First, you're saying *"Snowflake's AWS identity is allowed to assume this role"* (the trust policy). Second, you're saying *"once it has assumed the role, it can do these specific actions"* (the permissions policy). The `ExternalId` is a shared secret that prevents a third party from tricking Snowflake into accessing the wrong account.

### 4a. Create the IAM role

Replace `<API_AWS_IAM_USER_ARN>` and `<API_AWS_EXTERNAL_ID>` with the values you copied from Step 3:

```bash
aws iam create-role \
  --role-name snowflake-s3tables-reader \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "AWS": "<API_AWS_IAM_USER_ARN>" },
        "Action": "sts:AssumeRole",
        "Condition": {
          "StringEquals": { "sts:ExternalId": "<API_AWS_EXTERNAL_ID>" }
        }
      }
    ]
  }'
```

You should see JSON output describing the new role, ending with `"RoleName": "snowflake-s3tables-reader"`.

### 4b. Attach permissions to the role

This grants the role read access to AWS Glue (the Iceberg catalog), Lake Formation (which mediates table-level permissions), and your specific S3 Table Bucket. Replace `<YOUR_AWS_REGION>`, `<YOUR_AWS_ACCOUNT_ID>`, and `<YOUR_BUCKET_NAME>`:

```bash
aws iam put-role-policy \
  --role-name snowflake-s3tables-reader \
  --policy-name snowflake-s3tables-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "GlueAccess",
        "Effect": "Allow",
        "Action": [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables"
        ],
        "Resource": "*"
      },
      {
        "Sid": "LakeFormationAccess",
        "Effect": "Allow",
        "Action": ["lakeformation:GetDataAccess"],
        "Resource": "*"
      },
      {
        "Sid": "S3TablesReadAccess",
        "Effect": "Allow",
        "Action": [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:GetTable",
          "s3tables:ListTables",
          "s3tables:GetTableData",
          "s3tables:GetTableMetadataLocation"
        ],
        "Resource": [
          "arn:aws:s3tables:<YOUR_AWS_REGION>:<YOUR_AWS_ACCOUNT_ID>:bucket/<YOUR_BUCKET_NAME>",
          "arn:aws:s3tables:<YOUR_AWS_REGION>:<YOUR_AWS_ACCOUNT_ID>:bucket/<YOUR_BUCKET_NAME>/table/*"
        ]
      }
    ]
  }'
```

If the command returns no output, that's success. (AWS CLI returns an empty response on a successful `put-role-policy`.)

## Step 5 — Grant Lake Formation permissions

> **What's Lake Formation?** AWS Lake Formation is a permissions layer that sits *on top of* Glue and S3. Even if your IAM role has all the right S3 permissions, Lake Formation can still block the read at the table level — so you need to explicitly grant the role `SELECT` and `DESCRIBE` on the tables in your namespace.

Grant the Snowflake role read access to all tables in your namespace:

```bash
aws lakeformation grant-permissions \
  --region <YOUR_AWS_REGION> \
  --principal DataLakePrincipalIdentifier=arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-s3tables-reader \
  --resource '{
    "Table": {
      "CatalogId": "<YOUR_AWS_ACCOUNT_ID>:s3tablescatalog/<YOUR_BUCKET_NAME>",
      "DatabaseName": "<YOUR_NAMESPACE>",
      "TableWildcard": {}
    }
  }' \
  --permissions "SELECT" "DESCRIBE"
```

No output means success. Lake Formation just gave the Snowflake role permission to read every current and future table in the namespace.

## Step 6 — Verify the integration

Back in your Snowflake worksheet:

```sql
SELECT SYSTEM$VERIFY_CATALOG_INTEGRATION('tiger_s3tables_catalog');
```

A successful response looks like:

```json
{ "success": true, "errorCode": "", "errorMessage": "" }
```

If you see an error here, jump to the [Troubleshooting](#troubleshooting) section at the bottom.

## Step 7 — Register the Iceberg table in Snowflake

Snowflake now *can* read your Iceberg tables, but it doesn't know they exist yet. You need to register each table as a Snowflake-side reference.

**Create a database and schema:**

```sql
CREATE DATABASE IF NOT EXISTS tiger_data;
CREATE SCHEMA IF NOT EXISTS tiger_data.<YOUR_NAMESPACE>;
```

**See what tables Tiger Cloud has synced:**

```bash
aws s3tables list-tables \
  --table-bucket-arn arn:aws:s3tables:<YOUR_AWS_REGION>:<YOUR_AWS_ACCOUNT_ID>:bucket/<YOUR_BUCKET_NAME> \
  --namespace <YOUR_NAMESPACE> \
  --region <YOUR_AWS_REGION>
```

You should see `film_permits` in the output. (If not, give Tiger Cloud another minute or two to complete the first sync.)

**Register the table in Snowflake:**

```sql
CREATE ICEBERG TABLE tiger_data.<YOUR_NAMESPACE>.film_permits
  CATALOG = 'tiger_s3tables_catalog'
  CATALOG_TABLE_NAME = 'film_permits'
  AUTO_REFRESH = TRUE;
```

`AUTO_REFRESH = TRUE` tells Snowflake to periodically check for new data — combined with the `REFRESH_INTERVAL_SECONDS = 120` from Step 3, fresh inserts in Tiger Cloud will be visible in Snowflake within about 2 minutes.

> **Heads up** — When Tiger Cloud syncs *new* tables in the future (e.g. you add another hypertable), you'll need to run `CREATE ICEBERG TABLE` again for each new one. Existing-table updates are automatic; new tables are not.

**Quick sanity check:**

```sql
SELECT COUNT(*) AS total_permits FROM tiger_data.<YOUR_NAMESPACE>.film_permits;
```

You should see something close to 16,864 (depending on when you ran `load.py` and how many new permits NYC has filed since).

```sql
SELECT * FROM tiger_data.<YOUR_NAMESPACE>.film_permits LIMIT 5;
```

You should see five rows of NYC film permit data — the same data you loaded into Tiger Cloud, now readable from Snowflake.

## Step 8 — The payoff: join time-series data with a Snowflake-native table

A `SELECT *` proves the integration works, but it doesn't show *why* this is interesting. The payoff is what you can do *next*: join the time-series data living in Iceberg with reference data that lives natively in Snowflake — no ETL pipeline, no data movement.

**Create a borough population reference table that lives only in Snowflake.** This represents the kind of dimension/lookup data you'd normally have alongside your warehouse:

```sql
CREATE OR REPLACE TABLE tiger_data.public.borough_population (
    borough     STRING,
    population  NUMBER
);

INSERT INTO tiger_data.public.borough_population VALUES
    ('Manhattan',     1694251),
    ('Brooklyn',      2736074),
    ('Queens',        2405464),
    ('Bronx',         1472654),
    ('Staten Island',  495747);
```

> Population data: NYC Department of City Planning, 2020 Census.

**Now the payoff query — permits per 100k residents by borough, 2025:**

```sql
SELECT
    p.borough,
    COUNT(*)                                       AS permits_2025,
    pop.population,
    ROUND(COUNT(*) * 100000.0 / pop.population, 2) AS permits_per_100k
FROM tiger_data.<YOUR_NAMESPACE>.film_permits AS p
JOIN tiger_data.public.borough_population AS pop
    ON p.borough = pop.borough
WHERE YEAR(p.enddatetime) = 2025
GROUP BY p.borough, pop.population
ORDER BY permits_per_100k DESC;
```

You should see something like:

```
BOROUGH        PERMITS_2025  POPULATION  PERMITS_PER_100K
-------------  ------------  ----------  ----------------
Manhattan      ...           1694251     ...
Brooklyn       ...           2736074     ...
Queens         ...           2405464     ...
...
```

That single query reads time-series data from Iceberg (sitting in your AWS account) and joins it with reference data living natively in Snowflake. The query optimizer treats both like normal Snowflake tables — it has no idea one of them is "remote." No pipelines were harmed in the making of this query.

A few more queries you can try (also in `snowflake-payoff.sql`):

**Permits per borough in the last 90 days:**

```sql
SELECT borough, COUNT(*) AS permits
FROM tiger_data.<YOUR_NAMESPACE>.film_permits
WHERE enddatetime >= DATEADD(day, -90, CURRENT_TIMESTAMP())
GROUP BY borough
ORDER BY permits DESC;
```

**Monthly trend by category, last 12 months:**

```sql
SELECT
    DATE_TRUNC('month', enddatetime) AS month,
    category,
    COUNT(*)                          AS permits
FROM tiger_data.<YOUR_NAMESPACE>.film_permits
WHERE enddatetime >= DATEADD(month, -12, CURRENT_TIMESTAMP())
  AND category IS NOT NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

That's the end of the core walkthrough. From here, anything you can express in Snowflake SQL works — including BI tool connectors, scheduled tasks, and joins to other Snowflake databases.

## Going Further

The walkthrough above covers the core pattern. This section collects extras for when you want to go deeper.

### Force a metadata refresh

If you've inserted new rows in Tiger Cloud and don't want to wait the full 120 seconds for the auto-refresh:

```sql
ALTER CATALOG INTEGRATION tiger_s3tables_catalog REFRESH;
```

### Add another hypertable to the sync

Any table you create in Tiger Cloud with `create_hypertable(...)` is eligible for the Iceberg sync. After Tiger Cloud's connector picks it up (usually within a few minutes), register it in Snowflake:

```sql
CREATE ICEBERG TABLE tiger_data.<YOUR_NAMESPACE>.<NEW_TABLE_NAME>
  CATALOG = 'tiger_s3tables_catalog'
  CATALOG_TABLE_NAME = '<NEW_TABLE_NAME>'
  AUTO_REFRESH = TRUE;
```

### Restrict access to a single table

The Lake Formation grant in Step 5 used `TableWildcard` to grant access to every table in the namespace. To grant access to one specific table only:

```bash
aws lakeformation grant-permissions \
  --region <YOUR_AWS_REGION> \
  --principal DataLakePrincipalIdentifier=arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-s3tables-reader \
  --resource '{
    "Table": {
      "CatalogId": "<YOUR_AWS_ACCOUNT_ID>:s3tablescatalog/<YOUR_BUCKET_NAME>",
      "DatabaseName": "<YOUR_NAMESPACE>",
      "Name": "film_permits"
    }
  }' \
  --permissions "SELECT" "DESCRIBE"
```

### Create a Snowflake view for cleaner downstream usage

Hide the namespace and let downstream consumers query a stable view name:

```sql
CREATE OR REPLACE VIEW tiger_data.public.v_film_permits AS
SELECT * FROM tiger_data.<YOUR_NAMESPACE>.film_permits;
```

## Current Limitations

Things to be aware of when using this integration:

- **Read-only from Snowflake.** Snowflake can `SELECT` but cannot `INSERT`, `UPDATE`, or `DELETE`. All writes happen through Tiger Cloud.
- **New tables are not auto-registered.** When Tiger Cloud syncs a brand-new table, you have to manually `CREATE ICEBERG TABLE` for it in Snowflake. Existing-table updates are automatic.
- **Cross-region transfer fees apply** if your Tiger Cloud region and S3 Table Bucket region don't match.
- **Schema changes have a propagation delay.** Adding columns in Tiger Cloud may take a few minutes (and a `REFRESH`) to appear in Snowflake.
- **`ACCOUNTADMIN` is required** to create the Catalog Integration. If you don't have it on your primary Snowflake account, use a free trial.

## Tearing it down

When you're done with the tutorial and want to stop incurring charges:

**1. Drop the Snowflake objects:**

```sql
DROP ICEBERG TABLE IF EXISTS tiger_data.<YOUR_NAMESPACE>.film_permits;
DROP TABLE IF EXISTS tiger_data.public.borough_population;
DROP SCHEMA IF EXISTS tiger_data.<YOUR_NAMESPACE>;
DROP DATABASE IF EXISTS tiger_data;
DROP CATALOG INTEGRATION IF EXISTS tiger_s3tables_catalog;
```

**2. Disable the Tiger Cloud connector:**

In the Tiger Cloud Console → your service → Connectors → click the Iceberg connector and choose `Disable` (or `Delete`).

**3. Delete the AWS resources:**

```bash
aws iam delete-role-policy --role-name snowflake-s3tables-reader --policy-name snowflake-s3tables-access
aws iam delete-role --role-name snowflake-s3tables-reader
```

Then in the AWS Console → CloudFormation → select your stack → `Delete`. This removes the S3 Table Bucket, the Tiger Cloud IAM role, and all stored data.

**4. Optional — pause or delete your Tiger Cloud service** in the Tiger Cloud Console.

## What's Next

You've built a one-way analytical bridge from Tiger Cloud to Snowflake. Some directions to explore:

- **Connect a BI tool to the Iceberg table** — Tableau, Looker, Hex, or Mode can all hit Snowflake. The Iceberg table looks like any other Snowflake table to them, so dashboards work out of the box.
- **Add a streaming source to Tiger Cloud** — wire up Kafka or AWS Lambda to push real-time events into the same hypertable, then watch them propagate to Snowflake within ~2 minutes. See the [Tiger Cloud streaming integrations](https://www.tigerdata.com/docs/integrate/data-engineering-etl).
- **Try the Iceberg table from another engine** — the same files can be read by [Athena](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg.html), Spark, Trino, or DuckDB. No additional setup on the Tiger Cloud side.
- **Extend the dataset** — NYC Open Data has [hundreds of datasets](https://opendata.cityofnewyork.us/data/) with timestamp columns. Try loading [311 Service Requests](https://data.cityofnewyork.us/Social-Services/311-Service-Requests-from-2010-to-Present/erm2-nwe9) and joining filming permits with noise complaints by neighborhood.
- **Build a continuous aggregate in Tiger Cloud** — pre-compute daily permit counts per borough as a [continuous aggregate](https://www.tigerdata.com/docs/use-timescale/continuous-aggregates) and add *that* to the sync. You get cheap interactive queries in Snowflake on top of pre-aggregated data.

## Resources

- [NYC Film Permits dataset](https://data.cityofnewyork.us/City-Government/Film-Permits/tg4x-b46p) — the data used in this tutorial
- [Tiger Lake docs](https://www.tigerdata.com/docs/integrate/connectors/destination/tigerlake) — official Iceberg connector documentation
- [Apache Iceberg](https://iceberg.apache.org/) — the open table format
- [Snowflake Catalog Integration docs](https://docs.snowflake.com/en/sql-reference/sql/create-catalog-integration-rest) — the Snowflake-side reference
- [AWS S3 Tables](https://aws.amazon.com/s3/features/tables/) — the underlying storage
- [Tiger Cloud free trial](https://console.cloud.tigerdata.com) — sign up if you don't have an account
- [Snowflake free trial](https://signup.snowflake.com/) — sign up to get `ACCOUNTADMIN` access for testing

## Troubleshooting

| Error | Fix |
|---|---|
| `sts:AssumeRole not authorized` | The `API_AWS_IAM_USER_ARN` or `API_AWS_EXTERNAL_ID` in the IAM role trust policy is incorrect or stale. Re-run Steps 3 and 4a with fresh values from `DESC INTEGRATION`. |
| `glue:GetCatalog not authorized` | Snowflake role is missing Glue permissions. Re-run Step 4b. |
| `Unable to retrieve credentials from Lake Formation` | Snowflake role is missing `lakeformation:GetDataAccess`. Re-run Step 4b. |
| `Insufficient Lake Formation permission on table` | Lake Formation grant missing. Re-run Step 5. |
| `Unmatched catalog api type PUBLIC and authentication type SIGV4` | `CATALOG_API_TYPE = AWS_GLUE` is missing from `REST_CONFIG`. Re-run Step 3. |
| Table not visible after `list-tables` | Tiger Cloud sync hasn't completed a full cycle yet. Check connector status in Tiger Cloud Console. |
| Stale data in Snowflake | Run `ALTER CATALOG INTEGRATION tiger_s3tables_catalog REFRESH;` to force a metadata refresh. |
| Tiger Cloud write path failing | The Tiger Cloud IAM role should never be modified. The Snowflake role (`snowflake-s3tables-reader`) is completely separate — confirm you haven't accidentally edited the Tiger Cloud role. |
| `psql: command not found` | Install `libpq` (macOS: `brew install libpq && brew link --force libpq`). On Linux, install `postgresql-client`. |
| `load.py` fails with `ModuleNotFoundError` | You forgot `pip install -r requirements.txt`. |
| `load.py` errors with rate-limit | Get a free Socrata app token at [data.cityofnewyork.us/profile/app_tokens](https://data.cityofnewyork.us/profile/app_tokens) and add it to `.env` as `NYC_APP_TOKEN`. |
