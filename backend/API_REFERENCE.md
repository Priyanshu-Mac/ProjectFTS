# API Reference

This document describes the server routes, request payloads, and example responses for the current Express + TypeScript API.

Notes
- `x-user-id` header is used by routes to infer the acting user (set it in requests to simulate authentication).
- Attachments are accepted as JSON metadata (e.g. `{file_name, file_type, file_path}`); multipart/binary upload is not implemented yet.
- `save_as_draft: true` prevents starting the SLA clock and creating the initial Forward event.
- SLA calculations use the DB function `calculate_business_minutes` when running with the Postgres adapter; the memory adapter approximates.

---

## Routes (summary table)

| Route | Method | Request (headers + payload) | Example response |
|---|---:|---|---|
| `/` | GET | None | 200 OK  
```json
{ "message": "Hello from Express + TypeScript + Zod!" }
```
| `/health` | GET | None | 200 OK  
```json
{ "status": "ok" }
# Full API Reference (frontend-ready)

Complete reference of implemented routes, request/response schemas, validation rules, enums and examples. Give this document to frontend developers as the canonical contract. Where an endpoint or feature isn't implemented yet, it is marked "(NOT IMPLEMENTED)" and a suggested contract is provided.

Quick notes
- Auth: No full auth implemented. The server uses header `x-user-id` to infer the acting user for events — include it in requests to simulate the authenticated user.
- Attachments: currently accepted as JSON metadata in `attachments` arrays. Binary multipart uploads are not yet implemented (see "Suggested endpoints" below).
- Drafts: `save_as_draft: true` creates a file record but does NOT create the initial event or start the SLA timer.
- SLA calculations: Postgres adapter uses DB function `calculate_business_minutes` and SLA policy rows (`sla_policies`) for thresholds and pause behavior; memory adapter approximates and is for local/dev use only.

---

## Global enums and conventions

- Action types for events: `Forward`, `Return`, `SeekInfo`, `Hold`, `Escalate`, `Close`, `Dispatch`, `Reopen`.
- File statuses: `Open`, `WithOfficer`, `WithCOF`, `Dispatched`, `OnHold`, `WaitingOnOrigin`, `Closed`.
- Priority: `Routine`, `Urgent`, `Critical`.
- Date handling: date strings (ISO 8601). `date_received_accounts` and `date_initiated` accepted; server will COALESCE to CURRENT_DATE if omitted when creating files.
- Attachments: array of objects: `{ file_name, file_type, file_path }` (metadata only).
- Pagination: `page` (1-based) and `limit` (max 500 enforced by server; default 50).

---

## Common HTTP headers

- `Content-Type: application/json` for JSON requests.
- `x-user-id: <numeric>` recommended for endpoints that depend on the actor (events). This simulates the currently-acting user.

---

## Routes and detailed contracts

Each route below includes: path, method, required headers, request schema, validation rules, success response shape, common error responses, and example curl.

### 1) GET /
- Purpose: health / basic info.
- Request: none.
- Response 200 OK:
```json
{ "message": "Hello from Express + TypeScript + Zod!" }
```

### 2) GET /health
- Purpose: health check.
- Response 200 OK:
```json
{ "status": "ok" }
```

### 3) POST /echo
- Purpose: development helper.
- Headers: `Content-Type: application/json`.
- Request body schema (Zod EchoSchema):
```json
{ "name": "string (required)", "msg": "string (optional)" }
```
- Response 200 OK:
```json
{ "received": { "name": "Alice", "msg": "hello" } }
```

### 4) POST /files (Create / Intake)
- Purpose: Intake a new file record. If `save_as_draft` is false (default), creates initial Forward event and starts SLA timer.
- Headers: `Content-Type: application/json`, optional `x-user-id`.
- Request body (FileCreateSchema):

Required fields:
- `subject` (string)
- `notesheet_title` (string)
- `owning_office_id` (integer)
- `category_id` (integer)
- `forward_to_officer_id` (integer) — required unless `save_as_draft` is true

Optional fields:
- `sla_policy_id` (integer)
- `priority` ("Routine"|"Urgent"|"Critical")
- `confidentiality` (boolean)
- `date_initiated` (ISO date string)
- `date_received_accounts` (ISO date string)
- `attachments` (array of metadata objects)
- `remarks` (string)
- `save_as_draft` (boolean)

- Validation: enforced by Zod. Missing required fields => 400.

- Success response (201 Created) — non-draft:
```json
{
  "file": { /* file object (see File object schema below) */ },
  "checklist": { "initiation_date_present": true, "has_attachments": false, "priority_set": true },
  "duplicates": [ /* zero or more file objects with similar subject within last 30 days */ ]
}
```

- Success response (201 Created) — draft (save_as_draft=true):
```json
{ "file": { /* file object */ }, "checklist": { ... }, "duplicates": [...] }
```
Note: drafts don't create the initial event and `current_holder_user_id` will be null.

- Error responses:
- 400 Bad Request — validation errors (returns Zod error format)

- Example curl
```bash
curl -X POST 'http://localhost:3000/files' \
  -H 'Content-Type: application/json' \
  -H 'x-user-id: 5' \
  -d '{
    "subject":"Q3 Budget Approval",
    "notesheet_title":"Approval notesheet",
    "owning_office_id":1,
    "category_id":2,
    "forward_to_officer_id":11,
    "priority":"Routine",
    "remarks":"Intake"
  }'
```

---

### 5) GET /files (List / Search)
- Purpose: Search / list files with filters and pagination.
- Query parameters (all optional):
- `q` (string) — matches file_no, subject or notesheet_title via ILIKE `%q%`.
- `office` (int) — owning_office_id
- `category` (int) — category_id
- `status` (string) — file status
- `sla_policy_id` (int)
- `holder` (int) — current_holder_user_id
- `page` (int) — 1-based (default 1)
- `limit` (int) — default 50, max 500
- `date_from` / `date_to` — ISO date strings to filter created_at range

- Success response 200 OK (paginated):
```json
{
  "total": 123,
  "page": 1,
  "limit": 50,
  "results": [ /* array of File objects */ ]
}
```

---

### 6) GET /files/:id (Get file details)
- Purpose: Retrieve single file record.
- Path param: `id` (integer)
- Response 200 OK: file object (see schema below)
- 404 Not Found if ID missing.

---

### 7) GET /files/:id/sla (SLA status)
- Purpose: Compute SLA consumption for a file.
- Path param: `id`.
- Response 200 OK:
```json
{
  "sla_minutes": 1440,
  "consumed_minutes": 360,
  "percent_used": 25,
  "status": "On-track", // 'On-track' | 'Warning' | 'Breach'
  "remaining_minutes": 1080
}
```

- Notes:
- Uses `files.sla_policy_id` to look up `sla_policies` (sla_minutes, warning_pct, escalate_pct, pause_on_hold).
- Closed events sum uses `file_events.business_minutes_held` (trigger populates this on ended_at).
- Ongoing open event minutes are computed with `public.calculate_business_minutes(started_at, now())` when using Postgres adapter.
- If SLA policy `pause_on_hold = true`, durations of events with `action_type` IN ('Hold','SeekInfo') are excluded from SLA consumption.

---

### 8) GET /files/:id/events (List events for a file)
- Purpose: Get the immutable ledger for a file.
- Response 200 OK: array of event objects in seq order.

Event object example:
```json
{
  "id":501,
  "file_id":123,
  "seq_no":1,
  "from_user_id":null,
  "to_user_id":11,
  "action_type":"Forward",
  "started_at":"2025-09-30T10:00:00.000Z",
  "ended_at":"2025-09-30T12:30:00.000Z",
  "business_minutes_held":150,
  "remarks":"Initial forward",
  "attachments_json":[]
}
```

---

### 9) POST /files/:id/events (Append an event / Movement)
- Purpose: Append an immutable event to a file (hand-off, hold, seek info, escalate, close, etc.).
- Headers: `Content-Type: application/json`, recommended `x-user-id` to identify actor.
- Request body (EventCreateSchema):
```json
{
  "to_user_id": 12,            // required for many action types
  "action_type": "Forward",  // enum; required
  "remarks": "...",
  "attachments": [ /* same shape as file attachments */ ]
}
```

- Server behavior and guards:
- `from_user_id` is auto-derived from last event or file.current_holder_user_id; route fills this automatically.
- `to_user_id` is required for action types: Forward, Return, SeekInfo, Escalate, Dispatch (route enforces this).
- `remarks` is required for Hold and Escalate (route enforces this).
- On SeekInfo, the server (PG adapter) will insert a `query_threads` row linking the file to the clarification request. (There is no dedicated /files/:id/queries route implemented yet.)

- Successful response: 201 Created — the created event object.
- Error responses: 400 Bad Request for validation/guards; 404 if file not found; DB errors propagate as 500.

- Example curl
```bash
curl -X POST 'http://localhost:3000/files/123/events' \
  -H 'Content-Type: application/json' \
  -H 'x-user-id: 11' \
  -d '{ "to_user_id": 12, "action_type": "Forward", "remarks": "Please verify" }'
```

---

### 10) GET /dashboards/summary
- Purpose: Minimal executive KPIs implemented by current backend (total_open, avg_tat_days).
- Response 200 OK:
```json
{ "total_open": 27, "avg_tat_days": 1.75 }
```

---

### 11) GET /internal/db
- Purpose: diagnostics (which adapter in use and counts).
- Response 200 OK:
```json
{ "usingPg": true, "files_count": 123, "events_count": 456 }
```

---

## Data schemas (full)

### FileCreate (request)
- subject: string (required)
- notesheet_title: string (required)
- owning_office_id: integer (required)
- category_id: integer (required)
- forward_to_officer_id: integer (required unless draft)
- sla_policy_id: integer (optional)
- priority: enum (Routine|Urgent|Critical)
- confidentiality: boolean
- date_initiated: ISO date
- date_received_accounts: ISO date
- attachments: array of { file_name, file_type, file_path }
- remarks: string
- save_as_draft: boolean

### File (response)
- id: integer
- file_no: string (ACC-YYYYMMDD-XX)
- subject, notesheet_title
- owning_office_id, category_id
- priority
- date_initiated, date_received_accounts
- current_holder_user_id
- status (enum)
- confidentiality
- sla_policy_id
- created_by, created_at
- attachments: array of metadata

### EventCreate (request)
- action_type: enum (Forward, Return, SeekInfo, Hold, Escalate, Close, Dispatch, Reopen)
- to_user_id: integer (required for most actions)
- remarks: string (required for Hold/Escalate)
- attachments: array of metadata

### Event (response)
- id, file_id, seq_no, from_user_id, to_user_id, action_type, started_at, ended_at, business_minutes_held, remarks, attachments_json

### SLA Policy (read from DB)
- id, category_id, sla_minutes (integer), name, warning_pct (int), escalate_pct (int), pause_on_hold (boolean), notify_role (string), notify_user_id (int), notify_channel (jsonb), auto_escalate (boolean), active (boolean), description, created_at, updated_at

---

## Errors and validation

- 400 Bad Request: validation error (Zod) or missing required fields. Response example:
```json
{ "error": { /* zod formatted error */ } }
```
- 404 Not Found: file/event not found. Example:
```json
{ "error": "not found" }
```
- 500 Internal Server Error: DB errors or unexpected exceptions. Example (PG FK violation):
```json
{ "error": "insert or update on table \"file_events\" violates foreign key constraint" }
```

---

## Pagination and performance notes

- The list endpoints return `{ total, page, limit, results }`.
- `limit` defaults to 50, and the PG adapter caps it at 500 to avoid very large responses.

---

## Suggestions for the frontend (UX contract)

- Intake form (File Receiving): show required fields, quick checklist (initiation_date_present, attachments, priority) — server returns this checklist in the create response.
- Draft flow: if user chooses Save Draft, call POST /files with `save_as_draft: true`.
- After successful create (non-draft) the server will have created an initial Forward event and set the file `current_holder_user_id` to the forwarded officer.
- To display SLA live status, poll GET /files/:id/sla (or refresh on event create).
- For Seek Clarification, server will create a `query_threads` row on SeekInfo. There is no dedicated endpoint for queries yet; if you need one I can add `GET /files/:id/queries` and `POST /files/:id/queries`.

---

## Suggested (NOT IMPLEMENTED) endpoints for frontend convenience

These are suggestions you can request to be implemented if desired:
- `GET /files/:id/queries` — list query threads for a file (returns `query_threads` rows).
- `POST /files/:id/queries` — create a query thread (alternative to SeekInfo event).
- `POST /files/:id/attachments` (multipart/form-data) — upload binary attachments and return stored metadata.
- `GET /reports/pendency` — advanced reports used by dashboards.

If you want any of these implemented I can add them and provide API examples.

---

## Quick curl examples

- Create and start SLA (JSON):
```bash
curl -X POST 'http://localhost:3000/files' -H 'Content-Type: application/json' -H 'x-user-id: 5' -d '{ "subject":"Q3 Budget Approval","notesheet_title":"Notesheet","owning_office_id":1,"category_id":2,"forward_to_officer_id":11 }'
```

- Create draft (no SLA start):
```bash
curl -X POST 'http://localhost:3000/files' -H 'Content-Type: application/json' -d '{ "subject":"Draft item","notesheet_title":"Draft","owning_office_id":1,"category_id":2,"forward_to_officer_id":11, "save_as_draft": true }'
```

- Append an event (Forward):
```bash
curl -X POST 'http://localhost:3000/files/123/events' -H 'Content-Type: application/json' -H 'x-user-id: 11' -d '{"to_user_id":12,"action_type":"Forward","remarks":"Please check"}'
```

- Get SLA for a file:
```bash
curl -sS 'http://localhost:3000/files/123/sla' | jq
```

---

## Deliverables you can give frontend

1. This `API_REFERENCE.md` file (canonical contract).
2. One or more example JSON payload files (I can add them to repo on request).
3. Postman collection or OpenAPI spec (I can generate either).

---

Last updated: 2025-09-30
