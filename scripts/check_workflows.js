// The repository is public, so a build left as a run artifact or a release can be downloaded by anyone.
// Only the screenshots and test results listed here are uploaded, and the two store uploads refuse a commit
// without a green CI run. Run from the repository root: node scripts/check_workflows.js
const fs = require('fs');
const path = require('path');

const allowed = new Map([
  ['mac-screens', '${{ runner.temp }}/shots'],
  ['ios-screenshots${{ matrix.suffix }}', '${{ runner.temp }}/ios-screenshots'],
  ['ios-tests-xcresult${{ matrix.suffix }}', '${{ runner.temp }}/ios-tests.xcresult|${{ runner.temp }}/ios-app-tests.xcresult'],
]);
const never = /pages-artifact|gh\s+release|action-gh-release|create-release|release-action|upload-release/;

function files(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return files(full);
    return /\.ya?ml$/.test(entry.name) ? [full] : [];
  });
}

const indent = line => line.length - line.trimStart().length;
const problems = [];

for (const file of files('.github')) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  lines.forEach((line, i) => {
    if (!line.trimStart().startsWith('#') && never.test(line)) problems.push(`${file}:${i + 1} publishes something: ${line.trim()}`);
  });
  lines.forEach((line, i) => {
    if (!/uses:\s*["']?[^\s"']*upload-artifact/.test(line) || line.trimStart().startsWith('#')) return;
    let start = i;
    while (start > 0 && !/^\s*-\s/.test(lines[start])) start--;
    const dash = indent(lines[start]);
    let end = i + 1;
    while (end < lines.length && (lines[end].trim() === '' || indent(lines[end]) > dash)) end++;
    const step = lines.slice(start, end);
    const where = `${file}:${i + 1}`;
    const withAt = step.findIndex(l => /^\s*with:/.test(l));
    if (withAt < 0) return problems.push(`${where} uploads an artifact with no name`);
    const withLine = step[withAt];
    let name, artifactPath;
    if (withLine.includes('{')) {
      name = /name:\s*([^,}]+)/.exec(withLine)?.[1].trim();
      artifactPath = /path:\s*([^,}]+)/.exec(withLine)?.[1].trim();
    } else {
      const body = step.slice(withAt + 1);
      const nameLine = body.find(l => /^\s*name:/.test(l));
      name = nameLine?.replace(/^\s*name:\s*/, '').trim();
      const pathAt = body.findIndex(l => /^\s*path:/.test(l));
      if (pathAt >= 0) {
        const first = body[pathAt].replace(/^\s*path:\s*/, '').trim();
        if (/^[|>]/.test(first)) {
          const own = indent(body[pathAt]);
          const rest = [];
          for (const l of body.slice(pathAt + 1)) {
            if (l.trim() === '') continue;
            if (indent(l) <= own) break;
            rest.push(l.trim());
          }
          artifactPath = rest.join('|');
        } else {
          artifactPath = first;
        }
      }
    }
    if (!name) return problems.push(`${where} uploads an artifact with no name`);
    if (!allowed.has(name)) return problems.push(`${where} uploads an artifact named ${name}`);
    if (allowed.get(name) !== artifactPath) problems.push(`${where} uploads ${name} from ${artifactPath}, not ${allowed.get(name)}`);
  });
}

for (const file of ['.github/workflows/testflight.yml', '.github/workflows/macappstore.yml']) {
  if (!fs.readFileSync(file, 'utf8').includes('Check that CI passed')) problems.push(`${file} does not check the CI run of the commit`);
}
if (fs.existsSync('.github/workflows/release.yml')) problems.push('release.yml is back');

if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log('workflows ok');
