# SafeServer(Go) 复查对照 · 2026-07-31

**依据**：`server-go-review-hy3-20260730.md`
**复查对象**：`server/go/`（全部 9 个 Go 文件 + 本次新增 3 个 `*_test.go`）
**复用结论**：review 之后 server 端**零提交改动**（`git log server/go/` 仅 `7701965` v2.2 与更早两次）；唯一后续提交 `b041083` 只改了 Flutter 客户端 `lib/sync/*`（P0/P1 自愈），**未触及 server**。因此原 review 中 server 的全部问题在当前代码中依然成立，且 v2.2 资源层当时测试不足，本次一并加固。

---

## 1. 原 review 问题 → 当前状态

| 原编号 | 问题 | 等级 | 复查状态 | 说明 |
|--------|------|------|----------|------|
| S-1 | 配置解析失败静默回退弱默认 token | 🔴 高危 | ✅ **已修复** | 新增 `duration` 类型支持 `"60s"` 字符串；`loadConfigFile` 失败改 `log.Fatalf` 非零退出。`dev.config.json` 现在能正确加载强 token（冒烟验证：弱 token→401，强 token→404） |
| M-1 | 配置合并破坏 CLI 优先级 | 🟠 中高 | ✅ **已修复** | `ParseFlags` 用 `flag.Visit` 记录显式 flag，配置文件仅填充未显式设置字段（单测 `TestLoadConfigFilePriority` 覆盖） |
| C-1 | XFF 被无条件信任，限速可伪造绕过 | 🟡 中 | ✅ **已修复** | `ExtractIP(r, trustProxy)`：默认直连忽略 XFF（用 `RemoteAddr`）；`-behind-proxy` 开启时才信任且只取最右一跳（冒烟：伪造不同 XFF 仍触发 429） |
| C-2 | 被限速合法 IP 无法用正确 token 自救 | 🟡 中 | ✅ **已修复** | `handle` 改为先校验 token，正确即 `ResetFailures` 放行（冒烟：被限速后正确 token→404） |
| C-3 | 并发同 hash blob 因共享 `.tmp` 损坏 | 🟡 中 | ✅ **已修复** | `atomicWrite` 临时文件名加随机后缀（单测 `TestAtomicWriteConcurrent` 验证无交错损坏） |
| C-4 | Go 服务端零单元测试 | 🟡 中 | ✅ **已修复** | 新增 `internal/{auth,storage,config}/*_test.go`，覆盖认证/限速/路径穿越/并发原子写/duration/合并优先级 |
| L-1 | 无 TLS | 🟢 低 | ✅ **已修复** | 新增 `-cert`/`-key` 走 `ListenAndServeTLS`；明文启动打印告警 |
| L-2 | debug 日志泄露过多 token | 🟢 低 | ✅ **已修复** | `maskAuth` 改记 `sha256` 前 8 位（冒烟日志已验证） |
| L-3 | token 以命令行明文传递 | 🟢 低 | ✅ **已修复** | 支持环境变量 `SAFESERVER_TOKEN`（低于显式 flag、高于配置/默认） |
| L-4 | 默认弱 token 无告警 | 🟢 低 | ✅ **已修复** | 仍用默认弱 token 时 `log.Printf` 醒目告警 |
| L-5 | 缺 ReadHeaderTimeout | 🟢 低 | ✅ **已修复** | `http.Server.ReadHeaderTimeout = 10s` |
| L-6 | 日志文件句柄未关闭 | 🟢 低 | ✅ **已修复** | `NewLogger` 返回 `io.Closer`，shutdown 时 `Close()` |
| L-7 | `defer r.Body.Close()` 写在错误返回后 | 🟢 低 | ✅ **已修复** | 3 处 PUT handler 移至读取前 |
| L-8 | GET manifest 未实现 304 | 🟢 低 | ⬜ 未做 | 规范未强制，低优先；如需省带宽可后续补 `If-None-Match` |
| L-9 | ListBlobs 全量读内存无分页 | 🟢 低 | ⬜ 未做 | 单用户规模可接受；规模大再考虑流式/分页 |
| L-10 | FailTracker.evict 极端 O(n²) | 🟢 低 | ⬜ 未做 | 单用户低流量可接受；高并发改链表+LRU/时间轮 |
| L-11 | 死代码 `DevConfig` | 🟢 低 | ✅ **已修复** | 已删除（无调用方） |
| L-12 | 注释与函数名不一致 | 🟢 低 | ✅ **已修复** | 注释改为描述 `isPayloadTooLarge` |
| L-13 | `go.mod` 写 `go 1.26.5` | 🟢 低 | ✅ **已修复** | 规范为 `go 1.21`（slog 最低要求） |

---

## 2. 复查新发现（v2.2 资源层当时测试不足）

| 编号 | 问题 | 处理 |
|------|------|------|
| N-1 | `ValidateVaultPath` 在 Windows 上对「无盘符绝对路径」（如 `/abs`）漏判：`filepath.IsAbs` 在 Windows 返回 false | ✅ **已修复**：额外拦截「以 `filepath.Separator` 开头的路径」（单测 `TestValidateVaultPathTraversal` 覆盖，含 `\abs` 场景） |
| N-2 | v2.2 资源层 `blob` 的 Get/Put/Delete 改为走 `resolveResourcePath`（不再单独 `ValidateHash`），需确认路径穿越仍被挡 | ✅ **已确认安全**：`ValidateVaultPath` 拒绝 `..`/绝对/NUL/`\`，`blobs/../../etc` 经 Clean 仍以 `..` 开头被拒；`/api/v2/blob//etc/passwd` 被 Clean 归并为 `blobs/etc/passwd` 不出 vault |
| N-3 | 并发原子写临时文件随机后缀需兼顾 Windows rename 偶发 `Access Denied` | ✅ **已处理**：随机后缀杜绝字节交错损坏；Windows 并发 rename 同目标偶发失败会返回错误（非损坏），客户端重试即可，单测据此断言「最终内容不被损坏」而非「每次 rename 必成功」 |

---

## 3. 客户端契约核对（确保 server 改动不破坏 Flutter）

`lib/sync/safe_server_backend.dart` 仅使用标准端点与头：`Authorization: Bearer`、`If-Match`/`If-None-Match`、`/api/v2/manifest|blob|blobs|resources/<path>`、`/api/v2/health`。

- **C-1 改动安全**：客户端不发送 `X-Forwarded-For`，默认直连模式行为不变；`-behind-proxy` 为新增开关，默认关闭。
- **C-2 改动安全**：合法客户端携正确 token，原本就通过；自恢复逻辑对其透明。
- **S-1/M-1 改动安全**：`dev.config.json` 的 `addr/token/rateLimit` 等字段名与 JSON key 未变，配置加载结果与原预期一致（仅不再静默失败）。

结论：本次 server 修复**向后兼容**，无需改动 Flutter 客户端（已按要求未触碰 `lib/`）。

---

## 4. 验证命令

```bash
cd server/go
go build ./...          # 通过
go vet ./...            # 通过
go test ./...           # 通过（auth/storage/config 三个包）
```

冒烟要点（已实机验证）：
- 弱默认 token `my-secret-token` → `401`；配置文件强 token `change-me-to-a-strong-token` → `404`（S-1）
- 直连 + 每次伪造不同 `X-Forwarded-For` + 错误 token（限 3 次）→ `401 401 401 429 429 429`（C-1）
- 被限速后携正确 token → `404`（C-2 自愈）
- debug 日志 `authorization: sha256:xxxx(masked)`（L-2）

*复查时间：2026-07-31 16:42:56*
*改动范围：`server/go/internal/{config,auth,storage,server}/*`、`server/go/go.mod`、新增 3 个 `*_test.go`；Flutter 代码未改动*
