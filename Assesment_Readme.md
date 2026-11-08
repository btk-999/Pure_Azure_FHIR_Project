# FHIR Data Engineering Assessment

## Project overview

This project is created to extract FHIR data from the public HAPI FHIR R4 API and load it into Azure storage and Azure SQL database.

The main purpose is to get Patient, Encounter, Observation and Condition data from API, store the original response and then transform it into cleaned tables for reporting.

## Architecture

HAPI FHIR R4 API
Azure Data Factory
ADLS Gen2 Bronze layer
Azure SQL staging
Azure SQL Silver tables
Reporting views

ADF is used for API extraction and pipeline orchestration. SQL stored procedures are used for parsing and loading the data into Silver layer.

## Resources used

- Azure Data Factory
- Azure Data Lake Storage Gen2 / Blob storage
- Azure SQL Database
- HAPI FHIR R4 public API

FHIR resources used:
- Patient
- Encounter
- Observation
- Condition

## Pipeline details

### 1. Dynamic ingestion pipeline

Pipeline name: PL_FHIR_Dynamic_Ingestion

A ForEach activity runs for the four resource types in the following order:
Patient, Encounter, Observation and Condition.

Inside the ForEach:
1. Lookup activity reads the resource-specific watermark from dbo.Fhir_Watermark.
2. Copy activity calls the HAPI FHIR API using the _lastUpdated filter.
3. Pagination is configured to follow the FHIR Bundle next link.
4. Execute Pipeline activity runs PL_ADLS_Bronze_To_SQL_Stg to load the raw JSON into SQL staging.
5. Stored Procedure activity calls dbo.usp_UpdateFHIRWatermark after the staging pipeline succeeds.

The watermark is maintained separately for each resource type.

### 2. Bronze to SQL staging

The API response is stored as raw JSON in ADLS Bronze. The Bronze-to-SQL pipeline loads the JSON and metadata into stg.FHIR_RAW.

The staging table keeps information such as:
- Resource type
- Raw JSON response
- Extraction timestamp
- API URL or parameters
- Source file
- Pipeline run ID

### 3. Silver load pipeline

Pipeline name: PL_FHIR_Silver_Load

The pipeline uses a ForEach activity to call slv.usp_LoadFHIRResource for the four resource types.

The common procedure uses `OPENJSON`, `JSON_VALUE` and `JSON_QUERY` to read the FHIR Bundle entries and load the resource-specific Silver tables.

Silver tables:
- slv.Patient
- slv.Encounter
- slv.Observation
- slv.Condition

Records are deduplicated using the resource ID and changes are detected using a SHA2_256 record hash.

### 4. Patient SCD Type 2

Patient history is maintained in slv.Patient_SCD2.

When a Patient record changes:
- The previous current record is marked as not current.
- Its ValidTo value is populated.
- A new current version is inserted with a new ValidFrom.
- slv.Patient is synchronised with the latest Patient details.

The Patient resource ID is used as the business key.

### 5. Reporting views

The following reporting views are created:

- rpt.vw_PatientDemographics – patient demographic details.
- rpt.vw_EncountersPerPatient – encounter count and period information by patient.
- rpt.vw_ObservationTrends – observation counts and average values by date and unit.
- rpt.vw_ConditionSummary – condition counts by patient.

## How to deploy and run

1. Create or select an Azure SQL Database.
2. Create the staging table, watermark table and staging insert procedure using Req_table_creation.sql.
3. Create the Silver tables using Silver_tables_creation.sql.
4. Create the Patient and common resource procedures using Common_Procedure.sql.
5. Create the reporting views using Reporting_layer_views_creation.sql.
6. Apply the required database permissions for the ADF identity. Review Access_Provide_queries.sql and replace any placeholder user name with the correct database user.
7. Configure the ADF linked services and datasets for the REST API, ADLS and Azure SQL.
8. Import or deploy the ADF resources using the exported ARM templates and provide the required environment-specific parameters.
9. Run PL_FHIR_Dynamic_Ingestion.
10. Run PL_FHIR_Silver_Load.
11. Query the Silver tables and reporting views to check the loaded data.

## Parameters and configuration

- FHIR API base URL: https://hapi.fhir.org/baseR4
- Resource types: Patient, Encounter, Observation and Condition
- Incremental filter: _lastUpdated=ge
- Pipeline parameter: last_updated is retained with an initial default value for the initial load. The Lookup activity supplies the resource-specific watermark to the API request.
- SQL watermark table: dbo.Fhir_Watermark
- Raw staging table: stg.FHIR_RAW

Linked service names and storage/database locations may need to be changed when deploying in another Azure environment. Credentials and connection strings are not included in this project.

## Known limitations

- The watermark update procedure calculates the maximum meta.lastUpdated timestamp from all matching records currently present in staging for that resource. It is not restricted to only the current pipeline run.
- The watermark logic should be further tested with late-arriving records, overlapping timestamps and repeated runs before using it for production workloads.
- The project uses a public HAPI FHIR endpoint. The data returned by a public test server can change over time.
- This is an assessment implementation and not a production healthcare data platform.

## Project files

- ADF_ARM_Templates – exported ADF ARM template and parameter file.
- SQL_Scripts – table creation scripts, stored procedures, reporting views and permission queries.
- Documentation – README documentation.
- Demo – short pipeline walkthrough recording.

No passwords, credentials, connection strings or sensitive healthcare data should be included in the submission.
