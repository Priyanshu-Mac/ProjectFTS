-- Add SLAReason to allowed action_type values on file_events
ALTER TABLE file_events DROP CONSTRAINT IF EXISTS file_events_action_type_check;
ALTER TABLE file_events
  ADD CONSTRAINT file_events_action_type_check
  CHECK (action_type IN ('Forward','Return','SeekInfo','Hold','Escalate','Close','Dispatch','Reopen','SLAReason'));
