#!/bin/bash

set -euo pipefail 
IFS=$'\n\t' 

#Логирование
LOG_FILE="/var/log/backup.log"
BACKUP_DIR="/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="backup_${TIMESTAMP}.gz"
TEMP_DIR=$(mktemp -d) 

   
#Постгре настройки

PG_HOST="localhost"
PG_PORT="5432"
PG_USER="postgres"




#функция логгирования:

log() {
    local level=$1
    shift 
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"  
}

log_info() {
    log "INFO" "$@"
}

log_error () {
    log "ERROR" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

#функция очистки

cleanup() {
    local exit_code=$?
    
    log_info "Очистка временных файлов!"
    
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_success "Временная директория удалена: $TEMP_DIR"
    fi
           
   
    if [[ $exit_code -ne 0 ]]; then
        log_error "Ошибка во время выполнения скрипта: $exit_code"
        exit $exit_code
    fi
}

trap cleanup EXIT

#функции проверок

check_dependencies() {
    log_info "Проверка наличия зависимостей..."
    local missing=()
    local dependencies=("gzip" "pg_dump" "psql")
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
            log_error "Не найдена утилита $dep"
        fi
    done    
    
    if (( ${#missing[@]} > 0 )); then
        log_error "Отсутствуют зависимости: ${missing[*]}"
        exit 1
    else 
        log_success "Все зависимости установлены!" 
    fi
}

check_diskspace() {
    log_info "Детальная проверка места для бэкапа..."
    
    local db_info
    db_info=$(psql -U postgres -d postgres -t -c "
        SELECT 
            datname,
            pg_size_pretty(pg_database_size(datname)) as size_pretty,
            pg_database_size(datname) as size_bytes
        FROM pg_database 
        WHERE datistemplate = false 
        AND datname NOT IN ('postgres')
        ORDER BY size_bytes DESC
    ")
    
    local total_size=0
    local safety_buffer=1.3  # 30% запас
    
    echo "Размеры баз данных:"
    while IFS='|' read -r db_name size_pretty size_bytes; do
        db_name=$(echo "$db_name" | xargs)
        size_pretty=$(echo "$size_pretty" | xargs)
        
        if [[ -n "$db_name" && -n "$size_bytes" ]]; then
            total_size=$((total_size + size_bytes))
            log_info "$db_name: $size_pretty"
        fi
    done <<< "$db_info"
    
    local required_space=$((total_size * safety_buffer))
    local available_space=$(df "$BACKUP_DIR" | awk "NR==2 {print \$4 * 1024}")  # в байтах
    
    local total_mb=$((total_size / 1024 / 1024))
    local required_mb=$((required_space / 1024 / 1024)) 
    local available_mb=$((available_space / 1024 / 1024))
    
    log_info "Общий размер БД: ${total_mb} MB"
    log_info "Требуется с запасом 30%: ${required_mb} MB"
    log_info "Доступно в $BACKUP_DIR: ${available_mb} MB"
    
    if [[ $available_space -lt $required_space ]]; then
        log_error "Недостаточно места! Нужно: ${required_mb} MB, доступно: ${available_mb} MB"
        exit 1
    fi
    
    log_success "Проверка места пройдена успешно"
    return 0
}

#основная логика бэкапа

main() {
    log_info "Приступаем к резервному копированию!"
    
    check_dependencies
    check_diskspace
    mkdir -p "$BACKUP_DIR"
    
    log_info "Получение списка баз данных!"
    local databases
    if ! databases=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -t -c "
        SELECT datname FROM pg_database
        WHERE datistemplate = false
        AND datname NOT IN ('postgres')
        order by datname;" 2>&1); then
        log_error "Ошибка при исполнении запроса psql: $databases"
        exit 1
    fi
    
    if [[ -z "$databases" ]]; then
        log_error "Ошибка получения списка датабаз или список пуст!"
        exit 1
    fi
    
    log_success "Датабазы найдены: $(echo "$databases" | tr '\n' ' ')" 
    
    local dump_errors=0
    
    for db in $databases; do
        log_info "Создание дампа для датабазы: $db"
        local dump_file="${TEMP_DIR}/${db}.sql"
        if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" -f "$dump_file" 2>>"$LOG_FILE"; then
            log_success "Дамп датабазы $db успешно создан!"
            if [[ ! -s "$dump_file" ]]; then
                log_error "Дамп датабазы $db НЕ создан или пуст!"
                ((dump_errors++))
            fi    
        else
            log_error "Ошибка при создании дампа $db"
            ((dump_errors++))
        fi    
    done

    if [[ $dump_errors -gt 0 ]]; then
        log_error "Ошибки при создании дампов датабазы. Всего $dump_errors ошибок!"
        exit 1
    fi    

#создание архива

    log_info "Создание архива $BACKUP_NAME"
    
    if cd "$TEMP_DIR" && tar -czf "${TEMP_DIR}/${BACKUP_NAME}" *.sql 2>>"$LOG_FILE"; then
        log_success "Архив ${TEMP_DIR}/${BACKUP_NAME} успешно создан!"
    else
        log_error "Ошибка при создании архива ${TEMP_DIR}/${BACKUP_NAME}"
    	exit 1
    fi    
    
#проверка валидности архива

    log_info "Проверка целостности архива ${TEMP_DIR}/${BACKUP_NAME}"
    if gzip -t "${TEMP_DIR}/${BACKUP_NAME}" 2>>"$LOG_FILE"; then
        log_success "Архив прошел проверку целостности!"
    else
        log_error "Архив НЕ прошёл проверку целостности!"
        exit 1
    fi    

#перемещение архива в целевую директорию

    log_info "Перемещение ${TEMP_DIR}/${BACKUP_NAME} в $BACKUP_DIR"
        if mv "${TEMP_DIR}/${BACKUP_NAME}" "${BACKUP_DIR}/${BACKUP_NAME}"; then
            log_success "Архив успешно перемещен ${BACKUP_DIR}/${BACKUP_NAME}!"
        else
            log_error "Произошла ошибка при перемещении архива в ${BACKUP_DIR}/${BACKUP_NAME}"
            exit 1
        fi    
       
#финальная проверка

    local final_size
    final_size=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}" | cut -f1)
    
    log_success "Резервное копирование успешно произведено!"
    log_success "Архив: ${BACKUP_DIR}/${BACKUP_NAME}" 
    log_success "Размер: $final_size KB"
}

if [[ $EUID -eq 0 ]]; then
    log_error "Ошибка: нельзя запускать от root. Используйте пользователя postgres!"
    exit 1
fi    

main
