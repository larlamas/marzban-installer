#!/bin/bash

# 1. Запрос домена у пользователя
read -p "Пожалуйста, введите домен (SNI) [например, example.com]: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "Ошибка: Домен обязателен."
    exit 1
fi

# Убедимся, что DEST формируется корректно
DEST="${DOMAIN}:443"
echo "Используемый домен: $DOMAIN"
echo "Цель (dest): $DEST"

# 2. Генерация ключей через docker (Marzban)
echo "Генерация ключей (sudo docker exec marzban-marzban-1 xray x25519)..."
# Используем eval или просто запуск, но убедимся, что ошибки ловятся
KEY_OUTPUT=$(sudo docker exec marzban-marzban-1 xray x25519 2>&1)
RET_CODE=$?

if [ $RET_CODE -ne 0 ]; then
    echo "ОШИБКА: Не удалось выполнить команду в Docker."
    echo "Детали: $KEY_OUTPUT"
    echo "Убедитесь, что Marzban установлен и запущен (контейнер marzban-marzban-1)."
    exit 1
fi

# Извлечение ключей
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key:" | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ОШИБКА: Не удалось распарсить ключи из вывода xray."
    echo "Вывод был: $KEY_OUTPUT"
    exit 1
fi

echo "Приватный ключ получен."
echo "Публичный ключ получен."

# 3. Генерация ShortID
echo "Генерация ShortID (openssl)..."
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$SHORT_ID" ]; then
    echo "ОШИБКА: Не удалось сгенерировать ShortID. Проверьте наличие openssl."
    exit 1
fi

echo "ShortID: $SHORT_ID"

# 4. Формирование JSON
OUTPUT_FILE="config.json"

cat > "$OUTPUT_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK",
        "type": "field"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "DIRECT"
    },
    {
      "protocol": "blackhole",
      "tag": "BLOCK"
    }
  ]
}
EOF

echo ""
echo "==================================================="
echo " УСПЕХ! Конфигурация сохранена в файл: $OUTPUT_FILE"
echo "==================================================="
echo "Вы можете скопировать содержимое ниже:"
echo ""
cat "$OUTPUT_FILE"
echo ""
