# ============================================================
# 作成日：2026-11-20
# 目的　：マウスポインターの速度をリアルタイムにデスクトップへ表示するガジェット
#         右クリックメニュー：この位置で固定（トグル）/ 設定 / About / 終了
#         設定は %APPDATA%\MouseSpeedometer\settings.json に保存
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName    = 'MouseSpeedometer'
$AppVersion = '1.0.0'
$ConfigDir  = Join-Path $env:APPDATA $AppName
$ConfigPath = Join-Path $ConfigDir 'settings.json'

# 表示色
$BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 160)
$SubColor  = [System.Drawing.Color]::FromArgb(150, 210, 190)   # max. / avr. 行の色

# 既定の設定値を返す
function Get-DefaultConfig {
    [ordered]@{
        FontName = 'Segoe UI'
        FontSize = 20
        UpdateInterval = 0.5   # 表示の更新間隔（秒）
        Locked   = $false
        X        = 100
        Y        = 100
    }
}

# 設定ファイルを読み込む（無い・壊れている場合は既定値）
function Read-Config {
    $cfg = Get-DefaultConfig
    try {
        if (Test-Path $ConfigPath) {
            $json = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $json.$k) { $cfg[$k] = $json.$k }
            }
        }
    } catch { }
    $cfg
}

# 現在の設定と位置をファイルへ保存する
function Save-Config {
    try {
        if (-not (Test-Path $ConfigDir)) {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        }
        $state.Config.X = $form.Left
        $state.Config.Y = $form.Top
        $state.Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# 座標がどれかの画面内にあるか判定する（モニター構成が変わった時の対策）
function Test-OnScreen([int]$x, [int]$y) {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        if ($s.WorkingArea.Contains($x + 10, $y + 10)) { return $true }
    }
    $false
}

# フォント名・サイズから Font を作る（失敗時は既定フォント）
function New-GadgetFont([string]$name, [single]$size) {
    try {
        New-Object System.Drawing.Font($name, $size, [System.Drawing.FontStyle]::Regular)
    } catch {
        New-Object System.Drawing.Font('Segoe UI', $size)
    }
}

# 1行ぶん（見出し・数値・単位）のラベルを作ってフォームに載せる
function New-Row([bool]$big, [string]$caption, $color) {
    $row = @{ Big = $big }
    foreach ($k in 'Cap', 'Num', 'Unit') {
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize  = $false
        $l.ForeColor = $color
        $l.BackColor = $BackColor
        $form.Controls.Add($l)
        $row[$k] = $l
    }
    $row.Cap.Text  = $caption; $row.Cap.TextAlign  = 'MiddleLeft'
    $row.Num.Text  = '0';      $row.Num.TextAlign  = 'MiddleRight'
    $row.Unit.Text = 'px/s';   $row.Unit.TextAlign = 'MiddleLeft'
    $row
}

# 設定のフォントを反映し、3行を「数字の右端」で揃えて配置する
function Set-GadgetFont {
    $big   = New-GadgetFont $state.Config.FontName ([single]$state.Config.FontSize)
    $small = New-GadgetFont $state.Config.FontName ([single][Math]::Max(8, [Math]::Round($state.Config.FontSize * 0.5)))
    $tr = [System.Windows.Forms.TextRenderer]

    # 列幅：見出し列 + 数値列（5桁ぶん固定で桁数によるガタつき防止）
    $capW = $tr::MeasureText('avr.', $small).Width + 6
    $numW = [Math]::Max($tr::MeasureText('88888', $big).Width, $tr::MeasureText('88888', $small).Width) + 4
    $numRight = 10 + $capW + $numW   # 全行共通の数字の右端

    $y = 4
    $right = 0
    foreach ($r in $rows) {
        $f = if ($r.Big) { $big } else { $small }
        $h = $tr::MeasureText('8', $f).Height
        $unitW = $tr::MeasureText('px/s', $f).Width + 2
        foreach ($l in @($r.Cap, $r.Num, $r.Unit)) { $l.Font = $f }
        $r.Cap.Location  = New-Object System.Drawing.Point(10, $y)
        $r.Cap.Size      = New-Object System.Drawing.Size($capW, $h)
        $r.Num.Location  = New-Object System.Drawing.Point(($numRight - $numW), $y)
        $r.Num.Size      = New-Object System.Drawing.Size($numW, $h)
        $r.Unit.Location = New-Object System.Drawing.Point(($numRight + 4), $y)
        $r.Unit.Size     = New-Object System.Drawing.Size($unitW, $h)
        $right = [Math]::Max($right, $numRight + 4 + $unitW)
        $y += $h
    }
    $form.ClientSize = New-Object System.Drawing.Size(($right + 10), ($y + 4))
}

# max. / avr. の集計をリセットする
function Reset-Stats {
    $state.MaxSpeed = 0.0
    $state.MoveDist = 0.0
    $state.MoveTime = 0.0
    $rowMax.Num.Text = '0'
    $rowAvg.Num.Text = '0'
}

# 固定状態に応じてマウスカーソルの形を変える
function Update-DragCursor {
    $c = if ($state.Config.Locked) { [System.Windows.Forms.Cursors]::Default } else { [System.Windows.Forms.Cursors]::SizeAll }
    $form.Cursor = $c
    foreach ($ctl in $form.Controls) { $ctl.Cursor = $c }
}

# 設定ダイアログを表示する
function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = '設定'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.TopMost         = $true
    $dlg.ClientSize      = New-Object System.Drawing.Size(360, 306)

    # フォント種類
    $lblFont = New-Object System.Windows.Forms.Label
    $lblFont.Text     = 'フォント'
    $lblFont.Location = New-Object System.Drawing.Point(16, 20)
    $lblFont.AutoSize = $true

    $cbFont = New-Object System.Windows.Forms.ComboBox
    $cbFont.DropDownStyle = 'DropDownList'
    $cbFont.Location      = New-Object System.Drawing.Point(90, 16)
    $cbFont.Width         = 250
    $names = [System.Drawing.FontFamily]::Families |
        Where-Object { $_.IsStyleAvailable([System.Drawing.FontStyle]::Regular) } |
        ForEach-Object { $_.Name }
    $cbFont.Items.AddRange([object[]]$names)
    $idx = $cbFont.Items.IndexOf($state.Config.FontName)
    $cbFont.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }

    # フォントサイズ
    $lblSize = New-Object System.Windows.Forms.Label
    $lblSize.Text     = 'サイズ'
    $lblSize.Location = New-Object System.Drawing.Point(16, 56)
    $lblSize.AutoSize = $true

    $numSize = New-Object System.Windows.Forms.NumericUpDown
    $numSize.Minimum  = 8
    $numSize.Maximum  = 120
    $numSize.Value    = [decimal]([Math]::Min(120, [Math]::Max(8, [int]$state.Config.FontSize)))
    $numSize.Location = New-Object System.Drawing.Point(90, 52)
    $numSize.Width    = 80

    # 表示の更新間隔（秒）
    $lblInterval = New-Object System.Windows.Forms.Label
    $lblInterval.Text     = '更新間隔'
    $lblInterval.Location = New-Object System.Drawing.Point(16, 92)
    $lblInterval.AutoSize = $true

    $numInterval = New-Object System.Windows.Forms.NumericUpDown
    $numInterval.DecimalPlaces = 1
    $numInterval.Increment     = [decimal]0.1
    $numInterval.Minimum       = [decimal]0.1
    $numInterval.Maximum       = [decimal]2.0
    $numInterval.Value    = [decimal]([Math]::Min(2.0, [Math]::Max(0.1, [double]$state.Config.UpdateInterval)))
    $numInterval.Location = New-Object System.Drawing.Point(90, 88)
    $numInterval.Width    = 80

    $lblSec = New-Object System.Windows.Forms.Label
    $lblSec.Text     = '秒（大きいほど数字が落ち着く）'
    $lblSec.Location = New-Object System.Drawing.Point(176, 92)
    $lblSec.AutoSize = $true

    # プレビュー
    $preview = New-Object System.Windows.Forms.Label
    $preview.Text        = '1,234 px/s'
    $preview.TextAlign   = 'MiddleCenter'
    $preview.BorderStyle = 'FixedSingle'
    $preview.BackColor   = $BackColor
    $preview.ForeColor   = $ForeColor
    $preview.Location    = New-Object System.Drawing.Point(16, 128)
    $preview.Size        = New-Object System.Drawing.Size(324, 120)

    # プレビューを現在の選択内容で更新する
    $updatePreview = {
        $preview.Font = New-GadgetFont ([string]$cbFont.SelectedItem) ([single]$numSize.Value)
    }
    $cbFont.Add_SelectedIndexChanged($updatePreview)
    $numSize.Add_ValueChanged($updatePreview)
    & $updatePreview

    # OK / キャンセル
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text         = 'OK'
    $btnOk.DialogResult = 'OK'
    $btnOk.Location     = New-Object System.Drawing.Point(184, 262)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'キャンセル'
    $btnCancel.DialogResult = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(266, 262)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.AddRange(@($lblFont, $cbFont, $lblSize, $numSize, $lblInterval, $numInterval, $lblSec, $preview, $btnOk, $btnCancel))

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $state.Config.FontName = [string]$cbFont.SelectedItem
        $state.Config.FontSize = [int]$numSize.Value
        $state.Config.UpdateInterval = [double]$numInterval.Value
        Set-GadgetFont
        Save-Config
    }
    $dlg.Dispose()
}

# About ダイアログを表示する
function Show-About {
    $msg = "Mouse Speedometer  v$AppVersion`r`n`r`n" +
           "マウスポインターの移動速度（ピクセル/秒）をリアルタイム表示します。`r`n" +
           "更新間隔ごとの平均値を 10px/s 単位で表示します。`r`n" +
           "max.：最高速度 / avr.：動いていた時間の平均速度`r`n`r`n" +
           "・左ドラッグ：移動（固定していない時）`r`n" +
           "・右クリック：メニュー`r`n`r`n" +
           "設定ファイル：`r`n$ConfigPath"
    [System.Windows.Forms.MessageBox]::Show($form, $msg, 'About', 'OK', 'Information') | Out-Null
}

# ---------- 状態 ----------
$cfg = Read-Config
if (-not (Test-OnScreen ([int]$cfg.X) ([int]$cfg.Y))) { $cfg.X = 100; $cfg.Y = 100 }

$state = @{
    Config    = $cfg
    LastPos   = [System.Windows.Forms.Cursor]::Position
    Watch     = [System.Diagnostics.Stopwatch]::StartNew()
    LastMs    = 0.0
    AccDist   = 0.0   # 区間内の移動距離の合計（px）
    AccTime   = 0.0   # 区間内の経過時間の合計（秒）
    MaxSpeed  = 0.0   # max.：区間平均の最大値
    MoveDist  = 0.0   # avr. 用：動いていた区間の距離合計
    MoveTime  = 0.0   # avr. 用：動いていた区間の時間合計
    Dragging  = $false
    DragStart = $null
    FormStart = $null
}

# ---------- メインウィンドウ ----------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Mouse Speed'
$form.FormBorderStyle = 'None'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.StartPosition   = 'Manual'
$form.BackColor       = $BackColor
$form.Opacity         = 0.85
$form.Location        = New-Object System.Drawing.Point([int]$cfg.X, [int]$cfg.Y)

# 現在値（大）/ max.（小）/ avr.（小）の3行
$rowNow = New-Row $true  ''     $ForeColor
$rowMax = New-Row $false 'max.' $SubColor
$rowAvg = New-Row $false 'avr.' $SubColor
$rows   = @($rowNow, $rowMax, $rowAvg)

Set-GadgetFont
Update-DragCursor

# ---------- ドラッグ移動 ----------
$onMouseDown = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and -not $state.Config.Locked) {
        $state.Dragging  = $true
        $state.DragStart = [System.Windows.Forms.Cursor]::Position
        $state.FormStart = $form.Location
    }
}
$onMouseMove = {
    if ($state.Dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(
            ($state.FormStart.X + $p.X - $state.DragStart.X),
            ($state.FormStart.Y + $p.Y - $state.DragStart.Y))
    }
}
$onMouseUp = {
    if ($state.Dragging) {
        $state.Dragging = $false
        Save-Config
    }
}
foreach ($c in (@($form) + @($form.Controls))) {
    $c.Add_MouseDown($onMouseDown)
    $c.Add_MouseMove($onMouseMove)
    $c.Add_MouseUp($onMouseUp)
}

# ---------- 右クリックメニュー ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miLock = New-Object System.Windows.Forms.ToolStripMenuItem('この位置で固定')
$miLock.CheckOnClick = $true
$miLock.Checked      = [bool]$cfg.Locked
$miLock.Add_CheckedChanged({
    $state.Config.Locked = $miLock.Checked
    $state.Dragging = $false
    Update-DragCursor
    Save-Config
})

$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem('設定...')
$miSettings.Add_Click({ Show-Settings })

$miReset = New-Object System.Windows.Forms.ToolStripMenuItem('max. / avr. をリセット')
$miReset.Add_Click({ Reset-Stats })

$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem('About')
$miAbout.Add_Click({ Show-About })

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('終了')
$miExit.Add_Click({ $form.Close() })

$menu.Items.AddRange(@(
    $miLock,
    $miReset,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miSettings,
    $miAbout,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miExit
))
$form.ContextMenuStrip = $menu
foreach ($ctl in $form.Controls) { $ctl.ContextMenuStrip = $menu }

# ---------- 速度計測（50ms ごと） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
    $now = $state.Watch.Elapsed.TotalMilliseconds
    $dt  = ($now - $state.LastMs) / 1000.0
    if ($dt -le 0) { return }

    $p  = [System.Windows.Forms.Cursor]::Position
    $dx = $p.X - $state.LastPos.X
    $dy = $p.Y - $state.LastPos.Y

    # 計測は 50ms ごと、距離と時間を区間内で積算する
    $state.AccDist += [Math]::Sqrt($dx * $dx + $dy * $dy)
    $state.AccTime += $dt
    $state.LastPos = $p
    $state.LastMs  = $now

    # 更新間隔ぶん溜まったら区間平均を表示（10px/s 単位に丸め）
    if ($state.AccTime -ge [double]$state.Config.UpdateInterval) {
        $avg = $state.AccDist / $state.AccTime
        $shown = [Math]::Round($avg / 10) * 10
        $rowNow.Num.Text = '{0:0}' -f $shown

        # max.：区間平均の最大値を保持
        if ($shown -gt $state.MaxSpeed) { $state.MaxSpeed = $shown }
        # avr.：止まっていた区間（0表示）を除いた時間加重平均
        if ($shown -gt 0) {
            $state.MoveDist += $state.AccDist
            $state.MoveTime += $state.AccTime
        }
        $mean = if ($state.MoveTime -gt 0) { [Math]::Round($state.MoveDist / $state.MoveTime / 10) * 10 } else { 0 }
        $rowMax.Num.Text = '{0:0}' -f $state.MaxSpeed
        $rowAvg.Num.Text = '{0:0}' -f $mean
        $state.AccDist = 0.0
        $state.AccTime = 0.0
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-Config
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
