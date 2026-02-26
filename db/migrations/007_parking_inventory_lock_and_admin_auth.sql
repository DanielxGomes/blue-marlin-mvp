-- 007 - Bloqueio real de vagas + disponibilidade pública via RPC

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Exclusion constraint: impede duas reservas simultâneas para mesma vaga (status reserved)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'parking_reservation_no_overlap'
  ) THEN
    ALTER TABLE public.parking_reservations
      ADD CONSTRAINT parking_reservation_no_overlap
      EXCLUDE USING gist (
        parking_spot_id WITH =,
        daterange(start_date, end_date, '[)') WITH &&
      )
      WHERE (status = 'reserved');
  END IF;
END $$;

-- RPC de disponibilidade para frontend (anon/authenticated)
CREATE OR REPLACE FUNCTION public.get_parking_availability_public(
  p_start DATE,
  p_end DATE,
  p_size TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reserved text[];
  v_available text[];
BEGIN
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RETURN jsonb_build_object('error', true, 'message', 'Período inválido');
  END IF;

  SELECT COALESCE(array_agg(ps.code ORDER BY ps.code), ARRAY[]::text[])
    INTO v_reserved
  FROM public.parking_reservations pr
  JOIN public.parking_spots ps ON ps.id = pr.parking_spot_id
  WHERE pr.status = 'reserved'
    AND daterange(pr.start_date, pr.end_date, '[)') && daterange(p_start, p_end, '[)')
    AND (p_size IS NULL OR ps.spot_type = p_size);

  SELECT COALESCE(array_agg(ps.code ORDER BY ps.code), ARRAY[]::text[])
    INTO v_available
  FROM public.parking_spots ps
  WHERE ps.active = true
    AND (p_size IS NULL OR ps.spot_type = p_size)
    AND NOT (ps.code = ANY(v_reserved));

  RETURN jsonb_build_object(
    'success', true,
    'reserved', v_reserved,
    'available', v_available
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_parking_availability_public(DATE, DATE, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_parking_availability_public(DATE, DATE, TEXT) TO anon, authenticated;

-- Endurece create_order_public para persistir parking_reservations e travar conflito
CREATE OR REPLACE FUNCTION public.create_order_public(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_guest jsonb;
  v_items jsonb;
  v_phone text;
  v_name text;
  v_room text;
  v_access_token text;
  v_guest_id uuid;
  v_stay_id uuid;
  v_order_id uuid;
  v_item jsonb;
  v_qty int;
  v_unit numeric(12,2);
  v_subtotal numeric(12,2) := 0;
  v_fee numeric(12,2) := 0;
  v_total numeric(12,2) := 0;
  v_item_type text;
  v_rate_count int;
  v_items_count int;
  v_spot_code text;
  v_size text;
  v_start date;
  v_end date;
  v_spot_id uuid;
  v_nights int;
BEGIN
  v_guest := COALESCE(p_payload->'guest', '{}'::jsonb);
  v_items := COALESCE(p_payload->'items', '[]'::jsonb);
  v_access_token := COALESCE(p_payload->>'accessToken', '');

  IF jsonb_typeof(v_items) <> 'array' THEN RAISE EXCEPTION 'Itens inválidos'; END IF;

  v_items_count := jsonb_array_length(v_items);
  IF v_items_count = 0 THEN RAISE EXCEPTION 'Itens obrigatórios'; END IF;
  IF v_items_count > 30 THEN RAISE EXCEPTION 'Limite de itens excedido (máximo 30)'; END IF;

  v_phone := regexp_replace(COALESCE(v_guest->>'guestPhone',''), '\D', '', 'g');
  v_name := btrim(COALESCE(v_guest->>'guestName',''));
  v_room := regexp_replace(COALESCE(v_guest->>'roomNumber',''), '\D', '', 'g');

  IF v_phone = '' THEN RAISE EXCEPTION 'WhatsApp obrigatório'; END IF;
  IF left(v_phone,2)='55' THEN v_phone := '+'||v_phone; ELSE v_phone := '+55'||v_phone; END IF;
  IF NOT (v_phone ~ '^\+[1-9][0-9]{7,14}$') THEN RAISE EXCEPTION 'WhatsApp inválido'; END IF;

  IF NOT public.consume_order_access_token(v_access_token, v_phone) THEN
    RAISE EXCEPTION 'Token de acesso inválido/expirado';
  END IF;

  IF v_name = '' OR length(v_name) > 120 THEN RAISE EXCEPTION 'Nome inválido'; END IF;
  IF v_room = '' OR length(v_room) > 4 THEN RAISE EXCEPTION 'Quarto inválido'; END IF;

  SELECT count(*)::int INTO v_rate_count
  FROM public.api_order_request_audit
  WHERE phone_e164 = v_phone
    AND created_at >= NOW() - INTERVAL '5 minutes'
    AND success = true;

  IF v_rate_count >= 8 THEN RAISE EXCEPTION 'Muitas tentativas. Aguarde alguns minutos.'; END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items)
  LOOP
    v_qty := GREATEST(COALESCE((v_item->>'qty')::int,1),1);
    IF v_qty > 20 THEN RAISE EXCEPTION 'Quantidade por item excede máximo permitido (20)'; END IF;
    v_unit := COALESCE((v_item->>'unitPrice')::numeric,0);
    IF v_unit < 0 OR v_unit > 10000 THEN RAISE EXCEPTION 'Preço unitário inválido'; END IF;
    v_subtotal := v_subtotal + (v_qty * v_unit);
  END LOOP;

  IF v_subtotal > 50000 THEN RAISE EXCEPTION 'Subtotal acima do limite permitido'; END IF;

  v_fee := COALESCE((p_payload->'totals'->>'fee')::numeric, 0);
  IF v_fee < 0 OR v_fee > 10000 THEN RAISE EXCEPTION 'Taxa de serviço inválida'; END IF;

  v_total := v_subtotal + v_fee;

  INSERT INTO guests (phone_e164, full_name)
  VALUES (v_phone, v_name)
  ON CONFLICT (phone_e164)
  DO UPDATE SET full_name = EXCLUDED.full_name, updated_at = NOW()
  RETURNING id INTO v_guest_id;

  INSERT INTO stays (guest_id, room_number, source)
  VALUES (v_guest_id, v_room, 'web')
  RETURNING id INTO v_stay_id;

  INSERT INTO orders (stay_id, status, service_fee_applied, subtotal, service_fee_amount, total_amount, currency)
  VALUES (v_stay_id, 'pending', (v_fee > 0), v_subtotal, v_fee, v_total, 'BRL')
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items)
  LOOP
    v_qty := GREATEST(COALESCE((v_item->>'qty')::int,1),1);
    v_unit := COALESCE((v_item->>'unitPrice')::numeric,0);
    v_item_type := CASE WHEN lower(COALESCE(v_item->>'type','')) IN ('estacionamento','parking') THEN 'parking' ELSE 'service' END;

    INSERT INTO order_items (order_id, item_type, title, detail, quantity, unit_price)
    VALUES (
      v_order_id,
      v_item_type,
      LEFT(COALESCE(v_item->>'title','Item'), 150),
      LEFT(COALESCE(v_item->>'detail',''), 1000),
      v_qty,
      v_unit
    );

    IF v_item_type = 'parking' THEN
      v_spot_code := COALESCE(v_item->>'spot', '');
      v_size := COALESCE(v_item->>'size', '');
      v_start := NULLIF(v_item->>'startDate','')::date;
      v_end := NULLIF(v_item->>'endDate','')::date;

      IF v_spot_code = '' OR v_start IS NULL OR v_end IS NULL OR v_end <= v_start THEN
        RAISE EXCEPTION 'Dados de estacionamento inválidos';
      END IF;

      SELECT id INTO v_spot_id
      FROM public.parking_spots
      WHERE code = v_spot_code
        AND active = true
        AND (v_size = '' OR spot_type = v_size)
      LIMIT 1;

      IF v_spot_id IS NULL THEN
        RAISE EXCEPTION 'Vaga inválida/inativa';
      END IF;

      -- lock pessimista da vaga
      PERFORM 1 FROM public.parking_spots WHERE id = v_spot_id FOR UPDATE;

      IF EXISTS (
        SELECT 1
        FROM public.parking_reservations pr
        WHERE pr.parking_spot_id = v_spot_id
          AND pr.status = 'reserved'
          AND daterange(pr.start_date, pr.end_date, '[)') && daterange(v_start, v_end, '[)')
      ) THEN
        RAISE EXCEPTION 'Vaga já reservada para o período';
      END IF;

      v_nights := (v_end - v_start);
      IF v_nights <= 0 THEN RAISE EXCEPTION 'Período de estacionamento inválido'; END IF;

      INSERT INTO public.parking_reservations (
        order_id, parking_spot_id, start_date, end_date, daily_price, total_price, status
      ) VALUES (
        v_order_id,
        v_spot_id,
        v_start,
        v_end,
        ROUND(v_unit / GREATEST(v_nights,1), 2),
        v_unit,
        'reserved'
      );
    END IF;
  END LOOP;

  INSERT INTO public.api_order_request_audit (
    source, phone_e164, guest_name, room_number, items_count, subtotal, service_fee, total, success
  ) VALUES (
    'web', v_phone, v_name, v_room, v_items_count, v_subtotal, v_fee, v_total, true
  );

  RETURN jsonb_build_object('success', true, 'orderId', v_order_id, 'stayId', v_stay_id);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.api_order_request_audit (
    source, phone_e164, guest_name, room_number, items_count, subtotal, service_fee, total, success, error_message
  ) VALUES (
    'web', v_phone, v_name, v_room, COALESCE(v_items_count,0), COALESCE(v_subtotal,0), COALESCE(v_fee,0), COALESCE(v_total,0), false, LEFT(SQLERRM, 500)
  );
  RETURN jsonb_build_object('error', true, 'message', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_public(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order_public(jsonb) TO anon, authenticated;

COMMIT;
