// 输入是字节流,可能在多字节 UTF-8 字符中间被切帧(TTY stdin 分片)。
// 逐帧 toString("utf8") 会把半个序列解成 U+FFFD �。这里只切到最后一个
// 完整字符的边界,返回可安全解码的字节数,剩余尾字节由调用方留到下一帧。

// UTF-8 首字节引导的序列长度;续字节(10xxxxxx)返回 0。
function seqLen(b: number): number {
  if (b < 0x80) return 1; // 0xxxxxxx
  if (b < 0xc0) return 0; // 10xxxxxx 续字节
  if (b < 0xe0) return 2; // 110xxxxx
  if (b < 0xf0) return 3; // 1110xxxx
  if (b < 0xf8) return 4; // 11110xxx
  return 1; // 非法首字节:当单字节交出,toString 会给 �(真非法数据,不缓冲以免卡死)
}

// 返回 buf 中可安全解码的前缀字节数。末尾若是不完整的多字节序列,截到它之前。
export function utf8SafeCut(buf: Uint8Array): number {
  if (buf.length === 0) return 0;
  // 4 字节字符最多有 3 个续字节,末尾回看至多 3 个即可定位序列起点
  const start = Math.max(0, buf.length - 3);
  for (let i = buf.length - 1; i >= start; i--) {
    const len = seqLen(buf[i]!);
    if (len === 0) continue; // 续字节,继续向前找首字节
    // 找到末尾序列的起点:够长则整段完整,否则截到起点前
    return i + len <= buf.length ? buf.length : i;
  }
  // 回看范围内全是续字节(截断的超长序列或垃圾):整段交出,不无限缓冲
  return buf.length;
}
