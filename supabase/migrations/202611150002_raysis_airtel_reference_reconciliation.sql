-- Raysis V2: Airtel Money manual reference reconciliation
-- Requires a customer-supplied transaction reference for Airtel Money entries
-- at the app layer, and prevents reuse of a reference in the payment ledger.

BEGIN;

ALTER TABLE public.sales
ADD COLUMN IF NOT EXISTS initial_payment_reference text;

CREATE OR REPLACE FUNCTION public.raysis_record_initial_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_received_by uuid;
BEGIN
  IF COALESCE(NEW.amount_paid, 0) > 0 THEN
    v_received_by := COALESCE(NEW.created_by, auth.uid());

    IF v_received_by IS NULL
       OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_received_by) THEN
      RAISE EXCEPTION 'A valid receiving user is required for an initial payment on sale %', NEW.receipt_number;
    END IF;

    IF LOWER(BTRIM(COALESCE(NEW.payment_method, ''))) = 'airtel money'
       AND NULLIF(BTRIM(NEW.initial_payment_reference), '') IS NULL THEN
      RAISE EXCEPTION 'Airtel Money transaction reference is required for the initial payment';
    END IF;

    INSERT INTO public.payments (
      sale_id, amount, payment_method, reference_number,
      received_by, notes, client_operation_id
    )
    VALUES (
      NEW.id, NEW.amount_paid,
      COALESCE(NULLIF(BTRIM(NEW.payment_method), ''), 'Cash'),
      COALESCE(NEW.initial_payment_reference, ''),
      v_received_by,
      'Initial payment for sale ' || NEW.receipt_number,
      COALESCE(NEW.client_operation_id, gen_random_uuid())
    );
  END IF;

  RETURN NEW;
END;
$function$;

CREATE UNIQUE INDEX IF NOT EXISTS payments_airtel_reference_uidx
ON public.payments (LOWER(BTRIM(reference_number)))
WHERE LOWER(BTRIM(payment_method)) = 'airtel money'
  AND NULLIF(BTRIM(reference_number), '') IS NOT NULL;

COMMIT;
