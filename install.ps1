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

# Своя иконка: две копии значка Antigravity со сдвигом, задняя — со сменой цвета.
# Собирается из установленного Antigravity.exe, поэтому сам значок Google в репозитории не хранится.
function New-MultiIcon([string]$exe, [string]$out) {
    Add-Type -AssemblyName System.Drawing
    if (-not ('MG.Shell' -as [type])) {
        Add-Type -Namespace MG -Name Shell -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, int[] ids, uint n, uint flags);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
'@
    }
    $h = New-Object IntPtr[] 1; $ids = New-Object int[] 1
    if ([MG.Shell]::PrivateExtractIcons($exe, 0, 256, 256, $h, $ids, 1, 0) -lt 1 -or $h[0] -eq [IntPtr]::Zero) { return $false }
    $src = [System.Drawing.Icon]::FromHandle($h[0]).ToBitmap()   # ToBitmap сохраняет прозрачность, FromHicon — нет
    [void][MG.Shell]::DestroyIcon($h[0])

    # поворот оттенка на 150° (матрица hue-rotate из SVG)
    $c = [math]::Cos(150 * [math]::PI / 180); $s = [math]::Sin(150 * [math]::PI / 180)
    $m = [single[][]]@(
        [single[]]@((0.213 + $c * 0.787 - $s * 0.213), (0.213 - $c * 0.213 + $s * 0.143), (0.213 - $c * 0.213 - $s * 0.787), 0, 0),
        [single[]]@((0.715 - $c * 0.715 - $s * 0.715), (0.715 + $c * 0.285 + $s * 0.140), (0.715 - $c * 0.715 + $s * 0.715), 0, 0),
        [single[]]@((0.072 - $c * 0.072 + $s * 0.928), (0.072 - $c * 0.072 - $s * 0.283), (0.072 + $c * 0.928 + $s * 0.072), 0, 0),
        [single[]]@(0, 0, 0, 1, 0),
        [single[]]@(0, 0, 0, 0, 1))
    $attrs = New-Object System.Drawing.Imaging.ImageAttributes
    $attrs.SetColorMatrix((New-Object System.Drawing.Imaging.ColorMatrix -ArgumentList (, $m)))

    $canvas = New-Object System.Drawing.Bitmap 256, 256
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 76, 4, 176, 176), 0, 0, $src.Width, $src.Height, 'Pixel', $attrs)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 4, 76, 176, 176))
    $g.Dispose()

    # .ico из PNG-кадров нескольких размеров (поддерживается начиная с Vista)
    $frames = foreach ($size in 256, 48, 32, 16) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $gg = [System.Drawing.Graphics]::FromImage($bmp); $gg.InterpolationMode = 'HighQualityBicubic'
        $gg.DrawImage($canvas, 0, 0, $size, $size); $gg.Dispose()
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , @($size, $ms.ToArray())
    }
    $fs = [IO.File]::Create($out); $w = New-Object IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f[0] -ge 256) { 0 } else { $f[0] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$f[1].Length); $w.Write([uint32]$offset)
        $offset += $f[1].Length
    }
    foreach ($f in $frames) { $w.Write([byte[]]$f[1]) }
    $w.Close(); $canvas.Dispose(); $src.Dispose()

    # самопроверка: WPF (им иконку читает лаунчер) должен открыть все кадры
    try {
        Add-Type -AssemblyName PresentationCore
        $d = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$out, 'None', 'OnLoad')
        if ($d.Frames.Count -eq $frames.Count) { return $true }
    } catch {}
    Remove-Item $out -ErrorAction SilentlyContinue
    return $false
}

$icon = Join-Path $root 'multigravity.ico'
if ((Test-Path $agy) -and (New-MultiIcon $agy $icon)) { Say "  [ok] Иконка: $icon" 'Green' }
elseif (Test-Path $agy) { $icon = $agy; Say '  [!] Не удалось собрать иконку, будет значок Antigravity.' 'Yellow' }

function New-Shortcut([string]$dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $path = Join-Path $dir 'MultiGravity.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $root 'launcher.vbs') + '"'
    $lnk.WorkingDirectory = $root
    if ($icon -and (Test-Path $icon)) { $lnk.IconLocation = "$icon,0" }
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
