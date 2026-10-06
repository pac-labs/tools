[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'pacdiag-report'),
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'

function Find-Python {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @{ Exe = $py.Source; PrefixArgs = @('-3') }
    }

    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return @{ Exe = $cmd.Source; PrefixArgs = @() }
        }
    }

    throw 'Python 3 was not found. Install Python 3 and run this script again.'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )

    # Windows PowerShell 5.x can turn native stderr into NativeCommandError
    # when $ErrorActionPreference is Stop. Native tools are therefore run
    # under Continue and judged by their real process exit code instead.
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        if ($Quiet) {
            & $Exe @Arguments *> $null
            $exitCode = $LASTEXITCODE
        }
        else {
            # Capture native output first so it does not become part of this
            # function's PowerShell return value. Then write it to the host.
            # Without this, assigning Invoke-Native to $pipExit captures both
            # pip's normal stdout and the numeric exit code.
            $nativeOutput = & $Exe @Arguments 2>&1
            $exitCode = $LASTEXITCODE

            if ($null -ne $nativeOutput) {
                $nativeOutput | Out-Host
            }
        }

        return [int]$exitCode
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Invoke-BasePython {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Python,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )

    $allArgs = @($Python.PrefixArgs) + @($Arguments)
    return Invoke-Native -Exe $Python.Exe -Arguments $allArgs -Quiet:$Quiet
}

$reporter = Join-Path $PSScriptRoot 'report.py'
$requirements = Join-Path $PSScriptRoot 'requirements.txt'

if (-not (Test-Path -LiteralPath $reporter)) {
    throw "report.py was not found next to run-report.ps1: $reporter"
}

$basePython = Find-Python
$venvDir = Join-Path $PSScriptRoot '.pacdiag-venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host 'Creating local PACDIAG Python environment...'
    $code = Invoke-BasePython -Python $basePython -Arguments @('-m', 'venv', $venvDir)
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
        throw 'Unable to create the local Python virtual environment.'
    }
}

# Probe for reportlab without importing it. This avoids a traceback on stderr
# when the module is not installed yet, which Windows PowerShell 5.x can treat
# as a terminating NativeCommandError.
$probeCode = "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('reportlab') else 1)"
$probeExit = Invoke-Native -Exe $venvPython -Arguments @('-c', $probeCode) -Quiet

if ($probeExit -ne 0) {
    Write-Host 'Installing PDF dependency (reportlab) into the local PACDIAG environment...'

    if (Test-Path -LiteralPath $requirements) {
        $pipExit = Invoke-Native -Exe $venvPython -Arguments @(
            '-m', 'pip', 'install', '--disable-pip-version-check', '-r', $requirements
        )
    }
    else {
        $pipExit = Invoke-Native -Exe $venvPython -Arguments @(
            '-m', 'pip', 'install', '--disable-pip-version-check', 'reportlab>=4,<5'
        )
    }

    if ($pipExit -ne 0) {
        throw "Unable to install the PDF dependency (pip exit code $pipExit)."
    }

    $probeExit = Invoke-Native -Exe $venvPython -Arguments @('-c', $probeCode) -Quiet
    if ($probeExit -ne 0) {
        throw 'reportlab still cannot be found after installation.'
    }
}

$tempInput = Join-Path ([System.IO.Path]::GetTempPath()) ("pacdiag-{0}.txt" -f ([guid]::NewGuid().ToString('N')))

try {
    Write-Host ''
    Write-Host 'PACDIAG report builder' -ForegroundColor Cyan
    Write-Host 'Paste one or more PACDIAG blocks or legacy scan.sh outputs below.'
    Write-Host 'You can paste results from any number of servers.'
    Write-Host ''
    Write-Host 'When finished, type this on a NEW line:' -ForegroundColor Yellow
    Write-Host 'PACDIAG-DONE' -ForegroundColor Green
    Write-Host ''

    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = [Console]::ReadLine()

        if ($null -eq $line) {
            break
        }

        if ($line.Trim() -eq 'PACDIAG-DONE') {
            break
        }

        $lines.Add($line)
    }

    if ($lines.Count -eq 0) {
        throw 'No diagnostic input was pasted.'
    }

    [System.IO.File]::WriteAllLines($tempInput, $lines, (New-Object System.Text.UTF8Encoding($false)))

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $reportArgs = @($reporter, $tempInput, '--output-dir', $OutputDir)
    if ($Offline) {
        $reportArgs += '--offline'
    }

    Write-Host ''
    Write-Host 'Building environment report...' -ForegroundColor Cyan
    $reportExit = Invoke-Native -Exe $venvPython -Arguments $reportArgs

    # report.py intentionally exits 1 if production-readiness blockers are found.
    # That is a diagnostic result, not a report-generation failure.
    if ($reportExit -gt 1) {
        throw "report.py failed with exit code $reportExit"
    }

    $pdf = Join-Path $OutputDir 'environment-report.pdf'
    $hardwarePdf = Join-Path $OutputDir 'hardware-report.pdf'
    $html = Join-Path $OutputDir 'environment-report.html'
    $hardwareHtml = Join-Path $OutputDir 'hardware-report.html'
    $markdown = Join-Path $OutputDir 'environment-report.md'
    $hardwareMarkdown = Join-Path $OutputDir 'hardware-report.md'
    $json = Join-Path $OutputDir 'environment-data.json'

    if (-not (Test-Path -LiteralPath $pdf)) {
        throw "The reporter completed but did not produce the expected readiness PDF: $pdf"
    }
    if (-not (Test-Path -LiteralPath $hardwarePdf)) {
        throw "The reporter completed but did not produce the expected hardware PDF: $hardwarePdf"
    }

    Write-Host ''
    Write-Host 'Reports generated successfully:' -ForegroundColor Green
    Write-Host "  Hardware PDF:  $hardwarePdf"
    Write-Host "  Readiness PDF: $pdf"
    if (Test-Path -LiteralPath $hardwareHtml) { Write-Host "  Hardware HTML: $hardwareHtml" }
    if (Test-Path -LiteralPath $html) { Write-Host "  Readiness HTML: $html" }
    if (Test-Path -LiteralPath $hardwareMarkdown) { Write-Host "  Hardware MD:   $hardwareMarkdown" }
    if (Test-Path -LiteralPath $markdown) { Write-Host "  Readiness MD:  $markdown" }
    if (Test-Path -LiteralPath $json) { Write-Host "  JSON:          $json" }

    if ($reportExit -eq 1) {
        Write-Host ''
        Write-Host 'The report contains one or more production-readiness blockers.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Opening hardware PDF...'
    Start-Process -FilePath $hardwarePdf
}
finally {
    Remove-Item -LiteralPath $tempInput -Force -ErrorAction SilentlyContinue
}
