-- 008 - Hardening de acesso admin ao catálogo
BEGIN;

CREATE TABLE IF NOT EXISTS public.admin_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_admin_users_service_all ON public.admin_users;
CREATE POLICY p_admin_users_service_all
ON public.admin_users
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

DROP POLICY IF EXISTS p_admin_users_self_read ON public.admin_users;
CREATE POLICY p_admin_users_self_read
ON public.admin_users
FOR SELECT
TO authenticated
USING (
  lower(email) = lower(coalesce(auth.jwt()->>'email',''))
  AND active = true
);

CREATE OR REPLACE FUNCTION public.is_admin_panel_access()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(coalesce(auth.jwt()->>'email',''));
  v_ok boolean := false;
BEGIN
  IF v_email <> '' THEN
    SELECT true INTO v_ok
    FROM public.admin_users au
    WHERE lower(au.email) = v_email
      AND au.active = true
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object('is_admin', coalesce(v_ok,false), 'email', v_email);
END;
$$;

REVOKE ALL ON FUNCTION public.is_admin_panel_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin_panel_access() TO authenticated;

DROP POLICY IF EXISTS p_services_catalog_auth_manage ON public.services_catalog;
CREATE POLICY p_services_catalog_auth_manage
ON public.services_catalog
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.admin_users au
    WHERE lower(au.email) = lower(coalesce(auth.jwt()->>'email',''))
      AND au.active = true
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.admin_users au
    WHERE lower(au.email) = lower(coalesce(auth.jwt()->>'email',''))
      AND au.active = true
  )
);

COMMIT;
