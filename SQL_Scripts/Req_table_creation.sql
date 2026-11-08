
--creating staging table

CREATE TABLE stg.FHIR_RAW
(RawID BIGINT IDENTITY(1,1) PRIMARY KEY, ResourceType NVARCHAR(50), RawJson NVARCHAR(MAX), 
ExtractionTimestamp DATETIME2 DEFAULT SYSUTCDATETIME(), ApiUrlOrParams NVARCHAR(2000), 
SourceFile NVARCHAR(1000), PipelineRunID NVARCHAR(100)
);


--creating watermark table
CREATE TABLE dbo.Fhir_Watermark
(ResourceType VARCHAR(50) PRIMARY KEY, LastWatermark DATETIME, UpdatedAt DATETIME DEFAULT GETDATE());

--inserting into watermark table
INSERT INTO dbo.Fhir_Watermark
(ResourceType, LastWatermark)
VALUES
('Patient', '1970-01-01'),
('Encounter', '1970-01-01'),
('Observation', '1970-01-01'),
('Condition', '1970-01-01');

SELECT * FROM dbo.Fhir_Watermark;


CREATE OR ALTER PROCEDURE dbo.usp_Insert_FHIR_RAW
(@ResourceType NVARCHAR(50), @RawJson NVARCHAR(MAX), @ApiUrlOrParams NVARCHAR(2000), 
@SourceFile NVARCHAR(1000), @PipelineRunID NVARCHAR(100))
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO stg.FHIR_RAW
    (ResourceType, RawJson, ExtractionTimestamp, ApiUrlOrParams, SourceFile, PipelineRunID)
    VALUES
    (@ResourceType, @RawJson, SYSUTCDATETIME(), @ApiUrlOrParams, @SourceFile, @PipelineRunID);
END;


USE Synapx_sql_db;

GRANT EXECUTE ON OBJECT::dbo.usp_Insert_FHIR_RAW
TO [YOUR_ADF_DATABASE_USER];
GO