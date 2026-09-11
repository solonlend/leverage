#!/bin/bash
# Solon dual-vault monitor — read-only chain feed + BadDebt + keeper-event checks, alerts to the
# strategy group via the PM push bot. The bot token is sourced from the PM .env so it never lands
# in the launchd plist. Heartbeat check is OFF until the keeper writes a heartbeat file.
set -e
cd "$(dirname "$0")"
export RPC_URL="https://rpc.mainnet.chain.robinhood.com/rpc"
export VAULT="0x9Db7aDa64D1E8b856E15D916d886797501F28ce0"
export CHAIN_ID="4663"
export START_BLOCK="56546362"          # mainnet deploy floor — sees every position from genesis (state is persisted after first catch-up)
export HEARTBEAT_ENABLED="true"        # keeper (farmkeeper-dual) writes runtime/keeper-heartbeat.json each successful scan
export TELEGRAM_CHAT_ID="-5194704210"  # strategy group
export TELEGRAM_BOT_TOKEN="$(grep '^TG_PM_BOT_TOKEN=' $HOME/clawd/polymarket_bot/.env | cut -d= -f2- | sed -E 's/^["'\'' ]+//; s/["'\'' ]+$//')"
exec node index.mjs
