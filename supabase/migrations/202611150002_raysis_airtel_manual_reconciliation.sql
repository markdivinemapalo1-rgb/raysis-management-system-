-- Raysis V2: Airtel Money manual reconciliation fields and duplicate-reference protection
-- Apply after 202611150001_raysis_payment_ledger.sql.

BEGIN;

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS customer_phone text;

-- Airtel references must be unique, ignoring case and surrounding spaces.
-- Blank references on non-Airtel payment methods are unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS payments_airtel_reference_uidx
  ON public.payments (LOWER(BTRIM(reference_number)))
  WHERE LOWER(BTRIM(payment_method)) = 'airtel money'
    AND NULLIF(BTRIM(reference_number), '') IS NOT NULL;

-- Keep the initial-payment ledger entry aligned with the sale's reference and phone.
CREATE OR REPLACE FUNCTION public.raysis_record_initial_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_received_by uuid;
  v_method text;
BEGIN
  IF COALESCE(NEW.amount_paid, 0) > 0 THEN
    v_received_by := COALESCE(NEW.created_by, auth.uid());
    v_method := COALESCE(NULLIF(BTRIM(NEW.payment_method), ''), 'Cash');

    IF v_received_by IS NULL
       OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_received_by) THEN
      RAISE EXCEPTION 'A valid receiving user is required for an initial payment on sale %', NEW.receipt_number;
    END IF;

    IF LOWER(v_method) = 'airtel money'
       AND (NULLIF(BTRIM(NEW.initial_payment_reference), '') IS NULL
            OR NULLIF(BTRIM(NEW.customer_phone), '') IS NULL) THEN
      RAISE EXCEPTION 'Airtel Money payments require the customer phone number and transaction reference';
    END IF;

    INSERT INTO public.payments (
      sale_id, amount, payment_method, reference_number, customer_phone,
      received_by, notes, client_operation_id
    )
    VALUES (
      NEW.id, NEW.amount_paid, v_method,
      COALESCE(NEW.initial_payment_reference, ''),
      COALESCE(NEW.customer_phone, ''),
      v_received_by,
      'Initial payment for sale ' || NEW.receipt_number,
      COALESCE(NEW.client_operation_id, gen_random_uuid())
    );
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.raysis_record_initial_payment()
FROM PUBLIC, anon, authenticated;

-- Seven-argument wrapper preserves the existing, tested atomic/idempotent RPC.
-- It adds the structured customer phone field without changing the old RPC contract.
CREATE OR REPLACE FUNCTION public.raysis_record_additional_payment(
  p_sale_id bigint,
  p_amount numeric,
  p_payment_method text,
  p_client_operation_id uuid,
  p_reference_number text,
  p_notes text,
  p_customer_phone text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_payment_id bigint;
BEGIN
  IF LOWER(BTRIM(COALESCE(p_payment_method, ''))) = 'airtel money'
     AND (NULLIF(BTRIM(COALESCE(p_reference_number, '')), '') IS NULL
          OR NULLIF(BTRIM(COALESCE(p_customer_phone, '')), '') IS NULL) THEN
    RAISE EXCEPTION 'Airtel Money payments require the customer phone number and transaction reference';
  END IF;

  v_payment_id := public.raysis_record_additional_payment(
    p_sale_id,
    p_amount,
    p_payment_method,
    p_client_operation_id,
    p_reference_number,
    p_notes
  );

  UPDATE public.payments
  SET customer_phone = NULLIF(BTRIM(COALESCE(p_customer_phone, '')), '')
  WHERE id = v_payment_id
    AND sale_id = p_sale_id;

  RETURN v_payment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.raysis_record_additional_payment(
  bigint, numeric, text, uuid, text, text, text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.raysis_record_additional_payment(
  bigint, numeric, text, uuid, text, text, text
) TO authenticated;

COMMIT;
