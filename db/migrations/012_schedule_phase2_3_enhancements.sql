BEGIN;

ALTER TABLE public.parking_spots
  ADD COLUMN IF NOT EXISTS location_label TEXT,
  ADD COLUMN IF NOT EXISTS spot_color TEXT;

UPDATE public.parking_spots
SET location_label = COALESCE(location_label, 'Setor ' || CASE WHEN spot_type='grande' THEN 'G' ELSE 'P' END),
    spot_color = COALESCE(spot_color, CASE WHEN spot_type='grande' THEN 'laranja' ELSE 'azul' END);

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
  p_spot_type TEXT DEFAULT NULL,
  p_preferred_spot_code TEXT DEFAULT NULL
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
  v_spot_type TEXT := NULLIF(lower(COALESCE(p_spot_type,'')), '');
  v_spot public.parking_spots%ROWTYPE;
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

  IF p_service_code = 'estacionamento' THEN
    IF v_plate IS NULL OR v_plate = '' THEN
      RETURN jsonb_build_object('error', true, 'message', 'plate_required');
    END IF;
    IF v_spot_type IS NULL OR v_spot_type = '' THEN
      RETURN jsonb_build_object('error', true, 'message', 'spot_type_required');
    END IF;

    IF p_preferred_spot_code IS NOT NULL AND p_preferred_spot_code <> '' THEN
      SELECT * INTO v_spot
      FROM public.parking_spots ps
      WHERE ps.active = true
        AND ps.spot_type = v_spot_type
        AND ps.code = p_preferred_spot_code
        AND NOT EXISTS (
          SELECT 1
          FROM public.service_bookings sb
          WHERE sb.establishment_id = v_est.id
            AND sb.service_code = 'estacionamento'
            AND sb.booking_date = p_booking_date
            AND sb.status IN ('scheduled','confirmed')
            AND sb.meta->>'spot_code' = ps.code
        )
      LIMIT 1;
    END IF;

    IF v_spot.id IS NULL THEN
      SELECT * INTO v_spot
      FROM public.parking_spots ps
      WHERE ps.active = true
        AND ps.spot_type = v_spot_type
        AND NOT EXISTS (
          SELECT 1
          FROM public.service_bookings sb
          WHERE sb.establishment_id = v_est.id
            AND sb.service_code = 'estacionamento'
            AND sb.booking_date = p_booking_date
            AND sb.status IN ('scheduled','confirmed')
            AND sb.meta->>'spot_code' = ps.code
        )
      ORDER BY ps.code
      LIMIT 1;
    END IF;

    IF v_spot.id IS NULL THEN
      RETURN jsonb_build_object('error', true, 'message', 'no_spot_available_for_type');
    END IF;
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
    CASE WHEN p_service_code='estacionamento' THEN jsonb_build_object(
      'same_staff', p_same_staff,
      'plate', v_plate,
      'spot_type', v_spot_type,
      'spot_code', v_spot.code,
      'spot_color', v_spot.spot_color,
      'spot_location', v_spot.location_label
    ) ELSE jsonb_build_object('same_staff', p_same_staff) END
  ) RETURNING id INTO v_booking_id;

  IF p_service_code='estacionamento' THEN
    RETURN jsonb_build_object(
      'success', true,
      'booking_id', v_booking_id,
      'reservation_id', v_res.id,
      'parking', jsonb_build_object(
        'spot_code', v_spot.code,
        'spot_type', v_spot.spot_type,
        'spot_color', v_spot.spot_color,
        'spot_location', v_spot.location_label,
        'plate', v_plate
      )
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'booking_id', v_booking_id, 'reservation_id', v_res.id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_service_booking_public(TEXT, TEXT, TEXT, TEXT, DATE, UUID, INT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_service_booking_public(TEXT, TEXT, TEXT, TEXT, DATE, UUID, INT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO anon, authenticated;

COMMIT;
