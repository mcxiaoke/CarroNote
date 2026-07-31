# SafeNotes SafeServer (Go) 代码审查报告

**审查对象**：`server/go/`（SafeServer v2.1 Go 参考实现，仅标准库）
**审查日期**：2026-07-30 22:09:10
**审查人**：WorkBuddy（Hy3）
**范围**：`server/go/main.go` + `internal/{config,auth,storage,server}` 全部 9 个 Go 文件
**方法**：逐文件静态审查 + `go build` / `go vet` + 真实运行冒烟测试（curl 验证全部端点、限速、路径穿越、XFF 伪造）

---

## 0. 总体结论

代码整体结构清晰、分层合理、注释详尽，`go build` 与 `go vet` 均通过，协议符合性（401/404/412/429/204、ETag、乐观锁、路径穿越防护）实测基本正确。但存在 **1 个高危安全缺陷、1 个中高危配置缺陷、若干中低危安全/并发/健壮性隐患，以及缺失 Go 单元测试**。

> 既有报告 `code-review-report-202607291924.md` §6.1 对 Go 服务端的评价是「无明显安全问题」，本次深入运行验证后发现该结论过于乐观，特此补充。

| 等级 | 数量 | 关键项 |
|------|------|--------|
| 🔴 高危（安全） | 1 | 配置加载整体失败 → 静默回退到弱默认 token |
| 🟠 中高危 | 1 | 配置合并破坏 CLI 优先级（修复上一项后暴露） |
| 🟡 中危 | 4 | XFF 伪造绕过限速 / 限速用户无法自救 / 并发同 hash blob 损坏 / 无 Go 单测 |
| 🟢 低危 | 多项 | TLS 缺失、debug 日志泄露 token、缺 ReadHeaderTimeout、日志文件未关闭等 |

---

## 1. 实证验证结果（冒烟测试）

构建与基础验证：

```
go build ./...   → 通过（无错误）
go vet ./...     → 通过（无警告）
```

功能端点（端口 14080，token=test-token-123，rate-limit=3）：

| 测试 | 预期 | 实测 | 结论 |
|------|------|------|------|
| GET /health | 200 | 200 | ✅ |
| 无 token 访问 manifest | 401 + WWW-Authenticate | 401 | ✅ |
| PUT manifest (If-None-Match:*) | 200 + ETag | 200 + ETag | ✅ |
| 重复 PUT (If-None-Match:*) | 412 | 412 | ✅ |
| GET manifest | 200 + body | 200 + body | ✅ |
| PUT/GET blob | 200 + body | 200 + body | ✅ |
| GET 不存在 blob | 404 | 404 | ✅ |
| blob 路径穿越 `..%2f..%2f` | 400 | 400 | ✅ |
| GET/DELETE /blobs | 200 `[]` | 200 | ✅ |
| 未知路径 | 404 | 404 | ✅ |
| 连续 3 次错误 token | 第 4 次起 429 | 401,401,401,429,429,429 | ✅ |
| 每次换 XFF 伪造 IP 错误 token | 应被限速 | **6 次均 401，从不 429** | ❌ 见问题 S-1 |

---

## 2. 🔴 高危安全问题

### S-1：配置文件解析失败会静默回退到弱默认 Token（HIGH）

**现象（实测）**：按 `server/README.md` 文档推荐的命令 `cd server/go && go run . -config dev.config.json` 启动，启动日志出现：

```
warning: load config file failed: json: cannot unmarshal string into Go struct field Config.readTimeout of type time.Duration
```

随后用**默认弱 token `my-secret-token`** 访问返回 `404`（即鉴权通过），而配置里设置的强 token `change-me-to-a-strong-token` 反而返回 `401`。

**根因**：`internal/config/config.go` 中 `ReadTimeout/WriteTimeout/IdleTimeout` 类型为 `time.Duration`，而 `dev.config.json` 里写的是字符串 `"60s"`。`json.Unmarshal` 无法把字符串解析成 `time.Duration`（它只接受数字纳秒），导致**整个 `loadConfigFile` 失败**，配置被整体丢弃，服务器回退到 `Default()` 里的弱默认 token `"my-secret-token"`。

```go
// config.go — 问题字段
ReadTimeout  time.Duration `json:"readTimeout"`   // JSON 里是 "60s" 字符串 → unmarshal 失败
WriteTimeout time.Duration `json:"writeTimeout"`
IdleTimeout  time.Duration `json:"idleTimeout"`
```

**危害**：
1. 开发者照着文档用 `dev.config.json` 启动，实际运行的是**弱默认 token**，且自己毫无察觉（启动日志只显示 `token_mask=*****` 长度，不显示真实值）。
2. warning 只打到 stderr，在 systemd（`StandardOutput=journal`）等环境易被忽略。
3. 同理，任何含 duration 字符串的配置文件都会**整体失效**，所有安全相关配置（token、rate-limit）一并回退默认值。

**修复建议**：为 duration 字段支持字符串解析。最干净的做法是定义自定义类型：

```go
type duration struct{ time.Duration }

func (d *duration) UnmarshalJSON(b []byte) error {
    var v interface{}
    if err := json.Unmarshal(b, &v); err != nil {
        return err
    }
    switch val := v.(type) {
    case float64: // 数字纳秒（兼容旧格式）
        d.Duration = time.Duration(val)
    case string:  // "60s" / "1m" 等
        parsed, err := time.ParseDuration(val)
        if err != nil {
            return err
        }
        d.Duration = parsed
    default:
        return fmt.Errorf("invalid duration: %v", v)
    }
    return nil
}
// 并把 Config 中三个字段改为 duration 类型，MarshalJSON 同样输出字符串。
```

同时建议在 `loadConfigFile` 失败时**区分「致命」与「非致命」**：duration 解析失败不应让整个文件作废；并考虑在解析失败时让 `LogLevel=error` 打到 stdout + 退出非零（由调用方决定是否 fatal），避免静默回退到弱凭据。

---

## 3. 🟠 中高危问题

### M-1：配置合并破坏「命令行优先级」（Medium-High，修复 S-1 后必然暴露）

`config.go` 的 `ParseFlags` 文档声明优先级是「命令行 flag > 配置文件 > 默认值」，但 `loadConfigFile` 的实现是「文件字段非零则无条件覆盖」：

```go
if fileCfg.Addr != ""        { c.Addr = fileCfg.Addr }
if fileCfg.RateLimit != 0    { c.RateLimit = fileCfg.RateLimit }
if fileCfg.MaxBodyBytes != 0 { c.MaxBodyBytes = fileCfg.MaxBodyBytes }
// ... 其他字段类似
```

它**无法区分**「用户在命令行显式设置了该值」与「用户没设置、当前值是默认值」。因此一旦 S-1 修好，只要配置文件同时设了该字段，CLI 显式传入的值就会被覆盖。例如：

```
go run . -addr :9000 -config dev.config.json   # 期望 :9000，实际被配置覆盖为 :4080
go run . -rate-limit -1 -config dev.config.json # 期望禁用限速，实际被覆盖为 10
```

**修复建议**：用 `flag.Visit` 记录显式设置的 flag，仅对「未显式设置」的字段套用配置文件：

```go
set := map[string]bool{}
flag.Visit(func(f *flag.Flag) { set[f.Name] = true })
// 之后：if !set["addr"] && fileCfg.Addr != "" { c.Addr = fileCfg.Addr }
```

---

## 4. 🟡 中危问题

### C-1：X-Forwarded-For 被无条件信任，限速可被伪造绕过（Medium，Security）

`auth.ExtractIP` 对任何请求都优先取 `X-Forwarded-For` 的第一个 IP 作为限速与失败追踪的 Key（实测：每个请求带不同 XFF，连续 6 次错误 token 全部 401，从不 429）。

规范 §10.6 建议「经反向代理时用 XFF 识别真实 IP」，但代码**未区分是否位于可信代理之后**：
- 若直连公网暴露，攻击者可任意伪造 XFF → **限速形同虚设**，可无限尝试 token。
- 攻击者可设 `X-Forwarded-For: <受害者IP>` 触发受害者被 429 锁定（DoS 放大，见 C-2）。

**修复建议**：增加 `-trusted-proxy` / `-behind-proxy` 开关（默认关闭）。仅在开启时取 XFF（且只取离服务端最近的一跳，忽略客户端可注入的前置条目）；默认直接用 `RemoteAddr`。

### C-2：已被限速的合法 IP 无法用正确 token 自救（Medium）

`server.go` 的 `handle` 中，**限速检查 `IsRateLimited` 在认证 `CheckToken` 之前**。因此被限速的 IP 即使后续发来正确 token，也会先被 429 拒绝，`ResetFailures`（仅成功认证才清除）永无执行机会。结合 C-1，攻击者对受害者 IP 伪造错误 token 触发其被限速后，受害者即便输入正确 token 也会被挡在门外，只能等 1 分钟窗口过期。

**修复建议**：限速命中时若后续携带的 token 正确，应放行并清除失败计数（「正确凭证即白名单」），让合法用户立即可恢复，同时阻断纯暴力枚举。

### C-3：并发 PUT 同一 hash 的 blob 可能因共享 `.tmp` 文件名而损坏（Medium，并发正确性）

`storage/fs.go` 的 `atomicWrite` 使用**固定**临时文件名 `path + ".tmp"`：

```go
tmpPath := path + ".tmp"
f, _ := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
```

若两个请求**并发 PUT 同一 hash**（客户端重试、并发同步、或 GC 期间重传都可能触发），二者会打开**同一个** `.tmp` 文件，`O_TRUNC` 会相互截断、写入相互交错，最终 `rename` 得到的 `blobs/<hash>` 是损坏数据。规范 §9.4 期望「原子 rename 自然解决冲突」，但前提是每次写入有**独立**临时文件。

**修复建议**：临时文件名加随机/进程后缀，保证并发写互不干扰：

```go
buf := make([]byte, 8); rand.Read(buf)
tmpPath := fmt.Sprintf("%s.%s.tmp", path, hex.EncodeToString(buf))
```

或按 hash 加 `sync.Mutex` 串行化同 hash 写入。blobs 目录也要在 `resolveBlobPath` 层面排除 `.tmp` 后缀（当前 `ListBlobs` 已跳过 `.tmp`，但 `GetBlob` 不会命中 `.tmp`，OK）。

### C-4：Go 服务端零单元测试（Medium）

`test/` 目录仅有 Flutter/Dart 集成测试，Go 的 `internal/{config,auth,storage,server}` 没有任何 `*_test.go`。对于处理加密同步数据的服务端，缺少对关键逻辑的回归测试风险较高，尤其应覆盖：
- `FailTracker` 滑动窗口、LRU 淘汰、OOM 边界；
- `atomicWrite` 原子性与并发；
- `resolveBlobPath` 路径穿越防护（含 Windows 分隔符、NUL、编码）；
- `PutManifest` 乐观锁（If-Match / If-None-Match / 无条件覆盖）在并发下的 TOCTOU；
- `CheckToken` 常数时间比较与边界（空 token、大小写 Bearer）。

---

## 5. 🟢 低危 / 加固建议

| 编号 | 问题 | 位置 | 建议 |
|------|------|------|------|
| L-1 | **无 TLS**：仅 `ListenAndServe`（明文 HTTP），token 以明文在网传 | `server.go` | 规范 §10.1 要求生产用 HTTPS。建议增加 `-cert`/`-key` 走 `ListenAndServeTLS`；至少在文档醒目处警告「禁止公网裸跑，必须前置 TLS 反向代理」 |
| L-2 | **debug 日志泄露过多 token**：`maskAuth` 保留前 12 字符，默认 15 字符 token 暴露 80% | `middleware.go` | 改为只保留前 4 位或仅记录长度/哈希（如 `sha256(token)[:8]`） |
| L-3 | **token 以命令行参数传递**，明文出现在进程列表（`ps`/`/proc`） | `config.go` | 支持环境变量（如 `SAFESERVER_TOKEN`），优先级高于 flag 默认但低于显式 flag |
| L-4 | **默认弱 token** `"my-secret-token"`，未提供时直接用它 | `config.go` | 未显式设置 token 时至少打印告警；或要求从环境变量/文件读取，缺失则启动失败 |
| L-5 | **缺 `ReadHeaderTimeout`**：慢速发送请求头（slowloris）可长期占用连接耗尽资源 | `server.go` | 设置 `srv.ReadHeaderTimeout`（如 10s） |
| L-6 | **日志文件句柄未关闭**：`NewLogger` 打开文件后未返回/未关闭，graceful shutdown 时不释放 | `logging.go` | 返回 `io.Closer` 或在 `Run` 的 shutdown 分支 `Close()` |
| L-7 | **`defer r.Body.Close()` 写在错误返回之后**：错误分支提前 return 时 body 未显式关闭（http server 会兜底，影响极小） | `handlers.go` | 移到 `io.ReadAll` 之前 |
| L-8 | **GET manifest 未实现 `If-None-Match → 304`**：每次都返回全量 body | `handlers.go` | 可省带宽，规范未强制，低优先 |
| L-9 | **`ListBlobs` 全量读入内存、无分页**：blob 极多时一次性返回大 JSON | `storage/fs.go` | 单用户规模可接受，规模大时考虑流式/分页 |
| L-10 | **`FailTracker.evict` 每次触发为 O(n)、极端 O(n²)**，maxIPs=10000 时每请求可达万级操作 | `auth.go` | 单用户低流量可接受；高并发改用链表+LRU 或时间轮 |
| L-11 | **死代码 `config.DevConfig`**：导出函数无任何调用（README 改用 `-config dev.config.json`） | `config.go` | 删除或接入使用 |
| L-12 | **注释与函数名不一致**：`handlers.go` 中 `isPayloadTooLarge` 上方注释写 `// maxBytesErr ...` | `handlers.go` | 修正注释 |
| L-13 | **`go.mod` 写 `go 1.26.5`**：Go 标准习惯为 `go 1.26`（无小版本） | `go.mod` | 规范为 `go 1.21`（slog 最低要求）即可，避免不必要的 toolchain 拉取 |

---

## 6. 正面评价（符合规范、质量良好部分）

- ✅ 分层清晰：`main → config → auth → storage(Vault 接口) → server(handlers/middleware/logging)`，职责单一，存储层抽象利于替换后端。
- ✅ 乐观锁正确：manifest 的「校验+写入」在 `v.mu` 锁内完成，实测 `If-None-Match:*` 重复 PUT 返回 412、`If-Match` 错误 etag 返回 412，防 TOCTOU 到位。
- ✅ 原子写入：tmp + `fsync` + `rename`，崩溃安全。
- ✅ 路径穿越防护：双层（ValidateHash + 绝对路径前缀校验），实测 `..%2f` 被 400 拦截。
- ✅ 认证常数时间比较（`subtle.ConstantTimeCompare`）+ 401 带 `WWW-Authenticate`。
- ✅ 中间件链（RequestID → Logging → Recover）+ 结构化日志（slog）+ graceful shutdown。
- ✅ 速率限制滑动窗口 + LRU 防 OOM 的整体设计方向正确（仅 XFF 信任与自愈逻辑有缺陷，见 C-1/C-2）。
- ✅ `go build` / `go vet` 干净，无明显编译/静态问题。

---

## 7. 优先级修复清单

### P0（安全，立即修复）
1. **S-1**：修复 `time.Duration` JSON 解析，使 `dev.config.json` 及任意配置文件可正确加载；解析失败不得静默回退到弱默认 token（至少告警/非零退出）。

### P1（正确性 / 健壮性）
2. **M-1**：用 `flag.Visit` 实现真正的 CLI 优先级覆盖。
3. **C-3**：blob 原子写临时文件加随机后缀，杜绝并发同 hash 写入损坏。
4. **C-1 / C-2**：XFF 仅在可信代理模式下信任；限速命中但 token 正确时放行并清除失败计数。
5. **C-4**：补齐 Go 单元测试（auth / storage / 乐观锁 / 路径穿越为最低集）。

### P2（加固 / 清理）
6. L-1 TLS 选项或部署告警；L-2 token 日志脱敏；L-3 环境变量传 token；L-4 弱默认 token 告警；L-5 ReadHeaderTimeout；L-6 关闭日志文件；L-7~L-13 低危清理。

---

## 8. 复现命令（供复核）

```bash
# 构建
cd server/go && go build -o /tmp/safeserver . && go vet ./...

# S-1 复现：仅用文档推荐的配置启动，实际用弱默认 token 鉴权通过
./safeserver -config dev.config.json
curl -i -H "Authorization: Bearer my-secret-token" http://localhost:4080/api/v2/manifest   # 404（鉴权通过）
curl -i -H "Authorization: Bearer change-me-to-a-strong-token" http://localhost:4080/api/v2/manifest  # 401

# C-1 复现：每次换 XFF 绕过限速
for i in $(seq 1 6); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer wrong" \
       -H "X-Forwarded-For: 10.0.0.$i" http://localhost:4080/api/v2/manifest
done   # 全部 401，从不 429
```

---

*报告生成时间：2026-07-30 22:09:10*
*审查工具：静态审查 + go build/vet + 真实运行 curl 冒烟测试*
