-- Raysis V2: Airtel Money manual reconciliation centre
-- Adds auditable verification status and branch-scoped RPCs.
BEGIN;

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS reconciliation_status text NOT NULL DEFAULT 'unverified',
  ADD COLUMN IF NOT EXISTS verified_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS verification_note text;

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_reconciliation_status_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_reconciliation_status_check
  CHECK (reconciliation_status IN ('unverified','verified','disputed'));

CREATE INDEX IF NOT EXISTS payments_airtel_reconciliation_status_idx
  ON public.payments (reconciliation_status, sale_id)
  WHERE LOWER(BTRIM(payment_method)) = 'airtel money';

-- Staff can see payments only for their assigned branch; CEO can see both.
CREATE OR REPLACE FUNCTION public.raysis_list_airtel_reconciliation()
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
         p.verified_at, p.verification_note, p.notes
  FROM public.payments p
  JOIN public.sales s ON s.id = p.sale_id
  WHERE LOWER(BTRIM(p.payment_method)) = 'airtel money'
    AND (v_profile.role = 'ceo' OR s.branch_name = v_profile.branch_name)
  ORDER BY p.id DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.raysis_set_airtel_reconciliation(
  p_payment_id bigint,
  p_status text,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile public.profiles%ROWTYPE;
  v_branch text;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = auth.uid();
  IF NOT FOUND OR v_profile.role NOT IN ('ceo','branch_user') THEN
    RAISE EXCEPTION 'Authenticated Raysis profile required';
  END IF;

  IF p_status NOT IN ('unverified','verified','disputed') THEN
    RAISE EXCEPTION 'Invalid reconciliation status';
  END IF;

  SELECT s.branch_name INTO v_branch
  FROM public.payments p
  JOIN public.sales s ON s.id = p.sale_id
  WHERE p.id = p_payment_id
    AND LOWER(BTRIM(p.payment_method)) = 'airtel money'
  FOR UPDATE OF p;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Airtel Money payment not found';
  END IF;

  IF v_profile.role <> 'ceo' AND v_branch IS DISTINCT FROM v_profile.branch_name THEN
    RAISE EXCEPTION 'You cannot reconcile payments for another branch';
  END IF;

  IF p_status = 'disputed' AND NULLIF(BTRIM(COALESCE(p_note,'')), '') IS NULL THEN
    RAISE EXCEPTION 'Enter a reason when marking a payment disputed';
  END IF;

  UPDATE public.payments
  SET reconciliation_status = p_status,
      verified_by = CASE WHEN p_status = 'verified' THEN auth.uid() ELSE NULL END,
      verified_at = CASE WHEN p_status = 'verified' THEN now() ELSE NULL END,
      verification_note = NULLIF(BTRIM(COALESCE(p_note,'')), '')
  WHERE id = p_payment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.raysis_list_airtel_reconciliation() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.raysis_set_airtel_reconciliation(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.raysis_list_airtel_reconciliation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.raysis_set_airtel_reconciliation(bigint,text,text) TO authenticated;

COMMIT;
