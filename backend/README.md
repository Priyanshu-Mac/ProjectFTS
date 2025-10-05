# Express Server (TypeScript Minimal)

Minimal Express server implemented in TypeScript.

Quick start:

```bash
cd /path/to/express-server-fast
npm install
npm run build
npm start
```

Endpoints:
- GET / -> { message }
- GET /health -> { status: 'ok' }
- POST /echo -> echoes JSON body

Development (fast reload):

```bash
npm run dev
```

Database migrations
-------------------

If using Postgres, ensure your schema allows the new SLAReason event type:

Run:

```sql
-- backend/sql/20251005_add_sla_reason_event_type.sql
ALTER TABLE file_events DROP CONSTRAINT IF EXISTS file_events_action_type_check;
ALTER TABLE file_events
	ADD CONSTRAINT file_events_action_type_check
	CHECK (action_type IN ('Forward','Return','SeekInfo','Hold','Escalate','Close','Dispatch','Reopen','SLAReason'));
```
