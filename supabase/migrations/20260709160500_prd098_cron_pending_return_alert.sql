-- PRD-098 WS-5: schedule the pending-return backlog alert (idempotent). Article 11: cron calls the RPC.
SELECT cron.schedule('prd098_pending_return_alert', '0 6 * * *', $$SELECT public.cron_pending_return_alert(3)$$);
