BEGIN;

-- Função pública para criar agendamento (arrumação/café/estacionamento)
CREATE OR REPLACE FUNCTION public.create_service_booking_public(
  p_establishment_code TEXT,
  p_phone_raw TEXT,
  p_email TEXT,
  p_service_code TEXT,
  p_booking_date DATE,
  p_slot_id UUID,
  p_people_count INT DEFAULT NULL,
  p_option_code TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_same_staff BOOLEAN DEFAULT false,
  p_plate TEXT DEFAULT NULL,
  p_spot_type TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_phone TEXT;
  v_est public.establishments%ROWTYPE;
  v_res public.guest_reservations%ROWTYPE;
  v_window jsonb;
  v_slot public.service_slots%ROWTYPE;
  v_option_id UUID;
  v_rule public.service_capacity_rules%ROWTYPE;
  v_curr_count INT := 0;
  v_curr_people INT := 0;
  v_booking_id UUID;
  v_plate TEXT := NULLIF(regexp_replace(COALESCE(p_plate,''),'\s+','','g'),'');
  v_spot_type TEXT := NULLIF(lower(COALESCE(p_spot_type,'')),'');
BEGIN
  v_phone := regexp_replace(COALESCE(p_phone_raw,''), '\D', '', 'g');
  IF v_phone = '' THEN RETURN jsonb_build_object('error', true, 'message', 'phone_required'); END IF;
  IF left(v_phone,2)='55' THEN v_phone := '+'||v_phone; ELSE v_phone := '+55'||v_phone; END IF;

  SELECT * INTO v_est FROM public.establishments WHERE code = p_establishment_code AND active = true LIMIT 1;
  IF v_est.id IS NULL THEN RETURN jsonb_build_object('error', true, 'message', 'establishment_not_found'); END IF;

  SELECT * INTO v_res
  FROM public.guest_reservations
  WHERE establishment_id = v_est.id
    AND status = 'confirmed'
    AND (
      guest_phone_e164 = v_phone
      OR (COALESCE(lower(guest_email),'') <> '' AND lower(guest_email) = lower(COALESCE(p_email,'')))
    )
  ORDER BY checkin_date ASC
  LIMIT 1;

  IF v_res.id IS NULL THEN RETURN jsonb_build_object('error', true, 'message', 'reservation_not_found'); END IF;

  v_window := public.validate_booking_window(v_res.checkin_date, v_res.checkout_date, p_booking_date, NOW());
  IF COALESCE((v_window->>'ok')::boolean,false) = false THEN
    RETURN jsonb_build_object('error', true, 'message', v_window->>'reason');
  END IF;

  SELECT * INTO v_slot
  FROM public.service_slots
  WHERE id = p_slot_id
    AND establishment_id = v_est.id
    AND service_code = p_service_code
    AND active = true
  LIMIT 1;

  IF v_slot.id IS NULL THEN RETURN jsonb_build_object('error', true, 'message', 'slot_not_found'); END IF;

  IF p_option_code IS NOT NULL THEN
    SELECT so.id INTO v_option_id
    FROM public.service_options so
    JOIN public.service_groups sg ON sg.id = so.group_id
    WHERE sg.establishment_id = v_est.id
      AND sg.code = p_service_code
      AND so.code = p_option_code
      AND so.active = true
    LIMIT 1;
  END IF;

  SELECT * INTO v_rule
  FROM public.service_capacity_rules
  WHERE establishment_id = v_est.id
    AND service_code = p_service_code
    AND active = true
  ORDER BY id ASC
  LIMIT 1;

  SELECT COUNT(*), COALESCE(SUM(COALESCE(people_count,1)),0)
    INTO v_curr_count, v_curr_people
  FROM public.service_bookings
  WHERE establishment_id = v_est.id
    AND service_code = p_service_code
    AND booking_date = p_booking_date
    AND slot_id = p_slot_id
    AND status IN ('scheduled','confirmed');

  IF v_rule.max_bookings IS NOT NULL AND v_curr_count >= v_rule.max_bookings THEN
    RETURN jsonb_build_object('error', true, 'message', 'slot_capacity_reached');
  END IF;

  IF v_rule.max_people IS NOT NULL AND (v_curr_people + COALESCE(p_people_count,1)) > v_rule.max_people THEN
    RETURN jsonb_build_object('error', true, 'message', 'slot_people_limit_reached');
  END IF;

  INSERT INTO public.service_bookings(
    establishment_id, reservation_id, service_code, option_id,
    booking_date, slot_id, start_time, end_time, people_count,
    notes, status, assigned_staff, meta
  ) VALUES (
    v_est.id, v_res.id, p_service_code, v_option_id,
    p_booking_date, p_slot_id, v_slot.start_time, v_slot.end_time,
    p_people_count,
    p_notes,
    'scheduled',
    CASE WHEN p_same_staff THEN 'PREFER_SAME_STAFF' ELSE NULL END,
    jsonb_build_object(
      'same_staff', p_same_staff,
      'plate', v_plate,
      'spot_type', v_spot_type
    )
  ) RETURNING id INTO v_booking_id;

  RETURN jsonb_build_object('success', true, 'booking_id', v_booking_id, 'reservation_id', v_res.id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_service_booking_public(TEXT, TEXT, TEXT, TEXT, DATE, UUID, INT, TEXT, TEXT, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_service_booking_public(TEXT, TEXT, TEXT, TEXT, DATE, UUID, INT, TEXT, TEXT, BOOLEAN, TEXT, TEXT) TO anon, authenticated;


-- slot único de estacionamento (diário)
INSERT INTO public.service_slots (establishment_id, service_code, start_time, end_time, active)
SELECT e.id, 'estacionamento', '00:00'::time, '23:59'::time, true
FROM public.establishments e
WHERE e.code='blue-marlin'
  AND NOT EXISTS (
    SELECT 1 FROM public.service_slots ss
    WHERE ss.establishment_id=e.id AND ss.service_code='estacionamento' AND ss.start_time='00:00'::time
  );

-- Cartão de estacionamento (QR payload)
CREATE OR REPLACE FUNCTION public.get_parking_card_public(
  p_booking_id UUID
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sb public.service_bookings%ROWTYPE;
  res public.guest_reservations%ROWTYPE;
  color TEXT;
  card jsonb;
BEGIN
  SELECT * INTO sb FROM public.service_bookings WHERE id = p_booking_id LIMIT 1;
  IF sb.id IS NULL THEN RETURN jsonb_build_object('error', true, 'message', 'booking_not_found'); END IF;
  IF sb.service_code <> 'estacionamento' THEN RETURN jsonb_build_object('error', true, 'message', 'not_parking_booking'); END IF;

  SELECT * INTO res FROM public.guest_reservations WHERE id = sb.reservation_id LIMIT 1;

  color := CASE COALESCE(sb.meta->>'spot_type','')
    WHEN 'grande' THEN 'laranja'
    ELSE 'azul'
  END;

  card := jsonb_build_object(
    'guest_name', res.guest_name,
    'room_number', res.room_number,
    'date', sb.booking_date,
    'spot_type', COALESCE(sb.meta->>'spot_type','padrao'),
    'spot_color', color,
    'plate', COALESCE(sb.meta->>'plate','N/A'),
    'slot_start', sb.start_time,
    'slot_end', sb.end_time,
    'booking_id', sb.id
  );

  RETURN jsonb_build_object(
    'success', true,
    'card', card,
    'qr_payload', card::text
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_parking_card_public(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_parking_card_public(UUID) TO anon, authenticated;

COMMIT;
