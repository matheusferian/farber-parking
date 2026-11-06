// node tools/build-bookmarklet.mjs → tools/makers-bookmarklet.txt (one line "javascript:…" for Safari bookmarks)
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
const min = execSync('npx --yes esbuild@0.24.0 tools/makers-suite-bookmarklet.js --minify --charset=utf8 --target=safari15', { encoding: 'utf8' }).trim().replace(/\n/g, ' ');
if (/%[0-9A-Fa-f]{2}/.test(min)) throw new Error("bookmarklet contains a %XX sequence: Safari would decode it");
writeFileSync('tools/makers-bookmarklet.txt', 'javascript:' + min);
console.log('bookmarklet chars:', min.length + 11);
