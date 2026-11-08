-- Create schemas for the FHIR data platform

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    EXEC('CREATE SCHEMA stg');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'slv')
    EXEC('CREATE SCHEMA slv');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'rpt')
    EXEC('CREATE SCHEMA rpt');

SELECT name AS SchemaName
FROM sys.schemas WHERE name IN ('stg', 'slv', 'rpt');