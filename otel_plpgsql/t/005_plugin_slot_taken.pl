# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Only one plugin may hold the PLpgSQL_plugin rendezvous slot: whichever
# module's _PG_init runs first (shared_preload_libraries is processed in
# list order) wins it; a later one must WARN once and otherwise do
# nothing (see otel_plpgsql.c's _PG_init).
#
# SKIPPED, with the reasoning kept here rather than just dropping the
# file (the task brief explicitly allows this when a direct test is
# "too awkward"):
#
# The obvious zero-extra-code way to produce "another plugin already
# holds the slot" would be to preload BOTH otel_plpgsql and
# otel_plpgsql_stub together --- they're built from the one source and
# register for the exact same rendezvous slot, so the second one to load
# should see it taken.  That doesn't work: both _PG_init calls run their
# (unconditional, unguarded) DefineCustomBoolVariable("otel_plpgsql.enabled",
# ...) etc. BEFORE either one ever reaches the rendezvous-slot check, and
# PostgreSQL refuses to define the same custom GUC name twice from two
# different loaded modules ("FATAL: attempt to redefine parameter
# otel_plpgsql.enabled"), which aborts the postmaster before the actual
# scenario this test wants ever happens.
#
# A real test of this path needs some OTHER plugin already holding the
# slot --- a second, separate C module with its own (different) name and
# no GUCs of its own, built solely to claim PLpgSQL_plugin and do
# nothing else.  That's a reasonable thing to add later (and arguably
# belongs with otel_postgres_tracing once this module is folded in,
# where a shared test-helper plugin stub could live), but isn't worth a
# whole extra PGXS module+control+Makefile just for this one assertion
# right now.  _PG_init's slot-taken branch itself is a straight-line,
# independently-reviewable few lines (the find_rendezvous_variable()
# call, the *plugin_ptr != NULL check, and the WARNING+early-return);
# this is a deliberate coverage gap, not an untested code path left by
# accident.

use strict;
use warnings FATAL => 'all';

use Test::More;

plan skip_all =>
  'needs a second, independent PLpgSQL_plugin-claiming module; see the '
  . 'header comment in this file for why the obvious main+stub trick '
  . "doesn't work (GUC name collision aborts the postmaster first)";
