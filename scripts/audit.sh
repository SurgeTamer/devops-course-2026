#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]  $desc"
        ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
        ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

# TODO 1: проверьте, что значение параметра port отлично от 22
PORT_ACTUAL=$(sudo sshd -T | awk '/^port/{print $2}')
if [[ "$PORT_ACTUAL" != "22" && -n "$PORT_ACTUAL" ]]; then
    echo " [OK]  Порт SSH изменён (текущий: $PORT_ACTUAL)"
    ((PASS++))
else
    echo " [FAIL] Порт SSH не изменён (текущий: ${PORT_ACTUAL:-'не определен'})"
    ((FAIL++))
fi

# TODO 2: проверьте, что значение параметра maxauthtries равно 3
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# TODO 3: проверьте, что политика по умолчанию для входящего трафика равна deny
UFW_DEFAULT_IN=$(sudo ufw status verbose | grep Default | awk '{print $2}')
check "Политика по умолчанию для входящего трафика — deny" "deny" "$UFW_DEFAULT_IN"

echo "[3] Учётные записи"
awk -F: ' $3>=1000 && $3<65534 {printf " %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

echo "[4] Веб-сервер"
# Проверка синтаксиса Nginx (код возврата 0)
sudo nginx -t >/dev/null 2>&1
check "Конфигурация Nginx корректна" "0" "$?"

# Проверка срока действия сертификата (не истекает в ближайшие 30 дней)
# 2592000 секунд = 30 дней. Если сертификат действителен, код возврата 0.
openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/devops.crt >/dev/null 2>&1
check "Сертификат истекает не ранее чем через 30 дней" "0" "$?"

# Проверка отсутствия файлов с правом записи для всех
W_WRITABLE=$(find /var/www/devops-site -perm -o+w 2>/dev/null)
check "В каталоге ресурса нет файлов с правом записи для всех" "" "$W_WRITABLE"

# Проверка прав на закрытый ключ
check "Права ключа равны 600" "600" "$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1)"
# Проверка портов (если что-то слушает на *:5000 или *:5432 - это FAIL)
PORTS_ACTUAL=$(sudo ss -tln | awk '$4 ~ /:5000$|:5432$/ && $4 !~ /^127.0.0.1/ {print $4}')
check "Порты БД и App не доступны извне" "" "$PORTS_ACTUAL"
check "Права файла .env равны 600" "600" "$(sudo stat -c '%a' /home/devops/app/.env)"
