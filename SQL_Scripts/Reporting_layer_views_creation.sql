-- Create reporting schema
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');

-- 1. Patient demographics
CREATE OR ALTER VIEW rpt.vw_PatientDemographics AS
SELECT ResourceID AS PatientID, Gender, BirthDate, IsActive, MetaLastUpdated
FROM slv.Patient;

-- 2. Encounters per patient
CREATE OR ALTER VIEW rpt.vw_EncountersPerPatient AS
SELECT SubjectReference AS PatientReference, COUNT(*) AS TotalEncounters, MIN(PeriodStart) AS FirstEncounter, 
MAX(PeriodEnd) AS LastEncounter FROM slv.Encounter
GROUP BY SubjectReference;

-- 3. Observation trends
CREATE OR ALTER VIEW rpt.vw_ObservationTrends AS
SELECT CAST(EffectiveDateTime AS date) AS ObservationDate, ValueUnit, COUNT(*) AS TotalObservations, 
AVG(ValueQuantity) AS AverageValue FROM slv.Observation
GROUP BY CAST(EffectiveDateTime AS date), ValueUnit;

-- 4. Condition summaries
CREATE OR ALTER VIEW rpt.vw_ConditionSummary AS
SELECT SubjectReference AS PatientReference, COUNT(*) AS TotalConditions, 
MAX(RecordedDate) AS LatestRecordedDate FROM slv.Condition
GROUP BY SubjectReference;

--checking

SELECT *  FROM rpt.vw_PatientDemographics

SELECT 'Patient Demographics' AS ViewName, COUNT(*) AS TotalRecords FROM rpt.vw_PatientDemographics
UNION ALL
SELECT 'Encounters Per Patient', COUNT(*) FROM rpt.vw_EncountersPerPatient
UNION ALL
SELECT 'Observation Trends', COUNT(*) FROM rpt.vw_ObservationTrends
UNION ALL
SELECT 'Condition Summary', COUNT(*) FROM rpt.vw_ConditionSummary;