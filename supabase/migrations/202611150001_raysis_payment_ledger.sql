-- Raysis V2 payment ledger
-- Date: 2026-11-15
-- Adds automatic initial-payment ledger entries and a secure additional-payment RPC.
-- Existing sales, quotation, RLS, and audit triggers are preserved.

BEGIN;

-- 1. Create one ledger entry for the initial payment on every newly inserted paid sale.
-- Reuses the sale operation ID so retries remain traceable and idempotent.
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
       OR NOT EXISTS (
         SELECT 1
         FROM auth.users u
         WHERE u.id = v_received_by
       ) THEN
      RAISE EXCEPTION
        'A valid receiving user is required for an initial payment on sale %',
        NEW.receipt_number;
    END IF;

    INSERT INTO public.payments (
      sale_id,
      amount,
      payment_method,
      received_by,
      notes,
      client_operation_id
    )
    VALUES (
      NEW.id,
      NEW.amount_paid,
      COALESCE(NULLIF(BTRIM(NEW.payment_method), ''), 'Cash'),
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

DROP TRIGGER IF EXISTS raysis_record_initial_payment ON public.sales;

CREATE TRIGGER raysis_record_initial_payment
AFTER INSERT ON public.sales
FOR EACH ROW
EXECUTE FUNCTION public.raysis_record_initial_payment();


-- 2. Record later payments atomically.
-- The sale row lock serializes concurrent payments against the same balance.
-- The payment operation ID makes retries safe, including concurrent retries.
CREATE OR REPLACE FUNCTION public.raysis_record_additional_payment(
  p_sale_id bigint,
  p_amount numeric,
  p_payment_method text,
  p_client_operation_id uuid,
  p_reference_number text DEFAULT '',
  p_notes text DEFAULT ''
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile public.profiles%ROWTYPE;
  v_sale public.sales%ROWTYPE;
  v_existing public.payments%ROWTYPE;
  v_payment_id bigint;
  v_method text;
BEGIN
  SELECT *
  INTO v_profile
  FROM public.profiles
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Authenticated Raysis profile required';
  END IF;

  IF p_client_operation_id IS NULL THEN
    RAISE EXCEPTION 'Payment operation ID is required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero';
  END IF;

  v_method := NULLIF(BTRIM(p_payment_method), '');

  IF v_method IS NULL THEN
    RAISE EXCEPTION 'Payment method is required';
  END IF;

  SELECT *
  INTO v_sale
  FROM public.sales
  WHERE id = p_sale_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sale not found';
  END IF;

  IF v_profile.role <> 'ceo'
     AND v_profile.branch_name IS DISTINCT FROM v_sale.branch_name THEN
    RAISE EXCEPTION 'You cannot record payments for another branch';
  END IF;

  -- First handle an already-committed retry, even if the sale is now fully paid.
  SELECT *
  INTO v_existing
  FROM public.payments
  WHERE client_operation_id = p_client_operation_id;

  IF FOUND THEN
    IF v_existing.sale_id <> p_sale_id
       OR v_existing.amount <> p_amount
       OR v_existing.payment_method <> v_method THEN
      RAISE EXCEPTION
        'Payment operation ID already belongs to a different payment';
    END IF;

    RETURN v_existing.id;
  END IF;

  IF p_amount > (v_sale.total_amount - v_sale.amount_paid) THEN
    RAISE EXCEPTION 'Payment exceeds the outstanding balance';
  END IF;

  -- ON CONFLICT handles the rare case where the same operation ID is
  -- submitted concurrently for different sale rows.
  INSERT INTO public.payments (
    sale_id,
    amount,
    payment_method,
    reference_number,
    notes,
    received_by,
    client_operation_id
  )
  VALUES (
    p_sale_id,
    p_amount,
    v_method,
    COALESCE(p_reference_number, ''),
    COALESCE(p_notes, ''),
    auth.uid(),
    p_client_operation_id
  )
  ON CONFLICT (client_operation_id)
    WHERE client_operation_id IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_payment_id;

  IF v_payment_id IS NULL THEN
    SELECT *
    INTO v_existing
    FROM public.payments
    WHERE client_operation_id = p_client_operation_id;

    IF NOT FOUND
       OR v_existing.sale_id <> p_sale_id
       OR v_existing.amount <> p_amount
       OR v_existing.payment_method <> v_method THEN
      RAISE EXCEPTION
        'Payment operation ID already belongs to a different payment';
    END IF;

    RETURN v_existing.id;
  END IF;

  UPDATE public.sales
  SET amount_paid = amount_paid + p_amount
  WHERE id = p_sale_id;

  RETURN v_payment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.raysis_record_additional_payment(
  bigint, numeric, text, uuid, text, text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.raysis_record_additional_payment(
  bigint, numeric, text, uuid, text, text
) TO authenticated;

COMMIT;
