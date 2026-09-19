# Create the Apple iOS distribution certificate material, on Windows, without a Mac.
#
#   .\tool\make_ios_cert.ps1 -Step csr          run FIRST, gives you a .csr to upload to Apple
#   .\tool\make_ios_cert.ps1 -Step p12          run AFTER, turns Apple's .cer into a .p12
#
# Everything is written to tool/ios_signing/, which is git-ignored. NOTHING here is ever printed to
# a console log or committed: the whole point is that the private key stays on this machine. The
# workflow that used to generate this inside GitHub Actions wrote the key into a public build log.
#
# Requires nothing but XAMPP's OpenSSL, which is already on this machine.

param(
    [Parameter(Mandatory = $true)][ValidateSet('csr', 'p12')][string]$Step,
    [string]$Email    = 'jbharwana34@icloud.com',
    [string]$CommonName = 'Smart Step Transportation',
    [string]$Country  = 'QA',
    [string]$OpenSsl  = 'F:\xampp\apache\bin\openssl.exe'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OpenSsl)) { throw "OpenSSL not found at $OpenSsl. Pass -OpenSsl <path>." }

# XAMPP's openssl.exe is compiled to look for its config at a path that does not exist here, so
# `openssl req` fails with a confusing error unless this is set explicitly.
$cnf = Join-Path (Split-Path (Split-Path $OpenSsl)) 'conf\openssl.cnf'
if (Test-Path $cnf) { $env:OPENSSL_CONF = $cnf }

$dir = Join-Path $PSScriptRoot 'ios_signing'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$key = Join-Path $dir 'ios_distribution.key'
$csr = Join-Path $dir 'ios_distribution.csr'
$cer = Join-Path $dir 'distribution.cer'
$pem = Join-Path $dir 'distribution.pem'
$p12 = Join-Path $dir 'ios_distribution.p12'

if ($Step -eq 'csr') {
    if (Test-Path $key) {
        Write-Host "A private key already exists at $key." -ForegroundColor Yellow
        Write-Host "Delete it only if you intend to start over - the certificate Apple issued for" -ForegroundColor Yellow
        Write-Host "the old key stops working the moment you do." -ForegroundColor Yellow
        $ans = Read-Host "Type REPLACE to overwrite, anything else to stop"
        if ($ans -ne 'REPLACE') { Write-Host 'Stopped. Nothing changed.'; exit }
    }

    & $OpenSsl genrsa -out $key 2048 2>&1 | Out-Null
    & $OpenSsl req -new -key $key -out $csr -subj "/emailAddress=$Email/CN=$CommonName/C=$Country" 2>&1 | Out-Null
    if (-not (Test-Path $csr)) { throw 'CSR generation failed.' }

    Write-Host ''
    Write-Host 'Created:' -ForegroundColor Green
    Write-Host "  private key : $key   <-- never share, never commit, back this up"
    Write-Host "  request     : $csr   <-- this is the file Apple wants"
    Write-Host ''
    Write-Host 'Next:'
    Write-Host '  1. https://developer.apple.com/account/resources/certificates/add'
    Write-Host '  2. Choose "Apple Distribution", upload the .csr above'
    Write-Host '  3. Download the .cer Apple gives you, save it as:'
    Write-Host "       $cer"
    Write-Host '  4. Run:  .\tool\make_ios_cert.ps1 -Step p12'
    exit
}

# ---- p12 ---------------------------------------------------------------------------------------
if (-not (Test-Path $key)) { throw "Private key missing at $key. Run -Step csr first." }
if (-not (Test-Path $cer)) { throw "Apple's certificate not found at $cer. Download it and save it there." }

# Apple ships DER; the bundling step needs PEM.
& $OpenSsl x509 -inform DER -in $cer -out $pem 2>&1 | Out-Null
if (-not (Test-Path $pem)) {
    # Some downloads are already PEM. Try that before giving up.
    Copy-Item $cer $pem -Force
}

$pw = Read-Host 'Choose a password for the .p12 (you will store this as a GitHub secret)' -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
if ([string]::IsNullOrWhiteSpace($plain)) { throw 'An empty password will not import on the runner.' }

# -keypbe / -certpbe / -macalg pin the older algorithms. OpenSSL 3 defaults to AES-256 with PBKDF2,
# which some macOS runner images refuse to import with a misleading "MAC verification failed".
# Note there is deliberately no -legacy flag: this OpenSSL build has no legacy provider DLL, and
# passing it fails outright.
& $OpenSsl pkcs12 -export -out $p12 -inkey $key -in $pem `
    -name 'Smart Step Distribution' `
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 `
    -passout "pass:$plain" 2>&1 | Out-Null

if (-not (Test-Path $p12)) { throw 'p12 export failed.' }

# Prove it opens before handing it over.
& $OpenSsl pkcs12 -in $p12 -passin "pass:$plain" -nokeys -clcerts -noout 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The .p12 was written but will not open with that password.' }

$b64Path = Join-Path $dir 'p12_base64.txt'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($p12)) |
    Set-Content -Path $b64Path -NoNewline -Encoding ascii

Write-Host ''
Write-Host 'Created and verified:' -ForegroundColor Green
Write-Host "  certificate : $p12"
Write-Host "  base64      : $b64Path  ($((Get-Item $b64Path).Length) chars, one line)"
Write-Host ''
Write-Host 'Add these GitHub secrets (Settings -> Secrets and variables -> Actions):'
Write-Host '  IOS_DIST_CERT_P12_BASE64   = the entire contents of p12_base64.txt'
Write-Host '  IOS_DIST_CERT_PASSWORD     = the password you just chose'
Write-Host '  IOS_PROVISIONING_PROFILE_BASE64 = base64 of your .mobileprovision (see below)'
Write-Host '  IOS_TEAM_ID                = your 10-character Team ID'
Write-Host ''
Write-Host 'To base64 the provisioning profile once you have downloaded it:'
Write-Host '  [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\profile.mobileprovision")) | Set-Content profile_b64.txt -NoNewline'
Write-Host ''
Write-Host 'Keep tool/ios_signing/ off GitHub. It is git-ignored already - do not force-add it.' -ForegroundColor Yellow
