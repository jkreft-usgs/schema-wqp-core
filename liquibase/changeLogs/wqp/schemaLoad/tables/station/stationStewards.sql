create unlogged table if not exists ${WQP_SCHEMA_NAME}.station_stewards
partition of ${WQP_SCHEMA_NAME}.station
for values in (1)
with (fillfactor = 100)
;
