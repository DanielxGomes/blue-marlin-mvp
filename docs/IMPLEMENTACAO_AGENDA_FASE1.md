# Blue Marlin — Implementação Agenda (Fase 1)

## Executado
- Reset de dados operacionais no Supabase (mantida estrutura).
- Criação do core de agenda:
  - establishments
  - guest_reservations
  - service_groups / service_options
  - service_slots
  - service_capacity_rules
  - service_bookings
- Regras de janela e período via função:
  - `validate_booking_window`
- Consulta pública de disponibilidade da agenda:
  - `get_schedule_availability_public`

## Regras aplicadas
- Agendamento somente no período da reserva (`checkin <= dia < checkout`).
- Cutoff de pedido: **17h do dia anterior**.
- Janela de inserção: **24h a 48h antes do check-in**.

## Configuração inicial
- Estabelecimento: `blue-marlin`.
- Serviços base:
  - Arrumação de quarto
  - Café da manhã
  - Estacionamento
- Opções padrão 01/02/03 para arrumação e café.
- Slots:
  - Arrumação (2h): 09–11, 11–13, 13–15, 15–17
  - Café (30/30): 08:00 até 10:30
- Capacidade inicial (ajustável):
  - Arrumação: 6 bookings/slot
  - Café: 20 bookings/slot e 60 pessoas/slot
  - Estacionamento: 23 bookings

## Estacionamento
- Inventário ativo ajustado para 23 vagas:
  - 15 padrão
  - 8 grandes

## Pendências da próxima fase
1. UI de agenda por dia/hora no app.
2. Fluxo de múltiplos dias por serviço.
3. Persistência de placa e emissão de cartão (cor/padrão/QR/nº vaga).
4. Integração com **Erbon** (ficou por último, conforme solicitado).
