#!/bin/bash

set -e

BASE_DIR="/opt/backups"
SCRIPTS_DIR="$BASE_DIR/scripts"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$SCRIPTS_DIR"
mkdir -p "$LOG_DIR"

# =========================
# LISTAR JOBS
# =========================
list_jobs() {
    echo "=== BACKUPS CONFIGURADOS ==="

    local found=0
    for file in "$SCRIPTS_DIR"/*.sh; do
        [ -e "$file" ] || continue
        found=1

        JOB_NAME=$(basename "$file" .sh)
        CRON_LINE=$(crontab -l 2>/dev/null | grep "$file" || true)

        echo "--------------------------------"
        echo "Job:        $JOB_NAME"
        echo "Script:     $file"
        echo "Cron:       ${CRON_LINE:-Não encontrado}"
    done

    if [ "$found" -eq 0 ]; then
        echo "Nenhum job configurado"
    fi
    return 0
}

# =========================
# REMOVER JOB
# =========================
remove_job() {
    read -p "Nome do job: " JOB_NAME

    SCRIPT_PATH="$SCRIPTS_DIR/$JOB_NAME.sh"
    BACKUP_DIR="$BASE_DIR/$JOB_NAME"

    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Job não encontrado"
        return
    fi

    read -p "Confirmar remoção? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    rm -f "$SCRIPT_PATH"

    read -p "Remover arquivos locais também? (y/n): " del
    if [ "$del" = "y" ]; then rm -rf "$BACKUP_DIR"; fi

    echo "Removido com sucesso"
}

# =========================
# EXECUTAR JOB AGORA
# =========================
run_job() {
    read -p "Nome do job: " JOB_NAME
    SCRIPT_PATH="$SCRIPTS_DIR/$JOB_NAME.sh"

    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Job não encontrado"
        return
    fi

    echo "Executando $JOB_NAME..."
    bash "$SCRIPT_PATH"
}

# =========================
# CRIAR JOB
# =========================
create_job() {

    echo "=== CONFIGURADOR DE BACKUP ==="

    # --- Nome do job ---
    while true; do
        read -p "Nome do job: " JOB_NAME
        if [[ ! "$JOB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Nome inválido (use apenas letras, números, _ e -)"
            continue
        fi
        SCRIPT_PATH="$SCRIPTS_DIR/$JOB_NAME.sh"
        if [ -f "$SCRIPT_PATH" ]; then
            echo "Job '$JOB_NAME' já existe. Escolha outro nome."
            continue
        fi
        break
    done

    # --- Path local ---
    while true; do
        read -p "Path local: " LOCAL_PATH
        if [ ! -e "$LOCAL_PATH" ]; then
            echo "Path não existe: $LOCAL_PATH"
            continue
        fi
        break
    done

    # --- Remote rclone ---
    while true; do
        echo ""
        echo "Digite o destino no rclone (ex: drive:backups/app)"
        echo "ou 'l' para listar remotes configurados"
        read -p "Destino: " REMOTE_INPUT

        if [ "$REMOTE_INPUT" = "l" ]; then
            echo ""
            echo "=== REMOTES DISPONÍVEIS ==="
            rclone listremotes
            echo "==========================="
            continue
        fi

        if [ -z "$REMOTE_INPUT" ]; then
            echo "Destino não pode ser vazio"
            continue
        fi

        REMOTE_NAME=$(echo "$REMOTE_INPUT" | cut -d':' -f1)

        if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
            echo "Remote '$REMOTE_NAME' não existe"
            continue
        fi

        echo "Testando acesso e criando diretório se necessário..."
        if ! rclone mkdir "$REMOTE_INPUT" &>/dev/null; then
            echo "Falha ao acessar/criar '$REMOTE_INPUT'. Verifique permissões."
            continue
        fi
        echo "OK: $REMOTE_INPUT"

        REMOTE_PATH="$REMOTE_INPUT"
        break
    done

    # --- Retenção ---
    while true; do
        read -p "Retenção (dias): " RETENTION_DAYS
        if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$RETENTION_DAYS" -lt 1 ]; then
            echo "Informe um número válido de dias (mínimo 1)"
            continue
        fi
        break
    done

    # --- Agendamento ---
    echo "1) Hora"
    echo "2) Diário"
    echo "3) Semanal"
    echo "4) Mensal"
    read -p "Opção: " S

    case $S in
        1)
            CRON="0 * * * *"
            if [ "$RETENTION_DAYS" -lt 1 ]; then
                echo "⚠ Atenção: backup horário com retenção menor que 1 dia pode acumular muitos arquivos."
            fi
            ;;
        2) CRON="0 2 * * *" ;;
        3) CRON="0 2 * * 0" ;;
        4) CRON="0 2 1 * *" ;;
        *) echo "Inválido"; return ;;
    esac

    # --- Notificação ---
    NOTIFY_URL=""
    read -p "Webhook para notificação de falha (deixe vazio para pular): " NOTIFY_URL

    BACKUP_DIR="$BASE_DIR/$JOB_NAME"
    mkdir -p "$BACKUP_DIR"

    cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash

set -euo pipefail

JOB_NAME="$JOB_NAME"
LOCAL_PATH="$LOCAL_PATH"
REMOTE_PATH="$REMOTE_PATH"
RETENTION_DAYS=$RETENTION_DAYS
NOTIFY_URL="$NOTIFY_URL"

BACKUP_DIR="$BACKUP_DIR"
LOG_DIR="$LOG_DIR"

DATE=\$(date +"%Y-%m-%d_%H-%M-%S")
FILE_NAME="\${JOB_NAME}-\$(hostname)-\$DATE.tar.gz"
BACKUP_PATH="\$BACKUP_DIR/\$FILE_NAME"
LOG_FILE="\$LOG_DIR/\${JOB_NAME}-\$DATE.log"

LOCK_FILE="/tmp/\${JOB_NAME}.lock"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [\$1] \$2" | tee -a "\$LOG_FILE"
}

notify_failure() {
    local MSG="\$1"
    log ERROR "\$MSG"
    if [ -n "\$NOTIFY_URL" ]; then
        curl -sf -X POST "\$NOTIFY_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"❌ Backup FALHOU: \${JOB_NAME} — \${MSG}\"}" \
            &>/dev/null || true
    fi
}

FAILED=0

on_exit() {
    rm -f "\$LOCK_FILE"
    if [ "\$FAILED" -eq 1 ]; then
        notify_failure "Erro inesperado — verifique o log: \$LOG_FILE"
    fi
}

trap 'FAILED=1' ERR
trap 'on_exit' EXIT

# =========================
# LOCK COM PID
# =========================
if [ -f "\$LOCK_FILE" ] && kill -0 "\$(cat "\$LOCK_FILE")" 2>/dev/null; then
    log ERROR "Já está rodando (PID \$(cat "\$LOCK_FILE"))"
    exit 1
fi
echo \$\$ > "\$LOCK_FILE"

START=\$(date +%s)

log INFO "Iniciando backup"
log INFO "Origem: \$LOCAL_PATH"
log INFO "Destino: \$REMOTE_PATH"

# =========================
# VALIDAÇÕES
# =========================
if [ ! -e "\$LOCAL_PATH" ]; then
    notify_failure "Path inválido: \$LOCAL_PATH"
    exit 1
fi

if ! command -v rclone &> /dev/null; then
    notify_failure "rclone não instalado"
    exit 1
fi

# =========================
# COMPACTAR (sem -v para não encher log)
# =========================
log INFO "Compactando..."
tar -czf "\$BACKUP_PATH" -C "\$(dirname "\$LOCAL_PATH")" "\$(basename "\$LOCAL_PATH")" >> "\$LOG_FILE" 2>&1

if [ ! -s "\$BACKUP_PATH" ]; then
    notify_failure "Arquivo gerado está vazio ou inválido"
    exit 1
fi

SIZE=\$(du -h "\$BACKUP_PATH" | cut -f1)
log INFO "Tamanho: \$SIZE"

HASH=\$(sha256sum "\$BACKUP_PATH" | awk '{print \$1}')
log INFO "SHA256: \$HASH"

# =========================
# UPLOAD
# =========================
log INFO "Upload..."

if timeout 1h rclone copy "\$BACKUP_PATH" "\$REMOTE_PATH" \
    --stats 5s \
    --stats-one-line \
    --log-level INFO \
    --retries 5 \
    --low-level-retries 10 \
    --transfers 1 \
    --checkers 2 \
    --tpslimit 2 \
    --tpslimit-burst 2 \
    2>&1 | tee -a "\$LOG_FILE"; then

    log INFO "Upload concluído"
else
    notify_failure "Erro no upload para \$REMOTE_PATH"
    exit 1
fi

# =========================
# LIMPEZA
# =========================
find "\$BACKUP_DIR" -type f -mtime +\$RETENTION_DAYS -delete >> "\$LOG_FILE" 2>&1
find "\$LOG_DIR" -type f -name "*.log" -mtime +15 -delete
find "\$LOG_DIR" -type f -name "*.log" -size +50M -delete

END=\$(date +%s)
DUR=\$((END - START))

log INFO "Finalizado em \${DUR}s"

EOF

    chmod +x "$SCRIPT_PATH"

    (crontab -l 2>/dev/null; echo "$CRON $SCRIPT_PATH") | crontab -

    echo ""
    echo "✅ Job '$JOB_NAME' criado com sucesso"
    echo "   Cron: $CRON"
    echo "   Script: $SCRIPT_PATH"
}

# =========================
# MENU
# =========================

while true; do
    echo ""
    echo "====== BACKUP MANAGER ======"
    echo "1) Criar"
    echo "2) Listar"
    echo "3) Remover"
    echo "4) Executar agora"
    echo "5) Sair"
    echo "============================"
    read -p "Opção: " OP

    case $OP in
        1) create_job ;;
        2) list_jobs ;;
        3) remove_job ;;
        4) run_job ;;
        5) exit ;;
        *) echo "Inválido" ;;
    esac
done