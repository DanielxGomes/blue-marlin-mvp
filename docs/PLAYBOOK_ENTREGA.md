# Playbook de Entrega (Blue Marlin)

## Fluxo padrão
1. Branch curta
2. PR pequeno (ideal <= 300 linhas)
3. CI verde (lint + smoke + checks SQL)
4. Revisão
5. Merge main
6. Verificar GitHub Pages + smoke produção

## Definition of Done
- UX validada em mobile e desktop
- Catálogo/admin funcionando
- Estacionamento sem dupla venda
- RLS/migrations versionadas
- Rollback documentado

## Métricas semanais (DORA-lite)
- Lead time de mudança
- Taxa de falha de deploy
- Tempo de recuperação
- Frequência de deploy
