# 桌面读取个人平台账户

在用户 Web 的账户页登记钱包或预算读取密钥，然后展开桌面的“个人平台账户”，核对服务地址与读取权限，输入密钥并点“读取账户”。结果显示令牌实际所属的个人账户。预算支持分页，所有微积分使用规范十进制字符串，能保留超过 JavaScript 安全整数范围的金额。

目标来自桌面源码里的 `config/personal-account-origin.json`，通过原生桥返回给界面。部署构建时使用唯一、规范的 HTTPS origin。在公网部署上将 allow_local_development_certificate 设为 false；变更部署配置后重新生成绑定清单并构建桌面包。

本机开发默认连接 `https://127.0.0.1:43122`。可先运行下列命令，为同一开发 Web 服务准备回环 TLS 叶证书及独立的公开根证书。程序将叶私钥、叶证书和公开根放在选定的私有目录。随后将用户 Web 的 ORANGE_USER_TLS_DIR 指向该目录，在桌面“本机开发证书”中粘贴 ca.pem 的公开内容。系统信任库无须改动。Rust 客户端仍核对服务器证书与 IP，且不会跟随重定向。

```sh
python3.12 scripts/prepare-personal-account-dev-tls.py --output .local/personal-account-tls
```

Wallet 密钥访问 GET /api/v1/automation/account/wallet，Budgets 密钥访问 GET /api/v1/automation/account/budgets。FRB 暴露 personalApiEndpoint、readPersonalWallet 和 readPersonalBudgets 三个调用。每次读取独立验证当前 Host 句柄，固定目标、方法和凭据用途。预算翻页接受经过校验的游标及 1 至 100 的页大小。单次响应最多 64 KiB；同进程最多同时进行四次账户读取。UI 在折叠、切换 Host 或应用进入非活跃状态时清除令牌和结果，晚到响应须匹配原界面代次。密钥仅用于个人元数据读取，无法据此签发密钥、提交任务或付款。

[锁定的生产者契约](../config/personal-api-contract.lock.json) · [本地读取接口快照](../contracts/personal-account/read-operations.json)
