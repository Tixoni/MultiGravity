#requires -version 5.1
# Установка MultiGravity: проверка зависимостей и ярлыки на рабочем столе и в меню «Пуск».
param(
    [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop'),
    [switch]$NoStartMenu
)

$root = $PSScriptRoot
$ok = $true

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

Say ''
Say '  MultiGravity — установка' 'Cyan'
Say '  ========================' 'Cyan'
Say ''

# Python нужен утилите pgrav (профили) и stats.py (статистика)
$python = Get-Command python -ErrorAction SilentlyContinue
$pyVersion = $null
if ($python) { try { $pyVersion = (& python --version 2>&1) -join ' ' } catch {} }
if ($pyVersion -match 'Python 3\.(\d+)') {
    Say "  [ok] $pyVersion" 'Green'
} else {
    $ok = $false
    Say '  [!] Python 3 не найден.' 'Yellow'
    Say '      Установите его с https://www.python.org/downloads/ и отметьте «Add python.exe to PATH».'
}

$agy = $env:ANTIGRAVITY_BIN
if (-not $agy) { $agy = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe' }
if (Test-Path $agy) {
    Say "  [ok] Antigravity: $agy" 'Green'
} else {
    $ok = $false
    Say '  [!] Antigravity не найден.' 'Yellow'
    Say '      Установите десктопное приложение: https://antigravity.google/download'
}

# файлы из ZIP-архива помечены как скачанные из интернета — снимаем пометку, иначе Windows будет предупреждать
Get-ChildItem $root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

function New-Shortcut([string]$dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $path = Join-Path $dir 'MultiGravity.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $root 'launcher.vbs') + '"'
    $lnk.WorkingDirectory = $root
    if (Test-Path $agy) { $lnk.IconLocation = "$agy,0" }
    $lnk.Description = 'MultiGravity — несколько аккаунтов Antigravity одновременно'
    $lnk.Save()
    Say "  [ok] Ярлык: $path" 'Green'
}

New-Shortcut $ShortcutDir
if (-not $NoStartMenu) { New-Shortcut ([Environment]::GetFolderPath('Programs')) }

Say ''
if ($ok) {
    Say '  Готово. Запускайте MultiGravity ярлыком.' 'Cyan'
} else {
    Say '  Ярлыки созданы, но сначала установите то, что отмечено [!] выше.' 'Yellow'
}
Say '  Не забудьте: включённый VPN и пропатченный Antigravity — подробности в README.md.'
Say ''
