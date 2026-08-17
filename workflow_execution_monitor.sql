------------------------------------------------------------------
-- CREATE/target environment Deployment
-- QA Check for target environment Procedure
CREATE OR REPLACE PROCEDURE DB.SCHEMA.MONITOR_WORKFLOW_EXECUTIONS(WORKFLOW_TABLE_LIST VARCHAR)
RETURNS STRING
LANGUAGE JAVASCRIPT
AS
$$
    // Function to send email
    function sendEmail(subject, body) {
        var send_email_sql = `CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'EMAIL_RECIPIENT',
            ?,
            ?
        )`;
        var email_stmt = snowflake.createStatement({
            sqlText: send_email_sql,
            binds: [subject, body]
        });
        email_stmt.execute();
    }

    // Query the workflow table list to get all workflow tables
    var sql_fetch_workflows = "SELECT workflow_name FROM " + WORKFLOW_TABLE_LIST;
    var stmt_workflows = snowflake.createStatement({sqlText: sql_fetch_workflows});
    var result_workflows = stmt_workflows.execute();
    
    var workflow_tables = [];
    while (result_workflows.next()) {
        workflow_tables.push(result_workflows.getColumnValue(1));
    }
    
    // For each workflow table, get the procedure names inside the workflow table
    var all_procedure_names = []; 
    var workflow_procedure_map = {}; // Map to track which workflow table each procedure comes from
    
    for (var i = 0; i < workflow_tables.length; i++) {
        var workflow_table = workflow_tables[i];
        var sql_fetch_procedures = "SELECT procedure_name FROM " + workflow_table + " ORDER BY SEQUENCE_ORDER";
        
        try {
            var stmt_procedures = snowflake.createStatement({sqlText: sql_fetch_procedures});
            var result_procedures = stmt_procedures.execute();
            
            // Get short workflow name from the full workflow name 
            var workflow_short_name = workflow_table.split('.').pop();
            
            while (result_procedures.next()) {
                var full_path = result_procedures.getColumnValue(1);
                
                // Extract just the procedure name part (SP_XXX) from the procedure name
                var sp_pattern = /SP_[A-Za-z0-9_]+/i;
                var match = full_path.match(sp_pattern);
                if (match) {
                    var proc_name = match[0].toUpperCase(); 
                    all_procedure_names.push(proc_name);
                    
                    // Track which workflow this procedure comes from
                    if (!workflow_procedure_map[proc_name]) {
                        workflow_procedure_map[proc_name] = [];
                    }
                    workflow_procedure_map[proc_name].push(workflow_short_name);
                }
            }
        } catch (err) {
            // Log error and continue with other workflow tables
            snowflake.execute({
                sqlText: "INSERT INTO DB.SCHEMA.WORKFLOW_MONITOR_ERROR_LOG (ERROR_SOURCE, ERROR_MESSAGE, ERROR_TIMESTAMP) VALUES (?, ?, CURRENT_TIMESTAMP())",
                binds: ["MONITOR_WORKFLOW_EXECUTIONS", "Error querying workflow table " + workflow_table + ": " + err.message]
            });
        }
    }
    
    // Remove duplicates 
    all_procedure_names = [...new Set(all_procedure_names)];
    
    if (all_procedure_names.length === 0) {
        return "No valid procedure names found in any workflow tables. Please check the workflow table list.";
    }
    
    // SQL to check for missing procedures and get successfully refreshed procedures
    var sql_check_status = `
    SELECT 
        LISTAGG(CASE WHEN today_status IS NULL THEN proc_name ELSE NULL END, ', ') 
            WITHIN GROUP (ORDER BY proc_name) as missing_procedures,
        LISTAGG(CASE WHEN today_status IS NOT NULL THEN proc_name ELSE NULL END, ', ') 
            WITHIN GROUP (ORDER BY proc_name) as present_procedures
    FROM (
        SELECT 
            input_procs.proc_name,
            MAX(CASE WHEN DATE(log_dt) = CURRENT_DATE() THEN 1 ELSE NULL END) as today_status
        FROM (
            SELECT TRIM(value) as proc_name
            FROM TABLE(FLATTEN(INPUT => PARSE_JSON(?)))
        ) input_procs
        LEFT JOIN DB.SCHEMA.PROCEDURE_RUN_STATUS status
            ON input_procs.proc_name = status.sp_name
            AND DATE(CONVERT_TIMEZONE('UTC', status.log_dt)) = DATE(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))
        GROUP BY input_procs.proc_name
    )`;
    
    // Execute the SQL to check procedure status
    var stmt_status = snowflake.createStatement({
        sqlText: sql_check_status,
        binds: [JSON.stringify(all_procedure_names)]
    });
    var result_status = stmt_status.execute();
    
    var missing_procedures_list = '';
    var present_procedures = '';
    
    if (result_status.next()) {
        missing_procedures_list = result_status.getColumnValue(1);
        present_procedures = result_status.getColumnValue(2);
    }
    
    // Send email for any missing procedures 
    if (missing_procedures_list) {
        var missing_procedures = missing_procedures_list.split(', ');
        
        // Group missing procedures by workflow
        var workflow_missing_map = {};
        
        for (var j = 0; j < missing_procedures.length; j++) {
            var proc_name = missing_procedures[j];
            var source_workflows = workflow_procedure_map[proc_name] || ["Unknown Workflow"];
            
            // Deduplicate source workflows
            source_workflows = [...new Set(source_workflows)];
            
            for (var k = 0; k < source_workflows.length; k++) {
                var wf = source_workflows[k];
                if (!workflow_missing_map[wf]) {
                    workflow_missing_map[wf] = [];
                }
                workflow_missing_map[wf].push(proc_name);
            }
        }
        
        // Build email body grouped by workflows
        var email_subject = "ALERT: Missing Procedure Executions for workflows in " + WORKFLOW_TABLE_LIST;
        var email_body = "The following procedures were not found in ANALYTICS_PROD.PROCEDURE_RUN_STATUS for today:\n\n";
        
        for (var workflow in workflow_missing_map) {
            email_body += "Workflow: " + workflow + "\n";
            email_body += "- " + workflow_missing_map[workflow].join("\n- ") + "\n\n";
        }
        
        sendEmail(email_subject, email_body);
    }
    
    // Proceed to check row count differences for succeed procedures
    if (present_procedures) {
        var procedure_list = present_procedures.split(', ').map(name => "'" + name + "'").join(',');
        var sql_check_diff = `
        WITH today_stats AS (
            SELECT sp_name, row_count AS today_count
            FROM DB.SCHEMA.PROCEDURE_RUN_STATUS
            WHERE DATE(CONVERT_TIMEZONE('UTC', log_dt)) = DATE(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))
            AND sp_name IN (${procedure_list})
        ),
        yesterday_stats AS (
            SELECT sp_name, row_count AS yesterday_count
            FROM DB.SCHEMA.PROCEDURE_RUN_STATUS
            WHERE DATE(CONVERT_TIMEZONE('UTC', log_dt)) = DATEADD(day, -1, DATE(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())))
            AND sp_name IN (${procedure_list})
        )
        SELECT 
            t.sp_name,
            t.today_count,
            y.yesterday_count,
            ROUND(((t.today_count - y.yesterday_count) / NULLIF(y.yesterday_count, 0) * 100), 2) as percentage_diff
        FROM today_stats t
        JOIN yesterday_stats y ON t.sp_name = y.sp_name
        WHERE ABS(((t.today_count - y.yesterday_count) / NULLIF(y.yesterday_count, 0) * 100)) > 10
        `;
        
        // Execute the SQL to check row count differences
        var stmt_diff = snowflake.createStatement({sqlText: sql_check_diff});
        var result_diff = stmt_diff.execute();
        
        var significant_diff_procedures = [];
        var workflow_diff_map = {};
        
        // Process the results and group by workflow
        while (result_diff.next()) {
            var proc_name = result_diff.getColumnValue(1);
            var today_count = result_diff.getColumnValue(2);
            var yesterday_count = result_diff.getColumnValue(3);
            var percentage_diff = result_diff.getColumnValue(4);
            
            // Get workflow for this procedure
            var source_workflows = workflow_procedure_map[proc_name] || ["Unknown Workflow"];
            source_workflows = [...new Set(source_workflows)];
            
            var proc_info = proc_name + ' (' + percentage_diff + '%, ' + yesterday_count + ' -> ' + today_count + ')';
            significant_diff_procedures.push(proc_info);
            
            // Group by workflow for the email
            for (var m = 0; m < source_workflows.length; m++) {
                var wf = source_workflows[m];
                if (!workflow_diff_map[wf]) {
                    workflow_diff_map[wf] = [];
                }
                workflow_diff_map[wf].push(proc_info);
            }
        }
        
        if (significant_diff_procedures.length > 0) {
            var email_subject = "ALERT: Significant Row Count Differences for workflows in " + WORKFLOW_TABLE_LIST;
            var email_body = "The following procedures have a row count difference > 10% compared to yesterday:\n\n";
            
            for (var workflow in workflow_diff_map) {
                email_body += "Workflow: " + workflow + "\n";
                email_body += "- " + workflow_diff_map[workflow].join("\n- ") + "\n\n";
            }
            
            sendEmail(email_subject, email_body);
            return "Emails sent for missing procedures and significant row count differences.";
        }
    }
    
    if (missing_procedures_list) {
        return "Email sent for missing procedures. No significant row count differences found for present procedures.";
    } else {
        return "All procedures from workflows in " + WORKFLOW_TABLE_LIST + " were found and have no significant row count differences.";
    }
$$;



-- create workflow check table for ANALYTICS Daily Workflows
CREATE OR REPLACE TABLE DB.SCHEMA.DAILY_WORKFLOW_TABLE_LIST(
    workflow_name VARCHAR,
    Update_Date TIMESTAMP
);



