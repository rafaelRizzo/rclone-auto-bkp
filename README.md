# 🗂️ Backup Manager

Script interativo para gerenciar backups automatizados com `rclone` e `cron`.

## Dependências

- `rclone` instalado e configurado (`rclone config`)
- `bash`, `tar`, `cron`

## Instalação

```bash
chmod +x backup-manager.sh
./backup-manager.sh
```

## Estrutura

```
/opt/backups/
├── scripts/   # Scripts gerados por job
├── logs/      # Logs por execução
└── <job>/     # Arquivos .tar.gz locais
```

## Funcionalidades

| Opção   | Descrição                                          |
| ------- | -------------------------------------------------- |
| Criar   | Configura novo job de backup                       |
| Listar  | Exibe jobs e agendamentos                          |
| Remover | Remove job, script e opcionalmente arquivos locais |

## Criando um Job

Campos solicitados:

- **Nome do job** — identificador único
- **Path local** — diretório/arquivo a ser backupeado
- **Destino rclone** — ex: `drive:backups/app` (digite `l` para listar remotes)
- **Retenção** — dias para manter backups locais
- **Frequência** — horária / diária / semanal / mensal

## Agendamentos Disponíveis

| Opção   | Cron        |
| ------- | ----------- |
| Horário | `0 * * * *` |
| Diário  | `0 2 * * *` |
| Semanal | `0 2 * * 0` |
| Mensal  | `0 2 1 * *` |

## O que cada execução faz

1. Adquire lock (`/tmp/<job>.lock`) — evita execuções paralelas
2. Compacta origem em `.tar.gz` com timestamp + hostname
3. Valida arquivo gerado (tamanho e SHA256)
4. Upload via `rclone` com retry e rate limit
5. Remove backups locais mais antigos que o período de retenção
6. Remove logs com mais de 15 dias
7. Registra duração total

## Logs

```
/opt/backups/logs/<job>-<data>.log
```

Formato:

```
[2025-01-01 02:00:01] [INFO] Iniciando backup
[2025-01-01 02:00:05] [INFO] Tamanho: 24M
[2025-01-01 02:00:05] [INFO] SHA256: abc123...
[2025-01-01 02:00:30] [INFO] Finalizado em 29s
```

## Upload (rclone)

Configurado com throttle para evitar rate limit:

- `--tpslimit 2` / `--tpslimit-burst 2`
- `--retries 5` / `--low-level-retries 10`
- Timeout de 1h por upload