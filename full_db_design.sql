-- =====================================================================
-- Bench Match — Complete Database Design (skill-matching + workflow scope)
-- =====================================================================
--
-- This is the full design arrived at through discussion, not a partial
-- or "just skill matching" version like the earlier schema. It covers:
--   1. Reference/rules tables       — how we classify skills (admin-owned)
--   2. Supply side                  — bench employees
--   3. Demand side                  — client/internal requisitions
--   4. Matching engine output       — the actual candidate proposals
--   5. Reviewer workflow            — decisions, history, identity
--   6. Refresh/import audit         — traceability of periodic Excel loads
--
-- CORE PRINCIPLE running through this whole design (this is the part
-- that matters more than any single column): every table is either
--   (a) RE-DERIVABLE  — fully rebuilt from the source Excel on every
--       refresh, safe to overwrite wholesale, never holds anything a
--       human typed in, or
--   (b) PERSISTENT    — written only by a human/reviewer action, a
--       refresh job must NEVER write to these tables.
-- Each table below is labelled with which one it is. This split is what
-- lets us treat the source Excel exports as an external, not-owned,
-- periodically-refreshed feed (an anti-corruption layer) without ever
-- losing reviewer work when a new export lands.
--
-- Scope note: band/location matching logic and full scoring/tiering
-- math still live in the Python engine (build_matches.py), not SQL —
-- this schema stores the inputs and outputs of that logic, it doesn't
-- reimplement it.
--
-- Design already reflects decisions made but not yet implemented in
-- the Python engine (cross-persona matching removed; REST/RESTful API
-- no longer tracked as a separate named accessory; MAS Mapping is a
-- validation flag, not a filter; Additional Request is a surfaced,
-- never-auto-parsed field). This file is a design deliverable only —
-- engine.py / build_matches.py / classify_inputs.py are unchanged.
--
-- IMPLEMENTATION NOTE (2026-10-06): the real Java/Spring app's Flyway
-- migrations have moved two tables below slightly past what this design
-- file originally specified, once the Review feature's web UI started
-- exercising them for real. Both changes are additive (new columns/
-- widened CHECK constraints, nothing removed or renamed) and are called
-- out inline at the relevant CREATE TABLE below rather than leaving the
-- real migration files (V11__override_decision_status.sql,
-- V12__flagged_for_hiring_column.sql) as the only record of them.
-- =====================================================================


-- =====================================================================
-- 0. IDENTITY
-- =====================================================================
-- PERSISTENT. Needed as soon as any table wants a real "who did this"
-- reference instead of a free-text name. Kept deliberately small —
-- this is not a full auth system, just enough to FK against.

CREATE TABLE users (
    user_id      SERIAL PRIMARY KEY,
    display_name TEXT NOT NULL,
    email        TEXT UNIQUE,
    role         TEXT NOT NULL DEFAULT 'reviewer',   -- reviewer / admin / etc.
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =====================================================================
-- 1. REFERENCE / RULES  (skill-cluster classification)
-- =====================================================================
-- PERSISTENT, but admin-maintained rather than reviewer-maintained —
-- a refresh of the AFD-Supply/Demand Excel never touches these. They
-- change only when the business's skill taxonomy itself changes.

CREATE TABLE personas (
    persona_id   SERIAL PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE          -- e.g. 'Fullstack Java', 'Frontend'
);

CREATE TABLE sub_personas (
    sub_persona_id SERIAL PRIMARY KEY,
    persona_id     INTEGER NOT NULL REFERENCES personas(persona_id),
    name           TEXT NOT NULL,              -- e.g. 'React', 'Angular', 'iOS'
    UNIQUE (persona_id, name)
);

-- Exact-match lookup used on the SUPPLY side: a literal skill-cluster
-- string maps to exactly one persona/sub-persona/anchor/accessory set.
-- One row per known supply Skill Cluster value (mirrors engine.py's
-- SUPPLY_TABLE dict).
CREATE TABLE skill_cluster_rules (
    rule_id            SERIAL PRIMARY KEY,
    skill_cluster_text TEXT NOT NULL UNIQUE,    -- raw literal text, e.g. 'Java,React.js,Spring Boot'
    persona_id         INTEGER NOT NULL REFERENCES personas(persona_id),
    sub_persona_id     INTEGER REFERENCES sub_personas(sub_persona_id),
    anchor_skill       TEXT NOT NULL,
    named_accessories  TEXT[] NOT NULL DEFAULT '{}'   -- REST intentionally never appears here (implied by Spring/Spring Boot)
);

-- Token vocabulary used to classify DEMAND free-text (the demand side
-- has no clean literal string to look up — it has to be parsed).
CREATE TABLE skill_tokens (
    token_id   SERIAL PRIMARY KEY,
    category   TEXT NOT NULL,     -- e.g. 'JAVA_TOKENS', 'REACT_TOKENS', 'OUT_OF_SCOPE_TOKENS'
    token_text TEXT NOT NULL,
    UNIQUE (category, token_text)
);


-- Added 2026-10-01 (V7__mas_mapping_categories.sql). Which "MAS Mapping" categories (Full Stack,
-- Front End, Tpm, Testing, Polyglot, Devops & Sre, Integration, Mainframe, Architects & Emerging)
-- are in active Phase 1 scope — for BOTH supply and demand. Replaces the old hardcoded
-- `Engine.PHASE1_MAS_MAPPING = List.of("Full Stack", "Front End")` Java literal (and the
-- equivalent Python PHASE1_MAS_MAPPING constant, now sourced from the CLI's own
-- mas_mapping_categories.json — kept in sync with this table's seed data by hand, since the CLI
-- has no database) with a real, editable data source: flip a category's status to flip it into
-- scope, no code change needed. Found and decided after a real bug: Demand.xlsx widened to
-- include non-engineering MAS Mapping values, and 32 "Java,Microservices,React.js" rows tagged
-- MAS Mapping='Tpm' (Technical Project Management, not an engineering role) were silently being
-- classified Fullstack Java purely from skill-cluster text.
--
-- IMPORTANT: activating a category here is necessary but NOT sufficient — it only stops the gate
-- from excluding that category's rows; it does not create a persona, matching rules, or an
-- eligible supply pool for it. See V7__mas_mapping_categories.sql's full comment and
-- demand-supply-mapping-requirements.md's "MAS Mapping scoping" section before flipping anything.
CREATE TABLE mas_mapping_categories (
    category TEXT PRIMARY KEY,
    status   TEXT NOT NULL CHECK (status IN ('active', 'inactive')),
    note     TEXT
);


-- =====================================================================
-- 2. SUPPLY SIDE
-- =====================================================================

-- RE-DERIVABLE. One row per bench employee. Fully truncated/upserted
-- on every AFD-Supply.xlsx refresh — nothing here survives a refresh
-- on its own merit; anything worth keeping goes in supply_overrides.
CREATE TABLE supply_enriched (
    employee_id         BIGINT PRIMARY KEY,      -- Employee Code from source
    employee_name        TEXT NOT NULL,
    band                 TEXT,
    location              TEXT,
    capability            TEXT,                  -- e.g. 'MAS'
    afd_status            TEXT,                  -- Available for Deployment / Blocked-Proposed / etc.
    skill_cluster_raw     TEXT,                  -- literal source text, e.g. 'Java,React.js,Spring Boot'

    persona_id            INTEGER REFERENCES personas(persona_id),
    sub_persona_id        INTEGER REFERENCES sub_personas(sub_persona_id),
    named_accessories     TEXT[] NOT NULL DEFAULT '{}',
    classification_status TEXT NOT NULL DEFAULT 'classified',  -- classified / unclassified / data_issue

    -- hash covers ONLY classification-relevant source columns
    -- (skill_cluster_raw, capability) — deliberately EXCLUDES afd_status,
    -- band, location, which churn constantly as staffing moves and would
    -- make the hash (and needs_reattention downstream) useless noise.
    source_row_hash       TEXT,
    last_refreshed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- PERSISTENT. Recruiter/reviewer corrections and constraints not
-- present in the source export at all. Never written to by a refresh.
CREATE TABLE supply_overrides (
    override_id   SERIAL PRIMARY KEY,
    employee_id   BIGINT NOT NULL REFERENCES supply_enriched(employee_id),
    override_type TEXT NOT NULL,     -- skill_add / skill_remove / constraint / note
    value_text    TEXT NOT NULL,
    added_by      INTEGER REFERENCES users(user_id),
    added_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =====================================================================
-- 3. DEMAND SIDE
-- =====================================================================

-- RE-DERIVABLE. One row per demand/requisition, keyed by the source
-- Job Requisition ID (kept as TEXT — ~3% of real IDs are alphanumeric,
-- e.g. 'HCL/DBS/2026/2820615', not purely numeric). Fully
-- upserted on every Demand.xlsx refresh.
CREATE TABLE demand_enriched (
    demand_id               TEXT PRIMARY KEY,     -- Job Requisition ID, as-is from source
    cluster_name_raw         TEXT,                 -- free-text demand ask, as typed by the requesting team
    final_skill_cluster_raw  TEXT,                 -- 'Final Skill Cluster' column, kept verbatim, informational only
    mas_mapping_raw           TEXT,                -- 'MAS Mapping' column, kept verbatim, NEVER used to filter/match
    additional_request_raw    TEXT,                -- 'Additional Request' column, surfaced to reviewer, NEVER auto-parsed
    location                  TEXT,
    band                      TEXT,

    persona_id                INTEGER REFERENCES personas(persona_id),
    sub_persona_id             INTEGER REFERENCES sub_personas(sub_persona_id),
    named_accessories          TEXT[] NOT NULL DEFAULT '{}',
    classification_status      TEXT NOT NULL DEFAULT 'classified',  -- classified / unclassified / data_issue

    -- true when mas_mapping_raw disagrees with the engine-derived persona
    -- (a validation signal for the reviewer, per Task #3 — matching logic
    -- itself never reads mas_mapping_raw)
    mas_mapping_mismatch_flag BOOLEAN NOT NULL DEFAULT FALSE,

    source_row_hash            TEXT,
    last_refreshed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- set when a demand_id that previously appeared stops appearing in
    -- an export (closed requisition, or simply dropped from the export).
    -- Never hard-deleted, so review state/decisions tied to it survive.
    is_active                  BOOLEAN NOT NULL DEFAULT TRUE,
    inactive_since              TIMESTAMPTZ
);

-- PERSISTENT. One row per demand — the reviewer's overall handling of
-- that requisition. Never written to by a refresh, EXCEPT that a
-- refresh may flip needs_reattention to TRUE when it detects the
-- underlying source changed under an open review (see hash comparison
-- logic below the schema). needs_reattention/reattention_reason are
-- reserved for that refresh-triggered signal specifically and nothing
-- else writes to them.
--
-- flagged_for_hiring/flagged_for_hiring_reason/_by/_at (added by
-- V12__flagged_for_hiring_column.sql, 2026-10-06) is a DIFFERENT, manual
-- signal: the Review web app's "Flag for hiring" action on an EXHAUSTED
-- demand (every Strong/Good candidate already Proposed/Rejected, but
-- positions remain open) — a reviewer saying "the engine has nothing
-- left to offer here, HR should open a requisition." An early build of
-- that feature repurposed needs_reattention/reattention_reason for this
-- instead of adding new columns, since the two looked like the same
-- "needs a human to look again" shape — but they're genuinely different
-- events (automated/refresh vs. manual/reviewer-initiated) with no
-- reason to share state, so they were split back apart before the
-- refresh-triggered side was ever built, to avoid the two colliding.
CREATE TABLE demand_review_state (
    demand_id          TEXT PRIMARY KEY REFERENCES demand_enriched(demand_id),
    status              TEXT NOT NULL DEFAULT 'open',   -- open / in_progress / closed / on_hold
    assigned_reviewer   INTEGER REFERENCES users(user_id),
    notes                TEXT,
    needs_reattention    BOOLEAN NOT NULL DEFAULT FALSE,
    reattention_reason   TEXT,       -- e.g. 'source text changed since last review'

    -- Added by V12__flagged_for_hiring_column.sql — see this table's own comment above.
    flagged_for_hiring        BOOLEAN NOT NULL DEFAULT FALSE,
    flagged_for_hiring_reason TEXT,
    flagged_for_hiring_by     INTEGER REFERENCES users(user_id),
    flagged_for_hiring_at     TIMESTAMPTZ,

    closed_by            INTEGER REFERENCES users(user_id),
    closed_at            TIMESTAMPTZ
);

-- PERSISTENT. Many rows per demand — one per (demand, employee) pair a
-- reviewer has actually acted on. This is NOT the same as the engine's
-- proposed candidate list (that's match_candidates, below) — it's the
-- subset a human has looked at and made a call on.
--
-- status/engine_tier_at_decision widened by V11__override_decision_status.sql
-- (2026-10-06) to add the Review interaction model's "Override" action:
-- status additionally allows 'overridden', and engine_tier_at_decision
-- additionally allows 'Excluded' — the engine tier Override is always
-- exercised against (a candidate excluded ONLY for being exactly one
-- sub-band below the demand's ask; see demand-supply-mapping-
-- requirements.md's "Review interaction model" and MatchingService.
-- isOneBandBelow() in the Java app). Override is deliberately a separate
-- status value from 'approved', not an alias for it, so it's never
-- mistaken for an ordinary Propose.
CREATE TABLE demand_candidate_decisions (
    decision_id           SERIAL PRIMARY KEY,
    demand_id             TEXT NOT NULL REFERENCES demand_enriched(demand_id),
    employee_id           BIGINT NOT NULL REFERENCES supply_enriched(employee_id),
    engine_tier_at_decision TEXT,     -- Strong / Good / Weak / Excluded, snapshot at decision time
    status                  TEXT NOT NULL DEFAULT 'pending',  -- pending / approved / rejected / staffed / overridden
    notes                    TEXT,
    decided_by               INTEGER REFERENCES users(user_id),
    decided_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (demand_id, employee_id)
);

-- PERSISTENT. Full audit trail of status changes on a decision, so
-- "approved then rejected then approved again" isn't lost to
-- last-write-wins. Written alongside every UPDATE to
-- demand_candidate_decisions.status, never by a refresh.
-- old_status/new_status widened alongside demand_candidate_decisions.status
-- above (same migration, same 'overridden' addition).
CREATE TABLE decision_history (
    history_id   SERIAL PRIMARY KEY,
    decision_id  INTEGER NOT NULL REFERENCES demand_candidate_decisions(decision_id),
    old_status   TEXT,
    new_status   TEXT NOT NULL,
    changed_by   INTEGER REFERENCES users(user_id),
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =====================================================================
-- 4. REFRESH / IMPORT AUDIT
-- =====================================================================
-- PERSISTENT (it's a log, not derived from anything). Records every
-- time a source Excel is loaded or matching is (re)run, so "why did
-- employee X disappear" or "why didn't demand Y update" is answerable
-- after the fact instead of a mystery. Declared before match_candidates
-- since that table references it.
CREATE TABLE refresh_runs (
    run_id          BIGSERIAL PRIMARY KEY,
    source           TEXT NOT NULL,        -- 'supply' / 'demand' / 'matching'
    file_name         TEXT,
    started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at         TIMESTAMPTZ,
    status               TEXT NOT NULL DEFAULT 'running',  -- running / succeeded / failed
    rows_in               INTEGER,
    rows_new               INTEGER,
    rows_changed             INTEGER,
    rows_flagged              INTEGER,     -- e.g. needs_reattention raised, mas_mapping_mismatch raised
    error_message              TEXT
);


-- =====================================================================
-- 5. MATCHING ENGINE OUTPUT
-- =====================================================================
-- RE-DERIVABLE. This is what was previously missing from the design:
-- the actual output of build_matches.py (Strong/Good/Weak/Excluded per
-- employee×demand pair). Fully truncated and rewritten every time
-- matching runs — this is what the web app's UI actually reads, so it
-- doesn't have to recompute scoring live on every page load.
--
-- band_signal stores band_signal()'s ported "below" quality for ANY
-- amount below the ask, unchanged (exact Python parity) — the Java app's
-- Override feature does NOT distinguish "one below" at this layer, to
-- avoid perturbing this port; it recomputes that distinction fresh, at
-- read time, from the raw sub-band values (MatchingService.isOneBandBelow()),
-- never from this column.
CREATE TABLE match_candidates (
    match_id       BIGSERIAL PRIMARY KEY,
    employee_id    BIGINT NOT NULL REFERENCES supply_enriched(employee_id),
    demand_id      TEXT NOT NULL REFERENCES demand_enriched(demand_id),
    overall_tier   TEXT NOT NULL,      -- Strong / Good / Weak / Excluded
    skill_signal   TEXT,               -- e.g. 'exact', 'core_gap', 'named accessory gap'
    band_signal    TEXT,
    location_signal TEXT,
    one_liner       TEXT,              -- the human-readable reasoning string
    run_id           BIGINT REFERENCES refresh_runs(run_id),
    computed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (employee_id, demand_id, run_id)
);


-- =====================================================================
-- 6. OPTIONAL — RAW SOURCE HISTORY (recommended for demand, skip for
--    supply unless staffing-history reporting is explicitly needed)
-- =====================================================================
-- PERSISTENT (it's a log). Not required for #2 (the re-derivable vs.
-- persistent split) to work — that only needs the single rolling
-- source_row_hash already on demand_enriched/supply_enriched. This
-- table is for "what did this demand actually say last Tuesday,"
-- which is a different, optional ask.
CREATE TABLE demand_source_snapshots (
    snapshot_id   BIGSERIAL PRIMARY KEY,
    demand_id     TEXT NOT NULL REFERENCES demand_enriched(demand_id),
    captured_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    raw_values     JSONB NOT NULL      -- the source columns as they appeared in that export
);


-- =====================================================================
-- Indexes worth having from day one (not exhaustive — add more as
-- real query patterns emerge)
-- =====================================================================
CREATE INDEX idx_supply_persona ON supply_enriched(persona_id, sub_persona_id);
CREATE INDEX idx_demand_persona ON demand_enriched(persona_id, sub_persona_id);
CREATE INDEX idx_demand_active ON demand_enriched(is_active);
CREATE INDEX idx_match_candidates_demand ON match_candidates(demand_id, overall_tier);
CREATE INDEX idx_match_candidates_employee ON match_candidates(employee_id, overall_tier);
CREATE INDEX idx_decisions_demand ON demand_candidate_decisions(demand_id);
CREATE INDEX idx_decisions_employee ON demand_candidate_decisions(employee_id);


-- =====================================================================
-- The refresh-safety mechanism this whole design exists to support
-- (implemented in the refresh job, not in SQL — noted here so the
-- schema's intent is legible without re-reading the discussion):
--
-- For each incoming source row (supply or demand):
--   1. Compute new_hash from the classification-relevant columns only.
--   2. Look up the existing row's stored source_row_hash.
--   3. If equal            -> just bump last_refreshed_at.
--   4. If different         -> recompute derived fields normally;
--                              if an open review/decision exists for
--                              this id, set needs_reattention = TRUE
--                              (demand side) with a reason.
--   5. Overwrite source_row_hash with new_hash either way — it is a
--      rolling checkpoint, not a history (that's demand_source_snapshots
--      if you want actual history).
--   6. If an id that existed before is missing from the new export,
--      set is_active = FALSE, inactive_since = now() — never delete,
--      so demand_review_state / demand_candidate_decisions referencing
--      it stay intact.
--
-- Step 4 (needs_reattention) is still NOT implemented in the Java app as
-- of 2026-10-06 — see RefreshService's own "Known gaps" Javadoc. It
-- remains available for this exact purpose; nothing else has claimed it
-- (see demand_review_state's comment above for what was briefly
-- considered and then deliberately kept separate instead).
-- =====================================================================
