-- otel_plpgsql/bench/tpcb_plpgsql.sql
--
-- pgbench's TPC-B-like transaction, reimplemented as a plpgsql function
-- that calls four simple helper functions (update account, update
-- teller, update branch, insert history), against the standard pgbench
-- schema (pgbench_accounts/_tellers/_branches/_history, as created by
-- `pgbench -i`).  Used by the otel_plpgsql overhead benchmark
-- (tests/otel_api_bench/run-plpgsql.sh): a root pg.plpgsql.function span plus 4
-- child function spans, each with statement spans under it when
-- otel_plpgsql.trace_statements is on.
--
-- Kept deliberately simple: no retry logic, no error handling --- this
-- is exercising span cost, not a production TPC-B implementation.
--
-- Run against a database already initialised with `pgbench -i`; see
-- tpcb_plpgsql.pgbench for the matching pgbench script.

CREATE OR REPLACE FUNCTION otel_plpgsql_bench_update_account(p_aid int, p_delta int)
RETURNS void AS $BODY$
BEGIN
	UPDATE pgbench_accounts SET abalance = abalance + p_delta WHERE aid = p_aid;
END;
$BODY$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION otel_plpgsql_bench_update_teller(p_tid int, p_delta int)
RETURNS void AS $BODY$
BEGIN
	UPDATE pgbench_tellers SET tbalance = tbalance + p_delta WHERE tid = p_tid;
END;
$BODY$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION otel_plpgsql_bench_update_branch(p_bid int, p_delta int)
RETURNS void AS $BODY$
BEGIN
	UPDATE pgbench_branches SET bbalance = bbalance + p_delta WHERE bid = p_bid;
END;
$BODY$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION otel_plpgsql_bench_insert_history(p_tid int, p_bid int, p_aid int, p_delta int)
RETURNS void AS $BODY$
BEGIN
	INSERT INTO pgbench_history (tid, bid, aid, delta, mtime)
	VALUES (p_tid, p_bid, p_aid, p_delta, CURRENT_TIMESTAMP);
END;
$BODY$ LANGUAGE plpgsql;

-- The transaction itself: root span pg.plpgsql.function for this call,
-- one child pg.plpgsql.function span per helper above.
CREATE OR REPLACE FUNCTION otel_plpgsql_bench_tpcb(p_aid int, p_tid int, p_bid int, p_delta int)
RETURNS void AS $BODY$
BEGIN
	PERFORM otel_plpgsql_bench_update_account(p_aid, p_delta);
	PERFORM otel_plpgsql_bench_update_teller(p_tid, p_delta);
	PERFORM otel_plpgsql_bench_update_branch(p_bid, p_delta);
	PERFORM otel_plpgsql_bench_insert_history(p_tid, p_bid, p_aid, p_delta);
END;
$BODY$ LANGUAGE plpgsql;
