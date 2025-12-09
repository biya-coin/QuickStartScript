#!/usr/bin/env bash
set -euo pipefail

# 优先使用 Go 安装目录中的二进制（例如 /home/ubuntu/go/bin/injectived / peggo）
export PATH="$HOME/go/bin:$PATH"

########## 配置项 ##########

TMP_DIR="/tmp/injective-release"

# 自定义 GitHub 仓库配置
INJECTIVE_CORE_REPO="https://github.com/biya-coin/injective-core.git"

# 固定 libwasmvm 版本
LIBWASMVM_VERSION="v1.16.1"


# lucky meat time clip thank table ancient burden boil junk curtain benefit
# Ethereum / Sepolia 相关配置（可按需修改）
ETH_NETWORK_NAME="sepolia"
ETH_CHAIN_ID="11155111"
ETH_RPC_URL="https://sepolia.infura.io/v3/7992c93ae01c402f806c5eec196f8c2b"
ETH_PRIVATE_KEY="0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1"  # 不要提交真实私钥到仓库，此私钥为一次性私钥

# 最小 ETH 余额（以 wei 为单位）
MIN_ETH_BALANCE="50000000000000000"  # 0.05 ETH
TARGET_ETH_BALANCE="100000000000000000"  # 0.1 ETH

# Injective 链配置
INJ_CHAIN_ID="injective-666"              # 官方 setup.sh 中使用的 chain-id，可按需修改
INJ_HOME_DIR="$HOME/.injectived"         # 官方脚本默认 home 目录
INJ_GENESIS_PATH="${INJ_HOME_DIR}/config/genesis.json"
INJ_OFFICIAL_SETUP_URL="https://raw.githubusercontent.com/InjectiveLabs/injective-chain-releases/master/scripts/setup.sh"
INJ_OFFICIAL_SETUP_SCRIPT="${TMP_DIR}/injective-node-setup.sh"

RESET_GENESIS=""   # 运行时由交互函数决定是否重置 genesis

# Peggy 合约部署参数（覆盖 deploy-on-evm.sh 默认值）
PEGGY_POWER_THRESHOLD="100"
PEGGY_VALIDATOR_POWERS="4294967295"

# Chainstream / JSON-RPC 相关配置（用于在节点启动时同时启用流服务）
CHAINSTREAM_ADDR="${CHAINSTREAM_ADDR:-0.0.0.0:9999}"
CHAINSTREAM_BUFFER_CAP="${CHAINSTREAM_BUFFER_CAP:-1000}"
CHAINSTREAM_PUBLISHER_BUFFER_CAP="${CHAINSTREAM_PUBLISHER_BUFFER_CAP:-1000}"

# 部署脚本 .env 参数（基于 .env.example）
PEGGY_DEPLOYER_RPC_URI="${ETH_RPC_URL}"
PEGGY_DEPLOYER_TX_GAS_PRICE="-1"       # -1 表示由部署脚本自行估算 gas price
PEGGY_DEPLOYER_TX_GAS_LIMIT="8000000"  # 提高默认 gas limit，避免合约部署时 out of gas
PEGGY_DEPLOYER_FROM=""              # 部署者地址，可选
PEGGY_DEPLOYER_FROM_PK="${ETH_PRIVATE_KEY}"

# 使用 biya-coin 的仓库
INJECTIVE_CORE_REPO="https://github.com/biya-coin/injective-core.git"
INJECTIVE_CORE_DIR="${TMP_DIR}/injective-core-src"

UNAME_OUT="$(uname -s)"
case "${UNAME_OUT}" in
  Linux*)   LIBWASMVM_TARGET_DIR="/usr/lib";;
  Darwin*)  LIBWASMVM_TARGET_DIR="/usr/local/lib";;
  *)        LIBWASMVM_TARGET_DIR="/usr/lib";;
esac

########## 日志记录 ##########
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >&2
    
    # 同时输出到日志文件
    if [ -n "${LOG_FILE:-}" ] && [ "$level" != "DEBUG" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# 设置日志文件
LOG_FILE="${TMP_DIR}/setup.log"
mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

########## 环境检查 ##########

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 验证环境
validate_environment() {
    log "INFO" "开始环境检查..."
    
    # 检查必需的命令
    local required_commands=("git" "curl" "make" "gcc" "go" "jq")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        log "ERROR" "缺少必要的命令: ${missing_commands[*]}"
        return 1
    fi
    
    # 检查环境变量
    local required_vars=("ETH_RPC_URL" "ETH_PRIVATE_KEY")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        log "ERROR" "缺少必要的环境变量: ${missing_vars[*]}"
        return 1
    fi
    
    # 检查 Go 版本
    local go_version
    go_version=$(go version | grep -o 'go[0-9.]*' | tr -d 'go')
    if [ "$(echo "$go_version < 1.20" | bc -l)" -eq 1 ]; then
        log "WARN" "检测到 Go 版本 $go_version，建议使用 Go 1.20 或更高版本"
    fi
    
    log "INFO" "环境检查通过"
    return 0
}


cleanup() {
  local exit_code=$?
  # 调试阶段：暂时不自动删除 TMP_DIR，方便查看 deploy.log 等中间文件
  echo "[cleanup] 脚本退出(exit_code=$exit_code)，调试模式下保留临时目录: ${TMP_DIR}"
  # 如需恢复自动清理，可将下面一行取消注释：
  # rm -rf "$TMP_DIR"
}

trap cleanup EXIT

cleanup_tmp_dir_prompt() {
  # 仅在 TMP_DIR 存在时提供交互式清理选项
  if [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ]; then
    return 0
  fi

  echo "[cleanup] 临时目录位置: ${TMP_DIR}"
  read -r -p "[cleanup] 是否删除该临时目录及其中的下载源码和中间文件？[y/N]: " ans
  case "$ans" in
    y|Y)
      rm -rf "$TMP_DIR" || true
      echo "[cleanup] 已删除临时目录 ${TMP_DIR}"
      ;;
    *)
      echo "[cleanup] 已保留临时目录 ${TMP_DIR}"
      ;;
  esac
}

########## 统一清理函数：停止旧进程并重置链数据 ##########

cleanup_injective_and_peggo() {
  echo "[cleanup] 停止旧的 injectived / peggo 进程和 tmux 会话（不在此处重置链数据）"

  if command_exists tmux; then
    tmux kill-session -t inj 2>/dev/null || true
    tmux kill-session -t orchestrator 2>/dev/null || true
  fi

  # 尝试结束可能存在的裸进程（忽略错误）
  pkill -f injectived 2>/dev/null || true
  pkill -f peggo 2>/dev/null || true
}

# 源化 shell 配置文件以应用环境变量
source_shell_config() {
  # 尝试 source .zshrc
  if [ -f "${HOME}/.zshrc" ]; then
    echo "[injective] 正在应用 .zshrc 中的环境变量..."
    # shellcheck source=/dev/null
    source "${HOME}/.zshrc" || true
  fi
  
  # 尝试 source .bashrc
  if [ -f "${HOME}/.bashrc" ]; then
    echo "[injective] 正在应用 .bashrc 中的环境变量..."
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" || true
  fi
  
  # 确保 PATH 包含必要的目录
  export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_injective_binary() {
  if ! command_exists injectived; then
    echo "[injective] 未检测到 injectived，将执行安装"
    return 1
  fi

  local current_version
  current_version="$(injectived version 2>/dev/null || echo "")"

  if [ -z "${INJ_RELEASE_TAG:-}" ]; then
    echo "[injective] INJ_RELEASE_TAG 未配置，跳过版本校验"
    return 0
  fi

  # 从 INJ_RELEASE_TAG 中提取版本号和 commit 短哈希，例如 v1.16.4-470633e84
  local expected_version_part expected_commit_part
  expected_version_part="${INJ_RELEASE_TAG%-*}"
  expected_commit_part="${INJ_RELEASE_TAG##*-}"

  if echo "$current_version" | grep -q "$expected_version_part" && \
     echo "$current_version" | grep -q "$expected_commit_part"; then
    echo "[injective] 检测到期望的 injectived: $current_version (匹配 INJ_RELEASE_TAG=$INJ_RELEASE_TAG)"
    return 0
  fi

  echo "[injective] 当前 injectived: $current_version"
  echo "[injective] 预期版本/commit 来自 INJ_RELEASE_TAG=$INJ_RELEASE_TAG (版本: $expected_version_part, commit: $expected_commit_part)"
  return 1
}

########## 工具函数：通过 RPC 推断 Peggy 部署高度 ##########

get_peggy_block_height_from_rpc() {
  local peggy_addr="$1"

  if [ -z "$peggy_addr" ] || [ -z "$ETH_RPC_URL" ]; then
    echo ""
    return 0
  fi

  local rpc_url="$ETH_RPC_URL"
  local fast_window=20
  local fallback_offset=50

  # 转小写，便于与 RPC 返回的地址格式对齐
  local peggy_addr_lc
  peggy_addr_lc="$(echo "$peggy_addr" | tr 'A-Z' 'a-z')"

  # 1) 获取最新区块号
  local payload_latest latest_hex latest_dec
  payload_latest='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  latest_hex="$(curl -s -X POST -H 'Content-Type: application/json' --data "$payload_latest" "$rpc_url" \
    | grep -o '"result":"0x[0-9a-fA-F]\+"' | head -n1 | sed 's/.*"result":"\(0x[0-9a-fA-F]\+\)".*/\1/' || true)"

  if [ -z "$latest_hex" ]; then
    echo ""
    return 0
  fi

  latest_dec=$((latest_hex))

  # 内部小函数：在 [start, end] 范围内查找首次有代码的高度
  peggy_find_height_in_range() {
    local start="$1"
    local end="$2"

    if [ "$start" -lt 0 ]; then
      start=0
    fi

    local h height_hex payload_code code_result
    for ((h=start; h<=end; h++)); do
      height_hex=$(printf "0x%x" "$h")

      payload_code=$(cat <<EOF
{"jsonrpc":"2.0","method":"eth_getCode","params":["${peggy_addr_lc}","${height_hex}"],"id":1}
EOF
)

      code_result="$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' --data "$payload_code" "$rpc_url" \
        | grep -o '"result":"0x[0-9a-fA-F]\+"' | head -n1 | sed 's/.*"result":"\([0-9a-zA-Zx]\+\)".*/\1/' || true)"

      if [ -n "$code_result" ] && [ "$code_result" != "0x" ]; then
        echo "$h"
        return 0
      fi
    done

    return 1
  }

  # 2) 快速路径：latest-fast_window 到 latest
  local fast_start fast_end
  fast_start=$((latest_dec - fast_window))
  fast_end=$latest_dec

  local h_fast
  h_fast="$(peggy_find_height_in_range "$fast_start" "$fast_end" || true)"
  if [ -n "$h_fast" ]; then
    echo "$h_fast"
    return 0
  fi

  # 3) 兜底路径：直接使用 latest-fallback_offset 作为起始高度（偏早一点更安全）
  local fallback_start
  fallback_start=$((latest_dec - fallback_offset))
  if [ "$fallback_start" -lt 0 ]; then
    fallback_start=0
  fi

  echo "$fallback_start"
  return 0
}

########## 工具函数：从 genesis 地址推导 valoper / orchestrator ##########

get_genesis_valoper_and_orchestrator() {
  local inj_addr="$1"

  if [ -z "$inj_addr" ]; then
    echo "" ""
    return 0
  fi

  # 某些环境下 debug addr 也会要求输入密码，这里默认使用 12345678 自动输入
  local debug_out
  debug_out="$(printf '12345678\n' | injectived debug addr "${inj_addr}" 2>/dev/null || true)"

  local acc_addr valoper_addr
  acc_addr="$(echo "$debug_out" | awk '/Bech32 Acc:/ {print $3}' | head -n1)"
  valoper_addr="$(echo "$debug_out" | awk '/Bech32 Val:/ {print $3}' | head -n1)"

  echo "$acc_addr" "$valoper_addr"
}

########## 工具函数：确保 jq 可用 ##########

ensure_jq() {
  if command_exists jq; then
    return 0
  fi

  echo "[genesis] 未检测到 jq，尝试使用 apt 安装 jq..."
  if command_exists sudo; then
    sudo apt-get update -y && sudo apt-get install -y jq || true
  else
    apt-get update -y && apt-get install -y jq || true
  fi

  if ! command_exists jq; then
    echo "[genesis] 错误: 未能安装 jq，请手动安装 jq 后重试" >&2
    return 1
  fi
}

########## 更新 Injective genesis.json 的 Peggy 配置 ##########

update_injective_genesis_with_peggy() {
  local peggy_addr="$1"
  local peggy_height="$2"

  if [ -z "$peggy_addr" ] || [ -z "$peggy_height" ]; then
    echo "[genesis] 警告: Peggy 地址或部署高度为空，跳过 genesis 更新" >&2
    return 0
  fi

  if [ ! -f "$INJ_GENESIS_PATH" ]; then
    echo "[genesis] 警告: 未找到 genesis.json ($INJ_GENESIS_PATH)，跳过 genesis 更新" >&2
    return 0
  fi

  ensure_jq || return 1

  local genesis_inj_addr orchestrator_addr genesis_valoper_addr
  genesis_inj_addr="$(get_genesis_injective_address)"
  read orchestrator_addr genesis_valoper_addr <<EOF
$(get_genesis_valoper_and_orchestrator "$genesis_inj_addr")
EOF

  # 将解析出的地址保存到全局变量，供后续 register_orchestrator_address 等函数复用
  GENESIS_INJ_ADDR="$genesis_inj_addr"

  if [ -z "$orchestrator_addr" ] || [ -z "$genesis_valoper_addr" ]; then
    echo "[genesis] 警告: 无法从 genesis 地址推导 orchestrator / valoper，跳过 genesis 更新" >&2
    return 0
  fi

  echo "[genesis] 使用 Peggy 地址 ${peggy_addr}, 部署高度 ${peggy_height} 更新 genesis.json"
  echo "[genesis] orchestrator=${orchestrator_addr}, valoper=${genesis_valoper_addr}"

  jq \
    --arg bridge_addr "$peggy_addr" \
    --argjson chain_id "$ETH_CHAIN_ID" \
    --argjson bridge_height "$peggy_height" \
    --arg val_power "$PEGGY_VALIDATOR_POWERS" \
    --arg val_eth_addr "$GENESIS_EVM_ADDR" \
    --arg orchestrator "$orchestrator_addr" \
    --arg valoper "$genesis_valoper_addr" \
    '
    .app_state.peggy.params.bridge_ethereum_address = $bridge_addr
    | .app_state.peggy.params.bridge_chain_id = ($chain_id | tonumber)
    | .app_state.peggy.params.bridge_contract_start_height = $bridge_height
    | .app_state.peggy.last_observed_nonce = "1"
    | .app_state.peggy.valsets = [
        {
          nonce: "1",
          members: [
            {
              power: $val_power,
              ethereum_address: $val_eth_addr
            }
          ],
          height: "1",
          reward_amount: "0",
          reward_token: "0x0000000000000000000000000000000000000000"
        }
      ]
    | .app_state.peggy.attestations = [
        {
          observed: true,
          votes: [ $valoper ],
          height: "1",
          claim: {
            "@type": "/injective.peggy.v1.MsgValsetUpdatedClaim",
            event_nonce: "1",
            valset_nonce: "1",
            block_height: ($bridge_height | tostring),
            members: [
              {
                power: $val_power,
                ethereum_address: $val_eth_addr
              }
            ],
            reward_amount: "0",
            reward_token: "0x0000000000000000000000000000000000000000",
            orchestrator: ""
          }
        }
      ]
    | .app_state.peggy.last_observed_valset = {
        nonce: "1",
        members: [
          {
            power: $val_power,
            ethereum_address: $val_eth_addr
          }
        ],
        height: "1",
        reward_amount: "0",
        reward_token: "0x0000000000000000000000000000000000000000"
      }
    ' "$INJ_GENESIS_PATH" > "${INJ_GENESIS_PATH}.tmp" && mv "${INJ_GENESIS_PATH}.tmp" "$INJ_GENESIS_PATH"

  echo "[genesis] genesis.json 已根据 Peggy 部署结果更新"

  # 同时更新 app.toml 中的 minimum-gas-prices，便于后续交易使用较低 gas price
  local app_toml
  app_toml="${INJ_HOME_DIR}/config/app.toml"
  if [ -f "$app_toml" ]; then
    if sed -i 's/^minimum-gas-prices *= ".*"/minimum-gas-prices = "0.0000001inj"/' "$app_toml"; then
      echo "[genesis] 已将 app.toml 中的 minimum-gas-prices 设置为 0.0000001inj"
    else
      echo "[genesis] 警告: 更新 app.toml 中的 minimum-gas-prices 失败，请手动检查" >&2
    fi
  else
    echo "[genesis] 提示: 未找到 app.toml (${app_toml})，跳过 minimum-gas-prices 更新" >&2
  fi
}

########## 启动 injectived 节点（tmux + 日志） ##########

register_orchestrator_address() {
  # 依赖前面从 genesis 解析出的 orchestrator / valoper / EVM 地址
  # 其中 orchestrator 和 valoper 实际上都使用 genesis inj 地址
  if [ -z "${GENESIS_INJ_ADDR:-}" ] || [ -z "${GENESIS_EVM_ADDR:-}" ]; then
    echo "[orchestrator] 警告: 未检测到 genesis inj / EVM 地址变量，请确认脚本前面已经成功解析相关地址" >&2
    echo "[orchestrator] 如需手动执行注册命令，可使用:"
    echo "  injectived tx peggy set-orchestrator-address \"<genesis inj address>\" \"<genesis inj address>\" \"<genesis EVM address>\" --from genesis --chain-id=${INJ_CHAIN_ID} --keyring-backend=file --yes --node=http://127.0.0.1:26657 --gas-prices=500000000inj"
    return 0
  fi

  # 如果当前 valset 已包含 GENESIS_EVM_ADDR，则跳过注册
  if command_exists injectived && command_exists jq; then
    local evm_lc
    evm_lc="$(echo "${GENESIS_EVM_ADDR}" | tr 'A-Z' 'a-z')"

    if injectived q peggy current-valset \
        --chain-id="${INJ_CHAIN_ID}" \
        --node=http://127.0.0.1:26657 -o json 2>/dev/null \
      | jq -e --arg addr "$evm_lc" '.valset.members[].ethereum_address | ascii_downcase == $addr' >/dev/null 2>&1; then
      echo "[orchestrator] 检测到 genesis EVM 地址 ${GENESIS_EVM_ADDR} 已存在于当前 valset，跳过 orchestrator 注册"
      return 0
    fi
  fi

  echo "[orchestrator] 即将发送注册 orchestrator 交易:"
  echo "  injectived tx peggy set-orchestrator-address \"${GENESIS_INJ_ADDR}\" \"${GENESIS_INJ_ADDR}\" \"${GENESIS_EVM_ADDR}\" --from genesis --chain-id=${INJ_CHAIN_ID} --keyring-backend=file --yes --node=http://127.0.0.1:26657 --gas-prices=500000000inj"
  read -r -p "[orchestrator] 是否继续执行该交易？[y/N]: " confirm
  case "${confirm}" in
    y|Y)
      injectived tx peggy set-orchestrator-address "${GENESIS_INJ_ADDR}" "${GENESIS_INJ_ADDR}" "${GENESIS_EVM_ADDR}" \
        --from genesis \
        --chain-id="${INJ_CHAIN_ID}" \
        --keyring-backend=file \
        --yes \
        --node=http://127.0.0.1:26657 \
        --gas-prices=500000000inj
      ;;
    *)
      echo "[orchestrator] 已取消发送 orchestrator 注册交易"
      ;;
  esac
}

########## 启动 injectived 节点（tmux + 日志） ##########

start_injective_node() {
  echo "[injective] 在 ${INJ_HOME_DIR} 中通过 tmux 启动 injectived，并输出日志到 logs/inj.log"

  if ! command_exists tmux; then
    echo "[injective] 警告: 未检测到 tmux，请先安装 tmux (例如: sudo apt-get install -y tmux)" >&2
    return 0
  fi

  mkdir -p "${INJ_HOME_DIR}/logs"
  # 启动前清理旧日志文件
  rm -f "${INJ_HOME_DIR}/logs/inj.log"
  (
    cd "${INJ_HOME_DIR}" || exit 1
    if tmux has-session -t inj 2>/dev/null; then
      echo "[injective] 检测到已有 tmux 会话 inj，先关闭旧会话"
      tmux kill-session -t inj || true
    fi

    tmux new -s inj -d "injectived \
      --log-level info \
      --rpc.laddr tcp://0.0.0.0:26657 \
      --json-rpc.address 0.0.0.0:8545 \
      --json-rpc.ws-address 0.0.0.0:8546 \
      --json-rpc.api 'eth,web3,net,txpool,debug,personal,inj' \
      --json-rpc.enable=true \
      --json-rpc.allow-unprotected-txs=true \
      --json-rpc.txfee-cap=50 \
      --optimistic-execution-enabled true \
      --chainstream-server ${CHAINSTREAM_ADDR} \
      --chainstream-buffer-cap ${CHAINSTREAM_BUFFER_CAP} \
      --chainstream-publisher-buffer-cap ${CHAINSTREAM_PUBLISHER_BUFFER_CAP} \
      --home ${INJ_HOME_DIR} \
      start 2>&1 | tee -a ./logs/inj.log"
    echo "[injective] 已在 tmux 会话 inj 中启动 injectived（启用 JSON-RPC 与 chainstream），日志: ${INJ_HOME_DIR}/logs/inj.log"
  )
}

check_injective_health_or_fix() {
  echo "[injective] 正在检测节点是否成功启动..."

  local rpc_url="http://127.0.0.1:26657/status"
  local max_attempts=10
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -s "$rpc_url" | grep -q '"node_info"'; then
      if command_exists tmux; then
        if tmux has-session -t inj 2>/dev/null; then
          echo "[injective] 检测到节点 RPC 正常响应且 tmux 会话 inj 存在 (attempt=${attempt}/${max_attempts})"
          return 0
        fi
      else
        echo "[injective] 检测到节点 RPC 正常响应 (attempt=${attempt}/${max_attempts})"
        return 0
      fi
    fi
    echo "[injective] 节点尚未就绪，等待 3 秒后重试 (${attempt}/${max_attempts})..."
    attempt=$((attempt + 1))
    sleep 3
  done

  echo "[injective] 节点在预期时间内未正常启动，将检查日志中是否存在初始化错误（仅提示，不自动重置链）..."

  local log_file="${INJ_HOME_DIR}/logs/inj.log"
  if [ ! -f "$log_file" ]; then
    echo "[injective] 警告: 未找到节点日志文件 ${log_file}，无法自动诊断错误" >&2
    echo "[injective] 建议：先查看 bridge/setup 脚本输出，再手动检查 ${INJ_HOME_DIR} 下的日志。" >&2
    return 1
  fi

  if grep -q 'genesis doc hash in db does not match loaded genesis doc' "$log_file" \
     || grep -q 'no last block time stored in state. Should not happen, did initialization happen correctly' "$log_file"; then
    echo "[injective] 检测到可能的初始化错误（genesis/state 不一致）。" >&2
    echo "[injective] 日志文件: ${log_file}" >&2
    echo "[injective] 建议：使用专门的“重置链并重新注册 orchestrator”菜单选项进行修复。" >&2
    return 1
  fi

  echo "[injective] 未检测到已知的 genesis/state 初始化错误，但节点仍未就绪，请手动检查 ${log_file}" >&2
  return 1
}

########## 写入 peggo 的 .env 配置 ##########

write_peggo_env() {
  local peggo_home="$HOME/.peggo"
  local peggo_env_file="${peggo_home}/.env"

  mkdir -p "$peggo_home"
  echo "[peggo] 写入默认 peggo 配置到 ${peggo_env_file}（如已存在将被覆盖）"
  # 尝试基于 ETH_RPC_URL 推导一个 wss 端点
  local derived_ws_url=""
  if echo "${ETH_RPC_URL}" | grep -q '^https://'; then
    derived_ws_url="$(echo "${ETH_RPC_URL}" | sed 's/^https:/wss:/')"
  fi
  # 优先尝试从 injectived keyring 中导出 genesis 账户对应的以太坊私钥
  # 这里在前台直接调用 injectived，让其正常输出提示：
  #   **WARNING this is an unsafe way to export your unencrypted private key**
  #   Enter key password:
  #   Enter keyring passphrase (attempt 1/3):
  # 用户可在这两个提示下输入密码（通常为 12345678，除非已修改）
  local exported_genesis_eth_pk=""
  if command_exists injectived; then
    local tmp_export_file
    tmp_export_file="$(mktemp)"

    echo "[peggo] 现在将前台执行 'injectived keys unsafe-export-eth-key genesis'，请根据提示输入密码..."
    echo "[peggo] 默认情况下，两次输入的密码都是 12345678（除非你在创建 genesis 账户时修改过）"
    injectived keys unsafe-export-eth-key genesis | tee "$tmp_export_file"

    if [ -s "$tmp_export_file" ]; then
      exported_genesis_eth_pk="$(tail -n1 "$tmp_export_file" | tr -d '\n' | xargs)"
    fi
    rm -f "$tmp_export_file"
  else
    echo "[peggo] 警告: 未找到 injectived 命令，无法自动导出 genesis EVM 私钥" >&2
  fi

  if [ -n "$exported_genesis_eth_pk" ]; then
    echo "[peggo] 已从命令输出中读取 genesis EVM 私钥，用作 PEGGO_ETH_PK"
  else
    echo "[peggo] 警告: 未能正确解析 genesis EVM 私钥，PEGGO_ETH_PK 将留空，请手动填写 ~/.peggo/.env 中的 PEGGO_ETH_PK" >&2
  fi

  cat >"$peggo_env_file" <<EOF
PEGGO_ENV="local"
PEGGO_LOG_LEVEL="info"

PEGGO_COSMOS_CHAIN_ID="${INJ_CHAIN_ID}"
PEGGO_COSMOS_GRPC="tcp://localhost:9900"
PEGGO_TENDERMINT_RPC="http://127.0.0.1:26657"

PEGGO_COSMOS_FEE_DENOM="inj"
PEGGO_COSMOS_GAS_PRICES="1600000000inj"
PEGGO_COSMOS_KEYRING="file"
PEGGO_COSMOS_KEYRING_DIR="${INJ_HOME_DIR}"
PEGGO_COSMOS_KEYRING_APP="injectived"
PEGGO_COSMOS_FROM="genesis"
PEGGO_COSMOS_FROM_PASSPHRASE="12345678"
PEGGO_COSMOS_PK="${exported_genesis_eth_pk}"

PEGGO_COSMOS_USE_LEDGER="false"

PEGGO_ETH_KEYSTORE_DIR=""
PEGGO_ETH_FROM=""
PEGGO_ETH_PASSPHRASE=""

# 默认使用从 injectived keyring 导出的 genesis EVM 私钥（如导出失败则为空，需手动填写）
PEGGO_ETH_PK="${exported_genesis_eth_pk}"

PEGGO_ETH_GAS_PRICE_ADJUSTMENT="1.3"
PEGGO_ETH_MAX_GAS_PRICE="500gwei"
PEGGO_ETH_CHAIN_ID="${ETH_CHAIN_ID}"
PEGGO_ETH_RPC="${ETH_RPC_URL}"
PEGGO_ETH_ALCHEMY_WS="${derived_ws_url}"
PEGGO_ETH_USE_LEDGER="false"
PEGGO_COINGECKO_API="https://api.coingecko.com/api/v3"

PEGGO_RELAY_VALSETS="true"
PEGGO_RELAY_VALSET_OFFSET_DUR="5m"
PEGGO_RELAY_BATCHES="true"
PEGGO_RELAY_BATCH_OFFSET_DUR="5m"
PEGGO_RELAY_PENDING_TX_WAIT_DURATION="20m"

PEGGO_MIN_BATCH_FEE_USD="0"

PEGGO_STATSD_PREFIX="peggo."
PEGGO_STATSD_ADDR="localhost:8125"
PEGGO_STATSD_STUCK_DUR="5m"
PEGGO_STATSD_MOCKING="false"
PEGGO_STATSD_DISABLED="true"

PEGGO_ETH_PERSONAL_SIGN="false"
PEGGO_ETH_SIGN_MODE="raw"
EOF

  echo "[peggo] 已生成 ${peggo_env_file}，请根据需要检查和调整 ETH_RPC / WSS 等字段。"
}

########## 启动 peggo orchestrator（tmux + 日志） ##########

start_peggo_orchestrator() {
  local peggo_home="$HOME/.peggo"
  local peggo_logs_dir="${peggo_home}/logs"

  if ! command_exists tmux; then
    echo "[peggo] 警告: 未检测到 tmux，请先安装 tmux (例如: sudo apt-get install -y tmux)" >&2
    return 0
  fi

  if ! command_exists peggo; then
    echo "[peggo] 警告: 未检测到 peggo 二进制，请确认已正确安装 peggo" >&2
    return 0
  fi

  mkdir -p "${peggo_logs_dir}"
  # 启动前清理旧 orchestrator 日志
  rm -f "${peggo_logs_dir}/orchestrator.log"

  (
    cd "${peggo_home}" || exit 1
    if tmux has-session -t orchestrator 2>/dev/null; then
      echo "[peggo] 检测到已有 tmux 会话 orchestrator，先关闭旧会话"
      tmux kill-session -t orchestrator || true
    fi

    tmux new -s orchestrator -d "peggo orchestrator 2>&1 | tee -a ./logs/orchestrator.log"
    echo "[peggo] 已在 tmux 会话 orchestrator 中启动 peggo orchestrator，日志: ${peggo_logs_dir}/orchestrator.log"
  )
}

########## 仅重启 Injective 节点和 peggo（不重新编译、不重新部署） ##########

restart_injective_and_peggo_only() {
  echo "[restart] 将仅重启 Injective 节点和 peggo orchestrator，不执行重新编译或重新部署。"

  # 先停止现有 tmux 会话和裸进程
  cleanup_injective_and_peggo

  # 启动 injectived 节点
  start_injective_node

  # 检查节点健康状态，如有必要尝试修复
  check_injective_health_or_fix || {
    echo "[restart] 警告: Injective 节点在重启后未能通过健康检查，请手动检查日志。" >&2
  }

  # 启动 peggo orchestrator
  start_peggo_orchestrator

  echo "[restart] 已执行 Injective 节点与 peggo orchestrator 的重启流程。"
}

########## 重置链并重新注册 orchestrator（显式确认后执行 unsafe-reset-all） ##########

reset_chain_and_reregister_orchestrator() {
  echo "[reset] 警告：该操作将对 ${INJ_HOME_DIR} 执行 unsafe-reset-all，重置本地链状态。" >&2
  echo "[reset] 这通常用于修复 genesis/state 不一致或 store 版本不匹配等严重错误。" >&2
  read -r -p "[reset] 确认继续吗？输入 y 继续，其他键取消 [y/N]: " ans

  case "$ans" in
    y|Y)
      ;;
    *)
      echo "[reset] 已取消链重置操作。"
      return 0
      ;;
  esac

  echo "[reset] 停止当前 injectived 进程和 tmux 会话..."
  if command_exists tmux; then
    tmux kill-session -t inj 2>/dev/null || true
  fi
  pkill -f injectived 2>/dev/null || true

  echo "[reset] 正在对 ${INJ_HOME_DIR} 执行 unsafe-reset-all --keep-addr-book..."
  injectived tendermint unsafe-reset-all --keep-addr-book --home "${INJ_HOME_DIR}" || {
    echo "[reset] 错误：unsafe-reset-all 执行失败，请手动检查链数据目录 ${INJ_HOME_DIR}" >&2
    return 1
  }

  echo "[reset] 已完成 unsafe-reset-all，准备重新启动节点..."
  start_injective_node

  echo "[reset] 等待节点重新启动并通过健康检查..."
  if ! check_injective_health_or_fix; then
    echo "[reset] 警告：节点在重置后未能通过健康检查，请检查日志后再重试。" >&2
    return 1
  fi

  echo "[reset] 节点已就绪，开始重新注册 orchestrator 地址（如有必要）..."
  register_orchestrator_address

  echo "[reset] 链重置及 orchestrator 注册流程已完成。"
}

########## 交互：是否重置 genesis ##########

ask_reset_genesis() {
  echo "是否重置 Injective 节点并重新生成 genesis？"
  echo "1) 是，执行官方 setup.sh（会清空当前链状态）"
  echo "2) 否，保留现有 genesis，直接部署 Peggy 合约"
  read -r -p "请输入选择 [1/2] (默认 2): " choice

  case "$choice" in
    1)
      echo "[chain] 选择重置 genesis，将执行官方 setup.sh"
      RESET_GENESIS="yes"
      ;;
    2|"")
      echo "[chain] 选择不重置 genesis，跳过官方 setup.sh"
      RESET_GENESIS="no"
      ;;
    *)
      echo "[chain] 无效输入，默认不重置 genesis"
      RESET_GENESIS="no"
      ;;
  esac

}

check_eth_balance() {
  local address=$1
  local balance_hex
  local balance_dec
  
  echo "[eth] 检查地址 ${address} 的 ETH 余额..." >&2
  
  # 使用 curl 调用 Infura API 获取余额
  balance_hex=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${address}\",\"latest\"],\"id\":1}" \
    "${ETH_RPC_URL}" 2>/dev/null | jq -r '.result' 2>/dev/null || echo "0x0")
    
  # 如返回值不是形如 0x... 的十六进制数，则视为 0
  if ! echo "$balance_hex" | grep -Eq '^0x[0-9a-fA-F]+$'; then
    balance_hex="0x0"
  fi

  # 将十六进制余额转换为十进制（wei）
  balance_dec=$(printf "%d" "$balance_hex" 2>/dev/null || echo 0)
  
  # 人类可读形式打印到 stderr，避免干扰调用方解析整数
  echo "[eth] 当前余额: $((balance_dec / 10**18)).$(printf "%018d" "$balance_dec" | cut -c-18) ETH" >&2
  
  # stdout 仅输出整数（wei），供调用方使用
  echo "$balance_dec"
}

send_eth() {
  local from_pk=$1
  local to=$2
  local amount=$3  # 以 wei 为单位
  
  echo "[eth] 正在从 ${from_pk:0:10}... 向 ${to:0:10}... 转账 $((amount / 10**18)) ETH..."
  
  # 使用 cast 发送 ETH
  cast send --rpc-url "$ETH_RPC_URL" --private-key "$from_pk" --value "${amount}wei" "$to"
}

check_and_topup_genesis_balance() {
	local genesis_inj_addr
	local genesis_evm_addr
	local current_balance
	
	# 获取 genesis Injective 地址
	genesis_inj_addr=$(get_genesis_injective_address 2>/dev/null || true)
	if [ -z "$genesis_inj_addr" ]; then
		echo "[eth] 警告: 无法获取 genesis Injective 地址，跳过余额检查"
		return 1
	fi

	# 获取 / 复用 genesis 对应的 EVM 地址 (0x...)
	if [ -n "${GENESIS_EVM_ADDR:-}" ]; then
		genesis_evm_addr="$GENESIS_EVM_ADDR"
	else
		genesis_evm_addr=$(get_evm_address_from_inj "$genesis_inj_addr" 2>/dev/null || true)
	fi

	if [ -z "$genesis_evm_addr" ]; then
		echo "[eth] 警告: 无法推导 genesis 对应的 EVM 地址，跳过余额检查"
		return 1
	fi

	echo "[eth] 将针对 genesis EVM 地址 ${genesis_evm_addr} 检查 Sepolia ETH 余额"

	# 获取当前余额（单位：wei）
	current_balance=$(check_eth_balance "$genesis_evm_addr")

	# 检查余额是否低于阈值
	if [ "$current_balance" -lt "$MIN_ETH_BALANCE" ]; then
		echo "[eth] 余额低于 0.05 ETH，正在补充至 0.1 ETH..."
		local amount_to_send=$((TARGET_ETH_BALANCE - current_balance))
		
		# 确保部署者地址有足够的余额可以发送
		local deployer_evm_addr
		local deployer_balance
		deployer_evm_addr="$(cast wallet address --private-key "$ETH_PRIVATE_KEY")"
		deployer_balance=$(check_eth_balance "$deployer_evm_addr")
		
		if [ "$deployer_balance" -lt "$amount_to_send" ]; then
			echo "[eth] 错误: 部署者地址 ${deployer_evm_addr} 余额不足，无法补充 genesis EVM 地址余额"
			return 1
		fi
		
		# 发送 ETH 到 genesis EVM 地址
		send_eth "$ETH_PRIVATE_KEY" "$genesis_evm_addr" "$amount_to_send"
		
		# 验证余额已更新
		check_eth_balance "$genesis_evm_addr"
	else
		echo "[eth] 余额充足，无需补充"
	fi
}

install_injective_binaries() {
  local need_injectived=false
  local need_peggo=false
  local need_wasmvm=false
  local branch_choice
  local FORCE_INSTALL=false

  # 检查是否强制重新安装
  if [ "$1" = "--force" ]; then
    FORCE_INSTALL=true
    echo "[injective] 强制重新安装 Injective 二进制文件"
  fi

  echo "[injective] 开始安装 / 校验 Injective 二进制文件"
  
  # 检查是否已经安装了必要的命令
  if [ "$FORCE_INSTALL" = false ] && command_exists injectived && command_exists peggo && [ -f "${LIBWASMVM_TARGET_DIR}/libwasmvm.x86_64.so" ]; then
    echo "[injective] 检测到已安装 injectived、peggo 和 libwasmvm，跳过安装"
    echo "[injective] 如需强制重新安装，请使用 --force 参数"
    return 0
  fi

  # 安装必要的构建工具
  echo "[injective] 正在检查并安装必要的构建工具..."
  
  # 安装 git
  if ! command_exists git; then
    echo "[injective] 正在安装 git..."
    if command_exists apt-get; then
      sudo apt-get update && sudo apt-get install -y git
    elif command_exists yum; then
      sudo yum install -y git
    elif command_exists brew; then
      brew install git
    else
      echo "错误: 无法自动安装 git，请手动安装后重试" >&2
      exit 1
    fi
  fi
  
  # 安装 Go
  if ! command_exists go; then
    echo "[injective] 正在安装 Go..."
    local go_install_url="https://go.dev/dl/go1.21.0.linux-amd64.tar.gz"
    if [ "$(uname -s)" = "Darwin" ]; then
      go_install_url="https://go.dev/dl/go1.21.0.darwin-amd64.tar.gz"
    fi
    
    curl -L $go_install_url -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    
    # 添加 Go 到 PATH (同时更新当前会话和持久化配置)
    export PATH="$PATH:/usr/local/go/bin"
    if ! grep -q "/usr/local/go/bin" "${HOME}/.zshrc" 2>/dev/null; then
      echo 'export PATH=$PATH:/usr/local/go/bin' >> "${HOME}/.zshrc"
      # 同时更新 .bashrc 以确保兼容性
      echo 'export PATH=$PATH:/usr/local/go/bin' >> "${HOME}/.bashrc"
      echo "[injective] 已将 Go 添加到 PATH 环境变量"
    fi
    
    # 验证安装
    if ! command_exists go; then
      echo "错误: Go 安装失败，请手动安装 Go 后重试" >&2
      exit 1
    fi
    
    # 设置 Go 环境变量
    export GOPATH="$HOME/go"
    export PATH="$PATH:$GOPATH/bin"
    
    # 创建必要的 Go 目录
    mkdir -p "$GOPATH/src" "$GOPATH/bin" "$GOPATH/pkg"
    
    # 更新 .zshrc 和 .bashrc 中的 GOPATH
    for rcfile in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
      if ! grep -q "export GOPATH" "$rcfile" 2>/dev/null; then
        echo "export GOPATH=\"\$HOME/go\"" >> "$rcfile"
        echo 'export PATH="$PATH:$GOPATH/bin"' >> "$rcfile"
      fi
    done
    
    # 立即应用环境变量
    source_shell_config
    
    echo "[injective] Go 安装完成: $(go version)"
  else
    echo "[injective] 检测到已安装 Go: $(go version)"
  fi
  
  # 安装 make 和 gcc
  for cmd in make gcc; do
    if ! command_exists "$cmd"; then
      echo "[injective] 正在安装 $cmd..."
      if command_exists apt-get; then
        sudo apt-get update && sudo apt-get install -y "$cmd"
      elif command_exists yum; then
        sudo yum install -y "$cmd"
      elif command_exists brew; then
        brew install "$cmd"
      else
        echo "错误: 无法自动安装 $cmd，请手动安装后重试" >&2
        exit 1
      fi
    fi
  done
  
  # 检查并安装 foundry (cast)
  if ! command_exists cast; then
    echo "[foundry] 未检测到 foundry，正在安装..."
    if ! command_exists curl; then
      echo "错误: 需要 curl 来安装 foundry" >&2
      exit 1
    fi
    
    # 安装 foundry
    curl -L https://foundry.paradigm.xyz | bash
    
    # 添加 foundry 到 PATH
    if [ -f "${HOME}/.zshrc" ] && ! grep -q "foundry" "${HOME}/.zshrc"; then
      echo 'export PATH="${PATH}:${HOME}/.foundry/bin"' >> "${HOME}/.zshrc"
      export PATH="${PATH}:${HOME}/.foundry/bin"
    fi
    
    # 如果 foundryup 已安装但不在 PATH 中
    if [ -f "${HOME}/.foundry/bin/foundryup" ]; then
      "${HOME}/.foundry/bin/foundryup"
    elif command_exists foundryup; then
      foundryup
    else
      echo "警告: 无法自动安装 foundry，请手动安装: https://book.getfoundry.sh/getting-started/installation" >&2
      exit 1
    fi
    
    # 验证安装
    if ! command_exists cast; then
      echo "错误: foundry 安装失败，请手动安装: https://book.getfoundry.sh/getting-started/installation" >&2
      exit 1
    fi
    
    echo "[foundry] 安装完成: $(cast --version)"
  fi

  # ========= 分支选择：先克隆到本地，再基于本地分支列表供用户选择 =========
  echo "[injective] 正在克隆 injective-core 仓库用于分支选择..."

  local repo_src_dir="${TMP_DIR}/injective-core-src"
  rm -rf "$repo_src_dir"
  mkdir -p "$repo_src_dir"

  if ! git clone "$INJECTIVE_CORE_REPO" "$repo_src_dir"; then
    echo "错误: 无法克隆仓库，请检查网络连接和仓库URL: $INJECTIVE_CORE_REPO" >&2
    return 1
  fi

  cd "$repo_src_dir" || {
    echo "错误: 无法进入仓库目录 $repo_src_dir" >&2
    return 1
  }

  # 更新所有远程分支
  git fetch --all --prune >/dev/null 2>&1 || true

  # 基于远程分支列表生成菜单（确保包含 dev 等 origin/* 分支）
  local branches=()
  local branch_names=()
  local i=1

  while read -r branch; do
    # 示例: "  origin/dev" 或 "origin/master"
    branch="${branch#* }"          # 去掉前面的空格和星号
    branch="${branch#origin/}"    # 去掉 origin/
    [ -z "$branch" ] && continue
    # 去重: 如果已经在列表里，则跳过
    local exists=false
    for b in "${branches[@]}"; do
      if [ "$b" = "$branch" ]; then
        exists=true
        break
      fi
    done
    $exists && continue
    branches+=("$branch")
    branch_names+=("$i) $branch")
    i=$((i+1))
  done < <(git branch -r | grep -v 'HEAD ->')

  if [ ${#branches[@]} -eq 0 ]; then
    echo "错误: 未在远程仓库中找到任何分支" >&2
    return 1
  fi

  echo "[injective] 请选择要构建的分支:"
  printf '%s\n' "${branch_names[@]}"

  local selected_index=0
  while true; do
    read -p "请输入选择 (1-${#branches[@]}): " branch_choice
    if [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le ${#branches[@]} ]; then
      selected_index=$((branch_choice - 1))
      break
    fi
    echo "无效选择，请输入 1-${#branches[@]} 之间的数字"
  done

  INJ_BRANCH="${branches[$selected_index]}"

  echo "[injective] 将使用分支: ${INJ_BRANCH}"

  # 如果本地已存在同名分支，直接切换；否则从 origin 创建本地分支
  if git show-ref --verify --quiet "refs/heads/${INJ_BRANCH}"; then
    git checkout "$INJ_BRANCH" || {
      echo "错误: 无法检出本地分支 ${INJ_BRANCH}" >&2
      return 1
    }
  else
    git checkout -b "$INJ_BRANCH" "origin/${INJ_BRANCH}" || {
      echo "错误: 无法从 origin/${INJ_BRANCH} 创建本地分支" >&2
      return 1
    }
  fi
  
  echo "[injective] 当前构建目录: $(pwd)"
  echo "[injective] 正在构建 injectived 和 peggo (make install)..."

  # 在仓库根目录构建 injectived 和 peggo（由项目 Makefile 决定具体安装内容）
  make install

  # 确保构建成功
  if ! command_exists injectived || ! command_exists peggo; then
    echo "[injective] 错误: 构建 injectived 或 peggo 失败" >&2
    return 1
  fi

  # 打印当前版本信息
  echo "[injective] Injective 二进制文件安装完成，当前版本信息:"  
  echo "  injectived: $(injectived version 2>/dev/null || echo 'unknown')"
  echo "  peggo:     $(peggo version 2>/dev/null || echo 'unknown')"

  # 安装 wasmvm 库
  echo "[injective] 正在安装 libwasmvm ${LIBWASMVM_VERSION}..."
  if [ ! -f "${LIBWASMVM_TARGET_DIR}/libwasmvm.x86_64.so" ]; then
    local wasmvm_url="https://github.com/CosmWasm/wasmvm/releases/download/${LIBWASMVM_VERSION}/libwasmvm.x86_64.so"
    
    echo "[injective] 下载 libwasmvm.x86_64.so (${LIBWASMVM_VERSION})..."
    sudo mkdir -p "$LIBWASMVM_TARGET_DIR"
    if ! sudo curl -L "$wasmvm_url" -o "${LIBWASMVM_TARGET_DIR}/libwasmvm.x86_64.so"; then
      echo "[injective] 错误: 下载 libwasmvm 失败，请检查网络连接" >&2
      return 1
    fi
    sudo chmod +x "${LIBWASMVM_TARGET_DIR}/libwasmvm.x86_64.so"
    
    # 设置动态库路径
    case "$(uname -s)" in
      Linux*)
        sudo ldconfig
        ;;
      Darwin*)
        # 对于 macOS，可能需要更新 DYLD_LIBRARY_PATH
        if ! grep -q "${LIBWASMVM_TARGET_DIR}" "${HOME}/.zshrc" 2>/dev/null; then
          echo "export DYLD_LIBRARY_PATH=\"${LIBWASMVM_TARGET_DIR}:\$DYLD_LIBRARY_PATH\"" >> "${HOME}/.zshrc"
          echo "[injective] 已将 ${LIBWASMVM_TARGET_DIR} 添加到 DYLD_LIBRARY_PATH"
          echo "[injective] 请运行 'source ~/.zshrc' 或重新打开终端使更改生效"
        fi
        ;;
    esac
  fi
  
  echo "[injective] 安装完成"
  
  # 显示版本信息
  echo "[injective] injectived 版本: $(injectived version)"
  echo "[injective] peggo 版本: $(peggo version)"
}

########## 初始化 Injective 链（官方 setup.sh） ##########

setup_injective_chain() {
  echo "[chain] 开始执行 Injective 官方节点初始化脚本，chain-id=${INJ_CHAIN_ID}"

  echo "[injective] 下载官方 Injective 节点安装脚本"
  mkdir -p "$TMP_DIR"
  curl -sSfL "$INJ_OFFICIAL_SETUP_URL" -o "$INJ_OFFICIAL_SETUP_SCRIPT"
  chmod +x "$INJ_OFFICIAL_SETUP_SCRIPT"

  # 使用当前脚本配置的 INJ_CHAIN_ID 替换官方脚本中写死的 injective-1
  # 这样可以通过修改本脚本顶部的 INJ_CHAIN_ID 来控制链 ID
  if [ -n "${INJ_CHAIN_ID:-}" ]; then
    echo "[injective] 使用 INJ_CHAIN_ID=${INJ_CHAIN_ID} 替换官方脚本中的默认链 ID injective-1"
    sed -i "s/injective-1/${INJ_CHAIN_ID}/g" "$INJ_OFFICIAL_SETUP_SCRIPT" || true
  fi

  # 将期望的 chain-id 传递给官方脚本（官方脚本一般会从环境变量读取或交互配置）
  INJ_CHAIN_ID_ENV="${INJ_CHAIN_ID}" INJ_HOME="${INJ_HOME_DIR}" \
    "${INJ_OFFICIAL_SETUP_SCRIPT}"

  echo "[chain] 官方 setup.sh 执行完成，开始读取创世地址"

  local genesis_inj_addr
  local genesis_evm_addr

  genesis_inj_addr="$(get_genesis_injective_address)" || return 1
  genesis_evm_addr="$(get_evm_address_from_inj "${genesis_inj_addr}")" || return 1

  echo "[chain] 创世 Injective 地址: ${genesis_inj_addr}"
  echo "[chain] 创世地址对应的 EVM 地址: ${genesis_evm_addr}"
}

########## 安装 Ethereum 侧依赖: solc-select & etherman ##########

ensure_solc_select_and_version() {
  # 先确保 PATH 中包含 ~/.local/bin（pip --user 默认安装位置）
  export PATH="$HOME/.local/bin:$PATH"

  if command_exists solc-select; then
    echo "[etherman] 已检测到 solc-select"
  else
    echo "[etherman] 未检测到 solc-select，尝试自动安装"

    if command_exists apt-get; then
      echo "[etherman] 使用 apt-get 确保 python3-pip 已安装"
      sudo apt-get update -y
      sudo apt-get install -y python3-pip
    fi

    echo "[etherman] 使用 pip3 安装 solc-select (--user)"
    pip3 install --user solc-select

    # 安装后再次确保 PATH，并写入 bashrc，供后续登录会话使用
    export PATH="$HOME/.local/bin:$PATH"
    if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
      echo "[etherman] 已将 ~/.local/bin 加入 ~/.bashrc 的 PATH"
    fi

    if ! command_exists solc-select; then
      echo "[etherman] 错误: 尝试安装 solc-select 后仍未检测到，请检查 Python/pip 环境" >&2
      return 1
    fi
  fi

  echo "[etherman] 确保已安装 solc 0.8.0 并切换到该版本"
  # 如未安装 0.8.0，则安装一次
  if ! solc-select versions 2>/dev/null | grep -q "0.8.0"; then
    solc-select install 0.8.0
  fi

  # 仅当当前 solc 版本不是 0.8.0 时才切换
  current_solc_version="$(solc --version 2>/dev/null | grep -o '0\.8\.0' || true)"
  if [ -z "$current_solc_version" ]; then
    solc-select use 0.8.0
  fi
}

install_etherman() {
  if command_exists etherman; then
    echo "[etherman] etherman 已存在，跳过构建"
    return 0
  fi

  if ! command_exists go; then
    echo "[etherman] 错误: 未检测到 Go 环境，请先安装 Go (例如: sudo apt install golang)" >&2
    return 1
  fi

  echo "[etherman] 开始构建 etherman"
  local build_dir
  build_dir="${TMP_DIR}/etherman-src"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"
  cd "${build_dir}"

  git clone https://github.com/InjectiveLabs/etherman.git .
  go mod tidy
  go build -o etherman

  chmod +x etherman
  sudo mv etherman /usr/local/bin/
  echo "[etherman] etherman 已安装到 /usr/local/bin/etherman"
}

########## 部署 Peggy 合约 (injective-core / Sepolia) ##########

get_genesis_injective_address() {
  local inj_addr
  # 某些环境下读取 genesis 地址会要求输入密钥密码，这里默认使用 12345678 自动输入
  inj_addr="$(printf '12345678\n' | injectived keys show genesis -a 2>/dev/null || true)"

  if [ -z "$inj_addr" ]; then
    echo "[chain] 错误: 无法通过 'injectived keys show genesis -a' 获取创世地址" >&2
    return 1
  fi

  echo "$inj_addr"
}

get_evm_address_from_inj() {
  local inj_addr="$1"
  local hex

  hex="$(injectived debug addr "${inj_addr}" 2>/dev/null | awk '/Address \(hex\):/ {print $3}' || true)"

  if [ -z "$hex" ]; then
    echo "[chain] 错误: 无法从 'injectived debug addr' 获取 EVM hex 地址" >&2
    return 1
  fi

  echo "0x$(echo "$hex" | tr 'A-Z' 'a-z')"
}

maybe_set_default_validator_from_genesis() {
  # 始终根据 genesis 地址推导 EVM 地址，写入全局 GENESIS_EVM_ADDR，供后续使用
  local genesis_inj_addr
  local genesis_evm_addr

  genesis_inj_addr="$(get_genesis_injective_address)" || return 1
  genesis_evm_addr="$(get_evm_address_from_inj "${genesis_inj_addr}")" || return 1

  echo "[chain] 创世 Injective 地址: ${genesis_inj_addr}"
  echo "[chain] 创世地址对应的 EVM 地址: ${genesis_evm_addr}"

  GENESIS_INJ_ADDR="${genesis_inj_addr}"
  GENESIS_EVM_ADDR="${genesis_evm_addr}"
}

deploy_peggy_contract() {
  echo "[peggy] 开始部署 Peggy 合约，目标网络: ${ETH_NETWORK_NAME} (chainId=${ETH_CHAIN_ID})"

  maybe_set_default_validator_from_genesis

  if [ -z "$ETH_RPC_URL" ] || [ -z "$ETH_PRIVATE_KEY" ]; then
    echo "[peggy] 错误: ETH_RPC_URL 或 ETH_PRIVATE_KEY 未配置，请在脚本配置区正确填写" >&2
    return 1
  fi

  # 确保 etherman 已安装
  if ! command_exists etherman; then
    echo "[peggy] 未检测到 etherman，正在安装..."
    if ! install_etherman; then
      echo "[peggy] 错误: 安装 etherman 失败，请检查网络或手动安装后重试" >&2
      return 1
    fi
  fi

  # 确保 solc / solc-select 已安装并切到合适版本
  if ! ensure_solc_select_and_version; then
    echo "[peggy] 错误: solc 或 solc-select 安装/版本切换失败" >&2
    return 1
  fi

  # 复用之前下载/构建使用的 injective-core 源码目录，如不存在则重新克隆
  if [ ! -d "${INJECTIVE_CORE_DIR}" ]; then
    echo "[peggy] 未找到现有 injective-core 源码目录，将重新克隆仓库"
    rm -rf "${INJECTIVE_CORE_DIR}"
    mkdir -p "${INJECTIVE_CORE_DIR}"
    cd "${INJECTIVE_CORE_DIR}"
    echo "[peggy] 克隆 injective-core 仓库: ${INJECTIVE_CORE_REPO}"
    git clone "${INJECTIVE_CORE_REPO}" .
  else
    cd "${INJECTIVE_CORE_DIR}"
  fi

  cd peggo/solidity/deployment

  if [ ! -f .env.example ]; then
    echo "[peggy] 错误: 未找到 .env.example，无法生成部署配置" >&2
    return 1
  fi

  echo "[peggy] 生成 .env 配置文件 (基于 .env.example)"
  cp .env.example .env

  # 用配置区中的参数覆盖 .env 内的关键字段
  sed -i \
    -e "s|^DEPLOYER_RPC_URI=.*|DEPLOYER_RPC_URI=\"${PEGGY_DEPLOYER_RPC_URI}\"|" \
    -e "s|^DEPLOYER_TX_GAS_PRICE=.*|DEPLOYER_TX_GAS_PRICE=${PEGGY_DEPLOYER_TX_GAS_PRICE}|" \
    -e "s|^DEPLOYER_TX_GAS_LIMIT=.*|DEPLOYER_TX_GAS_LIMIT=${PEGGY_DEPLOYER_TX_GAS_LIMIT}|" \
    -e "s|^DEPLOYER_FROM=.*|DEPLOYER_FROM=\"${PEGGY_DEPLOYER_FROM}\"|" \
    -e "s|^DEPLOYER_FROM_PK=.*|DEPLOYER_FROM_PK=\"${PEGGY_DEPLOYER_FROM_PK}\"|" \
    .env

  echo "[peggy] 执行 deploy-on-evm.sh 进行合约部署"
  chmod +x ./deploy-on-evm.sh

  POWER_THRESHOLD="${PEGGY_POWER_THRESHOLD}" \
  VALIDATOR_ADDRESSES="${GENESIS_EVM_ADDR}" \
  VALIDATOR_POWERS="${PEGGY_VALIDATOR_POWERS}" \
    ./deploy-on-evm.sh | tee deploy.log

  echo "[peggy] 部署完成，尝试从 deploy.log 中解析 Peggy 合约地址和部署高度"

  local peggy_addr
  local peggy_block_height

  # 从 "Peggy deployment done! Use 0x..." 这一行解析最终 Peggy 代理合约地址
  peggy_addr="$(grep -E 'Peggy deployment done! Use' deploy.log | tail -n1 | awk '{print $NF}' || true)"

  # 如果脚本有打印部署区块高度，例如 "Deployment block: 123456"，则尝试解析
  peggy_block_height="$(grep -Ei 'Deployment block' deploy.log | tail -n1 | awk '{print $NF}' || true)"

  # 如果日志中未包含部署高度，尝试通过 RPC 自动推断
  if [ -z "$peggy_block_height" ] && [ -n "$peggy_addr" ]; then
    local rpc_height
    rpc_height="$(get_peggy_block_height_from_rpc "$peggy_addr")"
    if [ -n "$rpc_height" ]; then
      peggy_block_height="$rpc_height"
    fi
  fi

  if [ -n "$peggy_addr" ]; then
    echo "[peggy] 解析到 Peggy 合约地址: ${peggy_addr}"
  else
    echo "[peggy] 警告: 未能从 deploy.log 中解析出 Peggy 合约地址，请手动检查 deploy.log"
  fi

  if [ -n "$peggy_block_height" ]; then
    echo "[peggy] 解析到合约部署区块高度: ${peggy_block_height}"
  else
    echo "[peggy] 警告: 未能从 deploy.log 中解析出部署区块高度，请手动检查 deploy.log"
  fi

  # 自动根据 Peggy 地址和部署高度更新 Injective genesis.json 中的 bridge / peggy 配置
  update_injective_genesis_with_peggy "$peggy_addr" "$peggy_block_height"
}

ask_reset_genesis() {
  echo "是否重置 Injective 节点并重新生成 genesis？"
  echo "1) 是，执行官方 setup.sh（会清空当前链状态）"
  echo "2) 否，保留现有 genesis，直接部署 Peggy 合约"
  read -r -p "请输入选择 [1/2] (默认 2): " choice

  case "$choice" in
    1)
      RESET_GENESIS="yes"
      ;;
    *)
      RESET_GENESIS="no"
      ;;
  esac
}

########## 顶层菜单：选择从哪个阶段开始 ##########

run_from_install_injective() {
  echo "[menu] 从安装 Injective 开始执行完整流程"
  cleanup_injective_and_peggo
  install_injective_binaries --force
  setup_injective_chain
  deploy_peggy_contract
  start_injective_node
  check_injective_health_or_fix || echo "[injective] 警告: 节点健康检查失败，请手动检查日志" >&2
  write_peggo_env
  register_orchestrator_address
  start_peggo_orchestrator

  echo "[eth] 最后一步: 检查并自动补充 genesis EVM 地址的 Sepolia ETH 余额..."
  check_and_topup_genesis_balance || echo "[eth] 警告: 自动补款失败，请手动检查并转账" >&2

  cleanup_tmp_dir_prompt
}

run_from_reset_genesis() {
  echo "[menu] 从 genesis 重置开始执行（假定二进制已安装）"
  cleanup_injective_and_peggo
  ask_reset_genesis
  setup_injective_chain
  deploy_peggy_contract
  start_injective_node
  check_injective_health_or_fix || echo "[injective] 警告: 节点健康检查失败，请手动检查日志" >&2
  write_peggo_env
  register_orchestrator_address
  start_peggo_orchestrator

  echo "[eth] 最后一步: 检查并自动补充 genesis EVM 地址的 Sepolia ETH 余额..."
  check_and_topup_genesis_balance || echo "[eth] 警告: 自动补款失败，请手动检查并转账" >&2
}

run_from_contract_deploy_only() {
  echo "[menu] 仅从 Peggy 合约部署开始执行（不重新安装、不重置 genesis）"
  cleanup_injective_and_peggo
  maybe_set_default_validator_from_genesis
  deploy_peggy_contract
  start_injective_node
  write_peggo_env
  register_orchestrator_address
  start_peggo_orchestrator

  echo "[eth] 最后一步: 检查并自动补充 genesis EVM 地址的 Sepolia ETH 余额..."
  check_and_topup_genesis_balance || echo "[eth] 警告: 自动补款失败，请手动检查并转账" >&2
}

run_from_peggo_config_only() {
  echo "[menu] 仅执行 peggo 配置（生成 ~/.peggo/.env，不修改 Injective 配置，也不启动 peggo)"
  write_peggo_env
}

run_build_and_restart_only() {
  echo "[menu] 仅重新编译安装 injectived 和 peggo 并重启节点（不重置链）"

  # 1. 先重新编译安装二进制，尽量缩短节点停机时间
  install_injective_binaries --force

  # 2. 平滑停止现有节点 / peggo 进程和 tmux 会话（但不 reset 数据目录）
  if command_exists tmux; then
    tmux kill-session -t inj 2>/dev/null || true
    tmux kill-session -t orchestrator 2>/dev/null || true
  fi
  pkill -f injectived 2>/dev/null || true
  pkill -f peggo 2>/dev/null || true

  # 3. 使用新二进制重启节点和 peggo，沿用当前链数据
  start_injective_node
  check_injective_health_or_fix || echo "[injective] 警告: 节点健康检查失败，请手动检查日志" >&2
  start_peggo_orchestrator

  cleanup_tmp_dir_prompt
}

main() {
  echo "###################### 执行步骤 ######################"
  echo "# 1、下载仓库 biya-coin/injective-core"
  echo "# 2、安装依赖: go mod tidy"
  echo "# 3、make install，构建出 injectived 和 peggo"
  echo "# 4、将 injectived 和 peggo 安装到系统 PATH（当前默认 $HOME/go/bin），可直接执行"
  echo "# 5、将 Peggy 合约部署到 Sepolia"
  echo "# 6、初始化 Injective 链：写入 Peggy 合约信息和 validator 初始信息到 genesis.json"
  echo "# 7、启动 Injective 节点"
  echo "# 8、配置 peggo 的 .env 文件"
  echo "# 9、启动 peggo orchestrator"
  echo "# 10、从合约部署地址转移 0.1 个 ETH 至 orchestrator 地址"
  echo "###################### 执行步骤 ######################"
  echo

  echo "[setup] 请选择要执行的阶段："
  echo "1 - 从源码 build 到跨链桥启动的完整流程"
  echo "2 - 从重置 genesis 到跨链桥启动的完整流程"
  # echo "3 - 从合约部署到跨链桥启动的完整流程（暂时禁用）"
  echo "3 - 仅配置 peggo (.env)"
  echo "4 - 只编译安装 injectived 和 peggo 并重启节点和bridge"
  echo "5 - 仅重启 Injective 节点和 peggo（不重新编译、不重新部署）"
  # echo "6 - 重置链并重新注册 orchestrator（unsafe-reset-all + 重启节点，仅在需要时使用）"

  read -r -p "请输入选择 [1/2/3/4/5] (默认 4): " choice

  case "$choice" in
    1)
      run_from_install_injective
      ;;
    2)
      run_from_reset_genesis
      ;;
    3)
      run_from_peggo_config_only
      ;;
    4)
      run_build_and_restart_only
      ;;
    5)
      restart_injective_and_peggo_only
      ;;
    *)
      run_build_and_restart_only
      ;;
  esac

  echo "[setup] 任务执行完成。如需查看 Peggy 部署日志，请检查：${TMP_DIR}/injective-core-src/peggo/solidity/deployment/deploy.log"
}

main "$@"