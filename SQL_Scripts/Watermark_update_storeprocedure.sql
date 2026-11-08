CREATE OR ALTER PROCEDURE dbo.usp_UpdateFHIRWatermark
    @ResourceType NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxLastUpdated DATETIME2;

    SELECT
        @MaxLastUpdated = MAX(TRY_CONVERT(DATETIME2,JSON_VALUE(E.value, '$.resource.meta.lastUpdated')))
    FROM stg.FHIR_RAW R
    CROSS APPLY OPENJSON(R.RawJson, '$.entry') E
    WHERE R.ResourceType = @ResourceType AND JSON_VALUE(E.value, '$.resource.resourceType') = @ResourceType;

    IF @MaxLastUpdated IS NOT NULL
    BEGIN
        UPDATE dbo.Fhir_Watermark SET LastWatermark = @MaxLastUpdated, UpdatedAt = GETDATE()
        WHERE ResourceType = @ResourceType AND LastWatermark < @MaxLastUpdated;
    END;
END;