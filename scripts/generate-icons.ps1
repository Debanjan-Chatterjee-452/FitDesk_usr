# Generates FitDesk PWA / Apple touch icons without external image tooling.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/generate-icons.ps1
param(
  [string]$OutDir = (Join-Path $PSScriptRoot '..\public\icons')
)

Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function New-RoundedPath {
  param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $R * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
  $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
  $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-FitDeskIcon {
  param(
    [int]$Size,
    [string]$File,
    [bool]$FullBleed
  )

  $super = 4
  $s = $Size * $super
  $canvas = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($canvas)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  $ratio = $s / 512.0
  $c1 = [System.Drawing.ColorTranslator]::FromHtml('#2DD4BF')
  $c2 = [System.Drawing.ColorTranslator]::FromHtml('#0F9E8F')
  $c3 = [System.Drawing.ColorTranslator]::FromHtml('#0B5F57')

  $bgPath = if ($FullBleed) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddRectangle((New-Object System.Drawing.Rectangle 0, 0, $s, $s))
    $p
  } else {
    New-RoundedPath (16 * $ratio) (16 * $ratio) (480 * $ratio) (480 * $ratio) (132 * $ratio)
  }

  $bgRect = New-Object System.Drawing.Rectangle 0, 0, $s, $s
  $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $bgRect, $c1, $c3, 52.0
  $blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
  $blend.Colors = [System.Drawing.Color[]]@($c1, $c2, $c3)
  $blend.Positions = [float[]]@(0.0, 0.55, 1.0)
  $bgBrush.InterpolationColors = $blend
  $g.FillPath($bgBrush, $bgPath)

  $g.SetClip($bgPath)
  $shineRect = New-Object System.Drawing.Rectangle 0, 0, $s, ([int]($s * 0.78))
  $shine = New-Object System.Drawing.Drawing2D.LinearGradientBrush $shineRect, ([System.Drawing.Color]::FromArgb(52, 255, 255, 255)), ([System.Drawing.Color]::FromArgb(0, 255, 255, 255)), 42.0
  $g.FillRectangle($shine, $shineRect)

  $halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(14, 255, 255, 255))
  $g.FillEllipse($halo, (296 * $ratio), (-64 * $ratio), (300 * $ratio), (300 * $ratio))
  $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(34, 4, 47, 42))
  $g.FillEllipse($shadow, (-100 * $ratio), (260 * $ratio), (376 * $ratio), (376 * $ratio))
  $g.ResetClip()

  # Geometric "F" mark, matching the in-app logo.
  $points = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF (166 * $ratio), (132 * $ratio)),
    (New-Object System.Drawing.PointF (352 * $ratio), (132 * $ratio)),
    (New-Object System.Drawing.PointF (352 * $ratio), (198 * $ratio)),
    (New-Object System.Drawing.PointF (236 * $ratio), (198 * $ratio)),
    (New-Object System.Drawing.PointF (236 * $ratio), (260 * $ratio)),
    (New-Object System.Drawing.PointF (342 * $ratio), (260 * $ratio)),
    (New-Object System.Drawing.PointF (342 * $ratio), (323 * $ratio)),
    (New-Object System.Drawing.PointF (236 * $ratio), (323 * $ratio)),
    (New-Object System.Drawing.PointF (236 * $ratio), (428 * $ratio)),
    (New-Object System.Drawing.PointF (166 * $ratio), (428 * $ratio))
  )
  $fPath = New-Object System.Drawing.Drawing2D.GraphicsPath
  $fPath.AddPolygon($points)
  $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(247, 255, 255, 255))
  $g.FillPath($white, $fPath)

  $dot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 5, 46, 42))
  $g.FillEllipse($dot, (322 * $ratio), (258 * $ratio), (68 * $ratio), (68 * $ratio))

  if (-not $FullBleed) {
    $border = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(46, 255, 255, 255)), (2 * $ratio)
    $g.DrawPath($border, $bgPath)
    $border.Dispose()
  }

  $target = New-Object System.Drawing.Bitmap $Size, $Size
  $tg = [System.Drawing.Graphics]::FromImage($target)
  $tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $tg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $tg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $tg.DrawImage($canvas, 0, 0, $Size, $Size)
  $target.Save((Join-Path $OutDir $File), [System.Drawing.Imaging.ImageFormat]::Png)

  $tg.Dispose()
  $target.Dispose()
  $g.Dispose()
  $canvas.Dispose()
  $bgBrush.Dispose()
  $shine.Dispose()
  $halo.Dispose()
  $shadow.Dispose()
  $white.Dispose()
  $dot.Dispose()
  $fPath.Dispose()
  $bgPath.Dispose()
}

New-FitDeskIcon -Size 192 -File 'icon-192.png' -FullBleed $false
New-FitDeskIcon -Size 512 -File 'icon-512.png' -FullBleed $false
New-FitDeskIcon -Size 512 -File 'icon-maskable-512.png' -FullBleed $true
New-FitDeskIcon -Size 180 -File 'apple-touch-icon.png' -FullBleed $true

Write-Output "Generated FitDesk icons in $OutDir"
