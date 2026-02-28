-- 010 - Ajuste de inventário estacionamento para total 23 vagas
BEGIN;

-- Mantém apenas 15 padrão (PD01..PD15) e 8 grandes (GR01..GR08) ativos
UPDATE public.parking_spots
SET active = false
WHERE code ~ '^PD([1-9]|1[6-9]|20)$'
   OR code ~ '^GR(09|10)$';

-- Garante base mínima ativa correta
INSERT INTO public.parking_spots (code, spot_type, active)
SELECT 'PD' || LPAD(gs::text, 2, '0'), 'padrao', true
FROM generate_series(1,15) gs
ON CONFLICT (code) DO UPDATE SET spot_type='padrao', active=true;

INSERT INTO public.parking_spots (code, spot_type, active)
SELECT 'GR' || LPAD(gs::text, 2, '0'), 'grande', true
FROM generate_series(1,8) gs
ON CONFLICT (code) DO UPDATE SET spot_type='grande', active=true;

COMMIT;
