# Files API (Complete Reference)

This document describes every `/files` route implemented in the server, including query parameters, request bodies, response shapes, examples, and behaviour notes. It's intended to be copied to front-end teams as a single source of truth.

Base route: `/files`

## List files

- Method: GET
- Path: `/files`
- Purpose: Return a paginated list of files matching optional filters.
- Query parameters (all optional):
  - `q` (string): full-text like search across `file_no`, `subject`, and `notesheet_title`.
  - `office` (integer): `owning_office_id` equality filter.
  - `category` (integer): `category_id` equality filter.
  - `status` (string): equality filter on `status` (e.g., `Open`, `WithOfficer`, `Closed`).
  - `sla_policy_id` (integer): equality filter on SLA policy id.
  - `holder` (integer): `current_holder_user_id` equality filter.
  - `page` (integer): page number (1-based). Default: `1`.
  - `limit` (integer): page size (max 500). Default: `50`.
  - `date_from` (string): filter `created_at >= date_from` (ISO date expected).
  - `date_to` (string): filter `created_at <= date_to` (ISO date expected).

Server-side schema (Zod):
```
FileListQuery = {
  q?: string,
  office?: number,
  category?: number,
  status?: string,
  sla_policy_id?: number,
  holder?: number,
  page?: number,
  limit?: number,
  date_from?: string,
  date_to?: string,
}
```

Example request:

```bash
GET /files?q=loan&office=2&page=1&limit=25
```

Successful response (200): returns whatever the `listFiles` adapter returns. Typical shape from the PG adapter:

```json
{
  "total": 123,
  "page": 1,
  "limit": 25,
  "results": [
    { /* file object */ }
  ]
}
```

The `file` object contains the columns from the `files` table (see DB schema). The memory adapter returns an array in `results` too. The route will return 400 if any query param fails validation.


## Create a file

- Method: POST
- Path: `/files`
- Purpose: Create a new file record. Optionally creates an initial `Forward` event unless the file is saved as a draft.
- Content-Type: application/json

Request body schema (Zod):
```
FileCreateSchema = {
  subject: string (min 1),
  notesheet_title: string (min 1),
  owning_office_id: integer (>0),
  category_id: integer (>0),
  sla_policy_id?: integer (>0),
  priority?: 'Routine'|'Urgent'|'Critical',
  confidentiality?: boolean,
  date_initiated?: string,
  date_received_accounts?: string,
  forward_to_officer_id: integer (>0),
  attachments?: array<any>,
  save_as_draft?: boolean,
  remarks?: string,
}
```

Notes on fields
- `forward_to_officer_id`: used to set `current_holder_user_id` when not saving as draft; also used to create the initial Forward event when `save_as_draft` is false.
- `save_as_draft`: if true, the server will create the file but will NOT create the initial `Forward` event and will keep `current_holder_user_id` null.
- `attachments`: currently treated as metadata (array of objects). Binary multipart-upload is not implemented; attachments should be an array of metadata objects (filename, size, etc.) if the client chooses to use it.

Example request body:
```json
{
  "subject": "Loan application",
  "notesheet_title": "Review notes",
  "owning_office_id": 2,
  "category_id": 5,
  "forward_to_officer_id": 12,
  "priority": "Urgent",
  "attachments": [{"filename":"form.pdf","size":12345}],
  "save_as_draft": false,
  "remarks": "Please handle urgently."
}
```

Successful response (201):

```json
{
  "file": { /* inserted file row */ },
  "checklist": {
    "initiation_date_present": false,
    "has_attachments": true,
    "priority_set": true
  },
  "duplicates": [ /* list of similar files from last 30 days */ ]
}
```

Behaviour details
- If `save_as_draft` is false (or missing), the server will call `addEvent(file.id, { to_user_id: forward_to_officer_id, action_type: 'Forward', remarks, attachments_json })` to create an initial Forward event.
- The `checklist` is a simple set of booleans used by the front-end to show missing pieces.
- `duplicates` uses a naive `listFiles({ q: subject, date_from: (now - 30 days), limit: 10 })` search to surface likely duplicates.
- The server generates `file_no` automatically using `generateFileNo` when not provided.
- If validation fails, response is 400 with zod error object.


## Get a file

- Method: GET
- Path: `/files/:id`
- Purpose: Retrieve a single file by numeric id.

Responses
- 200: returns the file object (columns from the `files` table)
- 404: `{ "error": "not found" }` if no file with that id exists

Example:
```
GET /files/42
```


## Get SLA status for a file

- Method: GET
- Path: `/files/:id/sla`
- Purpose: Return the SLA consumption and status for a given file.

Responses
- 200: returns an object with SLA info
- 404: `{ "error": "file not found" }` if file doesn't exist

Example successful response:
```json
{
  "sla_minutes": 1440,
  "consumed_minutes": 120,
  "percent_used": 8,
  "status": "On-track",
  "remaining_minutes": 1320
}
```

Notes
- The PG adapter uses `public.calculate_business_minutes(start, now)` to compute ongoing minutes for open events and respects `sla_policies.pause_on_hold` to optionally exclude durations from Hold/SeekInfo events.
- The memory adapter approximates ongoing minutes as 0 and simulates policy values.


## Errors and validation

- Validation errors return HTTP 400 with the Zod-formatted error object.
- Not found returns 404 where relevant.
- Server errors return 500.


## Helpful curl examples

Create a file (draft):
```bash
curl -X POST http://localhost:3000/files \
  -H "Content-Type: application/json" \
  -d '{"subject":"Test","notesheet_title":"T","owning_office_id":1,"category_id":1,"forward_to_officer_id":2,"save_as_draft":true}'
```

List files with pagination:
```bash
curl "http://localhost:3000/files?page=1&limit=20"
```

Get SLA for a file:
```bash
curl http://localhost:3000/files/123/sla
```


## Recommendations & next steps
- If you expect large data volumes, change `GET /files` to perform SQL aggregations and cursor-based pagination.
- Implement multipart upload endpoints for attachments and store files in object storage (S3) rather than uploading metadata-only JSON.
- Replace `forward_to_officer_id` with an explicit `assigned_to` field if you want clearer semantics.

---
This documentation was generated from the live server code in `src/routes/files.ts` and `src/schemas/file.ts`.
