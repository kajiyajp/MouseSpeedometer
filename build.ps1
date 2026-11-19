# ============================================================
# 作成日：2026-11-20
# 目的　：MouseSpeedometer.cs を exe にビルドし、自己署名証明書で署名する
#         1) アイコン生成（無ければ） 2) csc.exe でコンパイル 3) 署名 4) .cer 書き出し
# 実行　：powershell -ExecutionPolicy Bypass -File .\build.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$src  = Join-Path $here 'MouseSpeedometer.cs'
$exe  = Join-Path $here 'MouseSpeedometer.exe'
$ico  = Join-Path $here 'MouseSpeedometer.ico'
$cer  = Join-Path $here 'MouseSpeedometer.cer'
$CertSubject = 'CN=MouseSpeedometer Self-Signed'

# 指定サイズのアイコン画像（スピードメーター風）を PNG バイト列で返す
function New-IconPng([int]$size) {
    $s   = $size / 256.0
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # 角丸の背景
    $r = 48 * $s; $w = $size - 1
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r, $r, 180, 90)
    $path.AddArc($w - $r, 0, $r, $r, 270, 90)
    $path.AddArc($w - $r, $w - $r, $r, $r, 0, 90)
    $path.AddArc(0, $w - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(30, 30, 30))), $path)

    # メーターの弧
    $green = [System.Drawing.Color]::FromArgb(0, 255, 160)
    $pen = New-Object System.Drawing.Pen $green, ([single](22 * $s))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, [single](44 * $s), [single](52 * $s), [single](168 * $s), [single](168 * $s), 150, 240)

    # 針
    $c = 136 * $s
    $ang = -40 * [Math]::PI / 180
    $len = 72 * $s
    $needle = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single](16 * $s))
    $needle.StartCap = 'Round'; $needle.EndCap = 'Round'
    $g.DrawLine($needle, [single](128 * $s), [single]$c, [single](128 * $s + $len * [Math]::Cos($ang)), [single]($c + $len * [Math]::Sin($ang)))
    $d = 36 * $s
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $green), [single](128 * $s - $d / 2), [single]($c - $d / 2), [single]$d, [single]$d)

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

# 複数サイズの PNG を埋め込んだ .ico ファイルを作る
function New-GadgetIcon([string]$path) {
    $sizes = 16, 24, 32, 48, 256
    $pngs  = foreach ($sz in $sizes) { , (New-IconPng $sz) }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
}

# 1) アイコン
if (-not (Test-Path $ico)) {
    Write-Host 'アイコンを生成します...'
    New-GadgetIcon $ico
}

# 2) コンパイル
Write-Host 'コンパイルします...'
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/win32icon:$ico" "/out:$exe" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "$src"
if ($LASTEXITCODE -ne 0) { throw "コンパイルに失敗しました（exit $LASTEXITCODE）" }

# 3) 自己署名証明書（CurrentUser\My に無ければ作る）で署名
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -eq $CertSubject -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    Write-Host '自己署名のコード署名証明書を作成します...'
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject `
        -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5)
}
Write-Host "署名します（拇印 $($cert.Thumbprint)）..."
$sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256

# 4) 証明書の公開部分を書き出す（信頼させたい時に使う）
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

Write-Host ''
Write-Host "出力    : $exe"
Write-Host "署名状態: $($sig.Status)  ※ルート未登録なら UnknownError（=未信頼）が正常"
