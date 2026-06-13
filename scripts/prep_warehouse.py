#!/usr/bin/env python3
"""Prepare a known table in the OFEM integration-test Fabric Warehouse.

Run before the warehouse integration tests (locally and in CI). The table's data
lands in the warehouse's OneLake `/Tables/<schema>/<table>` area as Delta/Parquet,
which is what the OFEM engine then enumerates and reads.

Authentication uses `mssql-python` with `Authentication=ActiveDirectoryDefault`,
which resolves the ambient Azure identity (a signed-in user locally, the CI
service principal in GitHub Actions after `azure/login`). No password or client
secret is handled here.

Required environment:
  OFEM_TEST_WH_SERVER    warehouse SQL endpoint FQDN (…datawarehouse.fabric.microsoft.com)
  OFEM_TEST_WH_DATABASE  warehouse name (the database)
Optional:
  OFEM_TEST_WH_TABLE     table name (default: ofem_ci_orders)
  OFEM_SQL_AUTH          ActiveDirectory auth variant (default: ActiveDirectoryDefault)
"""
import importlib
import os
import sys


def main() -> int:
    server = os.environ["OFEM_TEST_WH_SERVER"]
    database = os.environ["OFEM_TEST_WH_DATABASE"]
    table = os.environ.get("OFEM_TEST_WH_TABLE", "ofem_ci_orders")
    auth = os.environ.get("OFEM_SQL_AUTH", "ActiveDirectoryDefault")

    conn_str = (
        f"Server={server};"
        f"Authentication={auth};"
        "Encrypt=yes;TrustServerCertificate=no;"
        f"Database={database}"
    )
    mssql = importlib.import_module("mssql_python")
    conn = mssql.connect(conn_str)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(f"DROP TABLE IF EXISTS dbo.{table}")
    cur.execute(
        f"CREATE TABLE dbo.{table} "
        "(id INT NOT NULL, name VARCHAR(50) NOT NULL, amount DECIMAL(10, 2) NOT NULL)"
    )
    cur.execute(
        f"INSERT INTO dbo.{table} (id, name, amount) VALUES "
        "(1, 'alpha', 10.50), (2, 'bravo', 20.00), (3, 'charlie', 30.25)"
    )
    cur.execute(f"SELECT COUNT(*) FROM dbo.{table}")
    count = cur.fetchone()[0]
    conn.close()
    print(f"prepared dbo.{table} in {database}: {count} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
