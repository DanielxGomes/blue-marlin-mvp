-- Blue Marlin - Baseline de RLS para produção
-- Objetivo: eliminar gaps de segurança e evitar erros de permissão inconsistentes no frontend.

BEGIN;

-- 1) Garantir RLS habilitado nas tabelas sensíveis
ALTER TABLE IF EXISTS public.guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.stays ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.api_order_request_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.order_access_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.services_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.parking_spots ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.parking_reservations ENABLE ROW LEVEL SECURITY;

-- 2) Revogar acesso direto para anon/authenticated em tabelas sensíveis
REVOKE ALL ON TABLE public.guests, public.stays, public.orders, public.order_items,
  public.payments, public.webhook_events, public.api_order_request_audit,
  public.order_access_tokens, public.parking_reservations
FROM anon, authenticated;

-- 3) Permitir leitura pública controlada de catálogo e vagas ativas (UX)
GRANT SELECT ON TABLE public.services_catalog, public.parking_spots TO anon, authenticated;

-- 4) Policies públicas mínimas (somente leitura de ativos)
DROP POLICY IF EXISTS p_services_catalog_public_read ON public.services_catalog;
CREATE POLICY p_services_catalog_public_read
ON public.services_catalog
FOR SELECT
TO anon, authenticated
USING (active = true);

DROP POLICY IF EXISTS p_parking_spots_public_read ON public.parking_spots;
CREATE POLICY p_parking_spots_public_read
ON public.parking_spots
FOR SELECT
TO anon, authenticated
USING (active = true);

-- 5) Policies administrativas para service_role
-- (service_role é usado por backend seguro e manutenção)
DROP POLICY IF EXISTS p_guests_service_all ON public.guests;
CREATE POLICY p_guests_service_all ON public.guests FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_stays_service_all ON public.stays;
CREATE POLICY p_stays_service_all ON public.stays FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_orders_service_all ON public.orders;
CREATE POLICY p_orders_service_all ON public.orders FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_order_items_service_all ON public.order_items;
CREATE POLICY p_order_items_service_all ON public.order_items FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_payments_service_all ON public.payments;
CREATE POLICY p_payments_service_all ON public.payments FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_webhook_events_service_all ON public.webhook_events;
CREATE POLICY p_webhook_events_service_all ON public.webhook_events FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_api_audit_service_all ON public.api_order_request_audit;
CREATE POLICY p_api_audit_service_all ON public.api_order_request_audit FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_token_service_all ON public.order_access_tokens;
CREATE POLICY p_token_service_all ON public.order_access_tokens FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_parking_reservations_service_all ON public.parking_reservations;
CREATE POLICY p_parking_reservations_service_all ON public.parking_reservations FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_services_catalog_service_all ON public.services_catalog;
CREATE POLICY p_services_catalog_service_all ON public.services_catalog FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_parking_spots_service_all ON public.parking_spots;
CREATE POLICY p_parking_spots_service_all ON public.parking_spots FOR ALL TO service_role USING (true) WITH CHECK (true);

COMMIT;
