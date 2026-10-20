$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class FermenterIconGenerator
{
    private static readonly float[] PurpleStops = { 0, 85, 135, 185, 240, 255 };
    private static readonly int[] PurpleColors =
    {
        0x30213A, 0x483256, 0x765185, 0xA38BB0, 0xF5EFF8, 0xFFFFFF
    };

    private static readonly float[] OrangeStops = { 0, 90, 145, 190, 235, 255 };
    private static readonly int[] OrangeColors =
    {
        0x8E4B14, 0xB96B18, 0xD88920, 0xF5B443, 0xFFE4A3, 0xFFFFFF
    };

    public static Bitmap Recolor(Bitmap source)
    {
        var result = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(result))
        {
            graphics.DrawImage(source, 0, 0, source.Width, source.Height);
        }

        var bounds = new Rectangle(0, 0, result.Width, result.Height);
        var data = result.LockBits(bounds, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        var pixels = new byte[Math.Abs(data.Stride) * data.Height];
        Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
        for (var y = 0; y < data.Height; y++)
        {
            for (var x = 0; x < data.Width; x++)
            {
                var index = y * data.Stride + x * 4;
                var blue = pixels[index];
                var green = pixels[index + 1];
                var red = pixels[index + 2];
                var alpha = pixels[index + 3];

                var dx = Math.Max(0, Math.Abs(x - 512) - 274);
                var dy = Math.Max(0, Math.Abs(y - 512) - 274);
                if (dx * dx + dy * dy > 190 * 190)
                {
                    pixels[index] = 0xF8;
                    pixels[index + 1] = 0xEF;
                    pixels[index + 2] = 0xF5;
                    continue;
                }

                if (alpha == 0) continue;
                var maximum = Math.Max(red, Math.Max(green, blue));
                var minimum = Math.Min(red, Math.Min(green, blue));
                if (maximum - minimum < 24) continue;

                var hue = Hue(red, green, blue, maximum, minimum);
                if (hue < 150 || hue > 210) continue;

                var luminance = 0.2126f * red + 0.7152f * green + 0.0722f * blue;
                var color = Interpolate(
                    hue <= 177 ? OrangeStops : PurpleStops,
                    hue <= 177 ? OrangeColors : PurpleColors,
                    luminance);
                pixels[index] = (byte)color;
                pixels[index + 1] = (byte)(color >> 8);
                pixels[index + 2] = (byte)(color >> 16);
            }
        }

        Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
        result.UnlockBits(data);
        return result;
    }

    public static void SavePng(Bitmap source, string path, int size)
    {
        using (var output = new Bitmap(size, size, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(output))
        {
            graphics.SmoothingMode = SmoothingMode.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(source, new Rectangle(0, 0, size, size));
            output.Save(path, ImageFormat.Png);
        }
    }

    private static float Hue(int red, int green, int blue, int maximum, int minimum)
    {
        var delta = maximum - minimum;
        float hue;
        if (delta == 0) return 0;
        if (maximum == red)
            hue = 60f * (((float)(green - blue) / delta) % 6);
        else if (maximum == green)
            hue = 60f * (((float)(blue - red) / delta) + 2);
        else
            hue = 60f * (((float)(red - green) / delta) + 4);
        return hue < 0 ? hue + 360 : hue;
    }

    private static int Interpolate(float[] stops, int[] colors, float value)
    {
        if (value <= stops[0]) return colors[0];
        for (var i = 1; i < stops.Length; i++)
        {
            if (value > stops[i]) continue;
            var amount = (value - stops[i - 1]) / (stops[i] - stops[i - 1]);
            var left = colors[i - 1];
            var right = colors[i];
            var red = Lerp((left >> 16) & 255, (right >> 16) & 255, amount);
            var green = Lerp((left >> 8) & 255, (right >> 8) & 255, amount);
            var blue = Lerp(left & 255, right & 255, amount);
            return (red << 16) | (green << 8) | blue;
        }
        return colors[colors.Length - 1];
    }

    private static int Lerp(int from, int to, float amount)
    {
        return (int)Math.Round(from + (to - from) * amount);
    }
}
'@ -ReferencedAssemblies @('System.dll', 'System.Drawing.dll')

$appRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $PSScriptRoot 'assets\app_icon_source.png'
$source = [System.Drawing.Bitmap]::FromFile($sourcePath)
$recolored = [FermenterIconGenerator]::Recolor($source)
$source.Dispose()

try {
    $master = New-Object System.Drawing.Bitmap(1024, 1024)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($master)
        try {
            $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml('#F5EFF8'))
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $iconSize = 760
            $offset = [int](($master.Width - $iconSize) / 2)
            $graphics.DrawImage(
                $recolored,
                [System.Drawing.Rectangle]::new($offset, $offset, $iconSize, $iconSize))
        }
        finally {
            $graphics.Dispose()
        }
    }
    finally {
        $recolored.Dispose()
    }

    $androidRes = Join-Path $appRoot 'android\app\src\main\res'
    $densitySizes = @{
        'mipmap-mdpi' = @(48, 108)
        'mipmap-hdpi' = @(72, 162)
        'mipmap-xhdpi' = @(96, 216)
        'mipmap-xxhdpi' = @(144, 324)
        'mipmap-xxxhdpi' = @(192, 432)
    }
    foreach ($density in $densitySizes.Keys) {
        $directory = Join-Path $androidRes $density
        [FermenterIconGenerator]::SavePng(
            $master,
            (Join-Path $directory 'ic_launcher.png'),
            $densitySizes[$density][0])
        [FermenterIconGenerator]::SavePng(
            $master,
            (Join-Path $directory 'ic_launcher_foreground.png'),
            $densitySizes[$density][1])
    }
}
finally {
    $master.Dispose()
}
