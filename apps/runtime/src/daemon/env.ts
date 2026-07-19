// 会话终端环境:声明自己干净的终端身份,并清掉 daemon 启动环境泄漏进来的
// 终端标识与颜色抑制变量。daemon 可能从 cmux / CI 这类 TERM=dumb、NO_COLOR=1 的
// 环境里被拉起,原样透传会让 Claude Code 等工具关掉配色,或按错误的 terminfo 渲染。

// NO_COLOR:任意非空值都会让遵循该约定的工具禁用配色(这里 daemon 明确要给终端上色)。
// TERM_PROGRAM / TERM_PROGRAM_VERSION / TERMINFO:描述的是 daemon 启动处的终端,
// 不该冒充成新会话的终端,尤其 TERMINFO 常指向别的 App 的 terminfo 库,与 xterm-256color 不一致。
const STRIPPED_TERMINAL_VARS = ["NO_COLOR", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERMINFO"];

export function buildSessionEnv(base: NodeJS.ProcessEnv = process.env): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(base)) {
    if (value !== undefined && !STRIPPED_TERMINAL_VARS.includes(key)) env[key] = value;
  }
  env.TERM = "xterm-256color";
  env.COLORTERM = "truecolor";
  return env;
}
