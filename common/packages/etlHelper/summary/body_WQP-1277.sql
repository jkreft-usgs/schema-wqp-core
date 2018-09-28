create or replace package body etl_helper_summary as

    procedure create_tables(p_table_suffix in user_tables.table_name%type) is
        table_name user_tables.table_name%type;
    begin

        create_station_sum(p_table_suffix);
        create_activity_sum(p_table_suffix);
        create_result_sum(p_table_suffix);
        create_result_grouping(p_table_suffix);
        create_organization_sum(p_table_suffix);
        create_qwportal_summary(p_table_suffix);

    end create_tables;

    procedure create_table(p_table_prefix in user_tables.table_name%type,
                           p_table_suffix in user_tables.table_name%type,
                           p_sql_suffix in varchar2,
                           p_parallel in boolean default true) is
        table_name user_tables.table_name%type;
    begin

        table_name := dbms_assert.sql_object_name(upper(p_table_prefix || p_table_suffix));

        dbms_output.put_line('dropping indexes on:' || table_name || ' at:' || systimestamp);
        etl_helper_main.drop_indexes(table_name);

        dbms_output.put_line('populating:' || table_name || ' at:' || systimestamp);
        execute immediate 'truncate table ' || table_name;

        if (p_parallel) then
            execute immediate 'insert /*+ append parallel(4) */ into ' || table_name || p_sql_suffix;
        else
            execute immediate 'insert /*+ append */ into ' || table_name || p_sql_suffix;
        end if;
        commit;

        dbms_output.put_line('finished populating:' || table_name || ' at:' || systimestamp);

    end create_table;

    procedure create_station_sum(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(30000 char);
    begin

        sql_suffix := '(data_source_id, data_source, station_id, site_id, organization, site_type, huc, governmental_unit_code, geom, activity_count, activity_count_past_12_months, activity_count_past_60_months, result_count, result_count_past_12_months, result_count_past_60_months, summary_past_12_months, summary_past_60_months, summary_all_months)
        select /*+ parallel(4) */
               station.data_source_id,
               station.data_source,
               station.station_id,
               station.site_id,
               station.organization,
               station.site_type,
               station.huc,
               station.governmental_unit_code,
               station.geom,
               nvl(activity.activity_count,0) activity_count,
               nvl(activity.activity_count_12_months,0) activity_count_past_12_months,
               nvl(activity.activity_count_60_months,0) activity_count_past_60_months,
               nvl(result.result_count,0) result_count,
               nvl(result.result_count_12_months,0) result_count_past_12_months,
               nvl(result.result_count_60_months,0) result_count_past_60_months,
               results_12_months.past_12_months summary_past_12_months,
               results_60_months.past_60_months summary_past_60_months,
               results_all_months.all_months summary_all_months
          from station_swap_' || p_table_suffix || ' station
               left join (select station_id, 
                                 count(*) activity_count, 
                                 sum(case when event_date > add_months(sysdate, -12) then 1 else 0 end) activity_count_12_months,
                                 sum(case when event_date > add_months(sysdate, -60) then 1 else 0 end) activity_count_60_months
                            from activity_swap_' || p_table_suffix || '
                               group by station_id) activity
                 on station.station_id = activity.station_id
               left join (select station_id,
                                 count(*) result_count,
                                 sum(case when event_date > add_months(sysdate, -12) then 1 else 0 end) result_count_12_months,
                                 sum(case when event_date > add_months(sysdate, -60) then 1 else 0 end) result_count_60_months
                            from result_swap_' || p_table_suffix || q'!
                               group by station_id) result
                 on station.station_id = result.station_id
               left join (select station_id,
                                 '{' || listagg('"' || characteristic_type || '": ' || counts_12_months.result_count_type, ',')
                                    within group (order by station_id, characteristic_type) || '}' past_12_months
                            from
                              (select station_id, characteristic_type, sum(result_count) result_count_type
                                from result_sum_swap_!' || p_table_suffix || q'!
                                where event_date > add_months(sysdate, -12) group by station_id, characteristic_type) counts_12_months
                            group by station_id) results_12_months
                  on station.station_id = results_12_months.station_id
               left join (select station_id,
                                 '{' || listagg('"' || characteristic_type || '": ' || counts_60_months.result_count_type, ',')
                                    within group (order by station_id, characteristic_type) || '}' past_60_months
                            from
                              (select station_id, characteristic_type, sum(result_count) result_count_type
                                from result_sum_swap_!' || p_table_suffix || q'!
                                where event_date > add_months(sysdate, -60) group by station_id, characteristic_type) counts_60_months
                            group by station_id) results_60_months
                  on station.station_id = results_60_months.station_id
               left join (select station_id,
                                 '{' || listagg('"' || characteristic_type || '": ' || counts_all.result_count_type, ',')
                                    within group (order by station_id, characteristic_type) || '}' all_months
                            from
                              (select station_id, characteristic_type, sum(result_count) result_count_type
                                from result_sum_swap_!' || p_table_suffix || '
                                group by station_id, characteristic_type) counts_all
                            group by station_id) results_all_months
                  on station.station_id = results_all_months.station_id';

        create_table('station_sum_swap_', p_table_suffix, sql_suffix);

    end create_station_sum;

    procedure create_activity_sum(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(4000 char);
    begin

        sql_suffix := '(data_source_id, data_source, station_id, site_id, event_date, sample_media,
                        organization, site_type, huc, governmental_unit_code, activity_id, project_id,
                        act_metric_count, result_count)
        select activity.data_source_id, activity.data_source, activity.station_id, site_id, activity.event_date, activity.sample_media,
               activity.organization, activity.site_type, activity.huc, activity.governmental_unit_code, activity.activity_id, activity.project_id,
               nvl(act_metric.act_metric_count,0), nvl(result.result_count,0)
          from activity_swap_' || p_table_suffix || ' activity
               left join (select station_id, activity_id, count(*) result_count
                            from result_swap_' || p_table_suffix || '
                               group by station_id, activity_id) result
                 on activity.station_id = result.station_id and
                    activity.activity_id = result.activity_id
               left join (select station_id, activity_id, count(*) act_metric_count
                            from act_metric_swap_' || p_table_suffix || '
                               group by station_id, activity_id) act_metric
                 on activity.station_id = act_metric.station_id and
                    activity.activity_id = act_metric.activity_id';

        create_table('activity_sum_swap_', p_table_suffix, sql_suffix);

    end create_activity_sum;

    procedure create_result_sum(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(4000 char);
    begin

        sql_suffix := '(data_source_id, data_source, station_id, site_id, event_date, analytical_method, p_code,
                        characteristic_name, characteristic_type, sample_media, organization, site_type, huc,
                        governmental_unit_code, project_id, assemblage_sampled_name, sample_tissue_taxonomic_name, activity_id, result_count)
        select data_source_id, data_source, station_id, site_id, event_date, analytical_method, p_code, characteristic_name,
               characteristic_type, sample_media, organization, site_type, huc, governmental_unit_code, project_id,
               assemblage_sampled_name, sample_tissue_taxonomic_name, activity_id, count(*) result_count
          from result_swap_' || p_table_suffix || '
            group by data_source_id, data_source, station_id, site_id, event_date, analytical_method, p_code, characteristic_name,
                     characteristic_type, sample_media, organization, site_type, huc, governmental_unit_code, project_id,
                     assemblage_sampled_name, sample_tissue_taxonomic_name, activity_id';

        create_table('result_sum_swap_', p_table_suffix, sql_suffix);

    end create_result_sum;

    procedure create_result_grouping(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(4000 char);
    begin

        sql_suffix := q'!(data_source, organization, the_year, characteristic_type, characteristic_name,
                          total_monitoring_locations, total_activities, total_results, last_result_date, grouping_id)
        select data_source,
               organization,
               to_char(event_date, 'yyyy') the_year,
               characteristic_type,
               characteristic_name,
               count(distinct site_id) total_monitoring_locations,
               count(distinct activity_id) total_activities,
               sum(result_count) total_results,
               max(event_date) last_result_date,
               grouping_id (to_char(event_date, 'yyyy'), characteristic_type, characteristic_name) grouping_id
          from result_sum_swap_!' || p_table_suffix || q'!
            group by grouping sets(
                                   (data_source, organization, to_char(event_date, 'yyyy')),
                                   (data_source, organization, to_char(event_date, 'yyyy'), characteristic_type),
                                   (data_source, organization, to_char(event_date, 'yyyy'), characteristic_type, characteristic_name)
                                  )!';

        create_table('result_grouping_swap_', p_table_suffix, sql_suffix);

    end create_result_grouping;

    procedure create_organization_sum(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(30000 char);
    begin

        sql_suffix := q'!(data_source_id, data_source, organization_id, organization, organization_name, organization_url,
                          all_time_last_result, all_time_site_count, all_time_activity_count,
                          five_year_last_result, five_year_site_count, five_year_activity_count,
                          current_year_last_result, current_year_site_count, current_year_activity_count,
                          all_time_summary, five_year_summary, current_year_summary)
        with org_sum as (select /*+ noparallel */ data_source,
                                organization, 
                                max(event_date) event_date_all_time,
                                count(distinct site_id) site_count_all_time,
                                count(distinct activity_id) activity_count_all_time,
                                max(case when event_date >= add_months(trunc(sysdate, 'yyyy'), - 48) then event_date else null end) event_date_five_year,
                                count(distinct case when event_date >= add_months(trunc(sysdate, 'yyyy'), - 48) then site_id else null end) site_count_five_year,
                                count(distinct case when event_date >= add_months(trunc(sysdate, 'yyyy'), - 48) then activity_id else null end) activity_count_five_year,
                                max(case when event_date >= trunc(sysdate, 'yyyy') then event_date else null end) event_date_current_year,
                                count(distinct case when event_date >= trunc(sysdate, 'yyyy') then site_id else null end) site_count_current_year,
                                count(distinct case when event_date >= trunc(sysdate, 'yyyy') then activity_id else null end) activity_count_current_year
                           from result_sum_swap_!' || p_table_suffix || q'!
                             group by data_source, organization),
             org_year_agg as (select /*+ noparallel */ data_source, 
                                     organization,
                                     the_year,
                                     '"characteristicGroupResultCount":{' || 
                                         listagg(case when grouping_id = 1 then '"' || characteristic_type || '": ' || total_results else null end, ',')
                                         within group (order by characteristic_type) ||
                                        '}' group_result_counts,
                                     case 
                                       when the_year >= to_char(sysdate, 'yyyy') THEN 1
                                       when the_year >= to_char(add_months(trunc(sysdate, 'yyyy'), - 48), 'yyyy') then 5
                                       else null
                                     end years_window,
                                     '"year": ' || the_year || 
                                         ', "start": "01-01-' || the_year ||
                                         '", "end": "12-31-' || the_year ||
                                         '", "activityCount": ' || min(case when grouping_id = 3 then total_activities else null end) ||
                                         ', "resultCount": ' || min(case when grouping_id = 3 then total_results else null end) ||
                                         ', "monitoringLocationsSampled": ' || min(case when grouping_id = 3 then total_monitoring_locations else null end) year_metadata,
                                     to_clob('"characteristicNameSummary":[') || 
                                         rtrim(clobagg(case
                                                         when grouping_id = 0
                                                           then '{"characteristicName": "' || CHARACTERISTIC_NAME || '",' ||
                                                                '"characteristicType": "' || CHARACTERISTIC_TYPE || '",' ||
                                                                '"activityCount":' || total_activities || ',' ||
                                                                '"resultCount":' || total_results || ',' ||
                                                                '"monitoringLocationCount":' || total_monitoring_locations || '}, '
                                                         else null
                                                       end),
                                               ', ') ||
                                         to_clob(']') name_result_counts
                                from result_grouping_swap_!' || p_table_suffix || q'! result_grouping
                               where grouping_id in (0, 1, 3)
                                  group by data_source, organization, the_year
                             )
        select /*+ noparallel */ org_data.data_source_id,
               org_data.data_source,
               org_data.organization_id,
               org_data.organization,
               org_data.organization_name,
               '/provider/' || org_data.data_source || '/' || org_data.organization organization_url,
               org_sum.event_date_all_time all_time_last_result,
               nvl2(org_sum.event_date_all_time, org_sum.site_count_all_time, null) all_time_site_count,
               nvl2(org_sum.event_date_all_time, org_sum.activity_count_all_time, null) all_time_activity_count,
               org_sum.event_date_five_year five_year_last_result,
               nvl2(org_sum.event_date_five_year, org_sum.site_count_five_year, null) five_year_site_count,
               nvl2(org_sum.event_date_five_year, org_sum.activity_count_five_year, null) five_year_activity_count,
               org_sum.event_date_current_year current_year_last_result,
               nvl2(org_sum.event_date_current_year, org_sum.site_count_current_year, null) current_year_site_count,
               nvl2(org_sum.event_date_current_year, org_sum.activity_count_current_year, null) current_year_activity_count,
               year_summary.all_time_summary,
               year_summary.five_year_summary,
               year_summary.current_year_summary
          from org_data_swap_!' || p_table_suffix || q'! org_data
               left join org_sum
                 on org_data.data_source = org_sum.data_source and
                    org_data.organization = org_sum.organization
               left join (
                          select /*+ noparallel */ data_source,
                                 organization,
                                 to_clob('[') ||
                                         rtrim(clobagg(case when years_window = 1 then to_clob(year_data || ',') else null end), ', ') ||
                                         to_clob(']') current_year_summary,
                                 to_clob('[') ||
                                         rtrim(clobagg(case when years_window < 6 then to_clob(year_data || ',') else null end), ', ') ||
                                         to_clob(']') five_year_summary,
                                 to_clob('[') ||
                                         rtrim(clobagg(year_data || ','), ', ') ||
                                         to_clob(']') all_time_summary
                            from (
                                  select /*+ noparallel */ data_source,
                                         organization,
                                         years_window,
                                         the_year,
                                         '{' || year_metadata ||
                                            ', ' || group_result_counts ||
                                            ', ' || name_result_counts ||
                                            '}' year_data
                                    from org_year_agg
                                 )
                              group by data_source, organization
                         ) year_summary
                 on org_data.data_source = year_summary.data_source and
                    org_data.organization = year_summary.organization!';

        create_table('organization_sum_swap_', p_table_suffix, sql_suffix, false);

    end create_organization_sum;

    procedure create_qwportal_summary(p_table_suffix in user_tables.table_name%type) is
        sql_suffix varchar2(4000 char);
    begin

        if upper(p_table_suffix) = 'NWIS' or
           upper(p_table_suffix) = 'STORET' then

            sql_suffix := q'!(data_source_id, fips_state_code, fips_county_code, fips_state_and_county, huc8, min_date, max_date,
                              samples_past_12_months, samples_past_60_months, samples_all_time)
            select /*+ parallel(4) */ data_source_id,
                   regexp_substr(state_code, '[^:]+', 1, 2) state_fips_code,
                   regexp_substr(county_code, '[^:]+', 1, 3) county_fips_code,
                   regexp_substr(state_code, '[^:]+', 1, 2)||regexp_substr(county_code, '[^:]+', 1, 3) fips_state_and_county,
                   huc_8,
                   min(case when event_date between to_date('01-JAN-1875', 'DD-MON-YYYY') and sysdate then event_date else null end) min_date,
                   max(case when event_date between to_date('01-JAN-1875', 'DD-MON-YYYY') and sysdate then event_date else null end) max_date,
                   count(distinct case when months_between(sysdate, event_date) between 0 and 12 then activity else null end) samples_past_12_months,
                   count(distinct case when months_between(sysdate, event_date) between 0 and 60 then activity else null end) samples_past_60_months,
                   count(distinct activity) samples_all_time
              from result_swap_!' || p_table_suffix || q'!
             where state_code between 'US:01' and 'US:56'
                group by data_source_id, regexp_substr(state_code, '[^:]+', 1, 2), regexp_substr(county_code, '[^:]+', 1, 3), huc_8!';

            create_table('qwportal_summary_swap_', p_table_suffix, sql_suffix);

        end if;

     end create_qwportal_summary;

     procedure create_indexes(p_table_suffix in user_tables.table_name%type) is
     begin

         create_station_sum_indexes(p_table_suffix);
         create_activity_sum_indexes(p_table_suffix);
         create_result_sum_indexes(p_table_suffix);
         create_organization_sum_idxs(p_table_suffix);

     end create_indexes;

    procedure create_station_sum_indexes(p_table_suffix in user_tables.table_name%type) is
        stmt       varchar2(32000);
        table_name user_tables.table_name%type;
    begin

        dbms_output.put_line('creating station_sum indexes...');
        table_name := dbms_assert.sql_object_name(upper('station_sum_swap_' || p_table_suffix));

        stmt := 'create bitmap index ss_' || p_table_suffix || '_country on ' || table_name || '(country_code) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_county on ' || table_name || '(county_code) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create index ss_' || p_table_suffix || '_geom on ' || table_name || q'!(geom) indextype is mdsys.spatial_index parameters ('SDO_INDX_DIMS=2 LAYER_GTYPE="POINT"')!';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc10 on ' || table_name || '(huc_10) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc12 on ' || table_name || '(huc_12) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc2 on ' || table_name || '(huc_2) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc4 on ' || table_name || '(huc_4) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc6 on ' || table_name || '(huc_6) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_huc8 on ' || table_name || '(huc_8) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_organization on ' || table_name || '(organization) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create unique index ss_' || p_table_suffix || '_pk on ' || table_name || '(data_source_id, station_id) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_site on ' || table_name || '(site_id) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_site_type on ' || table_name || '(site_type) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_state on ' || table_name || '(state_code) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index ss_' || p_table_suffix || '_station on ' || table_name || '(station_id) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

    end create_station_sum_indexes;

    procedure create_activity_sum_indexes(p_table_suffix in user_tables.table_name%type) is
        stmt       varchar2(32000);
        table_name user_tables.table_name%type;
    begin

        dbms_output.put_line('creating activity_sum indexes...');
        table_name := dbms_assert.sql_object_name(upper('activity_sum_swap_' || p_table_suffix));

        stmt := 'create bitmap index as_' || p_table_suffix || '_country on ' || table_name || '(country_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_county on ' || table_name || '(county_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_event_date on ' || table_name || '(event_date) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc10 on ' || table_name || '(huc_10) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc12 on ' || table_name || '(huc_12) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc2 on ' || table_name || '(huc_2) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc4 on ' || table_name || '(huc_4) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc6 on ' || table_name || '(huc_6) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_huc8 on ' || table_name || '(huc_8) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_organization on ' || table_name || '(organization) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_project on ' || table_name || '(project_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_sample_media on ' || table_name || '(sample_media) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_site on ' || table_name || '(site_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_site_type on ' || table_name || '(site_type) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_state on ' || table_name || '(state_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index as_' || p_table_suffix || '_station on ' || table_name || '(station_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

    end create_activity_sum_indexes;

    procedure create_result_sum_indexes(p_table_suffix in user_tables.table_name%type) is
        stmt       varchar2(32000);
        table_name user_tables.table_name%type;
    begin

        dbms_output.put_line('creating result_sum indexes...');
        table_name := dbms_assert.sql_object_name(upper('result_sum_swap_' || p_table_suffix));

        stmt := 'create bitmap index rs_' || p_table_suffix || '_analytical on ' || table_name || '(analytical_method) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_assemblage on ' || table_name || '(assemblage_sampled_name) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_char_name on ' || table_name || '(characteristic_name) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_char_type on ' || table_name || '(characteristic_type) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_country on ' || table_name || '(country_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_county on ' || table_name || '(county_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_event_date on ' || table_name || '(event_date) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc10 on ' || table_name || '(huc_10) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc12 on ' || table_name || '(huc_12) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc2 on ' || table_name || '(huc_2) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc4 on ' || table_name || '(huc_4) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc6 on ' || table_name || '(huc_6) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_huc8 on ' || table_name || '(huc_8) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_organization on ' || table_name || '(organization) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_p_code on ' || table_name || '(p_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_project on ' || table_name || '(project_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_sample_media on ' || table_name || '(sample_media) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_site on ' || table_name || '(site_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_site_type on ' || table_name || '(site_type) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_state on ' || table_name || '(state_code) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_station on ' || table_name || '(station_id) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

        stmt := 'create bitmap index rs_' || p_table_suffix || '_taxa_name on ' || table_name || '(sample_tissue_taxonomic_name) local parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

    end create_result_sum_indexes;

    procedure create_organization_sum_idxs(p_table_suffix in user_tables.table_name%type) is
        stmt       varchar2(32000);
        table_name user_tables.table_name%type;
    begin

        dbms_output.put_line('creating organization_sum indexes...');
        table_name := dbms_assert.sql_object_name(upper('organization_sum_swap_' || p_table_suffix));

        stmt := 'create bitmap index os_' || p_table_suffix || '_organization on ' || table_name || '(organization) parallel 4 nologging';
        dbms_output.put_line(stmt);
        execute immediate stmt;

    end create_organization_sum_idxs;

    procedure analyze_tables(p_table_suffix in user_tables.table_name%type) is
        suffix user_tables.table_name%type;
    begin

        suffix := dbms_assert.simple_sql_name(upper(p_table_suffix));

        dbms_output.put_line('analyze activity_sum...');
        dbms_stats.gather_table_stats(ownname => '${dataOwner}', tabname => 'ACTIVITY_SUM_SWAP_' || suffix, method_opt => 'FOR ALL INDEXED COLUMNS');

        dbms_output.put_line('analyze result_sum...');
        dbms_stats.gather_table_stats(ownname => '${dataOwner}', tabname => 'RESULT_SUM_SWAP_' || suffix, method_opt => 'FOR ALL INDEXED COLUMNS');

        dbms_output.put_line('analyze station_sum...');
        dbms_stats.gather_table_stats(ownname => '${dataOwner}', tabname => 'STATION_SUM_SWAP_' || suffix, method_opt => 'FOR ALL INDEXED COLUMNS');

    end analyze_tables;

    function validate_transformation(p_table_suffix in user_tables.table_name%type)
        return boolean is
        end_job boolean := false;
    begin

        if (upper(p_table_suffix) = 'STORET' or upper(p_table_suffix) = 'NWIS') then
            end_job := etl_helper_main.validate_table('qwportal_summary', 'summary_', p_table_suffix);
        end if;

        return end_job;

    end validate_transformation;

    procedure install(p_table_suffix in user_tables.table_name%type) is
        suffix user_tables.table_name%type;
    begin

        suffix := dbms_assert.simple_sql_name(p_table_suffix);

        dbms_output.put_line('organization_sum');
        execute immediate 'alter table organization_sum exchange partition organization_sum_' || suffix ||
                          ' with table organization_sum_swap_' || suffix || ' including indexes';

        dbms_output.put_line('station_sum');
        execute immediate 'alter table station_sum exchange partition station_sum_' || suffix ||
                          ' with table station_sum_swap_' || suffix || ' including indexes';

        dbms_output.put_line('activity_sum');
        execute immediate 'alter table activity_sum exchange partition activity_sum_' || suffix ||
                          ' with table activity_sum_swap_' || suffix || ' including indexes';

        dbms_output.put_line('result_sum');
        execute immediate 'alter table result_sum exchange partition result_sum_' || suffix ||
                          ' with table result_sum_swap_' || suffix || ' including indexes';

        if (suffix = 'storet' or suffix = 'nwis') then
            dbms_output.put_line('qwportal_summary');
            execute immediate 'alter table qwportal_summary exchange partition summary_' || suffix ||
                              ' with table qwportal_summary_swap_' || suffix || ' including indexes';
        end if;

    end install;

end etl_helper_summary;
/