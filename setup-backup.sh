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

    for file in "$SCRIPTS_DIR"/*.sh; do
        [ -e "$file" ] || continue

        JOB_NAME=$(basename "$file" .sh)
        CRON=$(crontab -l 2>/dev/null | grep "$file" || true)

        echo "--------------------------------"
        echo "Job: $JOB_NAME"
        echo "Script: $file"
        echo "Cron: ${CRON:-Não encontrado}"
    done
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
    [ "$confirm" != "y" ] && return

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -

    rm -f "$SCRIPT_PATH"

    read -p "Remover arquivos locais também? (y/n): " del
    [ "$del" = "y" ] && rm -rf "$BACKUP_DIR"

    echo "Removido com sucesso"
}

# =========================
# CRIAR JOB
# =========================
create_job() {

    echo "=== CONFIGURADOR DE BACKUP ==="

    read -p "Nome do job: " JOB_NAME
    read -p "Path local: " LOCAL_PATH

    # =========================
    # ESCOLHER REMOTE
    # =========================
    while true; do
        echo ""
        echo "Digite o destino no rclone (ex: drive:backups/app)"
        echo "ou digite 'l' para listar os remotes configurados"
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
            echo "Remote não existe"
            continue
        fi

        REMOTE_PATH="$REMOTE_INPUT"
        break
    done

    read -p "Retenção (dias): " RETENTION_DAYS

    echo "1) Hora"
    echo "2) Diário"
    echo "3) Semanal"
    echo "4) Mensal"
    read -p "Opção: " S

    case $S in
        1) CRON="0 * * * *" ;;
        2) CRON="0 2 * * *" ;;
        3) CRON="0 2 * * 0" ;;
        4) CRON="0 2 1 * *" ;;
        *) echo "Inválido"; return ;;
    esac

    BACKUP_DIR="$BASE_DIR/$JOB_NAME"
    SCRIPT_PATH="$SCRIPTS_DIR/$JOB_NAME.sh"

    mkdir -p "$BACKUP_DIR"

    cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash

set -euo pipefail

JOB_NAME="$JOB_NAME"
LOCAL_PATH="$LOCAL_PATH"
REMOTE_PATH="$REMOTE_PATH"
RETENTION_DAYS=$RETENTION_DAYS

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

# LOCK
if [ -f "\$LOCK_FILE" ]; then
    echo "Já está rodando" >> "\$LOG_FILE"
    exit 1
fi
trap "rm -f \$LOCK_FILE" EXIT
touch "\$LOCK_FILE"

START=\$(date +%s)

log INFO "Iniciando backup"
log INFO "Origem: \$LOCAL_PATH"
log INFO "Destino: \$REMOTE_PATH"

# validações
if [ ! -e "\$LOCAL_PATH" ]; then
    log ERROR "Path inválido"
    exit 1
fi

if ! command -v rclone &> /dev/null; then
    log ERROR "rclone não instalado"
    exit 1
fi

# compactar
log INFO "Compactando..."
tar -czvf "\$BACKUP_PATH" -C "\$(dirname "\$LOCAL_PATH")" "\$(basename "\$LOCAL_PATH")" >> "\$LOG_FILE" 2>&1

# validar arquivo
if [ ! -s "\$BACKUP_PATH" ]; then
    log ERROR "Arquivo inválido"
    exit 1
fi

SIZE=\$(du -h "\$BACKUP_PATH" | cut -f1)
log INFO "Tamanho: \$SIZE"

HASH=\$(sha256sum "\$BACKUP_PATH" | awk '{print \$1}')
log INFO "SHA256: \$HASH"

# =========================
# UPLOAD (AJUSTADO PARA RATE LIMIT)
# =========================

log INFO "Upload..."

if timeout 1h rclone copy "\$BACKUP_PATH" "\$REMOTE_PATH" \\
    --stats 5s \\
    --stats-one-line \\
    --log-level INFO \\
    --retries 5 \\
    --low-level-retries 10 \\
    --transfers 1 \\
    --checkers 2 \\
    --tpslimit 2 \\
    --tpslimit-burst 2 \\
    2>&1 | tee -a "\$LOG_FILE"; then

    log INFO "Upload concluído"
else
    log ERROR "Erro no upload"
    exit 1
fi

# limpar backups antigos
find "\$BACKUP_DIR" -type f -mtime +\$RETENTION_DAYS -delete >> "\$LOG_FILE" 2>&1

# limpar logs antigos
find "\$LOG_DIR" -type f -mtime +15 -delete

END=\$(date +%s)
DUR=\$((END - START))

log INFO "Finalizado em \${DUR}s"

EOF

    chmod +x "$SCRIPT_PATH"

    (crontab -l 2>/dev/null; echo "$CRON $SCRIPT_PATH") | crontab -

    echo "Criado com sucesso"
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
    echo "4) Sair"
    echo "============================"
    read -p "Opção: " OP

    case $OP in
        1) create_job ;;
        2) list_jobs ;;
        3) remove_job ;;
        4) exit ;;
        *) echo "Inválido" ;;
    esac
done