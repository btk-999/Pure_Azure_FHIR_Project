
CREATE OR ALTER PROCEDURE slv.usp_LoadPatient
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Step 1: Extract the latest Patient record for each ResourceID
    IF OBJECT_ID('tempdb..#PatientSource') IS NOT NULL
        DROP TABLE #PatientSource;

    ;WITH PatientData AS
    (
        SELECT
            R.RawID,
            R.PipelineRunID,
            R.SourceFile,
            R.ExtractionTimestamp,
            JSON_QUERY(E.value, '$.resource') AS ResourceJson,
            ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(E.value, '$.resource.id') ORDER BY R.ExtractionTimestamp DESC, R.RawID DESC) AS rn
        FROM stg.FHIR_RAW R
        CROSS APPLY OPENJSON(R.RawJson, '$.entry') E
        WHERE R.ResourceType = 'Patient' AND ISJSON(R.RawJson) = 1 AND JSON_VALUE(E.value, '$.resource.id') IS NOT NULL
    )

    SELECT
        JSON_VALUE(ResourceJson, '$.id') AS ResourceID,
        JSON_QUERY(ResourceJson, '$.identifier') AS IdentifierJson,
        CASE LOWER(JSON_VALUE(ResourceJson, '$.active')) WHEN 'true' THEN 1 WHEN 'false' THEN 0 ELSE NULL
        END AS IsActive,
        JSON_QUERY(ResourceJson, '$.name') AS NameJson,
        JSON_VALUE(ResourceJson, '$.gender') AS Gender,
        TRY_CONVERT(DATE, JSON_VALUE(ResourceJson, '$.birthDate')) AS BirthDate,
        JSON_VALUE(ResourceJson, '$.meta.versionId') AS MetaVersionID,
        TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(ResourceJson, '$.meta.lastUpdated')) AS MetaLastUpdated,
        JSON_VALUE(ResourceJson, '$.meta.source') AS MetaSource,
        JSON_QUERY(ResourceJson, '$.meta.tag') AS MetaTagJson,
        RawID AS SourceRawID,
        PipelineRunID,
        SourceFile,
        ExtractionTimestamp,
        ResourceJson AS RawResourceJson,
        CONVERT (CHAR(64),HASHBYTES('SHA2_256', CONVERT(VARBINARY(MAX), ResourceJson)),2) AS RecordHash
    INTO #PatientSource
    FROM PatientData WHERE rn = 1;


    BEGIN TRY
        BEGIN TRANSACTION;

        -- Step 2: Expire the old SCD Type 2 version
        UPDATE T
        SET T.IsCurrent = 0, T.ValidTo = COALESCE (S.MetaLastUpdated,S.ExtractionTimestamp,SYSUTCDATETIME())
        FROM slv.Patient_SCD2 T INNER JOIN #PatientSource S ON T.ResourceID = S.ResourceID
        WHERE T.IsCurrent = 1 AND ISNULL(T.RecordHash, '') <> ISNULL(S.RecordHash, '');


        -- Step 3: Insert new versions for new or changed Patients
        INSERT INTO slv.Patient_SCD2
        (ResourceID, IdentifierJson, IsActive, NameJson, Gender, BirthDate, 
        MetaVersionID, MetaLastUpdated, MetaSource, MetaTagJson, SourceRawID, PipelineRunID, 
        SourceFile, ExtractionTimestamp, RawResourceJson, RecordHash, IsCurrent, ValidFrom, ValidTo
        )
        SELECT S.ResourceID, S.IdentifierJson, S.IsActive, S.NameJson, S.Gender, S.BirthDate, 
        S.MetaVersionID, S.MetaLastUpdated, S.MetaSource, S.MetaTagJson, S.SourceRawID, S.PipelineRunID,
        S.SourceFile, S.ExtractionTimestamp, S.RawResourceJson, S.RecordHash, 1,
        COALESCE(S.MetaLastUpdated, S.ExtractionTimestamp, SYSUTCDATETIME()), NULL
        FROM #PatientSource S LEFT JOIN slv.Patient_SCD2 T ON T.ResourceID = S.ResourceID AND T.IsCurrent = 1
        WHERE T.ResourceID IS NULL;


        -- Step 4: Synchronize the latest Patient data into the
        -- current-state Silver Patient table
        UPDATE T
        SET T.IdentifierJson = S.IdentifierJson, T.IsActive = S.IsActive, T.NameJson = S.NameJson, 
        T.Gender = S.Gender, T.BirthDate = S.BirthDate, T.MetaVersionID = S.MetaVersionID, 
        T.MetaLastUpdated = S.MetaLastUpdated, T.MetaSource = S.MetaSource, T.MetaTagJson = S.MetaTagJson, 
        T.SourceRawID = S.SourceRawID, T.PipelineRunID = S.PipelineRunID, T.SourceFile = S.SourceFile, 
        T.ExtractionTimestamp = S.ExtractionTimestamp, T.RawResourceJson = S.RawResourceJson, 
        T.RecordHash = S.RecordHash, T.SilverLoadTime = SYSUTCDATETIME()
        FROM slv.Patient T INNER JOIN #PatientSource S ON T.ResourceID = S.ResourceID
        WHERE ISNULL(T.RecordHash, '') <> ISNULL(S.RecordHash, '');


        -- Step 5: Insert new Patients into the current-state table
        INSERT INTO slv.Patient
        (ResourceID, IdentifierJson, IsActive, NameJson, Gender, BirthDate, 
        MetaVersionID, MetaLastUpdated, MetaSource, MetaTagJson, SourceRawID, PipelineRunID, 
        SourceFile, ExtractionTimestamp, RawResourceJson, RecordHash, SilverLoadTime
        )
        SELECT S.ResourceID, S.IdentifierJson, S.IsActive, S.NameJson, S.Gender, S.BirthDate, 
        S.MetaVersionID, S.MetaLastUpdated, S.MetaSource, S.MetaTagJson, S.SourceRawID, S.PipelineRunID, 
        S.SourceFile, S.ExtractionTimestamp, S.RawResourceJson, S.RecordHash, SYSUTCDATETIME()
        FROM #PatientSource S
        WHERE NOT EXISTS (SELECT 1 FROM slv.Patient T WHERE T.ResourceID = S.ResourceID);

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;

END;




CREATE OR ALTER PROCEDURE slv.usp_LoadFHIRResource
    @ResourceType NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    -- Patient: reuse the SCD2 procedure already created
    IF @ResourceType = 'Patient'
    BEGIN
        EXEC slv.usp_LoadPatient;
        RETURN;
    END;

    -- Encounter
    IF @ResourceType = 'Encounter'
    BEGIN
        ;WITH SourceData AS
        (
            SELECT R.RawID AS SourceRawID, R.PipelineRunID, R.SourceFile, R.ExtractionTimestamp, 
            JSON_VALUE(E.value,'$.resource.id') AS ResourceID, 
            JSON_QUERY(E.value,'$.resource.identifier') AS IdentifierJson, 
            JSON_VALUE(E.value,'$.resource.status') AS Status, 
            JSON_QUERY(E.value,'$.resource.class') AS ClassJson, 
            JSON_VALUE(E.value,'$.resource.subject.reference') AS SubjectReference, 
            JSON_QUERY(E.value,'$.resource.subject') AS SubjectJson, 
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.period.start')) AS PeriodStart, 
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.period.end')) AS PeriodEnd, 
            JSON_QUERY(E.value,'$.resource.serviceType') AS ServiceTypeJson, 
            JSON_QUERY(E.value,'$.resource.participant') AS ParticipantJson, 
            JSON_QUERY(E.value,'$.resource.type') AS TypeJson, 
            JSON_VALUE(E.value,'$.resource.meta.versionId') AS MetaVersionID, 
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.meta.lastUpdated')) AS MetaLastUpdated, 
            JSON_QUERY(E.value,'$.resource') AS RawResourceJson
            FROM stg.FHIR_RAW R
            CROSS APPLY OPENJSON(R.RawJson,'$.entry') E
            WHERE R.ResourceType = 'Encounter' AND JSON_VALUE(E.value,'$.resource.resourceType') = 'Encounter'
        )
        MERGE slv.Encounter AS T
        USING
        (
            SELECT *, CONVERT(CHAR(64),HASHBYTES('SHA2_256', CONVERT(VARBINARY(MAX),RawResourceJson)),2) AS RecordHash
            FROM SourceData WHERE ResourceID IS NOT NULL
        ) AS S
        ON T.ResourceID = S.ResourceID

        WHEN MATCHED AND ISNULL(T.RecordHash, '') <> ISNULL(S.RecordHash, '') THEN THEN
            UPDATE SET T.IdentifierJson = S.IdentifierJson, T.Status = S.Status, T.ClassJson = S.ClassJson, 
            T.SubjectReference = S.SubjectReference, T.SubjectJson = S.SubjectJson, T.PeriodStart = S.PeriodStart, 
            T.PeriodEnd = S.PeriodEnd, T.ServiceTypeJson = S.ServiceTypeJson, T.ParticipantJson = S.ParticipantJson, 
            T.TypeJson = S.TypeJson, T.MetaVersionID = S.MetaVersionID, T.MetaLastUpdated = S.MetaLastUpdated, 
            T.SourceRawID = S.SourceRawID, T.PipelineRunID = S.PipelineRunID, T.SourceFile = S.SourceFile, 
            T.ExtractionTimestamp = S.ExtractionTimestamp, T.RawResourceJson = S.RawResourceJson, 
            T.RecordHash = S.RecordHash, T.SilverLoadTime = SYSUTCDATETIME()

        WHEN NOT MATCHED THEN
            INSERT
            (ResourceID, IdentifierJson, Status, ClassJson, SubjectReference, SubjectJson, PeriodStart, 
            PeriodEnd, ServiceTypeJson, ParticipantJson, TypeJson, MetaVersionID, MetaLastUpdated, SourceRawID, 
            PipelineRunID, SourceFile, ExtractionTimestamp, RawResourceJson, RecordHash, SilverLoadTime)
            VALUES
            (S.ResourceID, S.IdentifierJson, S.Status, S.ClassJson, S.SubjectReference, S.SubjectJson, S.PeriodStart, 
            S.PeriodEnd, S.ServiceTypeJson, S.ParticipantJson, S.TypeJson, S.MetaVersionID, S.MetaLastUpdated, S.SourceRawID,
            S.PipelineRunID, S.SourceFile, S.ExtractionTimestamp, S.RawResourceJson, S.RecordHash, SYSUTCDATETIME());
    END;

    -- Observation
    IF @ResourceType = 'Observation'
    BEGIN
        ;WITH SourceData AS
        (
            SELECT R.RawID AS SourceRawID, R.PipelineRunID, R.SourceFile, R.ExtractionTimestamp,
            JSON_VALUE(E.value,'$.resource.id') AS ResourceID,
            JSON_VALUE(E.value,'$.resource.status') AS Status,
            JSON_QUERY(E.value,'$.resource.category') AS CategoryJson,
            JSON_QUERY(E.value,'$.resource.code') AS CodeJson,
            JSON_VALUE(E.value,'$.resource.subject.reference') AS SubjectReference,
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.effectiveDateTime')) AS EffectiveDateTime,
            TRY_CONVERT(DECIMAL(18,4),JSON_VALUE(E.value,'$.resource.valueQuantity.value')) AS ValueQuantity,
            JSON_VALUE(E.value,'$.resource.valueQuantity.unit') AS ValueUnit,
            JSON_VALUE(E.value,'$.resource.valueQuantity.system') AS ValueSystem,
            JSON_VALUE(E.value,'$.resource.valueQuantity.code') AS ValueCode,
            JSON_VALUE(E.value,'$.resource.meta.versionId') AS MetaVersionID,
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.meta.lastUpdated')) AS MetaLastUpdated,
            JSON_QUERY(E.value,'$.resource') AS RawResourceJson
            FROM stg.FHIR_RAW R
            CROSS APPLY OPENJSON(R.RawJson,'$.entry') E
            WHERE R.ResourceType = 'Observation' AND JSON_VALUE(E.value,'$.resource.resourceType') = 'Observation'
        )
        MERGE slv.Observation AS T
        USING
        (
            SELECT *, CONVERT(CHAR(64),HASHBYTES('SHA2_256', CONVERT(VARBINARY(MAX),RawResourceJson)),2) AS RecordHash
            FROM SourceData WHERE ResourceID IS NOT NULL
        ) AS S
        ON T.ResourceID = S.ResourceID

        WHEN MATCHED AND T.RecordHash <> S.RecordHash THEN
            UPDATE SET T.Status = S.Status, T.CategoryJson = S.CategoryJson, T.CodeJson = S.CodeJson, 
            T.SubjectReference = S.SubjectReference, T.EffectiveDateTime = S.EffectiveDateTime, 
            T.ValueQuantity = S.ValueQuantity, T.ValueUnit = S.ValueUnit, T.ValueSystem = S.ValueSystem, 
            T.ValueCode = S.ValueCode, T.MetaVersionID = S.MetaVersionID, T.MetaLastUpdated = S.MetaLastUpdated, 
            T.SourceRawID = S.SourceRawID, T.PipelineRunID = S.PipelineRunID, T.SourceFile = S.SourceFile, 
            T.ExtractionTimestamp = S.ExtractionTimestamp, T.RawResourceJson = S.RawResourceJson, 
            T.RecordHash = S.RecordHash, T.SilverLoadTime = SYSUTCDATETIME()

        WHEN NOT MATCHED THEN
            INSERT
            (ResourceID, Status, CategoryJson, CodeJson, SubjectReference, EffectiveDateTime, ValueQuantity, 
            ValueUnit, ValueSystem, ValueCode, MetaVersionID, MetaLastUpdated, SourceRawID, PipelineRunID, 
            SourceFile, ExtractionTimestamp, RawResourceJson, RecordHash, SilverLoadTime)
            VALUES
            (S.ResourceID, S.Status, S.CategoryJson, S.CodeJson, S.SubjectReference, S.EffectiveDateTime, S.ValueQuantity, 
            S.ValueUnit, S.ValueSystem, S.ValueCode, S.MetaVersionID, S.MetaLastUpdated, S.SourceRawID, S.PipelineRunID, 
            S.SourceFile, S.ExtractionTimestamp, S.RawResourceJson, S.RecordHash, SYSUTCDATETIME());
    END;

    -- Condition
    IF @ResourceType = 'Condition'
    BEGIN
        ;WITH SourceData AS
        (
            SELECT R.RawID AS SourceRawID, R.PipelineRunID, R.SourceFile, R.ExtractionTimestamp,
            JSON_VALUE(E.value,'$.resource.id') AS ResourceID,
            JSON_QUERY(E.value,'$.resource.identifier') AS IdentifierJson,
            JSON_QUERY(E.value,'$.resource.clinicalStatus') AS ClinicalStatusJson,
            JSON_QUERY(E.value,'$.resource.verificationStatus') AS VerificationStatusJson,
            JSON_QUERY(E.value,'$.resource.code') AS CodeJson,
            JSON_VALUE(E.value,'$.resource.subject.reference') AS SubjectReference,
            JSON_VALUE(E.value,'$.resource.encounter.reference') AS EncounterReference,
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.onsetDateTime')) AS OnsetDateTime,
            TRY_CONVERT(DATE,JSON_VALUE(E.value,'$.resource.recordedDate')) AS RecordedDate,
            JSON_VALUE(E.value,'$.resource.asserter.reference') AS AsserterReference,
            JSON_VALUE(E.value,'$.resource.meta.versionId') AS MetaVersionID,
            TRY_CONVERT(DATETIMEOFFSET,JSON_VALUE(E.value,'$.resource.meta.lastUpdated')) AS MetaLastUpdated,
            JSON_QUERY(E.value,'$.resource') AS RawResourceJson
            FROM stg.FHIR_RAW R
            CROSS APPLY OPENJSON(R.RawJson,'$.entry') E
            WHERE R.ResourceType = 'Condition' AND JSON_VALUE(E.value,'$.resource.resourceType') = 'Condition'
        )
        MERGE slv.Condition AS T
        USING
        (
            SELECT *, CONVERT(CHAR(64),HASHBYTES('SHA2_256', CONVERT(VARBINARY(MAX),RawResourceJson)),2) AS RecordHash
            FROM SourceData WHERE ResourceID IS NOT NULL
        ) AS S
        ON T.ResourceID = S.ResourceID

        WHEN MATCHED AND T.RecordHash <> S.RecordHash THEN
            UPDATE SET T.IdentifierJson = S.IdentifierJson, T.ClinicalStatusJson = S.ClinicalStatusJson, 
            T.VerificationStatusJson = S.VerificationStatusJson, T.CodeJson = S.CodeJson, T.SubjectReference = S.SubjectReference, 
            T.EncounterReference = S.EncounterReference, T.OnsetDateTime = S.OnsetDateTime, T.RecordedDate = S.RecordedDate, 
            T.AsserterReference = S.AsserterReference, T.MetaVersionID = S.MetaVersionID, T.MetaLastUpdated = S.MetaLastUpdated, 
            T.SourceRawID = S.SourceRawID, T.PipelineRunID = S.PipelineRunID, T.SourceFile = S.SourceFile, 
            T.ExtractionTimestamp = S.ExtractionTimestamp, T.RawResourceJson = S.RawResourceJson, T.RecordHash = S.RecordHash, 
            T.SilverLoadTime = SYSUTCDATETIME()

        WHEN NOT MATCHED THEN
            INSERT
            ( ResourceID, IdentifierJson, ClinicalStatusJson, VerificationStatusJson, CodeJson, SubjectReference, EncounterReference, 
            OnsetDateTime, RecordedDate, AsserterReference, MetaVersionID, MetaLastUpdated, SourceRawID, PipelineRunID, SourceFile,
            ExtractionTimestamp, RawResourceJson, RecordHash, SilverLoadTime
            )
            VALUES
            (S.ResourceID, S.IdentifierJson, S.ClinicalStatusJson,S.VerificationStatusJson, S.CodeJson, S.SubjectReference,
            S.EncounterReference, S.OnsetDateTime, S.RecordedDate,S.AsserterReference, S.MetaVersionID, S.MetaLastUpdated,
            S.SourceRawID, S.PipelineRunID, S.SourceFile,S.ExtractionTimestamp, S.RawResourceJson, S.RecordHash,SYSUTCDATETIME());
    END;

    IF @ResourceType NOT IN ('Patient','Encounter','Observation','Condition')
        THROW 50001, 'Unsupported FHIR resource type.', 1;

END;

--execute the procedure

EXEC slv.usp_LoadFHIRResource @ResourceType = 'Patient';
EXEC slv.usp_LoadFHIRResource @ResourceType = 'Encounter';
EXEC slv.usp_LoadFHIRResource @ResourceType = 'Observation';
EXEC slv.usp_LoadFHIRResource @ResourceType = 'Condition';

-- checking

SELECT 'Patient' AS ResourceType, COUNT(*) AS TotalRecords FROM slv.Patient
UNION ALL
SELECT 'Encounter', COUNT(*) FROM slv.Encounter
UNION ALL
SELECT 'Observation', COUNT(*) FROM slv.Observation
UNION ALL
SELECT 'Condition', COUNT(*) FROM slv.Condition;


