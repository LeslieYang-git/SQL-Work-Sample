CREATE OR REPLACE PROCEDURE DB.SCHEMA.RUN_PROCEDURE_GROUP("WORKFLOW_TABLE_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS 
$$
var SP_Names = [];
var failed_SPs = [];

try {
    // Get the SP names from the specified table
    var sql_command_1 = "SELECT procedure_name FROM " + WORKFLOW_TABLE_NAME + " ORDER BY SEQUENCE_ORDER";
    var stmt = snowflake.createStatement({sqlText: sql_command_1});
    var resultSet = stmt.execute();

    // Store the SP names in an array
    while (resultSet.next()) {
        SP_Names.push(resultSet.getColumnValue(1));
    }

    // Define a function to execute each SP sequentially
    async function executeSP(index) {
        try {
            // Dynamic SQL to call the SP
            var sql_command = "CALL " + SP_Names[index] + "()";
            var stmt2 = snowflake.createStatement({sqlText: sql_command});
            await stmt2.execute();

            // Check for errors in the PROCEDURE_ERROR_LOG table
            var sp_name = SP_Names[index].substr(SP_Names[index].lastIndexOf('.') + 1);
            var sql_command3 = "SELECT ERROR_MSG FROM (SELECT ERROR_MSG, ERROR_CODE, RANK() OVER (ORDER BY LOG_DATE DESC) AS RANK FROM DB.SCHEMA.PROCEDURE_ERROR_LOG WHERE PROC_NAME = ? AND DATE(LOG_DATE) = CURRENT_DATE()) AS T WHERE RANK = 1";
            var stmt3 = snowflake.createStatement({sqlText: sql_command3, binds:[sp_name]});
            var resultSet3 = await stmt3.execute(); // Add await here
            var error_msg = '';

            if (resultSet3.next()) {
                error_msg = resultSet3.getColumnValue(1);
            }

            if (error_msg != '') {
                // Log the error and add to the failed_SPs array
                var stmt4 = snowflake.createStatement({sqlText: "INSERT INTO DB.SCHEMA.PROCEDURE_RUN_LOG (procedure_name, status, error_message, Execute_Time) VALUES (?, 'Failed', ?, current_timestamp())", binds:[SP_Names[index], error_msg]});
                await stmt4.execute();
                failed_SPs.push(SP_Names[index] + ": " + error_msg);
            } else {
                // Log successful execution of the stored procedure along with the run time
                var stmt5 = snowflake.createStatement({sqlText: "INSERT INTO DB.SCHEMA.PROCEDURE_RUN_LOG (procedure_name, status, Execute_Time) VALUES (?, 'Success', current_timestamp())", binds:[SP_Names[index]]});
                await stmt5.execute();
            }
        } catch (err) {
            // Log the error if the stored procedure fails
            var error_msg = err.message.split('\\n')[0];  // Extract the error message
            var stmt6 = snowflake.createStatement({sqlText: "INSERT INTO DB.SCHEMA.PROCEDURE_RUN_LOG (procedure_name, status, error_message, Execute_Time) VALUES (?, 'Failed', ?, current_timestamp())", binds:[SP_Names[index], error_msg]});
            await stmt6.execute();

            // Add the failed SP name and error message to the failed_SPs array
            failed_SPs.push(SP_Names[index] + ": " + error_msg);
        }

        // If there are more SPs to execute, recursively call executeSP with the next index
        if (index + 1 < SP_Names.length) {
            await executeSP(index + 1);
        } else {
            // If all SPs are executed, compile an email with the results
            var email_body = 'For ' + WORKFLOW_TABLE_NAME.substring(WORKFLOW_TABLE_NAME.lastIndexOf(".") + 1) + ' workflow';

            if (failed_SPs.length > 0) {
                email_body += '\\n\\nThe following stored procedures failed:\\n' + failed_SPs.join('\\n');
                var stmt7 = snowflake.createStatement({sqlText: "CALL SYSTEM$SEND_EMAIL('EMAIL_INTEGRATION', 'EMAIL_RECIPIENT', 'ALERT for Workflow: " + WORKFLOW_TABLE_NAME.substring(WORKFLOW_TABLE_NAME.lastIndexOf(".") + 1) + "', ?)", binds:[email_body]});
                await stmt7.execute();
            }

            return email_body;
        }
    }

    // Start executing the first SP
    executeSP(0);

    return 'SP completed successfully';
    
} catch (err) {
    // Handle any errors that occur during execution
    return 'Error: ' + err.message;
}
$$;
