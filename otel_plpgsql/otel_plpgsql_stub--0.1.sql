/* otel_plpgsql_stub--0.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION otel_plpgsql_stub" to load this file. \quit

-- This extension has no SQL surface.  The PLpgSQL_plugin hooks are
-- installed at _PG_init via shared_preload_libraries (or session/local
-- preload, or LOAD); this CREATE EXTENSION exists solely so the module's
-- catalogue entry can be tracked alongside the loadable library.  This is
-- the S0 "otel_api hooks compiled out" build: every hook is a no-op.
