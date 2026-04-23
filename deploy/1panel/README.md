# Sub2API 1Panel 发布说明

## 固定路径建议
- 仓库目录：`~/projects/sub2api`
- 编排目录：`~/projects/sub2api/deploy/1panel`
- 环境文件：`~/projects/sub2api/deploy/1panel/.env`
- 本地监听端口：`9406`
- FRP 远端口：`8015`

## 首次部署
```bash
cd ~/projects
git clone git@github.com:scauwjh/sub2api.git
cd sub2api
bash deploy/1panel/release.sh --skip-pull
```

首次执行会自动：
- 从 `deploy/.env.example` 初始化 `deploy/1panel/.env`
- 生成 `POSTGRES_PASSWORD`、`JWT_SECRET`、`TOTP_ENCRYPTION_KEY`
- 创建 `deploy/1panel/data`、`postgres_data`、`redis_data`
- 默认写入 `BIND_HOST=127.0.0.1`、`SERVER_PORT=9406`、`COMPOSE_PROJECT_NAME=sub2api-1panel`

## 日常发版
```bash
bash ~/projects/sub2api/deploy/1panel/release.sh
```

## 仅重启应用
```bash
bash ~/projects/sub2api/deploy/1panel/release.sh sub2api --skip-pull --skip-build
```

## 发版前提
- 服务器已安装 `git`、`docker`、`docker compose`
- 1Panel 执行任务用户对 Docker 有操作权限
- 如需自定义端口、管理员账号、上游密钥，请编辑 `deploy/1panel/.env`

## FRP 配置
服务器 `/etc/frp/frpc.toml` 可追加：

```toml
[[proxies]]
name = "sub2api"
type = "tcp"
localIP = "127.0.0.1"
localPort = 9406
remotePort = 8015
```
