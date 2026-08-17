-----------------------------------------------------------------
-- Table to store results
CREATE OR REPLACE TABLE DB.SCHEMA.FORM_RESPONSE_FLAT (
	AUD_ROW_SEQ VARCHAR(16777216),
	AUDIT_MASTER_ID VARCHAR(255),
    AUDIT_INSTANCE_ID VARCHAR,
    AUDIT_ID VARCHAR,
    TITLE VARCHAR,
	QUESTION_DESCRIPTION VARCHAR(255),
	PARSED_QUESTION VARCHAR(16777216),
	PARSED_CURRENT_ANSWER VARCHAR(16777216),
	INSERT_DT_TM TIMESTAMP_NTZ(9)
);


-----------------------------------------------------------------
-- Procedure Creation
CREATE OR REPLACE PROCEDURE DB.SCHEMA.FLATTEN_JSON_RESPONSES(start_date STRING, end_date STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.8'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json
from snowflake.snowpark.functions import col, lit
from snowflake.snowpark import Session

# Function to flatten JSON with proper handling for list indices
def flatten_json(data, prefix=''):
    items = {}
    if isinstance(data, dict):
        for key, value in data.items():
            new_key = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                items.update(flatten_json(value, new_key))
            elif isinstance(value, list):
                # Handle list indexing explicitly by adding the index [0], [1], etc.
                for i, item in enumerate(value):
                    indexed_key = f"{new_key}[{i}]"
                    if isinstance(item, dict):
                        items.update(flatten_json(item, indexed_key))
                    else:
                        items[indexed_key] = str(item)
            else:
                items[new_key] = str(value)
    elif isinstance(data, list):
        for i, item in enumerate(data):
            indexed_key = f"{prefix}[{i}]"
            if isinstance(item, dict):
                items.update(flatten_json(item, indexed_key))
            else:
                items[indexed_key] = str(item)
    else:
        items[prefix] = str(data)
    return items

# Parse JSON cell function, keeping non-JSON values intact
def parse_json_cell(cell_value: str) -> dict:
    if not cell_value or cell_value == '{}' or cell_value.lower() == 'null':
        return {}
    try:
        # Attempt to parse JSON
        data = json.loads(cell_value)
        return flatten_json(data)
    except json.JSONDecodeError:
        # If it's not valid JSON, treat it as a string value, similar to Python
        return {cell_value: cell_value}

# Main procedure logic
def main(session: Session, start_date: str, end_date: str) -> str:
    print("Starting the procedure")

    try:
        # Step 1: Truncate the output table to ensure only the latest run results are kept
        output_table = 'DB.SCHEMA.FORM_RESPONSE_FLAT'
        session.sql(f"TRUNCATE TABLE {output_table}").collect()
        print(f"Table {output_table} truncated successfully")

        # Step 2: Read certain columns from the source table where load_dt_tm is within the given range
        df = session.table('DB.SCHEMA.FORM_RESPONSE_STAGE').select(
            col('aud_row_seq'),
            col('audit_master_id'),
            col('audit_instance_id'),
            col('audit_id'),
            col('title'),
            col('questiondescription'),
            col('currentanswer')
        ).filter(
            (col('load_dt_tm') >= lit(start_date)) & (col('load_dt_tm') <= lit(end_date))
        )
        print(f"Data fetched from the source table for the date range: {start_date} to {end_date}")

        # Step 3: Collect the rows
        data = df.collect()
        print(f"Total rows fetched: {len(data)}")

        parsed_rows = []
        for row in data:
            aud_row_seq = row['AUD_ROW_SEQ']
            audit_master_id = row['AUDIT_MASTER_ID']
            audit_instance_id = row['AUDIT_INSTANCE_ID']
            audit_id = row['AUDIT_ID']
            title = row['TITLE']
            question_description = row['QUESTIONDESCRIPTION']
            current_answer = row['CURRENTANSWER']
            
            print(f"Processing row: AUD_ROW_SEQ={aud_row_seq}, AUDIT_MASTER_ID={audit_master_id}, AUDIT_INSTANCE_ID={audit_instance_id}, AUDIT_ID={audit_id}, TITLE={title}")

            # Parse the JSON content from CURRENTANSWER or keep it as a string if it is non-JSON
            parsed_data = parse_json_cell(current_answer)
            print(f"Parsed data: {parsed_data}")
            
            if parsed_data:
                for parsed_question, parsed_current_answer in parsed_data.items():
                    # Cast current timestamp to TIMESTAMP_NTZ
                    current_timestamp_ntz = session.sql("SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ").collect()[0][0]
                    parsed_rows.append((
                        aud_row_seq,
                        audit_master_id,
                        audit_instance_id,
                        audit_id,
                        title,
                        question_description,
                        parsed_question,
                        parsed_current_answer,
                        current_timestamp_ntz  # Insert current timestamp (casted to TIMESTAMP_NTZ)
                    ))
            else:
                # Cast current timestamp to TIMESTAMP_NTZ
                current_timestamp_ntz = session.sql("SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ").collect()[0][0]
                parsed_rows.append((
                    aud_row_seq,
                    audit_master_id,
                    audit_instance_id,
                    audit_id,
                    title,
                    question_description,
                    None,
                    None,
                    current_timestamp_ntz  # Insert current timestamp (casted to TIMESTAMP_NTZ)
                ))

        # Step 4: Insert parsed data into the target table
        if parsed_rows:
            # Define the schema of the output data
            df_parsed = session.create_dataframe(
                parsed_rows,
                schema=['AUD_ROW_SEQ', 'AUDIT_MASTER_ID', 'AUDIT_INSTANCE_ID', 'AUDIT_ID', 'TITLE', 'QUESTION_DESCRIPTION', 'PARSED_QUESTION', 'PARSED_CURRENT_ANSWER', 'INSERT_DT_TM']
            )
            
            print(f"Inserting {len(parsed_rows)} rows into {output_table}")
            df_parsed.write.mode('append').save_as_table(output_table)
        else:
            print("No parsed rows to insert")

        print("Procedure executed successfully")
        return f"Data parsed and inserted successfully. Rows processed: {len(parsed_rows)}"
    
    except Exception as e:
        print(f"Error during execution: {e}")
        return f"Failed with error: {e}"

$$;
