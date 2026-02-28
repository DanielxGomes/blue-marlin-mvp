# Plano de preparação para integração Erbon (fase posterior)

## Objetivo
Preparar o software Blue Marlin para integrar com Erbon por último, sem travar evolução de pedidos/agenda.

## Cenário de uso
- Cliente recebe link por WhatsApp
- Acessa portal de pedidos/serviços/agendamentos
- Sistema confere dados de reserva e limitações (período, janela e cutoff)
- Integração Erbon entra na etapa final para sincronizar reservas oficiais

## Endpoints Erbon mapeados (Swagger)
- POST `/auth/login`
- GET `/hotel/{hotelID}/booking/{bookingInternalID}`
- POST `/hotel/booking/list`
- POST `/booking/localizerList`
- POST `/hotel/{hotelID}/booking/search`
- PUT `/hotel/{hotelID}/booking/{bookingInternalID}/checkin`
- PUT `/hotel/{hotelID}/booking/{bookingInternalID}/checkout`

## Fases planejadas
1. Contrato de dados e segurança
2. Token manager e refresh
3. Sync read-only de reservas para `guest_reservations`
4. Operação assistida (checkin/checkout opcional)

## Pré-requisitos pendentes para executar
- `hotelID` oficial por pousada
- credenciais de API Erbon (usuário/senha)
- regra final de status elegível de reserva
- homologação de timezone e janela operacional
