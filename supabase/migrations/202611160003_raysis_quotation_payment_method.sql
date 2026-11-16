BEGIN;

-- Replace the old three-argument quotation conversion RPC.
-- The new signature captures the actual initial payment method and Airtel details.
DROP FUNCTION IF EXISTS public.convert_quotation_to_sale(bigint, numeric, text);

CREATE FUNCTION public.convert_quotation_to_sale(
  p_quote_id bigint,
  p_paid numeric,
  p_receipt_number text,
  p_payment_method text,
  p_payment_reference text,
  p_customer_phone text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  q public.quotations%ROWTYPE;
  v_profile public.profiles%ROWTYPE;
  v_sale_id bigint;
  v_invoice text;
  v_delivery text;
  v_method text;
  v_reference text;
  v_customer_phone text;
BEGIN
  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Authenticated Raysis profile required';
  END IF;

  SELECT * INTO q
  FROM public.quotations
  WHERE id = p_quote_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quotation not found';
  END IF;

  IF v_profile.role <> 'ceo'
     AND v_profile.branch_name IS DISTINCT FROM q.branch_name THEN
    RAISE EXCEPTION 'You cannot convert a quotation from another branch';
  END IF;

  IF q.accepted_sale_id IS NOT NULL THEN
    RAISE EXCEPTION 'Quotation has already been converted';
  END IF;

  IF p_paid IS NULL OR p_paid < 0 OR p_paid > q.total_amount THEN
    RAISE EXCEPTION 'Invalid payment amount';
  END IF;

  IF COALESCE(BTRIM(p_receipt_number), '') = '' THEN
    RAISE EXCEPTION 'Receipt number is required';
  END IF;

  -- A method is required only when money is actually received.
  IF p_paid > 0 THEN
    v_method := CASE LOWER(BTRIM(COALESCE(p_payment_method, '')))
      WHEN 'cash' THEN 'Cash'
      WHEN 'airtel money' THEN 'Airtel Money'
      WHEN 'mobile money' THEN 'Mobile Money'
      WHEN 'bank transfer' THEN 'Bank transfer'
      WHEN 'other' THEN 'Other'
      ELSE NULL
    END;

    IF v_method IS NULL THEN
      RAISE EXCEPTION 'Select a valid payment method for the amount received';
    END IF;

    v_reference := NULLIF(BTRIM(COALESCE(p_payment_reference, '')), '');
    v_customer_phone := NULLIF(BTRIM(COALESCE(p_customer_phone, '')), '');

    IF v_method = 'Airtel Money'
       AND (v_reference IS NULL OR v_customer_phone IS NULL) THEN
      RAISE EXCEPTION 'Airtel Money payments require the customer phone number and transaction reference';
    END IF;
  ELSE
    -- No payment was received: do not mislabel the sale as Cash.
    v_method := NULL;
    v_reference := NULL;
    v_customer_phone := NULLIF(BTRIM(COALESCE(q.customer_contact, '')), '');
  END IF;

  v_invoice := 'INV-' || LEFT(UPPER(q.branch_name), 1) || '-' || RIGHT(p_receipt_number, 7);
  v_delivery := 'DN-' || LEFT(UPPER(q.branch_name), 1) || '-' || RIGHT(p_receipt_number, 7);

  INSERT INTO public.sales (
    branch_name, receipt_number, transaction_date, customer_name, customer_phone,
    product_service, total_amount, amount_paid, payment_method,
    initial_payment_reference, notes, created_by, items, invoice_number,
    delivery_note_number, quotation_id, quotation_number, recorded_by
  )
  VALUES (
    q.branch_name, p_receipt_number, CURRENT_DATE, q.customer_name,
    COALESCE(v_customer_phone, q.customer_contact),
    COALESCE((
      SELECT STRING_AGG(elem.value->>'description', ', ')
      FROM JSONB_ARRAY_ELEMENTS(q.items) AS elem(value)
    ), 'Quoted items'),
    q.total_amount, p_paid, v_method, v_reference,
    'Created from accepted quotation ' || q.quotation_number,
    auth.uid(), q.items, v_invoice, v_delivery, q.id,
    q.quotation_number, COALESCE(v_profile.full_name, '')
  )
  RETURNING id INTO v_sale_id;

  -- The existing raysis_record_initial_payment trigger writes the ledger row
  -- when amount_paid > 0. Do not insert a second payment here.
  UPDATE public.quotations
  SET status = 'accepted',
      accepted_sale_id = v_sale_id,
      accepted_date = CURRENT_DATE
  WHERE id = q.id;

  RETURN v_sale_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.convert_quotation_to_sale(
  bigint, numeric, text, text, text, text
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.convert_quotation_to_sale(
  bigint, numeric, text, text, text, text
) FROM anon;

GRANT EXECUTE ON FUNCTION public.convert_quotation_to_sale(
  bigint, numeric, text, text, text, text
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
