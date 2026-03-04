const bufferInitial = ">EVENT cluster\r\nnode-1 joined\r\n>EVENT cluster\r\nnode-2 joined\r\n";
let buffer = bufferInitial;
let newlineIdx;
while ((newlineIdx = buffer.indexOf("\r\n")) !== -1) {
  const line = buffer.slice(0, newlineIdx);
  buffer = buffer.slice(newlineIdx + 2);
  if (line.startsWith(">EVENT ")) {
    const nextNewline = buffer.indexOf("\r\n");
    if (nextNewline !== -1) {
      const message = buffer.slice(0, nextNewline);
      buffer = buffer.slice(nextNewline + 2);
      const channel = line.slice(7).trim();
      console.log(`channel=${channel}, message=${message}`);
    } else {
      buffer = line + "\r\n" + buffer;
      break;
    }
  }
}
