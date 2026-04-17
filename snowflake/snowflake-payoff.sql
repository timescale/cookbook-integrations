-- ============================================================================
-- Snowflake payoff queries — run these after Step 8 of the README.
--
-- These demonstrate the *point* of the integration: time-series data living
-- in Tiger Cloud (synced to Iceberg) joined with reference data living
-- natively in Snowflake. Replace <YOUR_NAMESPACE> with the namespace from
-- the README's "Find your namespace" section.
-- ============================================================================

-- 1. Reference table that lives only in Snowflake.
--    Population data: NYC Department of City Planning, 2020 Census.
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

-- 2. Sanity check — confirm the Iceberg table is queryable from Snowflake.
SELECT COUNT(*) AS total_permits
FROM tiger_data.<YOUR_NAMESPACE>.film_permits;

-- 3. Permits per borough, last 90 days.
SELECT
    borough,
    COUNT(*) AS permits
FROM tiger_data.<YOUR_NAMESPACE>.film_permits
WHERE enddatetime >= DATEADD(day, -90, CURRENT_TIMESTAMP())
GROUP BY borough
ORDER BY permits DESC;

-- 4. The payoff: permits per 100k residents by borough, 2025 only.
--    Joins time-series film data (Iceberg) with reference population (Snowflake-native).
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

-- 5. Monthly trend by category, last 12 months.
SELECT
    DATE_TRUNC('month', enddatetime) AS month,
    category,
    COUNT(*)                          AS permits
FROM tiger_data.<YOUR_NAMESPACE>.film_permits
WHERE enddatetime >= DATEADD(month, -12, CURRENT_TIMESTAMP())
  AND category IS NOT NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
