#!/bin/bash
# Solon dual-vault monitor — read-only chain feed + BadDebt + keeper-event checks, alerts to the
# strategy group via the PM push bot. The bot token is sourced from the PM .env so it never lands
# in the launchd plist. Heartbeat check is OFF until the keeper writes a heartbeat file.
set -e
cd "$(dirname "$0")"
# dRPC (free key, archive + eth_getLogs span <=100 blocks) when a key is present; official public RPC otherwise.
DRPC_KEY="$(grep '^drpc=' "$HOME/.config/solon/rpc_keys.txt" 2>/dev/null | cut -d= -f2)"
if [ -n "$DRPC_KEY" ]; then
  export RPC_URL="https://lb.drpc.live/robinhood/$DRPC_KEY"
  export BLOCK_BATCH="100"
  export MAX_EVENT_BATCHES="30"   # 30x100 blocks per poll, RH makes ~600/min
else
  export RPC_URL="https://rpc.mainnet.chain.robinhood.com/rpc"
fi
unset DRPC_KEY
export VAULT="0x9Db7aDa64D1E8b856E15D916d886797501F28ce0"
export CHAIN_ID="4663"
export START_BLOCK="56546362"          # mainnet deploy floor — sees every position from genesis (state is persisted after first catch-up)
export HEARTBEAT_ENABLED="true"        # keeper (farmkeeper-dual) writes runtime/keeper-heartbeat.json each successful scan
export TELEGRAM_CHAT_ID="-5194704210"  # strategy group
export TELEGRAM_BOT_TOKEN="$(grep '^TG_PM_BOT_TOKEN=' $HOME/clawd/polymarket_bot/.env | cut -d= -f2- | sed -E 's/^["'\'' ]+//; s/["'\'' ]+$//')"
exec node index.mjs
