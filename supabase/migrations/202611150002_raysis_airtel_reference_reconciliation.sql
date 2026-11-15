-- Raysis V2: Airtel Money manual reference reconciliation
-- Requires a customer-supplied transaction reference for Airtel Money entries
-- at the app layer, and prevents reuse of a reference in the payment ledger.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS payments_airtel_reference_uidx
ON public.payments (LOWER(BTRIM(reference_number)))
WHERE LOWER(BTRIM(payment_method)) = 'airtel money'
  AND NULLIF(BTRIM(reference_number), '') IS NOT NULL;

COMMIT;
