-- 009 - RESET DE DADOS + CORE DE AGENDAMENTO (Blue Marlin)
-- Observação: integração Erbon fica para fase posterior.

BEGIN;

-- =========================================================
-- A) RESET DE DADOS CADASTRADOS (preserva estrutura)
-- =========================================================
TRUNCATE TABLE
  public.order_items,
  public.payments,
  public.webhook_events,
  public.parking_reservations,
  public.orders,
  public.stays,
  public.guests,
  public.order_access_tokens,
  public.api_order_request_audit,
  public.ui_funnel_events,
  public.services_catalog
RESTART IDENTITY CASCADE;

-- =========================================================
-- B) MODELO DE AGENDAMENTO (FASE 1 DO PLANO)
-- =========================================================

CREATE TABLE IF NOT EXISTS public.establishments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'America/Sao_Paulo',
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.guest_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES public.establishments(id) ON DELETE CASCADE,
  reservation_code TEXT,
  guest_name TEXT NOT NULL,
  guest_phone_e164 TEXT NOT NULL,
  guest_email TEXT,
  room_number TEXT,
  checkin_date DATE NOT NULL,
  checkout_date DATE NOT NULL,
  adults INT NOT NULL DEFAULT 1,
  children INT NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'manual',
  status TEXT NOT NULL DEFAULT 'confirmed',
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_guest_reservation_dates CHECK (checkout_date > checkin_date)
);

CREATE INDEX IF NOT EXISTS idx_guest_res_est_dates ON public.guest_reservations(establishment_id, checkin_date, checkout_date);
CREATE INDEX IF NOT EXISTS idx_guest_res_contact ON public.guest_reservations(guest_phone_e164, guest_email);

CREATE TABLE IF NOT EXISTS public.service_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES public.establishments(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (establishment_id, code)
);

CREATE TABLE IF NOT EXISTS public.service_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES public.service_groups(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (group_id, code)
);

CREATE TABLE IF NOT EXISTS public.service_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES public.establishments(id) ON DELETE CASCADE,
  service_code TEXT NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME,
  slot_minutes INT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_slot_definition CHECK (
    (end_time IS NOT NULL AND slot_minutes IS NULL) OR
    (end_time IS NULL AND slot_minutes IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_service_slots_lookup ON public.service_slots(establishment_id, service_code, active, start_time);

CREATE TABLE IF NOT EXISTS public.service_capacity_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES public.establishments(id) ON DELETE CASCADE,
  service_code TEXT NOT NULL,
  slot_id UUID REFERENCES public.service_slots(id) ON DELETE CASCADE,
  max_bookings INT,
  max_people INT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_capacity_positive CHECK (
    (max_bookings IS NULL OR max_bookings > 0) AND
    (max_people IS NULL OR max_people > 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_capacity_rules_lookup ON public.service_capacity_rules(establishment_id, service_code, active);

CREATE TABLE IF NOT EXISTS public.service_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES public.establishments(id) ON DELETE CASCADE,
  reservation_id UUID NOT NULL REFERENCES public.guest_reservations(id) ON DELETE CASCADE,
  service_code TEXT NOT NULL,
  option_id UUID REFERENCES public.service_options(id) ON DELETE SET NULL,
  booking_date DATE NOT NULL,
  slot_id UUID REFERENCES public.service_slots(id) ON DELETE SET NULL,
  start_time TIME,
  end_time TIME,
  people_count INT,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled',
  assigned_staff TEXT,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_people_count CHECK (people_count IS NULL OR people_count > 0)
);

CREATE INDEX IF NOT EXISTS idx_service_bookings_lookup ON public.service_bookings(establishment_id, service_code, booking_date, status);

-- =========================================================
-- C) RLS (baseline seguro)
-- =========================================================
ALTER TABLE public.establishments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guest_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_capacity_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_establishments_service_all ON public.establishments;
CREATE POLICY p_establishments_service_all ON public.establishments FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_guest_res_service_all ON public.guest_reservations;
CREATE POLICY p_guest_res_service_all ON public.guest_reservations FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_service_groups_service_all ON public.service_groups;
CREATE POLICY p_service_groups_service_all ON public.service_groups FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_service_options_service_all ON public.service_options;
CREATE POLICY p_service_options_service_all ON public.service_options FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_service_slots_service_all ON public.service_slots;
CREATE POLICY p_service_slots_service_all ON public.service_slots FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_service_capacity_service_all ON public.service_capacity_rules;
CREATE POLICY p_service_capacity_service_all ON public.service_capacity_rules FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS p_service_bookings_service_all ON public.service_bookings;
CREATE POLICY p_service_bookings_service_all ON public.service_bookings FOR ALL TO service_role USING (true) WITH CHECK (true);

-- leitura pública controlada para catálogo de agenda (slots/opções)
DROP POLICY IF EXISTS p_service_groups_public_read ON public.service_groups;
CREATE POLICY p_service_groups_public_read ON public.service_groups FOR SELECT TO anon, authenticated USING (active = true);

DROP POLICY IF EXISTS p_service_options_public_read ON public.service_options;
CREATE POLICY p_service_options_public_read ON public.service_options FOR SELECT TO anon, authenticated USING (active = true);

DROP POLICY IF EXISTS p_service_slots_public_read ON public.service_slots;
CREATE POLICY p_service_slots_public_read ON public.service_slots FOR SELECT TO anon, authenticated USING (active = true);

-- =========================================================
-- D) RPCs de validação e disponibilidade (público)
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_booking_window(
  p_checkin DATE,
  p_checkout DATE,
  p_target_date DATE,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_cutoff TIMESTAMPTZ;
BEGIN
  IF p_checkout <= p_checkin THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reservation_period');
  END IF;

  IF NOT (p_target_date >= p_checkin AND p_target_date < p_checkout) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'outside_stay_period');
  END IF;

  v_cutoff := (p_target_date::timestamp - INTERVAL '1 day') + TIME '17:00';
  IF p_now > v_cutoff THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cutoff_17h_previous_day');
  END IF;

  -- janela 24-48h antes do check-in (regra atual)
  IF p_now < (p_checkin::timestamp - INTERVAL '48 hours') OR p_now > (p_checkin::timestamp - INTERVAL '24 hours') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'outside_checkin_24_48h_window');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_schedule_availability_public(
  p_establishment_code TEXT,
  p_phone_raw TEXT,
  p_email TEXT,
  p_service_code TEXT,
  p_booking_date DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_phone TEXT;
  v_est_id UUID;
  v_res public.guest_reservations%ROWTYPE;
  v_window jsonb;
BEGIN
  v_phone := regexp_replace(COALESCE(p_phone_raw,''), '\D', '', 'g');
  IF v_phone = '' THEN
    RETURN jsonb_build_object('error', true, 'message', 'phone_required');
  END IF;
  IF left(v_phone,2)='55' THEN v_phone := '+'||v_phone; ELSE v_phone := '+55'||v_phone; END IF;

  SELECT id INTO v_est_id FROM public.establishments WHERE code = p_establishment_code AND active = true LIMIT 1;
  IF v_est_id IS NULL THEN
    RETURN jsonb_build_object('error', true, 'message', 'establishment_not_found');
  END IF;

  SELECT * INTO v_res
  FROM public.guest_reservations
  WHERE establishment_id = v_est_id
    AND status = 'confirmed'
    AND (
      guest_phone_e164 = v_phone
      OR (COALESCE(lower(guest_email),'') <> '' AND lower(guest_email) = lower(COALESCE(p_email,'')))
    )
  ORDER BY checkin_date ASC
  LIMIT 1;

  IF v_res.id IS NULL THEN
    RETURN jsonb_build_object('error', true, 'message', 'reservation_not_found');
  END IF;

  v_window := public.validate_booking_window(v_res.checkin_date, v_res.checkout_date, p_booking_date, NOW());
  IF COALESCE((v_window->>'ok')::boolean,false) = false THEN
    RETURN jsonb_build_object('error', true, 'message', v_window->>'reason');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'reservation', jsonb_build_object(
      'reservation_id', v_res.id,
      'checkin_date', v_res.checkin_date,
      'checkout_date', v_res.checkout_date,
      'adults', v_res.adults,
      'children', v_res.children,
      'room_number', v_res.room_number
    ),
    'slots', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'slot_id', ss.id,
        'start_time', ss.start_time,
        'end_time', ss.end_time,
        'slot_minutes', ss.slot_minutes,
        'booked_count', COALESCE(sb.cnt,0)
      ) ORDER BY ss.start_time), '[]'::jsonb)
      FROM public.service_slots ss
      LEFT JOIN (
        SELECT slot_id, COUNT(*) AS cnt
        FROM public.service_bookings
        WHERE establishment_id = v_est_id
          AND service_code = p_service_code
          AND booking_date = p_booking_date
          AND status IN ('scheduled','confirmed')
        GROUP BY slot_id
      ) sb ON sb.slot_id = ss.id
      WHERE ss.establishment_id = v_est_id
        AND ss.service_code = p_service_code
        AND ss.active = true
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_schedule_availability_public(TEXT, TEXT, TEXT, TEXT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_schedule_availability_public(TEXT, TEXT, TEXT, TEXT, DATE) TO anon, authenticated;

-- =========================================================
-- E) DADOS INICIAIS BLUE MARLIN (configuráveis)
-- =========================================================

INSERT INTO public.establishments (code, name)
VALUES ('blue-marlin', 'Pousada Blue Marlin')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, active = true, updated_at = NOW();

WITH est AS (
  SELECT id FROM public.establishments WHERE code = 'blue-marlin' LIMIT 1
)
INSERT INTO public.service_groups (establishment_id, code, name)
SELECT est.id, g.code, g.name
FROM est
JOIN (VALUES
  ('arrumacao_quarto','Arrumação de quarto'),
  ('cafe_manha','Café da manhã'),
  ('estacionamento','Estacionamento')
) AS g(code,name) ON true
ON CONFLICT (establishment_id, code) DO UPDATE SET name = EXCLUDED.name, active = true;

-- subgrupos/ opções 01, 02, 03 (exemplo inicial)
WITH grp AS (
  SELECT sg.id, sg.code
  FROM public.service_groups sg
  JOIN public.establishments e ON e.id = sg.establishment_id
  WHERE e.code = 'blue-marlin'
)
INSERT INTO public.service_options (group_id, code, name)
SELECT grp.id, o.code, o.name
FROM grp
JOIN (VALUES
  ('arrumacao_quarto','opt_01','Opção 01'),
  ('arrumacao_quarto','opt_02','Opção 02'),
  ('arrumacao_quarto','opt_03','Opção 03'),
  ('cafe_manha','opt_01','Opção 01'),
  ('cafe_manha','opt_02','Opção 02'),
  ('cafe_manha','opt_03','Opção 03')
) AS o(group_code,code,name)
  ON o.group_code = grp.code
ON CONFLICT (group_id, code) DO UPDATE SET name = EXCLUDED.name, active = true;

-- slots arrumação (2h): 9-11, 11-13, 13-15, 15-17
WITH est AS (
  SELECT id FROM public.establishments WHERE code = 'blue-marlin' LIMIT 1
)
INSERT INTO public.service_slots (establishment_id, service_code, start_time, end_time)
SELECT est.id, 'arrumacao_quarto', t.start_t, t.end_t
FROM est
JOIN (VALUES
  ('09:00'::time,'11:00'::time),
  ('11:00'::time,'13:00'::time),
  ('13:00'::time,'15:00'::time),
  ('15:00'::time,'17:00'::time)
) AS t(start_t,end_t) ON true
ON CONFLICT DO NOTHING;

-- slots café (30/30): 08:00 -> 10:30
WITH est AS (
  SELECT id FROM public.establishments WHERE code = 'blue-marlin' LIMIT 1
)
INSERT INTO public.service_slots (establishment_id, service_code, start_time, slot_minutes)
SELECT est.id, 'cafe_manha', t.start_t, 30
FROM est
JOIN (VALUES
  ('08:00'::time),('08:30'::time),('09:00'::time),('09:30'::time),('10:00'::time),('10:30'::time)
) AS t(start_t) ON true
ON CONFLICT DO NOTHING;

-- capacidade inicial (ajustável)
WITH est AS (
  SELECT id FROM public.establishments WHERE code = 'blue-marlin' LIMIT 1
)
INSERT INTO public.service_capacity_rules (establishment_id, service_code, max_bookings, max_people)
SELECT est.id, c.service_code, c.max_bookings, c.max_people
FROM est
JOIN (VALUES
  ('arrumacao_quarto', 6, NULL),
  ('cafe_manha', 20, 60),
  ('estacionamento', 23, NULL)
) AS c(service_code,max_bookings,max_people) ON true
ON CONFLICT DO NOTHING;

-- vagas estacionamento (total 23) - configuração inicial: 15 pequenas + 8 grandes
INSERT INTO public.parking_spots (code, spot_type, active)
SELECT 'PD' || LPAD(gs::text, 2, '0'), 'padrao', true
FROM generate_series(1,15) gs
ON CONFLICT (code) DO UPDATE SET active = true, spot_type = 'padrao';

INSERT INTO public.parking_spots (code, spot_type, active)
SELECT 'GR' || LPAD(gs::text, 2, '0'), 'grande', true
FROM generate_series(1,8) gs
ON CONFLICT (code) DO UPDATE SET active = true, spot_type = 'grande';

-- exemplos de reservas para permitir testes imediatos de agenda
WITH est AS (SELECT id FROM public.establishments WHERE code='blue-marlin' LIMIT 1)
INSERT INTO public.guest_reservations (
  establishment_id, reservation_code, guest_name, guest_phone_e164, guest_email,
  room_number, checkin_date, checkout_date, adults, children, source, status
)
SELECT est.id, 'BM-TEST-001', 'Hóspede Teste 1', '+5511999990001', 'teste1@blue.local',
       '101', (CURRENT_DATE + 2), (CURRENT_DATE + 5), 2, 0, 'manual', 'confirmed'
FROM est
UNION ALL
SELECT est.id, 'BM-TEST-002', 'Hóspede Teste 2', '+5511999990002', 'teste2@blue.local',
       '102', (CURRENT_DATE + 2), (CURRENT_DATE + 4), 2, 1, 'manual', 'confirmed'
FROM est
ON CONFLICT DO NOTHING;

COMMIT;
