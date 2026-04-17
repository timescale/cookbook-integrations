-- ============================================================================
-- Tiger-to-Snowflake Tutorial — One-command setup
--
-- What this does:
--   1. Enables the TimescaleDB extension
--   2. Creates the film_permits hypertable
--   3. Inserts 12 real rows of NYC Film Permits sample data
--   4. Adds a couple of indexes for common queries
--
-- Dataset:
--   NYC Film Permits — Mayor's Office of Media and Entertainment (MOME)
--   Source: https://data.cityofnewyork.us/City-Government/Film-Permits/tg4x-b46p
--   License: NYC Open Data Terms of Use (public domain)
--
-- Usage:
--   psql "$TIGER_SERVICE_URL" -f setup.sql
-- ============================================================================

-- 1. Extensions
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- 2. Table
-- Note: enddatetime is the time column. The source dataset's startdatetime
-- field is mostly null in recent records, so enddatetime (the scheduled
-- wrap time of the filming activity) is the reliably-populated time dimension.
CREATE TABLE IF NOT EXISTS film_permits (
    eventid           BIGINT       NOT NULL,
    enddatetime       TIMESTAMPTZ  NOT NULL,
    startdatetime     TIMESTAMPTZ,
    enteredon         TIMESTAMPTZ,
    eventtype         TEXT,
    eventagency       TEXT,
    parkingheld       TEXT,
    borough           TEXT,
    communityboard_s  TEXT,
    policeprecinct_s  TEXT,
    category          TEXT,
    subcategoryname   TEXT,
    country           TEXT,
    zipcode_s         TEXT,
    PRIMARY KEY (eventid, enddatetime)
);

SELECT create_hypertable(
    'film_permits',
    'enddatetime',
    chunk_time_interval => INTERVAL '1 month',
    if_not_exists       => TRUE
);

-- 3. Sample data (12 real rows, fetched from the NYC Open Data API)
INSERT INTO film_permits (
    eventid, enddatetime, enteredon, eventtype, eventagency,
    parkingheld, borough, communityboard_s, policeprecinct_s,
    category, subcategoryname, country, zipcode_s
) VALUES
    (906519, '2025-12-21 14:00:00+00', '2025-12-19 11:28:03+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'BROADWAY between WEST 190 STREET and WEST 193 STREET',
     'Manhattan', '12,', '34,', 'Film', 'Short', 'United States of America', '10040,'),

    (903701, '2025-12-14 20:00:00+00', '2025-12-03 14:53:07+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'WEST 24 STREET between 7 AVENUE and 8 AVENUE',
     'Manhattan', '4,', '10,', 'Film', 'Feature', 'United States of America', '10011,'),

    (904687, '2025-12-11 20:00:00+00', '2025-12-08 15:26:10+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'ST ANN''S AVENUE between EAST 143 STREET and EAST 144 STREET',
     'Bronx', '1,', '40,', 'Television', 'Cable-episodic', 'United States of America', '10454,'),

    (903540, '2025-12-06 03:00:00+00', '2025-12-02 20:44:49+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'DRIGGS AVENUE between SOUTH 4 STREET and SOUTH 5 STREET',
     'Brooklyn', '1,', '90,', 'Television', 'Episodic series', 'United States of America', '11211,'),

    (902176, '2025-12-05 01:00:00+00', '2025-11-24 13:49:50+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'JUNO STREET between 70 AVENUE and 71 AVENUE',
     'Queens', '6,', '112,', 'Television', 'Episodic series', 'United States of America', '11375,'),

    (903194, '2025-12-04 01:00:00+00', '2025-12-01 15:57:13+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'HUGHES AVENUE between EAST 187 STREET and EAST 188 STREET',
     'Bronx', '6,', '48,', 'WEB', 'Not Applicable', 'United States of America', '10458,'),

    (899746, '2025-12-03 04:00:00+00', '2025-11-13 11:57:08+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'CHERRY STREET between PIKE SLIP and FRANK T MODICA WAY',
     'Manhattan', '3,', '7,', 'Film', 'Feature', 'United States of America', '10002,'),

    (899742, '2025-12-02 04:00:00+00', '2025-11-13 11:50:26+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'CHERRY STREET between FRANK T MODICA WAY and PIKE SLIP',
     'Manhattan', '3,', '7,', 'Film', 'Feature', 'United States of America', '10002,'),

    (894297, '2025-10-11 02:30:00+00', '2025-10-08 06:14:00+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     'WATER STREET between PECK SLIP and DOVER STREET',
     'Manhattan', '1, 2, 3,', '1, 5,', 'Television', 'Episodic series', 'United States of America', '10002, 10012, 10013, 10038,'),

    (888142, '2025-09-13 04:00:00+00', '2025-09-05 20:00:47+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     '5 AVENUE between EAST 91 STREET and EAST 94 STREET',
     'Manhattan', '11, 64, 8,', '19, 22, 23,', 'Television', 'Cable-episodic', 'United States of America', '10029, 10128,'),

    (878555, '2025-08-01 03:00:00+00', '2025-07-24 08:21:04+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     '5 AVENUE between EAST 90 STREET and EAST 94 STREET',
     'Manhattan', '5, 64, 8,', '18, 19, 22,', 'Television', 'Cable-episodic', 'United States of America', '10019, 10022, 10128,'),

    (823837, '2024-12-10 01:00:00+00', '2024-12-05 16:35:04+00', 'Shooting Permit', 'Mayor''s Office of Film, Theatre & Broadcasting',
     '54 ROAD between 43 STREET and 46 STREET',
     'Brooklyn', '2, 6,', '108, 76,', 'Television', 'Episodic series', 'United States of America', '11201, 11378,')
ON CONFLICT (eventid, enddatetime) DO NOTHING;

-- 4. Indexes
CREATE INDEX IF NOT EXISTS idx_film_permits_borough     ON film_permits (borough, enddatetime DESC);
CREATE INDEX IF NOT EXISTS idx_film_permits_category    ON film_permits (category, enddatetime DESC);

-- Verify
SELECT
    COUNT(*)              AS total_rows,
    MIN(enddatetime)      AS earliest,
    MAX(enddatetime)      AS latest,
    COUNT(DISTINCT borough) AS boroughs
FROM film_permits;
