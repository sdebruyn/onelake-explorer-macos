-- Prepare a known table in the OFEM integration-test Fabric Warehouse.
--
-- Run before the warehouse integration tests (locally and in CI). The table's
-- data lands in the warehouse's OneLake /Tables/<schema>/<table> area as
-- Delta/Parquet, which is what the OFEM engine then enumerates and reads.
--
-- Run with go-sqlcmd (github.com/microsoft/go-sqlcmd) using Azure AD auth, which
-- resolves the ambient Azure identity (a signed-in user locally, the CI service
-- principal in GitHub Actions after `azure/login`). No password or secret here:
--
--   sqlcmd -S "$OFEM_TEST_WH_SERVER" -d "$OFEM_TEST_WH_DATABASE" \
--          --authentication-method ActiveDirectoryAzCli \
--          -v table="$OFEM_TEST_WH_TABLE" -i scripts/prep_warehouse.sql -b
SET NOCOUNT ON;

DROP TABLE IF EXISTS dbo.$(table);

CREATE TABLE dbo.$(table) (
    id INT NOT NULL,
    name VARCHAR(50) NOT NULL,
    amount DECIMAL(10, 2) NOT NULL
);

INSERT INTO dbo.$(table) (id, name, amount) VALUES
    (1, 'alpha', 10.50),
    (2, 'bravo', 20.00),
    (3, 'charlie', 30.25);

SELECT COUNT(*) AS row_count FROM dbo.$(table);
