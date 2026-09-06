$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repositoryRoot
try {
    $lua = Get-Command lua -ErrorAction SilentlyContinue
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $lua -and -not $npx) {
        throw "Tests require Lua or npx."
    }

    function Invoke-Lua {
        param([Parameter(Mandatory)][string[]]$Arguments)
        $Arguments = @("tests/run-file.lua") + $Arguments
        if ($lua) {
            & $lua.Source @Arguments
        }
        else {
            & $npx.Source --yes --package=fengari-node-cli@0.1.0 fengari @Arguments
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Lua command failed with exit code $LASTEXITCODE."
        }
    }

    Invoke-Lua -Arguments @("tests/minimum.lua")
    foreach ($regression in Get-ChildItem tests -Filter *-regression.lua | Sort-Object Name) {
        Invoke-Lua -Arguments @($regression.FullName)
    }

    $sourceFiles = @(
        Get-Item control.lua, data.lua, settings.lua
        Get-ChildItem prototypes, runtime -Filter *.lua -Recurse
    ) | Sort-Object FullName
    Invoke-Lua -Arguments (@("tests/check-syntax.lua") + @($sourceFiles.FullName))

    function Get-LocaleKeys([string]$Path) {
        $section = ""
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\[(.+)\]$') {
                $section = $Matches[1]
            }
            elseif ($line -match '^([^;][^=]*)=') {
                "$section.$($Matches[1])"
            }
        }
    }

    $englishKeys = @(Get-LocaleKeys "locale/en/locale.cfg" | Sort-Object -Unique)
    $frenchKeys = @(Get-LocaleKeys "locale/fr/locale.cfg" | Sort-Object -Unique)
    $localeDifference = @(Compare-Object $englishKeys $frenchKeys)
    if ($localeDifference.Count -ne 0) {
        throw "English/French locale key parity failed."
    }

    Write-Host "Locale key parity passed ($($englishKeys.Count) keys per language)"
}
finally {
    Pop-Location
}
