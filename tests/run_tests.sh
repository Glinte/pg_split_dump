#!/bin/bash

set -eux

PG_DUMP="$(which pg_dump)"

DBNAME=pg_split_dump_tests
export PGUSER=postgres
export PGHOST=${PGHOST:-"/var/run/postgresql"}

POSTGRES_VERSION="$(psql -tAXq -c 'SHOW server_version_num')"

dropdb --if-exists "$DBNAME"
createdb "$DBNAME"
psql -1 -X -v ON_ERROR_STOP=1 -f input.sql -d "$DBNAME"

if [ -d tmp ]; then
    rm -r tmp
fi
mkdir tmp

RUST_BACKTRACE=1 ../target/debug/pg_split_dump --format=t --pg-dump-binary="$PG_DUMP" "user=$PGUSER host=$PGHOST dbname=$DBNAME" tmp/tests.tar

RUST_BACKTRACE=1 ./bin/create_expected_archive/target/debug/create_expected_archive $POSTGRES_VERSION ./expected tmp/expected.tar

RUST_BACKTRACE=1 ../tar_diff/target/debug/tar_diff --aname expected --bname test_output tmp/expected.tar tmp/tests.tar > tmp/diff
if [ -s tmp/diff ]; then
    set +x

    echo "pg_split_dump tests FAILED" >&1
    echo "" >&1
    cat tmp/diff >&1
    exit 1
fi

# --no-owner leaves out ALTER ... OWNER TO statements, and the default keeps them.
RUST_BACKTRACE=1 ../target/debug/pg_split_dump --pg-dump-binary="$PG_DUMP" "user=$PGUSER host=$PGHOST dbname=$DBNAME" tmp/with_owner
RUST_BACKTRACE=1 ../target/debug/pg_split_dump --no-owner --pg-dump-binary="$PG_DUMP" "user=$PGUSER host=$PGHOST dbname=$DBNAME" tmp/no_owner
grep -rq "OWNER TO" tmp/with_owner
if grep -rq "OWNER TO" tmp/no_owner; then
    set +x

    echo "pg_split_dump tests FAILED: --no-owner output still has OWNER TO" >&1
    exit 1
fi

# --fk-in-table puts a foreign key in the referencing table's file instead of FK_CONSTRAINTS.
FK_DBNAME="${DBNAME}_fk"
dropdb --if-exists "$FK_DBNAME"
createdb "$FK_DBNAME"
psql -X -v ON_ERROR_STOP=1 -d "$FK_DBNAME" -c "
    CREATE TABLE parent (id integer PRIMARY KEY);
    CREATE TABLE child (parent_id integer CONSTRAINT child_parent_fkey REFERENCES parent (id));
"
RUST_BACKTRACE=1 ../target/debug/pg_split_dump --pg-dump-binary="$PG_DUMP" "user=$PGUSER host=$PGHOST dbname=$FK_DBNAME" tmp/fk_separate
RUST_BACKTRACE=1 ../target/debug/pg_split_dump --fk-in-table --pg-dump-binary="$PG_DUMP" "user=$PGUSER host=$PGHOST dbname=$FK_DBNAME" tmp/fk_in_table
grep -q "child_parent_fkey" tmp/fk_separate/public/FK_CONSTRAINTS/child.sql
if grep -q "child_parent_fkey" tmp/fk_separate/public/TABLES/child.sql; then
    set +x

    echo "pg_split_dump tests FAILED: default output has the foreign key in the table file" >&1
    exit 1
fi
if [ -e tmp/fk_in_table/public/FK_CONSTRAINTS ] || ! grep -q "child_parent_fkey" tmp/fk_in_table/public/TABLES/child.sql; then
    set +x

    echo "pg_split_dump tests FAILED: --fk-in-table did not move the foreign key" >&1
    exit 1
fi
dropdb "$FK_DBNAME"
