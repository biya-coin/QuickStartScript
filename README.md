# biyaSetUp 使用说明
**注意：**
脚本默认设置 injective chain-id 为 injective-666，参数如不了解可以不需要动，直接执行就行。发生任何错误，找相关人员即可。


## 一、脚本功能概览

`biyaSetUp.sh` 用于一键完成 Injective 本地/测试节点 + Peggy 跨链桥的搭建和调试工作，包括：

- 从源码编译并安装 `injectived` 与 `peggo`
- 调用官方 setup 脚本初始化 Injective 节点
- 在 Sepolia 部署 Peggy 合约并更新本地 `genesis.json`
- 启动 Injective 节点与 Peggo orchestrator
- 自动给创世 EVM 地址补充 Sepolia ETH 余额
- 提供只重启节点和桥、只配置 peggo 的快速入口
- 提供链启动健康检查和按需 `unsafe-reset-all` 修复

---

## 二、前置依赖

在运行脚本前，请确保：

- 已安装并在 PATH 中可用：
  - `bash`、`curl`、`jq`、`git`、`tmux`
  - Go（版本满足 Injective 要求）
  - `cast`（Foundry），用于在 Sepolia 上发送 ETH
- 能访问：
  - GitHub 仓库：`https://github.com/biya-coin/injective-core.git`
  - Injective 官方 setup 脚本：  
    `https://raw.githubusercontent.com/InjectiveLabs/injective-chain-releases/master/scripts/setup.sh`
  - Sepolia RPC：`ETH_RPC_URL` 配置的节点（默认是 Infura）

脚本会自动检查必要命令是否存在，不满足时会提示。

---

## 三、关键配置项（脚本开头）

可按需修改：

### 1. 临时目录与源码仓库

- `TMP_DIR="/tmp/injective-release"`
- `INJECTIVE_CORE_REPO="https://github.com/biya-coin/injective-core.git"`

### 2. 以太坊 / Sepolia

- `ETH_NETWORK_NAME="sepolia"`
- `ETH_CHAIN_ID="11155111"`
- `ETH_RPC_URL="https://sepolia.infura.io/v3/..."`
- `ETH_PRIVATE_KEY="0x...."`  
  脚本中默认是测试私钥，你应替换为自己的测试私钥，勿用于主网资产。

- `MIN_ETH_BALANCE` / `TARGET_ETH_BALANCE`（wei）：  
  少于 `MIN` 时，会自动从 `ETH_PRIVATE_KEY` 地址向创世 EVM 地址转账到 `TARGET`。

### 3. Injective 链

- `INJ_CHAIN_ID="injective-666"`（可按需改）
- `INJ_HOME_DIR="$HOME/.injectived"`
- `INJ_GENESIS_PATH="${INJ_HOME_DIR}/config/genesis.json"`

---

## 四、运行与主菜单

在脚本所在目录运行：

```bash
bash biyaSetUp.sh
```

会出现菜单：

```text
[setup] 请选择要执行的阶段：
1 - 从源码 build 到跨链桥启动的完整流程
2 - 从重置 genesis 到跨链桥启动的完整流程
# 3 - 从合约部署到跨链桥启动的完整流程（暂时禁用）
3 - 仅配置 peggo (.env)
4 - 只编译安装 injectived 和 peggo 并重启节点和bridge

请输入选择 [1/2/3/4] (默认 4):
```

---

## 五、菜单选项说明

### 选项 1：从源码 build 到跨链桥启动

对应 `run_from_install_injective`，流程：

- 停掉旧 `injectived` / `peggo` / tmux（不重置数据）
- 克隆/更新 `injective-core` 并 `make install`，安装新版本 `injectived` 和 `peggo`
- 调用官方 `setup.sh`，`rm -rf ~/.injectived` 并重新初始化链和 `genesis.json`
- 部署 Peggy 合约到 Sepolia，写入本地 genesis（valsets、attestations 等）
- 启动 Injective 节点（tmux 会话 `inj`）
- 立即执行健康检查：
  - 调 `http://127.0.0.1:26657/status`，要求返回 JSON 中有 `"node_info"`
  - 若系统存在 tmux，还要求 tmux 会话 `inj` 存在
  - 如果失败，会检查 `~/.injectived/logs/inj.log` 中是否包含  
    `genesis doc hash in db does not match loaded genesis doc` 或  
    `no last block time stored in state. Should not happen, did initialization happen correctly`  
    若是，则自动执行一次 `unsafe-reset-all` 并重启节点，再做一次短检查
- 写入 `~/.peggo/.env`
- 注册 orchestrator 地址（如 valset 已包含则跳过）
- 启动 peggo orchestrator（tmux 会话 `orchestrator`）
- 检查创世 EVM 地址 Sepolia ETH 余额并在不足时自动补齐
- 提示是否删除临时目录 `TMP_DIR`

适合用于：**全新搭建 / 重新初始化链 + 桥**。

### 选项 2：从重置 genesis 开始

对应 `run_from_reset_genesis`，流程与 1 类似，但不重新编译二进制：

- 停掉旧进程和 tmux
- 询问并按需重置 genesis / 重新执行官方 setup 逻辑
- 再执行 Peggy 部署、节点启动、健康检查、peggo 启动、补 ETH 等
- 不重新 `make install`，沿用已有 `injectived` / `peggo`

适合用于：**已安装好二进制，只需要重置链和桥状态**。

### 选项 3：仅配置 peggo (.env)

对应 `run_from_peggo_config_only`：

- 只生成或覆盖 `~/.peggo/.env` 文件
- 不启动/重启节点，不做链相关操作

适合用于：**单独调整 peggo 配置**（RPC、私钥等）。

### 选项 4：只编译安装并重启节点和 bridge（默认）

对应 `run_build_and_restart_only`：

- 基于当前源码重新 `make install` 构建并安装 `injectived` 和 `peggo`
- 停掉现有 `inj` / `orchestrator` tmux 与相关进程（不重置数据目录）
- 使用新二进制：
  - 启动 Injective 节点
  - 立即健康检查（RPC + tmux）并在必要时自动 `unsafe-reset-all` 一次
  - 节点确认正常后，启动 peggo orchestrator
- 提示是否删除临时目录 `TMP_DIR`

适合用于：**频繁改代码 / 升级二进制，但希望保留现有链状态**。

---

## 六、临时目录清理

- 脚本使用 `TMP_DIR`（默认 `/tmp/injective-release`）保存下载源码和中间文件；
- 在完整流程结束后会询问是否删除：
  - 选 `y`/`Y`：删除 `TMP_DIR`
  - 其他：保留目录以便后续查看日志或复用源码。

---

## 七、注意事项

- 脚本中自带的 `ETH_PRIVATE_KEY` 仅作示例，请替换为你自己的测试私钥；**不要在生产环境或主网使用**。
- 当前“从合约部署开始”的原选项 3 已暂时从菜单禁用，对应的函数 `run_from_contract_deploy_only` 仍在脚本中，但不会被调用。
- 若遇到节点启动失败，请先查看：
  - 终端输出中 `check_injective_health_or_fix` 的日志；
  - `${INJ_HOME_DIR}/logs/inj.log` 的最近错误行。