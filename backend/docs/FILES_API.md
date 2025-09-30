POST /files

Create a new file record. The API accepts these fields (most have DB defaults):

- file_no (string) - optional, unique; server can generate when omitted
- subject (string) - required
- notesheet_title (string) - required
- owning_office_id (integer)
- category_id (integer)
- priority (string) - optional but present in DB schema
- date_initiated (YYYY-MM-DD) - optional, defaults to CURRENT_DATE
- date_received_accounts (YYYY-MM-DD) - optional, defaults to CURRENT_DATE
- current_holder_user_id (integer)
- status (string) - defaults to 'Open'
- confidentiality (boolean) - defaults to false
- sla_policy_id (integer)
- created_by (integer)

Example curl:

curl -X POST "http://localhost:3000/files" -H "Content-Type: application/json" -d '{"subject":"Test","notesheet_title":"T","priority":"Routine"}'
