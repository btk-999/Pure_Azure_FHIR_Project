USE Synapx_sql_db;

GRANT EXECUTE ON OBJECT::dbo.usp_Insert_FHIR_RAW
TO [YOUR_ADF_DATABASE_USER];

GRANT EXECUTE
ON OBJECT::[slv].[usp_LoadFHIRResource]
TO [adf-synapx];

GRANT EXECUTE
ON OBJECT::dbo.usp_UpdateFHIRWatermark
TO [adf-synapx];