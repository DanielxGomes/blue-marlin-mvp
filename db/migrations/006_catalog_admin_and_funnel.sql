-- Blue Marlin - Admin de catálogo (auth) + telemetria de funil

BEGIN;

-- 1) Telemetria de funil
CREATE TABLE IF NOT EXISTS public.ui_funnel_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_name TEXT NOT NULL,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_ui_funnel_events_created_at ON public.ui_funnel_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ui_funnel_events_event_name ON public.ui_funnel_events(event_name);

ALTER TABLE public.ui_funnel_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_ui_funnel_service_all ON public.ui_funnel_events;
CREATE POLICY p_ui_funnel_service_all
ON public.ui_funnel_events
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.track_funnel_event_public(
  p_event TEXT,
  p_meta JSONB DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event TEXT;
BEGIN
  v_event := lower(trim(COALESCE(p_event, 'unknown')));
  IF v_event = '' THEN v_event := 'unknown'; END IF;

  INSERT INTO public.ui_funnel_events(event_name, meta)
  VALUES (
    left(v_event, 80),
    COALESCE(p_meta, '{}'::jsonb)
  );

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', true, 'message', left(SQLERRM, 300));
END;
$$;

REVOKE ALL ON FUNCTION public.track_funnel_event_public(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_funnel_event_public(TEXT, JSONB) TO anon, authenticated;

-- 2) Administração do catálogo via usuários autenticados
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.services_catalog TO authenticated;

DROP POLICY IF EXISTS p_services_catalog_auth_manage ON public.services_catalog;
CREATE POLICY p_services_catalog_auth_manage
ON public.services_catalog
FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);

COMMIT;
