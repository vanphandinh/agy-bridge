from pathlib import Path
p = Path('docker/tests/test-compose-workspace.ps1')
s = p.read_text()
old = '''  $createHostPath = $mount.bind.PSObject.Properties['create_host_path']
  if ($null -eq $createHostPath -or $createHostPath.Value -ne $false) {
    throw '/workspace bind.create_host_path must be false'
  }
'''
new = '''  # Compose may omit an explicit false value from resolved JSON. Lock the
  # source declaration and, when the resolved field is present, require false.
  $workspaceComposeSource = Get-Content -LiteralPath 'compose.workspace.yaml' -Raw
  if ($workspaceComposeSource -notmatch '(?m)^\\s*create_host_path:\\s*false\\s*$') {
    throw 'compose.workspace.yaml must declare bind.create_host_path: false'
  }
  $createHostPath = $mount.bind.PSObject.Properties['create_host_path']
  if ($null -ne $createHostPath -and $createHostPath.Value -ne $false) {
    throw '/workspace resolved bind.create_host_path must not be true'
  }
'''
if old not in s:
    raise SystemExit('compose create_host_path test block not found')
p.write_text(s.replace(old, new, 1))
