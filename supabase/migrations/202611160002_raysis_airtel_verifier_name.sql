-- Raysis V2: show the staff member who verified an Airtel payment
BEGIN;

DROP FUNCTION IF EXISTS public.raysis_list_airtel_reconciliation();

CREATE FUNCTION public.raysis_list_airtel_reconciliation()
RETURNS TABLE (
  payment_id bigint,
  sale_id bigint,
  receipt_number text,
  branch_name text,
  transaction_date date,
  customer_name text,
  customer_phone text,
  amount numeric,
  reference_number text,
  reconciliation_status text,
  received_by uuid,
  verified_by uuid,
  verified_by_name text,
  verified_at timestamptz,
  verification_note text,
  notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile public.profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = auth.uid();
  IF NOT FOUND OR v_profile.role NOT IN ('ceo','branch_user') THEN
    RAISE EXCEPTION 'Authenticated Raysis profile required';
  END IF;

  RETURN QUERY
  SELECT p.id, p.sale_id, s.receipt_number::text, s.branch_name::text,
         s.transaction_date, s.customer_name::text,
         COALESCE(p.customer_phone, s.customer_phone, '')::text,
         p.amount, COALESCE(p.reference_number,'')::text,
         p.reconciliation_status, p.received_by, p.verified_by,
         COALESCE(v.full_name, '')::text,
         p.verified_at, p.verification_note, p.notes
  FROM public.payments p
  JOIN public.sales s ON s.id = p.sale_id
  LEFT JOIN public.profiles v ON v.id = p.verified_by
  WHERE LOWER(BTRIM(p.payment_method)) = 'airtel money'
    AND (v_profile.role = 'ceo' OR s.branch_name = v_profile.branch_name)
  ORDER BY p.id DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.raysis_list_airtel_reconciliation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.raysis_list_airtel_reconciliation() TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
