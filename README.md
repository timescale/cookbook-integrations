# Tiger Data Integrations Cookbook

A collection of cookbooks, tutorials, and reference implementations showcasing how to integrate **Tiger Data** and **PostgreSQL** with the tools, frameworks, and services you already use.

## What's Inside

Each folder contains a self-contained cookbook focused on a specific integration, complete with working code, setup instructions, and explanations of when and why you'd reach for that integration.

| Cookbook | Description |
|---------|-------------|
| [Query Tiger Cloud data from Snowflake](./snowflake/) | Use the Tiger Lake Iceberg connector to make a Tiger Cloud hypertable queryable from Snowflake — and join it with Snowflake-native reference data. Walks through the NYC Film Permits dataset end-to-end. |

## Who This Is For

- Developers connecting Tiger Data or PostgreSQL to external tools, frameworks, or services
- Teams evaluating which integration fits their stack
- Anyone curious about what's possible when you plug Tiger Data into the rest of your toolchain

## Prerequisites

Before diving into any cookbook, make sure you have the following:

- **PostgreSQL 17 or 18** — via [Tiger Cloud](https://console.cloud.timescale.com), [Docker](https://github.com/timescale/timescaledb-docker-ha), or a [local install](https://www.postgresql.org/download/)
- **Docker** — required for local development without a manual PostgreSQL install. Get it at [docker.com/get-started](https://www.docker.com/get-started/)
- **Tiger CLI** *(optional)* — manage Tiger Cloud services from the terminal or integrate with AI assistants via [Tiger MCP](https://www.tigerdata.com/docs/get-started/quickstart/mcp-cli). Install with `brew install --cask timescale/tap/tiger-cli` (macOS) or see the [CLI docs](https://www.tigerdata.com/docs/get-started/quickstart/cli-rest-api)
- **Python 3.9+** — [python.org/downloads](https://www.python.org/downloads/) *(if the cookbook uses Python)*
- **A Python package manager** — we use [uv](https://docs.astral.sh/uv/) in the tutorials, but [pip](https://pip.pypa.io/) and [conda](https://docs.conda.io/) work too
- **API keys for the integration you're exploring** — each cookbook's README lists what it needs

## Getting Started

1. **Clone this repository**

   ```bash
   git clone https://github.com/timescale/cookbook-integrations.git
   cd cookbook-integrations
   ```

2. **Set up your environment variables**

   Each cookbook folder has its own `.env.example` file. Copy it and add your keys:

   ```bash
   cd <cookbook-folder>
   cp .env.example .env
   ```

   Open `.env` and replace the placeholders with your actual values.

3. **Pick a cookbook and follow the tutorial**

   Each cookbook folder has its own README with step-by-step instructions.

## Contributing

Have an integration you'd like to add? Open a PR! Each cookbook should include:

- A `README.md` with a step-by-step tutorial explaining the integration
- Example code demonstrating the integration end-to-end
- Sample data or a script to generate it, if applicable
- A `requirements.txt` (or equivalent) if any dependencies are needed
- A `.env.example` template for any required credentials

## License

This repository is licensed under the [Apache License 2.0](./LICENSE).
