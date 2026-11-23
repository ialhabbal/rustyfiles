$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$version = '1.2.161'
$publish = Join-Path ([System.IO.Path]::GetTempPath()) "rustyfiles-publish-$([guid]::NewGuid().ToString('N'))"
$output = Join-Path $root 'Releases'

Push-Location $root
try {
    $cargo = Get-Command cargo -CommandType Application -ErrorAction Stop
    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop

    $tools = & $dotnet.Source tool list --global
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list global .NET tools (exit code $LASTEXITCODE)."
    }

    $vpkLine = $tools | Where-Object { $_ -match '^\s*vpk\s+' } | Select-Object -First 1
    if ($vpkLine -and $vpkLine -match '^\s*vpk\s+(\S+)') {
        if ($Matches[1] -ne $version) {
            & $dotnet.Source tool update --global vpk --version $version
            if ($LASTEXITCODE -ne 0) {
                throw "Could not update vpk to version $version (exit code $LASTEXITCODE)."
            }
        }
    } else {
        & $dotnet.Source tool install --global vpk --version $version
        if ($LASTEXITCODE -ne 0) {
            throw "Could not install vpk version $version (exit code $LASTEXITCODE)."
        }
    }

    $vpkCommand = Get-Command vpk -CommandType Application -ErrorAction SilentlyContinue
    if ($vpkCommand) {
        $vpk = $vpkCommand.Source
    } else {
        $vpk = Join-Path $env:USERPROFILE '.dotnet\tools\vpk.exe'
        if (-not (Test-Path -LiteralPath $vpk -PathType Leaf)) {
            throw "vpk was installed, but its executable was not found at $vpk."
        }
    }

    $metadataLines = & $cargo.Source '+stable' metadata --no-deps --format-version 1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Cargo package metadata (exit code $LASTEXITCODE)."
    }
    $metadata = ($metadataLines -join [Environment]::NewLine) | ConvertFrom-Json
    $appPackage = $metadata.packages | Where-Object { $_.name -eq 'rf-app' } | Select-Object -First 1
    if (-not $appPackage) {
        throw 'Cargo metadata does not contain the rf-app package.'
    }

    Write-Host "Building rustyfiles $($appPackage.version)..."
    & $cargo.Source '+stable' build --release --locked -p rf-app -p rf-dialog -p rf-shellguard
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed (exit code $LASTEXITCODE)."
    }

    New-Item -ItemType Directory -Path $publish -Force | Out-Null
    $files = @(
        'rustyfiles.exe',
        'directlook.exe',
        'rustyfiles-shellguard.exe',
        'rustyfiles_dialog.dll',
        'LICENSE'
    )
    foreach ($file in $files) {
        $source = if ($file -eq 'LICENSE') {
            Join-Path $root $file
        } else {
            Join-Path $root "target\release\$file"
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required package file not found: $source"
        }
        Copy-Item -LiteralPath $source -Destination $publish
    }

    New-Item -ItemType Directory -Path $output -Force | Out-Null
    & $vpk pack -u rustyfiles -v $appPackage.version -p $publish -e rustyfiles.exe `
        --packTitle rustyfiles --packAuthors 'Özer Güzel' `
        -i (Join-Path $root 'crates\rf-app\assets\rustyfiles.ico') `
        -s (Join-Path $root 'crates\rf-app\assets\splash.gif') `
        --splashProgressColor '#ff6a1a' --runtime win-x64 -o $output
    if ($LASTEXITCODE -ne 0) {
        throw "vpk pack failed (exit code $LASTEXITCODE)."
    }

    $setup = Join-Path $output 'rustyfiles-win-Setup.exe'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        throw "vpk pack completed but the expected installer was not created: $setup"
    }
    Write-Host "Installer created: $setup"
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $publish) {
        Remove-Item -LiteralPath $publish -Recurse -Force
    }
}
