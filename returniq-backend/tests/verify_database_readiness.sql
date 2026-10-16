-- ==============================================================================
-- ReturnIQ Reverse Logistics & Quality Intelligence
-- File: tests/verify_database_readiness.sql
-- Description:
--   Consolidated, strictly read-only verification query suite.
--   Inspects PostgreSQL system catalogs (pg_class, pg_proc, pg_views,
--   pg_constraint, pg_attribute, pg_trigger, pg_roles, aclexplode) to verify
--   the database schema state without mutating data or executing DDL/DML.
--
-- Architecture & Safety Guarantees:
--   - 100% READ-ONLY: Contains exclusively SELECT statements and Common Table Expressions.
--   - ZERO MUTATIONS: Zero DDL/DML statements (no CREATE, ALTER, DROP, INSERT,
--     UPDATE, DELETE, TRUNCATE, GRANT, or REVOKE).
--   - TYPE SAFE: All internal catalog types (such as "char") are explicitly cast
--     to text, and message formatting uses FORMAT() to eliminate 42725 operator errors.
--   - OVERLOAD SAFE: All pg_proc and pg_trigger lookups use LATERAL subqueries
--     with LIMIT 1, guaranteeing exactly one row per check.
--   - IDEMPOTENT & SAFE: Can be run repeatedly in Supabase SQL Editor or psql.
--   - ISOLATION COMPLIANT: Does not create temporary tables or mutate session GUCs.
--
-- Scope Boundary:
--   - Verified by this script: Structural presence, exact signatures, return types,
--     security invoker settings, empty search_path, view defect aggregations, trigger
--     enablement, constraint definitions, foreign key delete rules, and stored columns.
--   - Requires Runtime Testing (Separate SQL suites): Concurrency row locking
--     (FOR UPDATE OF ri), atomic rollback of plan headers upon allocation failure,
--     and post-migration alert synchronization.
-- ==============================================================================

WITH check_results AS (

    -- -------------------------------------------------------------------------
    -- 1. CORE TABLES EXISTENCE
    -- -------------------------------------------------------------------------
    SELECT
        '1. Tables'::text AS check_category,
        ('table: public.' || t.relname)::text AS check_name,
        CASE WHEN c.oid IS NOT NULL THEN 'PASS' ELSE 'FAIL' END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN 'Table public.' || t.relname || ' exists.'
            ELSE 'FAIL: Table public.' || t.relname || ' is missing.'
        END::text AS details
    FROM (
        VALUES
            ('suppliers'),
            ('products'),
            ('supplier_batches'),
            ('returned_inventory'),
            ('recovery_plans'),
            ('recovery_allocations'),
            ('supplier_quality_alerts')
    ) AS t(relname)
    LEFT JOIN pg_class c
        ON c.relname = t.relname
       AND c.relkind::text = 'r'
       AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 2. ANALYTICS & RECOVERY PIPELINE VIEWS EXISTENCE
    -- -------------------------------------------------------------------------
    SELECT
        '2. Views'::text AS check_category,
        ('view: public.' || v.relname)::text AS check_name,
        CASE WHEN c.oid IS NOT NULL THEN 'PASS' ELSE 'FAIL' END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN 'View public.' || v.relname || ' exists.'
            ELSE 'FAIL: View public.' || v.relname || ' is missing.'
        END::text AS details
    FROM (
        VALUES
            ('vw_vendor_compliance_and_rtv'),
            ('vw_recovery_pipeline_summary'),
            ('vw_product_demand_and_inventory')
    ) AS v(relname)
    LEFT JOIN pg_class c
        ON c.relname = v.relname
       AND c.relkind::text = 'v'
       AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 3. DEFECT-RATE CALCULATION LOGIC (MIGRATION 00003 CORRECTIVE PATCH)
    -- Verifies that confirmed defects aggregate vendor_eligible_units,
    -- NOT returned_units, resolving the Batch HB-09 defect-rate inflation bug.
    -- Overload-safe: LATERAL lookup with LIMIT 1 targets the exact (uuid) function.
    -- -------------------------------------------------------------------------
    SELECT
        '3. Defect Rate Patch (00003)'::text AS check_category,
        'function: fn_recalculate_batch_quality_alert defect logic'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN p.prosrc ~* 'vendor_eligible_units.*is_confirmed_defect|is_confirmed_defect.*vendor_eligible_units'
             AND NOT (p.prosrc ~* 'sum\s*\(\s*returned_units\s*\).*is_confirmed_defect') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN
                'FAIL: Function public.fn_recalculate_batch_quality_alert(uuid) does not exist.'
            WHEN p.prosrc ~* 'vendor_eligible_units.*is_confirmed_defect|is_confirmed_defect.*vendor_eligible_units'
             AND NOT (p.prosrc ~* 'sum\s*\(\s*returned_units\s*\).*is_confirmed_defect') THEN
                'PASS: Function aggregates vendor_eligible_units for confirmed defects (migration 00003 patch verified).'
            ELSE
                'FAIL: Function still aggregates returned_units for confirmed defects (unpatched migration 00002 logic).'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid, p.prosrc
        FROM pg_proc p
        WHERE p.proname = 'fn_recalculate_batch_quality_alert'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
          AND p.pronargs = 1
          AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid' OR oidvectortypes(p.proargtypes) = 'uuid')
        ORDER BY p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '3. Defect Rate Patch (00003)'::text AS check_category,
        'view: vw_vendor_compliance_and_rtv defect logic'::text AS check_name,
        CASE
            WHEN pv.definition IS NULL THEN 'FAIL'
            WHEN pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*vendor_eligible_units'
             AND NOT (pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*returned_units') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN pv.definition IS NULL THEN
                'FAIL: View public.vw_vendor_compliance_and_rtv does not exist.'
            WHEN pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*vendor_eligible_units'
             AND NOT (pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*returned_units') THEN
                'PASS: View aggregates vendor_eligible_units on confirmed defects.'
            ELSE
                'FAIL: View aggregates returned_units on confirmed defects (unpatched baseline).'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_views pv
        ON pv.schemaname = 'public'
       AND pv.viewname = 'vw_vendor_compliance_and_rtv'

    UNION ALL

    SELECT
        '3. Defect Rate Patch (00003)'::text AS check_category,
        'view: vw_product_demand_and_inventory defect logic'::text AS check_name,
        CASE
            WHEN pv.definition IS NULL THEN 'FAIL'
            WHEN pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*vendor_eligible_units'
             AND NOT (pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*returned_units') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN pv.definition IS NULL THEN
                'FAIL: View public.vw_product_demand_and_inventory does not exist.'
            WHEN pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*vendor_eligible_units'
             AND NOT (pv.definition ~* 'case\s+when.*is_confirmed_defect.*then.*returned_units') THEN
                'PASS: View aggregates vendor_eligible_units on confirmed defects.'
            ELSE
                'FAIL: View aggregates returned_units on confirmed defects (unpatched baseline).'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_views pv
        ON pv.schemaname = 'public'
       AND pv.viewname = 'vw_product_demand_and_inventory'

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 4. TRIGGER FUNCTIONS & ATTACHED ENABLED TRIGGERS
    -- Overload-safe: LATERAL lookup with LIMIT 1 matches exact expected signatures.
    -- -------------------------------------------------------------------------
    SELECT
        '4. Trigger Functions'::text AS check_category,
        ('trigger function: public.' || fn.proname)::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN p.pronargs = 0 AND p.res = 'trigger' THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN
                FORMAT('FAIL: Function public.%s() does not exist.', fn.proname)
            WHEN p.pronargs = 0 AND p.res = 'trigger' THEN
                'PASS: Function exists with signature () RETURNS trigger.'
            ELSE
                FORMAT('FAIL: Function signature or return type mismatch. Found: (%s) RETURNS %s.',
                       COALESCE(p.args, ''), COALESCE(p.res, ''))
        END::text AS details
    FROM (
        VALUES
            ('set_updated_at'),
            ('trg_fn_set_vendor_return_deadline'),
            ('trg_fn_validate_recovery_allocation_limits'),
            ('trg_fn_validate_recovery_plan_reactivation'),
            ('trg_fn_check_supplier_batch_defects')
    ) AS fn(proname)
    LEFT JOIN LATERAL (
        SELECT
            p.oid,
            p.pronargs,
            pg_get_function_identity_arguments(p.oid) AS args,
            pg_get_function_result(p.oid) AS res
        FROM pg_proc p
        WHERE p.proname = fn.proname
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 0 AND pg_get_function_result(p.oid) = 'trigger') DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '4. Trigger Functions'::text AS check_category,
        'decision function: public.fn_evaluate_recovery_options'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN p.pronargs = 1
             AND (p.args ~* 'uuid' OR p.types = 'uuid')
             AND (p.res LIKE 'TABLE(%' OR p.res LIKE '%record%') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN
                'FAIL: Function public.fn_evaluate_recovery_options(uuid) does not exist.'
            WHEN p.pronargs = 1
             AND (p.args ~* 'uuid' OR p.types = 'uuid')
             AND (p.res LIKE 'TABLE(%' OR p.res LIKE '%record%') THEN
                'PASS: Function exists with signature (uuid) returning TABLE / SETOF record.'
            ELSE
                FORMAT('FAIL: Signature mismatch for fn_evaluate_recovery_options. Found: (%s) RETURNS %s.',
                       COALESCE(p.args, ''), COALESCE(p.res, ''))
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT
            p.oid,
            p.pronargs,
            pg_get_function_identity_arguments(p.oid) AS args,
            oidvectortypes(p.proargtypes) AS types,
            pg_get_function_result(p.oid) AS res
        FROM pg_proc p
        WHERE p.proname = 'fn_evaluate_recovery_options'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 1 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid' OR oidvectortypes(p.proargtypes) = 'uuid')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '4. Triggers'::text AS check_category,
        ('trigger: ' || tr.trg_name || ' on ' || tr.tbl_name)::text AS check_name,
        CASE
            WHEN t.oid IS NULL THEN 'FAIL'
            WHEN t.tgenabled NOT IN ('O', 'A') THEN 'FAIL'
            WHEN t.func_name IS DISTINCT FROM tr.expected_fn THEN 'FAIL'
            ELSE 'PASS'
        END::text AS status,
        CASE
            WHEN t.oid IS NULL THEN
                FORMAT('FAIL: Trigger %s on public.%s is missing.', tr.trg_name, tr.tbl_name)
            WHEN t.tgenabled NOT IN ('O', 'A') THEN
                FORMAT('FAIL: Trigger %s exists on public.%s but is DISABLED (tgenabled = ''%s'').',
                       tr.trg_name, tr.tbl_name, t.tgenabled)
            WHEN t.func_name IS DISTINCT FROM tr.expected_fn THEN
                FORMAT('FAIL: Trigger executes unexpected function public.%s (expected %s).',
                       COALESCE(t.func_name, 'none'), tr.expected_fn)
            ELSE
                FORMAT('PASS: Trigger attached to public.%s, enabled, and executes %s().',
                       tr.tbl_name, tr.expected_fn)
        END::text AS details
    FROM (
        VALUES
            ('trg_set_batch_deadline', 'supplier_batches', 'trg_fn_set_vendor_return_deadline'),
            ('trg_validate_recovery_allocation', 'recovery_allocations', 'trg_fn_validate_recovery_allocation_limits'),
            ('trg_validate_recovery_plan_reactivation', 'recovery_plans', 'trg_fn_validate_recovery_plan_reactivation'),
            ('trg_check_batch_defects', 'returned_inventory', 'trg_fn_check_supplier_batch_defects')
    ) AS tr(trg_name, tbl_name, expected_fn)
    LEFT JOIN pg_class cl
        ON cl.relname = tr.tbl_name
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT
            t.oid,
            t.tgenabled::text AS tgenabled,
            p.proname AS func_name
        FROM pg_trigger t
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid = cl.oid
          AND t.tgname = tr.trg_name
          AND NOT t.tgisinternal
        ORDER BY (p.proname = tr.expected_fn) DESC, t.oid ASC
        LIMIT 1
    ) t ON true

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 5. ATOMIC RPC STORED PROCEDURE (MIGRATION 00004)
    -- Overload-safe: LATERAL lookup targets the canonical (uuid, text, jsonb) RPC.
    -- -------------------------------------------------------------------------
    SELECT
        '5. Atomic RPC (00004)'::text AS check_category,
        'rpc: fn_create_recovery_plan_with_allocations existence'::text AS check_name,
        CASE WHEN p.oid IS NOT NULL THEN 'PASS' ELSE 'FAIL' END::text AS status,
        CASE
            WHEN p.oid IS NOT NULL THEN
                'PASS: Stored procedure public.fn_create_recovery_plan_with_allocations exists.'
            ELSE
                'FAIL: Stored procedure public.fn_create_recovery_plan_with_allocations is missing (migration 00004 not applied).'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '5. Atomic RPC (00004)'::text AS check_category,
        'rpc: fn_create_recovery_plan_with_allocations exact signature'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN p.pronargs = 3
             AND p.res = 'jsonb'
             AND (p.args ~* 'uuid.*text.*jsonb' OR p.types = 'uuid, text, jsonb') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL: Function is missing.'
            WHEN p.pronargs = 3
             AND p.res = 'jsonb'
             AND (p.args ~* 'uuid.*text.*jsonb' OR p.types = 'uuid, text, jsonb') THEN
                'PASS: Exact signature matches (uuid, text, jsonb) RETURNS jsonb.'
            ELSE
                FORMAT('FAIL: Signature or return mismatch. Found: (%s) RETURNS %s.',
                       COALESCE(p.args, 'none'), COALESCE(p.res, 'none'))
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT
            p.oid,
            p.pronargs,
            pg_get_function_identity_arguments(p.oid) AS args,
            oidvectortypes(p.proargtypes) AS types,
            pg_get_function_result(p.oid) AS res
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '5. Atomic RPC (00004)'::text AS check_category,
        'rpc: fn_create_recovery_plan_with_allocations security & empty search_path'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN NOT p.prosecdef
             AND EXISTS (
                 SELECT 1
                 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) AS cfg
                 WHERE split_part(cfg, '=', 1) = 'search_path'
                   AND trim(both '"'' ' from split_part(cfg, '=', 2)) = ''
             ) THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN
                'FAIL: Function is missing.'
            WHEN p.prosecdef THEN
                'FAIL: Function is configured with SECURITY DEFINER instead of SECURITY INVOKER.'
            WHEN NOT EXISTS (
                SELECT 1
                FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) AS cfg
                WHERE split_part(cfg, '=', 1) = 'search_path'
                  AND trim(both '"'' ' from split_part(cfg, '=', 2)) = ''
            ) THEN
                FORMAT('FAIL: Function search_path is missing or not set to empty (proconfig: %s).',
                       COALESCE(array_to_string(p.proconfig, ', '), 'NULL'))
            ELSE
                'PASS: Verified SECURITY INVOKER and search_path set strictly to empty string.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid, p.prosecdef, p.proconfig
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 6. RPC EXECUTION PRIVILEGES (MIGRATION 00004)
    -- In PostgreSQL, PUBLIC is a pseudo-role representing all users.
    -- Default function privileges grant EXECUTE to PUBLIC (proacl IS NULL).
    -- REVOKE EXECUTE FROM PUBLIC sets proacl with no grantee = 0 entry.
    -- Roles anon, authenticated, service_role are resolved safely via pg_roles OID.
    -- Overload-safe: Targets canonical (uuid, text, jsonb) stored procedure.
    -- -------------------------------------------------------------------------
    SELECT
        '6. RPC Privileges (00004)'::text AS check_category,
        'privilege: public pseudo-role execute access blocked'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN p.proacl IS NULL THEN 'FAIL'
            WHEN EXISTS (
                SELECT 1
                FROM aclexplode(p.proacl)
                WHERE grantee = 0 AND privilege_type = 'EXECUTE'
            ) THEN 'FAIL'
            ELSE 'PASS'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN
                'FAIL: Function is missing.'
            WHEN p.proacl IS NULL THEN
                'FAIL: proacl is NULL (default PostgreSQL permissions apply; PUBLIC has execute access).'
            WHEN EXISTS (
                SELECT 1
                FROM aclexplode(p.proacl)
                WHERE grantee = 0 AND privilege_type = 'EXECUTE'
            ) THEN
                'FAIL: Explicit EXECUTE permission remains granted to PUBLIC (grantee = 0).'
            ELSE
                'PASS: Public pseudo-role execution is blocked (no grantee = 0 entry in proacl).'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid, p.proacl
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true

    UNION ALL

    SELECT
        '6. RPC Privileges (00004)'::text AS check_category,
        'privilege: anon role execute access blocked'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN r_anon.oid IS NULL THEN 'INCONCLUSIVE'
            WHEN NOT has_function_privilege(r_anon.oid, p.oid, 'execute') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL: Function is missing.'
            WHEN r_anon.oid IS NULL THEN
                'INCONCLUSIVE: Role ''anon'' does not exist in this database environment.'
            WHEN NOT has_function_privilege(r_anon.oid, p.oid, 'execute') THEN
                'PASS: Role ''anon'' cannot execute the function.'
            ELSE
                'FAIL: Role ''anon'' retains execute permission.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true
    LEFT JOIN pg_roles r_anon
        ON r_anon.rolname = 'anon'

    UNION ALL

    SELECT
        '6. RPC Privileges (00004)'::text AS check_category,
        'privilege: authenticated role execute access blocked'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN r_auth.oid IS NULL THEN 'INCONCLUSIVE'
            WHEN NOT has_function_privilege(r_auth.oid, p.oid, 'execute') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL: Function is missing.'
            WHEN r_auth.oid IS NULL THEN
                'INCONCLUSIVE: Role ''authenticated'' does not exist in this database environment.'
            WHEN NOT has_function_privilege(r_auth.oid, p.oid, 'execute') THEN
                'PASS: Role ''authenticated'' cannot execute the function.'
            ELSE
                'FAIL: Role ''authenticated'' retains execute permission.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true
    LEFT JOIN pg_roles r_auth
        ON r_auth.rolname = 'authenticated'

    UNION ALL

    SELECT
        '6. RPC Privileges (00004)'::text AS check_category,
        'privilege: service_role execute access permitted'::text AS check_name,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL'
            WHEN r_serv.oid IS NULL THEN 'INCONCLUSIVE'
            WHEN has_function_privilege(r_serv.oid, p.oid, 'execute') THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN p.oid IS NULL THEN 'FAIL: Function is missing.'
            WHEN r_serv.oid IS NULL THEN
                'INCONCLUSIVE: Role ''service_role'' does not exist in this database environment.'
            WHEN has_function_privilege(r_serv.oid, p.oid, 'execute') THEN
                'PASS: Role ''service_role'' has execute permission.'
            ELSE
                'FAIL: Role ''service_role'' is missing execute permission.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN LATERAL (
        SELECT p.oid
        FROM pg_proc p
        WHERE p.proname = 'fn_create_recovery_plan_with_allocations'
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY (p.pronargs = 3 AND (pg_get_function_identity_arguments(p.oid) ~* 'uuid.*text.*jsonb' OR oidvectortypes(p.proargtypes) = 'uuid, text, jsonb')) DESC, p.oid ASC
        LIMIT 1
    ) p ON true
    LEFT JOIN pg_roles r_serv
        ON r_serv.rolname = 'service_role'

    UNION ALL

    -- -------------------------------------------------------------------------
    -- 7. KEY CONSTRAINTS & STORED GENERATED COLUMNS
    -- Full domain validation matching migration 00002 baseline:
    -- - Plan status: draft, pending_approval, approved, rejected, executed
    -- - Route: restock, refurbish_and_resell, return_to_vendor, liquidation, scrap_recycle
    -- - Channel: cash, supplier_credit, none
    -- - Item grade: Grade A, Grade B, Grade C, Grade D
    -- - Intake status: received, inspected, allocated, completed
    -- -------------------------------------------------------------------------
    SELECT
        '7. Constraints & Columns'::text AS check_category,
        ('check constraint: ' || expected.conname)::text AS check_name,
        CASE
            WHEN c.oid IS NULL THEN 'FAIL'
            WHEN pg_get_constraintdef(c.oid) ~* expected.pattern THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NULL THEN
                FORMAT('FAIL: Constraint %s on public.%s is missing.', expected.conname, expected.relname)
            WHEN pg_get_constraintdef(c.oid) ~* expected.pattern THEN
                FORMAT('PASS: Constraint %s active on public.%s.', expected.conname, expected.relname)
            ELSE
                FORMAT('FAIL: Constraint definition mismatch on %s. Found: %s.',
                       expected.conname, pg_get_constraintdef(c.oid))
        END::text AS details
    FROM (
        VALUES
            ('chk_vendor_units_le_returned', 'returned_inventory', 'vendor_eligible_units\s*<=\s*returned_units')
    ) AS expected(conname, relname, pattern)
    LEFT JOIN pg_class cl
        ON cl.relname = expected.relname
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.conname = expected.conname
          AND c.contype::text = 'c'
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        ('composite unique constraint: ' || expected.conname)::text AS check_name,
        CASE
            WHEN c.oid IS NULL THEN 'FAIL'
            WHEN cardinality(c.conkey) = 2
             AND pg_get_constraintdef(c.oid) ~* 'product_id'
             AND pg_get_constraintdef(c.oid) ~* 'batch_code' THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NULL THEN
                FORMAT('FAIL: Unique constraint %s on public.%s is missing.', expected.conname, expected.relname)
            WHEN cardinality(c.conkey) = 2
             AND pg_get_constraintdef(c.oid) ~* 'product_id'
             AND pg_get_constraintdef(c.oid) ~* 'batch_code' THEN
                FORMAT('PASS: Composite unique constraint %s on (product_id, batch_code) exists on public.%s.',
                       expected.conname, expected.relname)
            ELSE
                FORMAT('FAIL: Constraint exists but definition/columns mismatch on %s. Found: %s.',
                       expected.conname, COALESCE(pg_get_constraintdef(c.oid), 'none'))
        END::text AS details
    FROM (
        VALUES
            ('uq_product_batch', 'supplier_batches')
    ) AS expected(conname, relname)
    LEFT JOIN pg_class cl
        ON cl.relname = expected.relname
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid, c.conkey
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.conname = expected.conname
          AND c.contype::text = 'u'
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        ('single-column unique: ' || expected.relname || '.' || expected.colname)::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                FORMAT('PASS: Unique key constraint active on %s.%s.', expected.relname, expected.colname)
            ELSE
                FORMAT('FAIL: Missing single-column unique constraint on %s.%s.', expected.relname, expected.colname)
        END::text AS details
    FROM (
        VALUES
            ('suppliers', 'code'),
            ('products', 'sku'),
            ('returned_inventory', 'return_tracking_id'),
            ('recovery_plans', 'plan_code')
    ) AS expected(relname, colname)
    LEFT JOIN pg_class cl
        ON cl.relname = expected.relname
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN pg_attribute a
        ON a.attrelid = cl.oid
       AND a.attname = expected.colname
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'u'
          AND c.conkey = ARRAY[a.attnum]
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        'status domain check: recovery_plans'::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                'PASS: Status check constraint enforces all 5 statuses (draft, pending_approval, approved, rejected, executed).'
            ELSE
                'FAIL: Incomplete or missing status check constraint on recovery_plans.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_class cl
        ON cl.relname = 'recovery_plans'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'c'
          AND pg_get_constraintdef(c.oid) ~* '''draft'''
          AND pg_get_constraintdef(c.oid) ~* '''pending_approval'''
          AND pg_get_constraintdef(c.oid) ~* '''approved'''
          AND pg_get_constraintdef(c.oid) ~* '''rejected'''
          AND pg_get_constraintdef(c.oid) ~* '''executed'''
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        'route domain check: recovery_allocations'::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                'PASS: Route check constraint enforces all 5 routes (restock, refurbish_and_resell, return_to_vendor, liquidation, scrap_recycle).'
            ELSE
                'FAIL: Incomplete or missing route check constraint on recovery_allocations.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_class cl
        ON cl.relname = 'recovery_allocations'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'c'
          AND pg_get_constraintdef(c.oid) ~* '''restock'''
          AND pg_get_constraintdef(c.oid) ~* '''refurbish_and_resell'''
          AND pg_get_constraintdef(c.oid) ~* '''return_to_vendor'''
          AND pg_get_constraintdef(c.oid) ~* '''liquidation'''
          AND pg_get_constraintdef(c.oid) ~* '''scrap_recycle'''
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        'channel domain check: recovery_allocations'::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                'PASS: Channel check constraint enforces all 3 channels (cash, supplier_credit, none).'
            ELSE
                'FAIL: Incomplete or missing channel check constraint on recovery_allocations.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_class cl
        ON cl.relname = 'recovery_allocations'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'c'
          AND pg_get_constraintdef(c.oid) ~* '''cash'''
          AND pg_get_constraintdef(c.oid) ~* '''supplier_credit'''
          AND pg_get_constraintdef(c.oid) ~* '''none'''
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        'item grade domain check: returned_inventory'::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                'PASS: Item grade check constraint enforces all 4 grades (Grade A, Grade B, Grade C, Grade D).'
            ELSE
                'FAIL: Incomplete or missing item_grade check constraint on returned_inventory.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_class cl
        ON cl.relname = 'returned_inventory'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'c'
          AND pg_get_constraintdef(c.oid) ~* '''Grade A'''
          AND pg_get_constraintdef(c.oid) ~* '''Grade B'''
          AND pg_get_constraintdef(c.oid) ~* '''Grade C'''
          AND pg_get_constraintdef(c.oid) ~* '''Grade D'''
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        'intake status domain check: returned_inventory'::text AS check_name,
        CASE
            WHEN c.oid IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN c.oid IS NOT NULL THEN
                'PASS: Intake status check constraint enforces all 4 statuses (received, inspected, allocated, completed).'
            ELSE
                'FAIL: Incomplete or missing intake_status check constraint on returned_inventory.'
        END::text AS details
    FROM (SELECT 1) AS dummy
    LEFT JOIN pg_class cl
        ON cl.relname = 'returned_inventory'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid
        FROM pg_constraint c
        WHERE c.conrelid = cl.oid
          AND c.contype::text = 'c'
          AND pg_get_constraintdef(c.oid) ~* '''received'''
          AND pg_get_constraintdef(c.oid) ~* '''inspected'''
          AND pg_get_constraintdef(c.oid) ~* '''allocated'''
          AND pg_get_constraintdef(c.oid) ~* '''completed'''
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        ('foreign key: ' || expected.src_table || ' -> ' || expected.target_table)::text AS check_name,
        CASE
            WHEN c.oid IS NULL THEN 'FAIL'
            WHEN c.confdeltype <> expected.del_action THEN 'FAIL'
            ELSE 'PASS'
        END::text AS status,
        CASE
            WHEN c.oid IS NULL THEN
                FORMAT('FAIL: Foreign key missing from %s to %s.', expected.src_table, expected.target_table)
            WHEN c.confdeltype <> expected.del_action THEN
                FORMAT('FAIL: Foreign key exists but delete action mismatch on %s (found: confdeltype=''%s'', expected: ''%s'').',
                       expected.src_table, c.confdeltype, expected.del_action)
            ELSE
                FORMAT('PASS: Foreign key active with expected delete action (confdeltype=''%s'').', expected.del_action)
        END::text AS details
    FROM (
        VALUES
            ('recovery_plans', 'returned_inventory', 'c'),
            ('recovery_allocations', 'recovery_plans', 'c'),
            ('returned_inventory', 'supplier_batches', 'r'),
            ('returned_inventory', 'products', 'r')
    ) AS expected(src_table, target_table, del_action)
    LEFT JOIN pg_class cl_src
        ON cl_src.relname = expected.src_table
       AND cl_src.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN pg_class cl_tgt
        ON cl_tgt.relname = expected.target_table
       AND cl_tgt.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT c.oid, c.confdeltype::text AS confdeltype
        FROM pg_constraint c
        WHERE c.conrelid = cl_src.oid
          AND c.confrelid = cl_tgt.oid
          AND c.contype::text = 'f'
        ORDER BY (c.confdeltype::text = expected.del_action) DESC, c.oid ASC
        LIMIT 1
    ) c ON true

    UNION ALL

    SELECT
        '7. Constraints & Columns'::text AS check_category,
        ('stored generated column: recovery_allocations.' || expected.colname)::text AS check_name,
        CASE
            WHEN a.attgenerated = 's' THEN 'PASS'
            ELSE 'FAIL'
        END::text AS status,
        CASE
            WHEN a.attgenerated = 's' THEN
                FORMAT('PASS: Column recovery_allocations.%s is a database-calculated STORED column.', expected.colname)
            WHEN a.attnum IS NULL THEN
                FORMAT('FAIL: Column %s does not exist on table recovery_allocations.', expected.colname)
            ELSE
                FORMAT('FAIL: Column %s exists but is NOT configured as a stored generated column (attgenerated <> ''s'').', expected.colname)
        END::text AS details
    FROM (
        VALUES
            ('total_gross_recovery_inr'),
            ('total_cost_inr'),
            ('total_net_recovery_inr')
    ) AS expected(colname)
    LEFT JOIN pg_class cl
        ON cl.relname = 'recovery_allocations'
       AND cl.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    LEFT JOIN LATERAL (
        SELECT a.attnum, a.attgenerated::text AS attgenerated
        FROM pg_attribute a
        WHERE a.attrelid = cl.oid
          AND a.attname = expected.colname
        LIMIT 1
    ) a ON true
)

-- -----------------------------------------------------------------------------
-- REPORTING & ROLLUP
-- Strict Rule: OVERALL_STATUS is PASS only if 100% of checks pass (0 FAIL and 0 INCONCLUSIVE).
-- If any checks are INCONCLUSIVE and none FAIL, the overall status is INCONCLUSIVE.
-- If any checks FAIL, the overall status is FAIL.
-- -----------------------------------------------------------------------------
SELECT
    check_category,
    check_name,
    status,
    details
FROM check_results

UNION ALL

SELECT
    '8. SUMMARY'::text AS check_category,
    'OVERALL_STATUS'::text AS check_name,
    CASE
        WHEN COUNT(*) FILTER (WHERE status = 'FAIL') > 0 THEN 'FAIL'
        WHEN COUNT(*) FILTER (WHERE status = 'INCONCLUSIVE') > 0 THEN 'INCONCLUSIVE'
        ELSE 'PASS'
    END::text AS status,
    FORMAT(
        'Total: %s checks | Passed: %s | Failed: %s | Inconclusive: %s. %s',
        COUNT(*),
        COUNT(*) FILTER (WHERE status = 'PASS'),
        COUNT(*) FILTER (WHERE status = 'FAIL'),
        COUNT(*) FILTER (WHERE status = 'INCONCLUSIVE'),
        CASE
            WHEN COUNT(*) FILTER (WHERE status = 'FAIL') > 0 THEN
                'One or more checks failed. Inspect failed rows above before running migrations or test suites.'
            WHEN COUNT(*) FILTER (WHERE status = 'INCONCLUSIVE') > 0 THEN
                'All verifiable checks passed, but environment-specific checks (e.g. Supabase roles) were inconclusive.'
            ELSE
                'All database objects, defect patches, RPC definitions, permissions, and constraints verified successfully.'
        END
    )::text AS details
FROM check_results

ORDER BY check_category, check_name;
