const fs = require('node:fs/promises');
// Validate frame boundaries before streaming decode. Node's zstd stream can
// return a partial result for truncated input, so EOF alone is insufficient.
// Field layout follows the bundled upstream Zstandard frame-size reader.
async function validateZstdFile(file, size) {
  const handle = await fs.open(file, 'r');
  let at = 0, frames = 0;
  async function read(offset, count) {
    if (offset + count > size) throw new Error('压缩日志帧未写完');
    const bytes = Buffer.alloc(count), result = await handle.read(bytes, 0, count, offset);
    if (result.bytesRead !== count) throw new Error('压缩日志读取不完整');
    return bytes;
  }
  try {
    while (at < size) {
      const magic = (await read(at, 4)).readUInt32LE(0);
      if (((magic & 0xfffffff0) >>> 0) === 0x184d2a50) {
        const length = (await read(at + 4, 4)).readUInt32LE(0); at += 8 + length;
        if (at > size) throw new Error('压缩日志跳过帧未写完');
        continue;
      }
      if (magic !== 0xfd2fb528) throw new Error('压缩日志帧头无效');
      const descriptor = (await read(at + 4, 1))[0], single = (descriptor >>> 5) & 1, fcs = descriptor >>> 6;
      if (descriptor & 8) throw new Error('压缩日志包含不支持的帧参数');
      const headerSize = 5 + (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + [0, 2, 4, 8][fcs] + (single && !fcs ? 1 : 0);
      await read(at, headerSize); at += headerSize;
      while (true) {
        const bytes = await read(at, 3), header = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16), last = header & 1, type = (header >>> 1) & 3;
        if (type === 3) throw new Error('压缩日志块类型无效');
        at += 3 + (type === 1 ? 1 : header >>> 3);
        if (at > size) throw new Error('压缩日志块未写完');
        if (last) break;
      }
      if (descriptor & 4) { await read(at, 4); at += 4; }
      frames++;
    }
    if (!frames || at !== size) throw new Error('压缩日志缺少完整数据帧');
  } finally { await handle.close(); }
}
module.exports = { validateZstdFile };
